import AVFoundation
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
    /// Audio facts (Audio §1.1): read from the file, or a result's own (Base §10.1). A video's sound has them too.
    public var durationSeconds: Double?
    public var sampleRate: Int?
    public var channels: Int?
    /// Video facts (Video §1.1): the rate and the frame count, read from the file or a result's own.
    public var fps: Double?
    public var frames: Int?

    /// Images are probed for their size and audio for its duration, rate and channels; nothing else is read. A video
    /// isn't probed here: `reading(_:)` reads its facts.
    public init(file: URL, mediaType: String? = nil, name: String? = nil) {
        self.file = file
        self.mediaType = mediaType ?? MediaType.infer(file)
        self.name = name ?? file.lastPathComponent
        if isVideo { return }
        if isAudio {
            if let audio = try? AVAudioFile(forReading: file) {
                let format = audio.fileFormat
                sampleRate = Int(format.sampleRate)
                channels = Int(format.channelCount)
                durationSeconds = format.sampleRate > 0 ? Double(audio.length) / format.sampleRate : nil
            }
        } else if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let w = props[kCGImagePropertyPixelWidth] as? Int, h = props[kCGImagePropertyPixelHeight] as? Int
            let rotated = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            width = rotated ? h : w
            height = rotated ? w : h
        }
    }

    /// A file as an input with its facts: a video's size, rate, frames, duration and sound read with AVFoundation
    /// (`VideoFacts.read`), anything else as `init(file:)` probes it. A video that can't be read keeps no facts.
    public static func reading(_ file: URL, mediaType: String? = nil, name: String? = nil) async -> MediaItem {
        var item = MediaItem(file: file, mediaType: mediaType, name: name)
        if item.isVideo, let facts = try? await VideoFacts.read(file) { item.videoFacts = facts }
        return item
    }

    /// An output as an input: its facts come from the engine (Base §10.1), so the file isn't probed.
    public init(file: URL, output: Output, name: String) {
        self.file = file
        self.mediaType = output.mediaType
        self.name = name
        width = output.width
        height = output.height
        durationSeconds = output.durationSeconds
        sampleRate = output.sampleRate
        channels = output.channels
        fps = output.fps
        frames = output.frames
    }

    public var isAudio: Bool { mediaType.hasPrefix("audio/") }
    public var isVideo: Bool { mediaType.hasPrefix("video/") }
    /// The kind of input slot this item fills: `audio` for sound, `video` for clips, `image` for everything else
    /// (masks are images).
    public var kind: Kind { isAudio ? .audio : isVideo ? .video : .image }

    /// A video's facts, when known: "1280×704 · 24 fps · 121 frames · 5.04 s · sound 48 kHz stereo".
    public var videoFacts: VideoFacts? {
        get {
            guard isVideo, let width, let height, let fps else { return nil }
            return VideoFacts(width: width, height: height, fps: fps, frames: frames,
                              durationSeconds: durationSeconds ?? frames.map { Double($0) / fps } ?? 0,
                              sampleRate: sampleRate, channels: channels)
        }
        set {
            width = newValue?.width; height = newValue?.height; fps = newValue?.fps; frames = newValue?.frames
            durationSeconds = newValue?.durationSeconds; sampleRate = newValue?.sampleRate; channels = newValue?.channels
        }
    }
}

/// Audio facts for people: "0:03 · 24 kHz · mono".
public enum AudioFacts {
    public static func line(duration: Double?, sampleRate: Int?, channels: Int?) -> String? {
        var parts: [String] = []
        if let duration {
            let s = Int(duration.rounded(.down))
            parts.append(duration < 10 ? String(format: "%.1f s", duration) : String(format: "%d:%02d", s / 60, s % 60))
        }
        if let rate = sampleRate {
            parts.append(rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.2f kHz", Double(rate) / 1000))
        }
        if let channels { parts.append(channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) channels") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    public var isAudio: Bool { output.kind == .audio }
    public var isVideo: Bool { output.kind == .video }
    /// Data and text outputs (edit_speech's `transcript`, compose's `timestamps` and `score`), shown as text.
    public var isText: Bool { output.kind == .data || output.kind == .text }
    /// Duration, rate and channels, from the output's facts (Base §10.1).
    public var audioFacts: String? {
        AudioFacts.line(duration: output.durationSeconds, sampleRate: output.sampleRate, channels: output.channels)
    }
    /// A video's size, rate, frames, duration and sound, from the output's facts (Base §10.1); nil for other outputs.
    public var videoFacts: VideoFacts? { isVideo ? VideoFacts(output: output) : nil }

    public static func == (a: RunResult, b: RunResult) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public init(output: Output, file: URL, job: Job) {
        self.output = output
        self.file = file
        self.job = job
    }

    /// Use this result as the next operation's input (LITE-12), without saving it.
    public var asInput: MediaItem {
        isAudio || isVideo ? MediaItem(file: file, output: output, name: "\(job.operation) result")
            : MediaItem(file: file, mediaType: output.mediaType, name: "\(job.operation) result")
    }

    /// A data output's value: inline in the result, else the collected file's JSON.
    public var value: JSONValue? {
        output.value ?? (try? MESJSON.decoder.decode(JSONValue.self, from: Data(contentsOf: file)))
    }

    /// The output as text for people. A transcript (`{text}`) is its text; timed lines (`{lines: [{text, start_s,
    /// end_s}]}`) one per line with their times; a text output its contents; any other data its JSON.
    public var text: String {
        if output.kind == .text { return (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
        guard let value else { return "" }
        if let text = value["text"]?.stringValue, value.objectValue?.count == 1 { return text }
        if let lines = value["lines"]?.arrayValue, value.objectValue?.count == 1 {
            return lines.map { line in
                let at = [line["start_s"], line["end_s"]].compactMap { $0?.numberValue }.map { String(format: "%.1f", $0) }
                return (at.isEmpty ? "" : "[\(at.joined(separator: "–")) s] ") + (line["text"]?.stringValue ?? FormSchema.display(line))
            }.joined(separator: "\n")
        }
        return Self.json(value)
    }

    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? ""
    }
}

/// A streamed output while it arrives (Base §11): its format, how much has come, and how soon the first chunk did.
public struct StreamedOutput: Sendable, Equatable {
    public var output: String
    /// The stream's format from the plan (§7.2).
    public var format: StreamPlan?
    public var chunks = 0
    public var bytes = 0
    /// From sending the request to the first chunk.
    public var firstChunkAfter: TimeInterval?
    /// The final chunk has arrived.
    public var finished = false

    /// Seconds of sound received.
    public var seconds: Double {
        guard let format, format.frameBytes > 0, format.sampleRate > 0 else { return 0 }
        return Double(bytes / format.frameBytes) / Double(format.sampleRate)
    }
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
    /// The stills of a video output the engine sent while running (`job.preview` with `at_s`, Video §1.14), in time
    /// order. `preview` still holds the latest of them.
    public let framePreviews = FramePreviews()
    /// The licences whose terms the engine wouldn't run without (422 `policy_unmet`, reason `terms_not_accepted`,
    /// Base §10.3): the run needs its user's acceptance, not a fix.
    public private(set) var refusedTerms: [License] = []
    public private(set) var results: [RunResult] = []
    /// The output streaming while the job runs (Base §11), when the run asked for a stream.
    public private(set) var streamed: StreamedOutput?
    /// Called on each chunk of a streamed output as it arrives, in order (pa-run writes them; views use `chunks()`).
    public var onChunk: (@MainActor (OutputChunk) -> Void)?
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    /// When the request went to the engine (after the inputs were sent).
    public private(set) var submittedAt: Date?
    let folder: URL
    private var task: Task<Void, Never>?
    /// This run's chunks so far, for listeners that join late; dropped when the run ends.
    private var received: [OutputChunk] = []
    private var listeners: [UUID: AsyncStream<OutputChunk>.Continuation] = [:]
    /// `cancel()` was called: chunks still in flight are dropped.
    private var released = false
    /// Where the job runs; nil runs it here. Set before `start`.
    public weak var executor: (any RunExecutor)?

    /// - Parameter folder: where collected outputs go until saved (the session log's folder).
    public init(engine: any EngineConnection, engineInfo: EngineInfo, descriptor: Descriptor, folder: URL) {
        self.engine = engine
        self.engineInfo = engineInfo
        self.descriptor = descriptor
        self.form = OperationFormModel(descriptor: descriptor)
        self.folder = folder
        // The `voice` widget picks from the engine's voice lists, with samples (Base §6.5).
        form.voiceSource = VoiceSource(engine: engine)
        streamByDefault()
    }

    /// Streaming is on by default where the model that will run offers it (§6.4 `supports.stream`): the chosen model,
    /// or with none chosen the descriptor's default. Called again when the model changes.
    public func streamByDefault() {
        form.stream = !form.streamableOutputs.isEmpty && form.effectiveModel?.streams == true
    }

    /// Required inputs not yet given.
    public var missingInputs: [InputSpec] {
        form.missingInputs(media: Set(media.filter { !$0.value.isEmpty }.keys).union(data.keys))
    }

    public var canRun: Bool { !phase.isActive && missingInputs.isEmpty && form.issues.isEmpty }

    // MARK: - Users' acceptance (Base §10.2 rule 4, §10.3)

    /// This user's acceptances: the form sends every accepted licence of the operation's offers in `policy.accepted`.
    /// A workflow gives each run its own, kept across launches; a lone session keeps them in memory.
    public var acceptances: LicenseAcceptances {
        get { form.acceptances }
        set { form.acceptances = newValue }
    }

    /// The licences to show, with Accept, before this run can go: the chosen offer's, and any the engine refused, that
    /// this user hasn't accepted yet.
    public var needsAcceptance: [License] {
        var seen = Set<String>()
        return ([form.pendingAcceptance].compactMap { $0 } + refusedTerms)
            .filter { !acceptances.isAccepted($0) && seen.insert($0.spdx).inserted }
    }

    /// Whether an engine's answer refuses the run for terms its user hasn't accepted (Base §10.3).
    public static func refusesTerms(_ error: any Error) -> Bool {
        if case .engine(let e, _, _)? = error as? MESClientError { return refusesTerms(e) }
        return (error as? MESError).map(refusesTerms) ?? false
    }

    public static func refusesTerms(_ error: MESError) -> Bool {
        error.code == MESErrorCode.policyUnmet.rawValue && error.reason == Policy.termsNotAcceptedReason
    }

    /// The licences a terms refusal is about: those the error names, else every one of this operation's offers' that
    /// this user hasn't accepted.
    func termsRefused(by error: MESError) -> [License] {
        let unaccepted = form.licencesNeedingAcceptance.filter { !acceptances.isAccepted($0) }
        let named = unaccepted.filter { error.message.contains($0.spdx) }
        return named.isEmpty ? unaccepted : named
    }

    /// The run failed: a terms refusal is kept in `refusedTerms` and said as such; anything else is `otherwise`, or the
    /// error's message and code.
    func fail(_ error: MESError, otherwise: String? = nil) {
        if Self.refusesTerms(error) {
            refusedTerms = termsRefused(by: error)
            let spdx = refusedTerms.map(\.spdx).joined(separator: ", ")
            phase = .failed("Accept \(spdx.isEmpty ? "the model's terms" : "the terms of \(spdx)") to run this. The engine runs it only "
                            + "for people who have accepted them (\(error.code), \(error.reason ?? "")).")
        } else {
            phase = .failed(otherwise ?? "\(error.message) (\(error.code))")
        }
    }
    /// The request as it would be sent, with media shown as placeholders (for "show request" views).
    public var draftRequest: JobRequest {
        var inputs: [String: RequestInput] = media.mapValues { items in
            items.count == 1 ? .one(.upload("<\(items[0].name)>")) : .many(items.map { .upload("<\($0.name)>") })
        }
        for (name, value) in data { inputs[name] = .one(.data(value)) }
        return request(media: inputs)
    }

    /// The form's request, with each stream asked for as `pcm_s16le` where its output offers it (§7.1).
    func request(media: [String: RequestInput]) -> JobRequest {
        var request = form.request(media: media)
        request.stream = request.stream?.map { asked in
            let offered = descriptor.outputs.first { $0.name == asked.output }?.stream?.encodings ?? []
            return StreamRequest(output: asked.output, encoding: offered.contains(.pcmS16LE) ? .pcmS16LE : asked.encoding)
        }
        return request
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
            released = false
            startedAt = Date()
            finishedAt = nil
            results = []
            preview = nil
            framePreviews.reset()
            refusedTerms = []
            streamed = nil
            received = []
        }
        self.phase = phase
        switch phase {
        case .finished, .failed, .cancelled:
            finishedAt = Date()
            endStreams()
        default: break
        }
    }

    public func report(job: Job) { self.job = job }

    /// The run failed with `error`: a terms refusal (422 `policy_unmet`, `terms_not_accepted`) is shown as needing
    /// acceptance, with `refusedTerms`; anything else as the error.
    public func report(failure error: any Error) {
        switch error {
        case MESClientError.engine(let e, _, _): fail(e, otherwise: "\(error)")
        case let e as MESError: fail(e)
        default: phase = .failed("\(error)")
        }
        if !phase.isActive { finishedAt = Date(); endStreams() }
    }
    public func report(preview: Data) { self.preview = preview }
    public func report(results: [RunResult]) { self.results = results }

    /// One chunk of a streamed output (Base §11), in order: kept for late listeners and passed on.
    public func report(chunk: OutputChunk) {
        guard phase.isActive, !released else { return }            // released: nothing more is passed on (barge-in)
        var s = streamed?.output == chunk.output ? streamed! : StreamedOutput(output: chunk.output)
        if s.chunks == 0, let startedAt = submittedAt ?? startedAt { s.firstChunkAfter = Date().timeIntervalSince(startedAt) }
        s.format = chunk.format ?? s.format
        s.chunks += 1
        s.bytes += chunk.samples?.count ?? 0
        s.finished = chunk.final
        streamed = s
        received.append(chunk)
        onChunk?(chunk)
        for listener in listeners.values { listener.yield(chunk) }
        if chunk.final { endStreams() }
    }

    /// The streamed output's chunks: those already received, then each as it arrives, until the final one or the run
    /// ends. A run that has ended has none.
    public func chunks() -> AsyncStream<OutputChunk> {
        let (stream, continuation) = AsyncStream<OutputChunk>.makeStream()
        switch phase {
        case .finished, .failed, .cancelled:
            continuation.finish()
            return stream
        default: break
        }
        for chunk in received { continuation.yield(chunk) }
        if received.last?.final == true {
            continuation.finish()
            return stream
        }
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[id] = nil } }
        return stream
    }

    /// No more chunks: listeners finish, and what was kept for them goes.
    private func endStreams() {
        for listener in listeners.values { listener.finish() }
        listeners = [:]
        received = []
    }

    /// Runs to the end. Never throws: the outcome is in `phase`.
    public func run() async {
        phase = .submitting
        startedAt = Date()
        submittedAt = nil
        released = false
        results = []
        preview = nil
        framePreviews.reset()
        refusedTerms = []
        streamed = nil
        received = []
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
            let request = request(media: inputs)
            submittedAt = Date()
            let submitted = try await engine.submit(request, idempotencyKey: UUID().uuidString)
            job = submitted
            phase = .running(state: submitted.state, stage: nil, fraction: nil, message: nil)
            // 3. Follow its events (Base §11) until it holds its outputs or ends; a streamed output's chunks come
            //    with them, in order and once (MESClientKit's ChunkReader). The finished file is still collected.
            if submitted.state != .holding && submitted.state != .purged {
                var reader = ChunkReader(job: submitted.id, plans: submitted.plan?.streams ?? [])
                do {
                    for try await event in engine.events(job: submitted.id, after: 0) {
                        apply(event)
                        if request.stream != nil, let chunk = try reader.read(event) { report(chunk: chunk) }
                        if event.type == .outputReady || event.type == .ended { break }
                    }
                } catch is StreamIncomplete {
                    // The job ended without the stream's final chunk (§11 rule 5): its outcome says why.
                }
                endStreams()
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
                if let error = final.error { fail(error) } else { phase = .failed("The job failed.") }
            case .expired?:
                phase = .failed("The outputs expired before they were collected.")
            default:
                phase = .failed("The job ended \(final.state.rawValue) without outputs.")
            }
        } catch is CancellationError {
            phase = .cancelled
        } catch let error as MESClientError where !Task.isCancelled && Self.refusesTerms(error) {
            report(failure: error)
        } catch {
            phase = Task.isCancelled ? .cancelled : .failed("\(error)")
        }
        finishedAt = Date()
        endStreams()
    }

    /// Cancels the run: releases the job on the engine (Base §7.3), which ends it `cancelled`.
    ///
    /// A streaming run stops at once on this side (no chunk after this one is passed on) and on the engine within a
    /// chunk, since releasing cancels the job between chunks (barge-in, §11).
    public func cancel() async {
        released = true
        endStreams()
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
            framePreviews.ingest(event)                              // a still of a video, with its moment
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
