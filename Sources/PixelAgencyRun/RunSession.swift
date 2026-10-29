import Foundation
import ImageIO
import MESClientKit
import MESCore
import MESFormsUI
import Observation
import UniformTypeIdentifiers

/// A media input: a file on this Mac, dropped, pasted, opened, or a previous result (LITE-5, LITE-12).
public struct MediaItem: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public var file: URL
    public var mediaType: String
    public var name: String
    public var width: Int?
    public var height: Int?

    public init(file: URL, mediaType: String? = nil, name: String? = nil) {
        self.file = file
        self.mediaType = mediaType ?? MediaType.infer(file)
        self.name = name ?? file.lastPathComponent
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let w = props[kCGImagePropertyPixelWidth] as? Int, h = props[kCGImagePropertyPixelHeight] as? Int
            let rotated = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            width = rotated ? h : w
            height = rotated ? w : h
        }
    }
}

/// One output, collected: the file on this Mac and the job that made it.
public struct RunResult: Identifiable, Sendable, Hashable {
    public var id: String { "\(job.id)-\(output.index)" }
    public let output: Output
    /// In the session's folder until saved; deleted when the session ends (LITE-11).
    public let file: URL
    public let job: Job

    /// What happened (LITE-8): the model and its licence, the effective parameters, warnings and any remote provider.
    public var provenance: Provenance? { job.result?.provenance }
    public var effective: [String: JSONValue] { job.result?.effective ?? [:] }
    public var isImage: Bool { output.kind == .image || output.kind == .mask }

    public static func == (a: RunResult, b: RunResult) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public init(output: Output, file: URL, job: Job) {
        self.output = output
        self.file = file
        self.job = job
    }

    /// Use this result as the next operation's input (LITE-12), without saving it.
    public var asInput: MediaItem { MediaItem(file: file, mediaType: output.mediaType, name: "\(job.operation) result") }
}

/// Runs a session's job somewhere other than in the session itself. Pixel Agency Desktop runs each as a durable
/// ticket (Desktop-PRD RUN-5) that stores the results in its library before confirming them; the executor reports the
/// run's progress and results back through the session's `report` methods, so the views show it as they show any
/// run. Lite has none: a session runs its own job.
@MainActor
public protocol RunExecutor: AnyObject {
    func execute(_ session: RunSession) async
    func cancel(_ session: RunSession) async
}

/// One run of one operation (LITE-4, LITE-6–8): the inputs, the controls (from the descriptor), the job while it runs,
/// and its results. Lite keeps no custody: results are downloaded, checked against their SHA-256, and confirmed at
/// once, so the engine purges them (Base §13); they then live in the session's folder until saved or the app quits.
@MainActor @Observable
public final class RunSession: Identifiable {
    public enum Phase: Equatable, Sendable {
        case editing
        /// Sending inputs and the request.
        case submitting
        /// The job's state and progress, as the engine reports them.
        case running(state: JobState, stage: Stage?, fraction: Double?, message: String?)
        case collecting
        case finished
        case failed(String)
        case cancelled

        public var isActive: Bool {
            switch self {
            case .submitting, .running, .collecting: true
            default: false
            }
        }
    }

    public let id = UUID()
    public let engine: any EngineConnection
    public let engineInfo: EngineInfo
    public let descriptor: Descriptor
    /// The controls: parameters, model choice, policy and extensions, all from the descriptor (MESFormsUI).
    public let form: OperationFormModel
    /// Media inputs by input name.
    public var media: [String: [MediaItem]] = [:]
    /// Data inputs by input name (e.g. `image.segment`'s `points`), sent inline as JSON (Base §8).
    public var data: [String: JSONValue] = [:]
    public private(set) var phase: Phase = .editing
    public private(set) var job: Job?
    /// The latest preview the engine sent while running (`job.preview`), as image bytes.
    public private(set) var preview: Data?
    public private(set) var results: [RunResult] = []
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    let folder: URL
    private var task: Task<Void, Never>?
    /// Where the job runs; nil runs it here. Set before `start`.
    public weak var executor: (any RunExecutor)?

    /// - Parameter folder: where collected outputs go until saved (the session log's folder).
    public init(engine: any EngineConnection, engineInfo: EngineInfo, descriptor: Descriptor, folder: URL) {
        self.engine = engine
        self.engineInfo = engineInfo
        self.descriptor = descriptor
        self.form = OperationFormModel(descriptor: descriptor)
        self.folder = folder
    }

    /// Required inputs not yet given.
    public var missingInputs: [InputSpec] {
        form.missingInputs(media: Set(media.filter { !$0.value.isEmpty }.keys).union(data.keys))
    }

    public var canRun: Bool { !phase.isActive && missingInputs.isEmpty && form.issues.isEmpty }

    /// The request as it would be sent, with media shown as placeholders (for "show request" views).
    public var draftRequest: JobRequest {
        var inputs: [String: RequestInput] = media.mapValues { items in
            items.count == 1 ? .one(.upload("<\(items[0].name)>")) : .many(items.map { .upload("<\($0.name)>") })
        }
        for (name, value) in data { inputs[name] = .one(.data(value)) }
        return form.request(media: inputs)
    }

    // MARK: - Running

    /// Starts the run in the background; `phase` follows it.
    public func start() {
        guard !phase.isActive else { return }
        if let executor {
            task = Task { await executor.execute(self) }
        } else {
            task = Task { await run() }
        }
    }

    // MARK: - Reporting (for executors)

    /// What the run is doing now. Starting stamps `startedAt`; an end stamps `finishedAt`.
    public func report(_ phase: Phase) {
        if phase == .submitting {
            startedAt = Date()
            finishedAt = nil
            results = []
            preview = nil
        }
        self.phase = phase
        switch phase {
        case .finished, .failed, .cancelled: finishedAt = Date()
        default: break
        }
    }

    public func report(job: Job) { self.job = job }
    public func report(preview: Data) { self.preview = preview }
    public func report(results: [RunResult]) { self.results = results }

    /// Runs to the end. Never throws: the outcome is in `phase`.
    public func run() async {
        phase = .submitting
        startedAt = Date()
        results = []
        preview = nil
        do {
            // 1. Inputs: inline when small, uploaded otherwise (Base §8). Lite never serves grants.
            var inputs: [String: RequestInput] = [:]
            for (name, items) in media where !items.isEmpty {
                var values: [InputValue] = []
                for item in items {
                    values.append(try await engine.input(contentsOf: item.file, mediaType: item.mediaType,
                                                         inlineLimit: engineInfo.limits.maxInlineBytes))
                }
                inputs[name] = values.count == 1 ? .one(values[0]) : .many(values)
            }
            for (name, value) in data { inputs[name] = .one(.data(value)) }
            // 2. Submit (Base §7.1) with an idempotency key, so a retry after `busy` can't make a second job.
            let submitted = try await engine.submit(form.request(media: inputs), idempotencyKey: UUID().uuidString)
            job = submitted
            phase = .running(state: submitted.state, stage: nil, fraction: nil, message: nil)
            // 3. Follow its events (Base §11) until it holds its outputs or ends.
            if submitted.state != .holding && submitted.state != .purged {
                for try await event in engine.events(job: submitted.id, after: 0) {
                    apply(event)
                    if event.type == .outputReady || event.type == .ended { break }
                }
            }
            let final = try await engine.job(submitted.id, wait: 0)
            job = final
            // 4. Collect and confirm, or report how it ended.
            switch final.outcome {
            case .succeeded? where final.state == .holding:
                phase = .collecting
                results = try await collect(final)
                job = try await engine.confirm(final.id)
                phase = .finished
            case .cancelled?:
                phase = .cancelled
            case .failed?:
                phase = .failed(final.error.map { "\($0.message) (\($0.code))" } ?? "The job failed.")
            case .expired?:
                phase = .failed("The outputs expired before they were collected.")
            default:
                phase = .failed("The job ended \(final.state.rawValue) without outputs.")
            }
        } catch is CancellationError {
            phase = .cancelled
        } catch {
            phase = Task.isCancelled ? .cancelled : .failed("\(error)")
        }
        finishedAt = Date()
    }

    /// Cancels the run: releases the job on the engine (Base §7.3), which ends it `cancelled`.
    public func cancel() async {
        if let executor {
            await executor.cancel(self)
            return
        }
        if let job, job.state != .purged { _ = try? await engine.release(job.id) }
        task?.cancel()
        if phase.isActive || phase == .editing { phase = .cancelled }
    }

    /// Updates the phase, preview and warnings from one job event (Base §11).
    public func apply(_ event: Event) {
        switch event.type {
        case .state:
            let state = event.data["state"]?.stringValue.flatMap(JobState.init(rawValue:)) ?? .running
            if case .running(_, let stage, let fraction, let message) = phase {
                phase = .running(state: state, stage: stage, fraction: fraction, message: message)
            }
        case .progress:
            let progress = try? event.data.decode(as: JobProgress.self)
            if case .running(let state, _, _, _) = phase {
                phase = .running(state: state, stage: progress?.stage, fraction: progress?.fraction, message: progress?.message)
            }
        case .preview:
            if let base64 = event.data["data"]?.stringValue, let data = Data(base64Encoded: base64) { preview = data }
        case .warning:
            if let warning = try? event.data.decode(as: Warning.self), var current = job, !current.warnings.contains(warning) {
                current.warnings.append(warning)
                job = current
            }
        default:
            break
        }
    }

    /// Downloads every output into the session folder, checked against its SHA-256.
    func collect(_ job: Job) async throws -> [RunResult] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var collected: [RunResult] = []
        for output in job.result?.outputs ?? [] {
            let name = "\(job.id)-\(output.index).\(MediaType.fileExtension(output.mediaType))"
            let file = try await engine.download(job: job.id, output: output, to: folder.appendingPathComponent(name))
            collected.append(RunResult(output: output, file: file, job: job))
        }
        return collected
    }
}
