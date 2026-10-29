import Foundation
import MESClientKit
import MESConformance
import MESCore
import MESEngineKit
import MESInProcess
import MockEngineCore
@testable import PixelAgencyRun
import Testing

// The L1 test (Lite-PRD §9), at the model level: with only the mock engine, every Image operation runs end to end
// through Lite's run workflow, with its controls entirely from descriptors. Plus the workflow's other duties:
// progress, cancel, failures, use-as-input, masks, pairing, the working folder, the session's cleanup, and client
// conformance through `pa-run` (Lite's `lite-run` until the workflow moved here).

func engineConfig(_ tweak: (inout EngineConfiguration) -> Void = { _ in }) -> EngineConfiguration {
    let spool = FileManager.default.temporaryDirectory.appendingPathComponent("lite-test-\(UUID().uuidString)")
    var c = EngineConfiguration(id: "eng_lite_test", name: "Lite Test Engine", implementationName: "mes-mock-engine",
                                implementationVersion: "0.1.0", spoolDirectory: spool)
    c.advertise = false
    c.logLevel = .critical
    tweak(&c)
    return c
}

@MainActor
func serve(_ config: EngineConfiguration, engine: MockImageEngine = MockImageEngine(), _ body: @MainActor (Int) async throws -> Void) async throws {
    let server = MESEngineServer(engine: engine, configuration: config)
    let (ports, continuation) = AsyncStream<Int>.makeStream()
    let app = try await server.makeApplication { port in continuation.yield(port) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await app.runService() }
        var it = ports.makeAsyncIterator()
        guard let port = await it.next() else { return }
        try await body(port)
        group.cancelAll()
    }
}

func fixture(_ data: Data, _ ext: String = "png") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lite-fixture-\(UUID().uuidString).\(ext)")
    try data.write(to: url)
    return url
}

@MainActor
func session(_ port: Int, _ operation: String, log: SessionLog) async throws -> RunSession {
    let engine = HTTPEngineConnection(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!)
    let info = try await engine.engineInfo()
    let d = try #require(try await engine.operations().operations.first { $0.operation == operation })
    let run = RunSession(engine: engine, engineInfo: info, descriptor: d, folder: log.folder)
    log.add(run)
    return run
}

/// Fills a run the way a person would: text in every text box, the fixture image or mask in every required slot.
@MainActor
func fillInputs(_ run: RunSession) throws {
    for spec in run.form.textInputs { run.form.text[spec.name] = "a lighthouse at dusk" }
    for spec in run.descriptor.inputs where spec.required {
        switch spec.kind {
        case .image: run.media[spec.name] = [MediaItem(file: try fixture(Fixtures.png(width: 64, height: 48)))]
        case .mask: run.media[spec.name] = [MediaItem(file: try fixture(Fixtures.mask(width: 64, height: 48)))]
        default: break
        }
    }
}

@Suite("Lite's run workflow (L1)", .serialized)
@MainActor
struct RunWorkflowTests {
    @Test("Every Image operation of the mock runs end to end, controls from descriptors, results collected and confirmed")
    func everyOperation() async throws {
        try await serve(engineConfig()) { port in
            let log = SessionLog()
            defer { log.clear() }
            let engine = HTTPEngineConnection(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!)
            let operations = try await engine.operations().operations.map(\.operation)
            #expect(operations.count == ImageProfile.operations.operations.count)
            for op in operations {
                let run = try await session(port, op, log: log)
                try fillInputs(run)
                #expect(run.missingInputs.isEmpty && run.canRun, "\(op): \(run.missingInputs.map(\.name))")
                await run.run()
                #expect(run.phase == .finished, "\(op): \(run.phase)")
                #expect(!run.results.isEmpty, "\(op) produced no results")
                for result in run.results {
                    #expect(FileManager.default.fileExists(atPath: result.file.path), "\(op): \(result.file.lastPathComponent) missing")
                    #expect(result.provenance?.model.license.spdx == "Apache-2.0", "\(op): what happened shows the licence")
                }
                #expect(run.job?.state == .purged, "\(op): confirmed at once (Lite keeps no custody)")
            }
            #expect(log.runs.count == operations.count && log.results.count >= operations.count)
            let held = try await engine.jobs(state: .holding)
            #expect(held.isEmpty, "nothing left on the engine")
        }
    }

    @Test("Data inputs: segment's points go inline as JSON, and count as given")
    func dataInputs() async throws {
        try await serve(engineConfig()) { port in
            let log = SessionLog()
            defer { log.clear() }
            let run = try await session(port, "image.segment", log: log)
            try fillInputs(run)
            let points: JSONValue = [["x": 0.5, "y": 0.5, "label": "include"], ["x": 0.1, "y": 0.1, "label": "exclude"]]
            run.data["points"] = points
            #expect(run.missingInputs.isEmpty)
            #expect(run.draftRequest.inputs?["points"] == .one(.data(points)))
            await run.run()
            #expect(run.phase == .finished && run.results.first?.output.kind == .mask)

            // Run Again keeps every input, data included.
            let defaults = UserDefaults(suiteName: "lite-test-\(UUID().uuidString)")!
            let directory = EngineDirectory(credentials: MemoryCredentialStore(), clientName: "Lite Tests", defaults: defaults)
            let workflow = RunWorkflow(directory: directory, log: log)
            await workflow.select(try await directory.add(url: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            workflow.choose(run.descriptor)
            workflow.current?.media = run.media
            workflow.current?.data["points"] = points
            let first = workflow.current
            workflow.again()
            #expect(workflow.current !== first && workflow.current?.data["points"] == points)

            // A client offering only some profiles (Desktop: image) lists only their operations.
            let entry = try await directory.add(url: URL(string: "http://127.0.0.1:\(port)/mes/v0")!)
            workflow.profiles = ["image"]
            await workflow.select(entry)
            #expect(workflow.operations.count == ImageProfile.operations.operations.count)
            workflow.profiles = ["video"]
            await workflow.select(entry)
            #expect(workflow.operations.isEmpty && workflow.current == nil)
        }
    }

    @Test("Controls reach the engine: size, seed, quality and a model; what happened reports them")
    func controls() async throws {
        try await serve(engineConfig()) { port in
            let log = SessionLog()
            defer { log.clear() }
            let run = try await session(port, "image.generate", log: log)
            run.form.text["prompt"] = "a fox"
            run.form.setValue(["width": 96, "height": 64], at: ["size"])
            run.form.setValue(11, at: ["seed"])
            run.form.setValue("best", at: ["quality"])
            run.form.model = "mock"
            await run.run()
            let result = try #require(run.results.first)
            #expect(result.output.width == 96 && result.output.height == 64)
            #expect(result.provenance?.seed == 11 && result.effective["quality"] == "best")
        }
    }

    @Test("Progress is live, and cancel releases the job (ended cancelled)")
    func progressAndCancel() async throws {
        try await serve(engineConfig(), engine: MockImageEngine(stepDelay: .milliseconds(300), steps: 20)) { port in
            let log = SessionLog()
            defer { log.clear() }
            let run = try await session(port, "image.generate", log: log)
            run.form.text["prompt"] = "slow"
            run.start()
            var sawProgress = false
            for _ in 0..<50 where !sawProgress {
                try await Task.sleep(for: .milliseconds(100))
                if case .running(_, _, let fraction?, _) = run.phase, fraction > 0 { sawProgress = true }
            }
            #expect(sawProgress, "phase: \(run.phase)")
            await run.cancel()
            for _ in 0..<30 where run.job?.outcome != .cancelled {
                try await Task.sleep(for: .milliseconds(100))
                if let id = run.job?.id { _ = try? await run.engine.job(id, wait: 0) }
            }
            #expect(run.phase == .cancelled)
            let engine = run.engine
            let final = try await engine.job(try #require(run.job?.id), wait: 0)
            #expect(final.outcome == .cancelled)
        }
    }

    @Test("Failures are reported: a model the policy excludes, an engine refusal")
    func failures() async throws {
        try await serve(engineConfig()) { port in
            let log = SessionLog()
            defer { log.clear() }
            let run = try await session(port, "image.generate", log: log)
            run.form.text["prompt"] = "x"
            run.form.model = "mock-research"
            run.form.policy.license = .commercialUse
            await run.run()
            guard case .failed(let message) = run.phase else { Issue.record("expected failed, got \(run.phase)"); return }
            #expect(message.contains("policy_unmet"), "\(message)")
        }
    }

    @Test("A result is used as the next operation's input without saving (generate → upscale)")
    func useAsInput() async throws {
        try await serve(engineConfig()) { port in
            let log = SessionLog()
            defer { log.clear() }
            let generate = try await session(port, "image.generate", log: log)
            generate.form.text["prompt"] = "a lighthouse"
            generate.form.setValue(["width": 64, "height": 48], at: ["size"])
            await generate.run()
            let upscale = try await session(port, "image.upscale", log: log)
            upscale.media["image"] = [try #require(generate.results.first).asInput]
            upscale.form.setValue(2, at: ["scale"])
            await upscale.run()
            #expect(upscale.results.first?.output.width == 128 && upscale.results.first?.output.height == 96)
        }
    }

    @Test("Masks: brush strokes and a matte become 8-bit grey PNGs the engine accepts; fill keeps the unpainted pixels")
    func masks() async throws {
        var mask = MaskRaster(width: 64, height: 48)
        mask.paint([.init(points: [CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 47)], radius: 12)])
        #expect(mask.value(40, 10) == 255 && mask.value(5, 10) == 0 && !mask.isEmpty)
        let decoded = try DecodedImage(mask.png())
        #expect(decoded.isGrey && decoded.bitsPerComponent == 8 && decoded.width == 64 && decoded.height == 48)
        #expect(decoded.pixel(40, 5)[0] == 255 && decoded.pixel(5, 5)[0] == 0, "top-left origin, as the image")

        try await serve(engineConfig()) { port in
            let log = SessionLog()
            defer { log.clear() }
            // "Select subject": matte the image, take its mask.
            let image = try fixture(Fixtures.png(width: 64, height: 48))
            let matte = try await session(port, "image.matte", log: log)
            matte.media["image"] = [MediaItem(file: image)]
            await matte.run()
            let matteMask = try #require(matte.results.first { $0.output.kind == .mask })
            let fromMatte = try #require(MaskRaster(image: try Data(contentsOf: matteMask.file), width: 64, height: 48))
            #expect(fromMatte.width == 64)

            let fill = try await session(port, "image.fill", log: log)
            fill.media["image"] = [MediaItem(file: image)]
            fill.media["mask"] = [try mask.mediaItem(in: log.folder)]
            fill.form.text["prompt"] = "sky"
            await fill.run()
            let out = try DecodedImage(try Data(contentsOf: try #require(fill.results.first).file))
            let src = try DecodedImage(Fixtures.png(width: 64, height: 48))
            #expect(out.pixel(5, 20) == src.pixel(5, 20), "an unpainted pixel is unchanged")
        }
    }

    @Test("Pairing through the directory: the code, approval, then a pinned connection; forgetting unpairs")
    func pairing() async throws {
        let config = engineConfig { $0.mode = .paired; $0.pairingApproval = EngineConfiguration.approveAll }
        try await serve(config) { port in
            let defaults = UserDefaults(suiteName: "lite-test-\(UUID().uuidString)")!
            let directory = EngineDirectory(credentials: MemoryCredentialStore(), clientName: "Lite Tests", defaults: defaults)
            let entry = try await directory.add(url: URL(string: "https://localhost:\(port)/mes/v0")!)
            #expect(entry.needsPairing && entry.name == "Lite Test Engine" && entry.profiles == ["image/0.1"])
            await #expect(throws: MESClientError.self) { _ = try await directory.connect(entry) }
            let pairing = try await directory.beginPairing(entry)
            #expect(pairing.code.count == 6)
            #expect(try await directory.completePairing(pairing, wait: 10))
            let paired = try #require(directory.entries.first { $0.id == entry.id })
            #expect(paired.isPaired && !paired.needsPairing)
            let connection = try await directory.connect(paired)
            #expect(try await connection.operations().operations.count == ImageProfile.operations.operations.count)
            await directory.forget(paired)
            #expect(directory.entries.isEmpty)
            await #expect(throws: MESClientError.self) { _ = try await connection.operations() }
        }
    }

    @Test("The working folder: a bookmark that resolves, and a missing folder reported rather than silent")
    func workingFolder() throws {
        let defaults = UserDefaults(suiteName: "lite-wf-\(UUID().uuidString)")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lite-wf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wf = WorkingFolder(defaults: defaults)
        #expect(wf.status == .notChosen)
        try wf.choose(folder)
        #expect(wf.url?.standardizedFileURL.path == folder.standardizedFileURL.path)
        wf.stop()
        try FileManager.default.removeItem(at: folder)
        let again = WorkingFolder(defaults: defaults)
        guard case .unavailable = again.status else { Issue.record("expected unavailable, got \(again.status)"); return }
    }

    @Test("Saving never overwrites; the session's folder goes when the session ends")
    func savingAndCleanup() async throws {
        try await serve(engineConfig()) { port in
            let log = SessionLog()
            let run = try await session(port, "image.generate", log: log)
            run.form.text["prompt"] = "x"
            await run.run()
            let result = try #require(run.results.first)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("lite-save-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let a = try ResultExporter.save(result, to: destination, date: date)
            let b = try ResultExporter.save(result, to: destination, date: date)
            #expect(a != b && a.lastPathComponent.hasPrefix("generate-") && b.lastPathComponent.contains(" 2."))
            #expect(FileManager.default.fileExists(atPath: log.folder.path))
            log.clear()
            #expect(!FileManager.default.fileExists(atPath: log.folder.path) && log.runs.isEmpty)
            #expect(FileManager.default.fileExists(atPath: a.path), "saved files stay")
        }
    }

    @Test("Client conformance (LITE-14): pa-run, which drives RunSession, passes every CLIENT test")
    func clientConformance() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paRun = repo.appendingPathComponent(".build/debug/pa-run").path
        try #require(FileManager.default.isExecutableFile(atPath: paRun), "build pa-run first (swift build --product pa-run)")
        let report = await ClientSuite.run(client: .command(
            "\(paRun) --engine {url} --operation image.generate --text prompt={prompt} --param 'size={\"width\":64,\"height\":48}' --out {out}"))
        #expect(report.conforms, "\(report.results.filter { $0.status == .fail }.map { "\($0.id): \($0.detail ?? "")" })")
        #expect(report.results.count == 11)
    }
}

// MARK: - Embedding (Pixel Agency Desktop: a built-in engine, and runs executed as tickets)

/// Runs a session's request itself, the way Desktop's ticket executor does, and records what it saw.
@MainActor
final class RecordingExecutor: RunExecutor {
    var executed: [UUID] = []
    var cancelled: [UUID] = []

    func execute(_ session: RunSession) async {
        executed.append(session.id)
        session.report(.submitting)
        do {
            var inputs: [String: RequestInput] = [:]
            for (name, items) in session.media {
                inputs[name] = .one(try await session.engine.input(contentsOf: items[0].file, mediaType: items[0].mediaType,
                                                                   inlineLimit: session.engineInfo.limits.maxInlineBytes))
            }
            let job = try await session.engine.submit(session.form.request(media: inputs), idempotencyKey: UUID().uuidString)
            session.report(job: job)
            session.report(.running(state: job.state, stage: nil, fraction: nil, message: nil))
            for try await event in session.engine.events(job: job.id, after: 0) {
                session.apply(event)
                if event.type == .outputReady || event.type == .ended { break }
            }
            let final = try await session.engine.job(job.id, wait: 0)
            session.report(.collecting)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lite-exec-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var results: [RunResult] = []
            for output in final.result?.outputs ?? [] {
                let file = try await session.engine.download(job: job.id, output: output, to: folder.appendingPathComponent("\(output.index).png"))
                results.append(RunResult(output: output, file: file, job: final))
            }
            session.report(results: results)
            session.report(job: try await session.engine.confirm(job.id))
            session.report(.finished)
        } catch {
            session.report(.failed("\(error)"))
        }
    }

    func cancel(_ session: RunSession) async {
        cancelled.append(session.id)
        session.report(.cancelled)
    }
}

// Part of the L1 suite: run concurrently with it, two engines' worth of work on the main actor can starve its timers.
extension RunWorkflowTests {
    @Test("A built-in engine lists first, needs no pairing, and runs operations without the network")
    func builtIn() async throws {
        let (folder, defaults) = (FileManager.default.temporaryDirectory.appendingPathComponent("lite-local-\(UUID().uuidString)"),
                                  UserDefaults(suiteName: "lite-local-\(UUID().uuidString)")!)
        let directory = EngineDirectory(credentials: MemoryCredentialStore(), clientName: "tests", defaults: defaults)
        let local = try await InProcessEngine.start(engine: MockImageEngine(), configuration: engineConfig { $0.name = "Built-in" })
        let entry = try await directory.addLocal(local)
        #expect(entry.isBuiltIn && !entry.needsPairing && directory.entries.first?.id == entry.id)

        let workflow = RunWorkflow(directory: directory, log: SessionLog(folder: folder))
        defer { workflow.log.clear() }
        await workflow.select(entry)
        #expect(workflow.problem == nil && workflow.operations.count == ImageProfile.operations.operations.count)
        workflow.choose(try #require(workflow.operations.first { $0.operation == "image.matte" }))
        let run = try #require(workflow.current)
        try fillInputs(run)
        await run.run()
        #expect(run.phase == .finished && !run.results.isEmpty)

        directory.removeLocal(id: entry.id)
        #expect(directory.entries.isEmpty)
        await local.stop()
    }

    @Test("A workflow's executor runs its sessions; they report progress and results as their own runs do; cancel goes to it")
    func executor() async throws {
        try await serve(engineConfig()) { port in
            let defaults = UserDefaults(suiteName: "lite-exec-\(UUID().uuidString)")!
            let directory = EngineDirectory(credentials: MemoryCredentialStore(), clientName: "tests", defaults: defaults)
            let entry = try await directory.add(url: URL(string: "http://127.0.0.1:\(port)/mes/v0")!)
            let workflow = RunWorkflow(directory: directory, log: SessionLog())
            defer { workflow.log.clear() }
            let executor = RecordingExecutor()
            workflow.executor = executor
            await workflow.select(entry)
            workflow.choose(try #require(workflow.operations.first { $0.operation == "image.upscale" }))
            let run = try #require(workflow.current)
            #expect(run.executor === executor)
            try fillInputs(run)
            workflow.start()
            while run.phase != .finished, !(run.phase.isActive == false && run.phase != .editing) { try await Task.sleep(for: .milliseconds(20)) }
            #expect(executor.executed == [run.id])
            #expect(run.phase == .finished && run.results.count == 1 && run.job?.state == .purged)
            #expect(run.startedAt != nil && run.finishedAt != nil)

            workflow.again()
            let next = try #require(workflow.current)
            await next.cancel()
            #expect(executor.cancelled == [next.id] && next.phase == .cancelled)

            // A file from elsewhere (Desktop: a library asset) goes into the current run's empty image slot.
            workflow.choose(try #require(workflow.operations.first { $0.operation == "image.matte" }))
            workflow.current?.media = [:]
            let item = MediaItem(file: try fixture(Fixtures.png(width: 32, height: 32)))
            workflow.useAsInput(item)
            #expect(workflow.current?.media["image"]?.first?.file == item.file)
        }
    }
}

extension RunWorkflowTests {
    @Test("An allow-list: a refused engine leaves the list and can't be connected to; widening it brings it back")
    func admits() async throws {
        let defaults = UserDefaults(suiteName: "lite-admits-\(UUID().uuidString)")!
        let directory = EngineDirectory(credentials: MemoryCredentialStore(), clientName: "tests", defaults: defaults)
        let local = try await InProcessEngine.start(engine: MockImageEngine(), configuration: engineConfig { $0.name = "Built-in" })
        let entry = try await directory.addLocal(local)
        #expect(directory.entries.map(\.id) == [entry.id] && directory.refused.isEmpty)

        directory.admits = { $0.id != entry.id }                         // an administrator's list without it
        #expect(directory.entries.isEmpty && directory.refused.map(\.id) == [entry.id])
        await #expect(throws: MESClientError.self) { _ = try await directory.connect(entry) }

        directory.admits = { _ in true }
        #expect(directory.entries.map(\.id) == [entry.id] && directory.refused.isEmpty)
        _ = try await directory.connect(entry)
        await local.stop()
    }
}
