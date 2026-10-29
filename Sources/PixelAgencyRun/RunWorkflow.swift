import Foundation
import MESClientKit
import MESCore
import MESFormsUI
import Observation

/// The run workflow (LITE-16): an engine, one of its operations, the current run, and the session's runs. Lite's
/// window is this plus views; Desktop embeds the same thing.
@MainActor @Observable
public final class RunWorkflow {
    public let directory: EngineDirectory
    public let log: SessionLog

    public private(set) var engine: EngineEntry?
    public private(set) var info: EngineInfo?
    public private(set) var operations: [Descriptor] = []
    /// The run being edited, running, or showing its results.
    public private(set) var current: RunSession?
    /// Why the engine can't be used right now (unreachable, needs pairing, …).
    public private(set) var problem: String?
    public private(set) var isConnecting = false

    /// A pairing in progress (Base §5): its code is on screen until the engine's operator answers.
    public private(set) var pairing: Pairing?
    public private(set) var pairingProblem: String?

    /// New runs start with "commercial-use models only" on or off (LITE-9; off by default in Lite, OQ-3).
    public var commercialOnlyByDefault = false
    /// The MES profiles whose operations this client offers; nil offers every profile (Lite). Desktop sets
    /// `["image"]`: it's an image product, and video is a separate app.
    public var profiles: Set<String>?

    private var connection: (any EngineConnection)?
    /// Where new runs execute; nil runs them in their session (Lite). Desktop sets its ticket executor.
    public weak var executor: (any RunExecutor)?
    /// A result waiting to become the next operation's input (LITE-12).
    public private(set) var carried: MediaItem?

    public init(directory: EngineDirectory, log: SessionLog) {
        self.directory = directory
        self.log = log
    }

    // MARK: - Engines

    /// Connects to `entry` and loads its operations. A paired engine without a pairing starts one.
    public func select(_ entry: EngineEntry) async {
        engine = entry
        info = nil
        operations = []
        current = nil
        problem = nil
        if entry.needsPairing {
            problem = "\(entry.name) needs pairing."
            await pair()
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let connection = try await directory.connect(entry)
            let info = try await connection.engineInfo()
            let ops = try await connection.operations().operations.filter { profiles?.contains($0.profile) ?? true }
            self.connection = connection
            self.info = info
            operations = ops.sorted { ($0.profile, $0.title) < ($1.profile, $1.title) }
            if let first = operations.first { choose(first) }
        } catch {
            problem = "Couldn't reach \(entry.name): \(error)"
        }
    }

    /// Pairs with the selected engine: shows the code, waits for its operator, then connects.
    public func pair() async {
        guard let entry = engine else { return }
        pairingProblem = nil
        do {
            let pairing = try await directory.beginPairing(entry)
            self.pairing = pairing
            var approved = false
            for _ in 0..<5 where !approved && self.pairing != nil {
                approved = try await directory.completePairing(pairing, wait: 60)
            }
            self.pairing = nil
            guard approved, let paired = directory.entries.first(where: { $0.id == entry.id }) else {
                pairingProblem = "The engine's operator didn't approve the pairing."
                return
            }
            await select(paired)
        } catch {
            pairing = nil
            pairingProblem = (error as? MESClientError)?.code == "pairing_rejected"
                ? "The engine's operator declined the pairing." : "Pairing failed: \(error)"
        }
    }

    /// Stops waiting for a pairing.
    public func cancelPairing() { pairing = nil }

    // MARK: - Operations and runs

    /// Operations grouped by profile (LITE-3): `[("Image", [...])]`.
    public var groupedOperations: [(profile: String, operations: [Descriptor])] {
        Dictionary(grouping: operations, by: \.profile).sorted { $0.key < $1.key }
            .map { (FormSchema.label($0.key), $0.value) }
    }

    /// Starts a run of `descriptor`. Media inputs of the previous run carry over where the new operation takes an
    /// input of the same name and kind, and a result sent with "use as input" fills the first empty image slot.
    public func choose(_ descriptor: Descriptor) {
        guard let connection, let info else { return }
        let next = RunSession(engine: connection, engineInfo: info, descriptor: descriptor, folder: log.folder)
        next.executor = executor
        next.form.policy.license = commercialOnlyByDefault ? .commercialUse : nil
        if let previous = current {
            for spec in descriptor.inputs where spec.kind != .text {
                if let items = previous.media[spec.name], previous.descriptor.inputs.contains(where: { $0.name == spec.name && $0.kind == spec.kind }) {
                    next.media[spec.name] = items
                }
            }
        }
        if let carried, let slot = descriptor.inputs.first(where: { $0.kind == .image && (next.media[$0.name] ?? []).isEmpty })
            ?? descriptor.inputs.first(where: { $0.kind == .image }) {
            next.media[slot.name] = [carried]
            self.carried = nil
        }
        current = next
    }

    /// Runs the current session and lists it in the session log.
    public func start() {
        guard let current, current.canRun else { return }
        if !log.runs.contains(where: { $0 === current }) { log.add(current) }
        current.start()
    }

    /// A new run of the same operation with the same inputs and controls.
    public func again() {
        guard let previous = current else { return }
        choose(previous.descriptor)
        guard let next = current else { return }
        next.media = previous.media
        next.data = previous.data
        next.form.text = previous.form.text
        next.form.model = previous.form.model
        next.form.policy = previous.form.policy
        for (name, value) in previous.form.values { next.form.setValue(value, at: [name]) }
        for ext in previous.descriptor.extensions ?? [] where previous.form.isEnabled(ext) {
            next.form.setEnabled(ext, true)
            for (key, value) in previous.form.extensions[ext.name]?.objectValue ?? [:] { next.form.setExtensionValue(ext, value, at: [key]) }
        }
    }

    /// Shows a run from the session list.
    public func show(_ run: RunSession) { current = run }

    /// Sends a result to the next operation (LITE-12). If the current run is still being edited and has an empty
    /// image slot, it goes there at once.
    public func useAsInput(_ result: RunResult) { useAsInput(result.asInput) }

    /// Puts a file into the next run (Desktop: a library asset, RUN-3): into the current run's first empty image slot
    /// while it's being edited, otherwise carried to the next operation chosen.
    public func useAsInput(_ item: MediaItem) {
        if let current, current.phase == .editing,
           let slot = current.descriptor.inputs.first(where: { $0.kind == .image && (current.media[$0.name] ?? []).isEmpty }) {
            current.media[slot.name] = [item]
        } else {
            carried = item
        }
    }

    /// Runs `image.matte` on `image` and returns its mask ("select subject", Lite OQ-1), when the engine offers it.
    public func selectSubject(of image: MediaItem) async throws -> MaskRaster? {
        guard let connection, let info, let matte = operations.first(where: { $0.operation == "image.matte" }) else { return nil }
        let run = RunSession(engine: connection, engineInfo: info, descriptor: matte, folder: log.folder)
        run.media["image"] = [image]
        if matte.params["properties"]?["outputs"] != nil { run.form.setValue(["mask"], at: ["outputs"]) }
        await run.run()
        guard let mask = run.results.first(where: { $0.output.kind == .mask }), let w = image.width, let h = image.height else {
            if case .failed(let message) = run.phase { throw MESClientError.unexpected(message) }
            return nil
        }
        return MaskRaster(image: try Data(contentsOf: mask.file), width: w, height: h)
    }

    /// Whether the engine can select subjects for masks.
    public var canSelectSubject: Bool { operations.contains { $0.operation == "image.matte" } }
}
