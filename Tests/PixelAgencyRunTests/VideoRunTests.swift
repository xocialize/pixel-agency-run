import Foundation
import MESClientKit
import MESCore
import MESEngineKit
import MESConformance
import MESFormsUI
import MockEngineCore
@testable import PixelAgencyRun
import Testing

// Video in the run workflow (MES Video 0.1, AB-A-0243), against the mock's video engine: generate with a first frame
// and keyframes, users' acceptance (refused without, run with, the refusal shown as needing it), previews collected,
// an extend and an upscale whose video input is a previous result, and pa-run with --accept and --previews.

/// A session log of its own, as the audio suite's.
@MainActor
func videoLog() -> SessionLog {
    SessionLog(folder: FileManager.default.temporaryDirectory.appendingPathComponent("run-video-\(UUID().uuidString)", isDirectory: true))
}

/// The mock's licence whose terms bind each user (it stands for LTX-2 Community).
let community = MockVideoEngine.communityLicense

/// A workflow on the mock video engine, with acceptances of its own (in memory, or in `defaults`).
@MainActor
func videoWorkflow(_ port: Int, log: SessionLog, acceptances: LicenseAcceptances = LicenseAcceptances()) async throws -> RunWorkflow {
    let defaults = UserDefaults(suiteName: "run-video-test-\(UUID().uuidString)")!
    let directory = EngineDirectory(credentials: MemoryCredentialStore(), clientName: "Run Tests", defaults: defaults)
    let workflow = RunWorkflow(directory: directory, log: log, acceptances: acceptances)
    await workflow.select(try await directory.add(url: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
    return workflow
}

/// Chooses `operation` in `workflow` and returns its run.
@MainActor
func choose(_ operation: String, in workflow: RunWorkflow) throws -> RunSession {
    workflow.choose(try #require(workflow.operations.first { $0.operation == operation }))
    return try #require(workflow.current)
}

/// Starts the workflow's current run and waits for it to end.
@MainActor
func runToEnd(_ workflow: RunWorkflow) async throws -> RunSession {
    let run = try #require(workflow.current)
    #expect(run.canRun, "\(run.descriptor.operation): \(run.missingInputs.map(\.name)) \(run.form.issues)")
    workflow.start()
    for _ in 0..<400 where run.phase.isActive || run.phase == .editing { try await Task.sleep(for: .milliseconds(50)) }
    return run
}

@Suite("Video in the run workflow (AB-A-0243)", .serialized)
@MainActor
struct VideoRunTests {
    @Test("Generate with a first frame and two keyframes at times: a video result with its facts, its previews, and the grid's warning")
    func generateWithKeyframes() async throws {
        try await serve(engineConfig(), engine: MockVideoEngine()) { port in
            let log = videoLog()
            defer { log.clear() }
            let acceptances = LicenseAcceptances()
            acceptances.accept(community)
            let workflow = try await videoWorkflow(port, log: log, acceptances: acceptances)
            #expect(workflow.groupedOperations.map(\.profile) == ["Video"])
            let run = try choose("video.generate", in: workflow)
            #expect(run.acceptances === acceptances, "every run uses the workflow's acceptances")
            #expect(run.descriptor.inputs.first { $0.name == "keyframes" }?.max == 5)

            run.form.model = "mock-ltx-standard"                      // keyframes need the two-stage offer
            run.form.text["prompt"] = "a lighthouse at dusk, waves rolling in, gulls calling"
            run.media["first_frame"] = [MediaItem(file: try fixture(Fixtures.png(width: 256, height: 256)))]
            run.media["keyframes"] = [MediaItem(file: try fixture(Fixtures.png(width: 256, height: 256))),
                                      MediaItem(file: try fixture(Fixtures.png(width: 128, height: 128)))]
            #expect(run.media["keyframes"]?.allSatisfy { $0.kind == .image } == true, "keyframes are images, several in one slot")
            run.form.setValue([0.25, 0.5], at: ["keyframe_times"])
            run.form.setValue(1.0, at: ["duration_s"])
            #expect(run.needsAcceptance.isEmpty && run.form.issues.isEmpty, "\(run.form.issues)")
            #expect(run.draftRequest.policy?.accepted == [community.spdx], "the accepted licence goes in policy.accepted")
            #expect(run.draftRequest.inputs?["keyframes"].map { if case .many(let v) = $0 { v.count } else { 1 } } == 2)

            let finished = try await runToEnd(workflow)
            #expect(finished.phase == .finished, "\(finished.phase)")
            let result = try #require(finished.results.first)
            #expect(result.isVideo && !result.isImage && !result.isAudio && result.output.mediaType == "video/mp4")
            let facts = try #require(result.videoFacts)
            #expect(facts.width == 256 && facts.height == 256 && facts.fps == 24 && facts.frames == 25, "\(facts)")
            #expect(facts.sampleRate == 48_000 && facts.channels == 2, "LTX-shaped offers make sound")
            #expect(facts.line.contains("25 frames") && facts.line.contains("sound 48 kHz stereo"), "\(facts.line)")
            #expect(result.provenance?.model.id == "mock-ltx-standard" && result.provenance?.model.license.spdx == community.spdx)
            #expect(result.job.warnings.contains { $0.code == VideoProfile.WarningCode.durationSnapped }, "\(result.job.warnings)")

            // Previews: the still the engine sent, with its moment, and the latest preview as before.
            let stills = finished.framePreviews.frames
            #expect(stills.count == 1, "\(stills.count)")
            #expect(stills.first.map { $0.atSeconds > 0 && $0.atSeconds < facts.durationSeconds && $0.frame == 12 } == true)
            #expect(finished.preview == stills.first?.image)

            // The file itself reads the same.
            let read = await MediaItem.reading(result.file)
            #expect(read.kind == .video && read.width == 256 && read.frames == 25 && read.sampleRate == 48_000)
            #expect(MediaItem(file: result.file).width == nil, "a clip isn't probed as an image")
        }
    }

    @Test("Users' acceptance: refused without it (in the form, and 422 terms_not_accepted from the engine, shown as needing it), runs with it, persists, and can be revoked")
    func usersAcceptance() async throws {
        try await serve(engineConfig(), engine: MockVideoEngine()) { port in
            let log = videoLog()
            defer { log.clear() }
            let defaults = UserDefaults(suiteName: "run-video-acceptance-\(UUID().uuidString)")!
            let acceptances = LicenseAcceptances(defaults: defaults, key: "accepted")
            let workflow = try await videoWorkflow(port, log: log, acceptances: acceptances)

            // Named, without acceptance: the form holds it back, and says what to accept.
            let named = try choose("video.generate", in: workflow)
            named.form.model = "mock-ltx-compact"
            named.form.text["prompt"] = "a paper boat on a stream"
            #expect(named.needsAcceptance == [community])
            #expect(!named.canRun && named.form.issues["model"] != nil, "\(named.form.issues)")
            #expect(named.draftRequest.policy?.accepted == nil)
            // Sent anyway (as another client would), the engine refuses it, and the run says it needs acceptance.
            await named.run()
            guard case .failed(let message) = named.phase else { Issue.record("not refused: \(named.phase)"); return }
            #expect(named.refusedTerms == [community], "\(named.refusedTerms)")
            #expect(message.contains("Accept") && message.contains(community.spdx), "\(message)")
            #expect(named.results.isEmpty)

            // Automatic at a tier only that licence's offer has: the engine refuses it at submit, the same way.
            let automatic = try choose("video.generate", in: workflow)
            automatic.form.text["prompt"] = "a paper boat on a stream"
            automatic.form.setValue("best", at: ["quality"])
            #expect(automatic.needsAcceptance.isEmpty && automatic.canRun, "with no model chosen nothing is pending")
            await automatic.run()
            #expect(automatic.refusedTerms == [community], "\(automatic.phase)")
            #expect(automatic.needsAcceptance == [community])
            // Automatic at the default tier runs on the open offer, which needs nothing.
            let open = try choose("video.generate", in: workflow)
            open.form.text["prompt"] = "a paper boat on a stream"
            await open.run()
            #expect(open.phase == .finished && open.results.first?.provenance?.model.id == "mock-video-open", "\(open.phase)")

            // Accepted: the named run goes, with the licence in policy.accepted.
            acceptances.accept(community)
            workflow.show(named)
            workflow.again()
            let accepted = try #require(workflow.current)
            #expect(accepted.form.model == "mock-ltx-compact" && accepted.needsAcceptance.isEmpty && accepted.canRun)
            #expect(accepted.draftRequest.policy?.accepted == [community.spdx])
            let ran = try await runToEnd(workflow)
            #expect(ran.phase == .finished, "\(ran.phase)")
            #expect(ran.results.first?.provenance?.model.id == "mock-ltx-compact")
            #expect(ran.results.first?.videoFacts?.sampleRate == 48_000)

            // Kept per user: a new workflow on the same defaults has it; revoking takes it back.
            #expect(LicenseAcceptances(defaults: defaults, key: "accepted").accepted == [community.spdx])
            acceptances.revoke(community)
            #expect(accepted.needsAcceptance == [community] && !accepted.canRun)
            #expect(LicenseAcceptances(defaults: defaults, key: "accepted").accepted.isEmpty)

            // An executor's refusal (Desktop's ticket runner) is shown the same way.
            let executed = try choose("video.generate", in: workflow)
            executed.report(.submitting)
            executed.report(failure: MESClientError.engine(
                MESError(.policyUnmet, "Mock LTX compact is under \(community.spdx), whose terms bind each user.",
                         reason: Policy.termsNotAcceptedReason, param: "policy"), status: 422, retryAfter: nil))
            #expect(executed.refusedTerms == [community] && executed.finishedAt != nil)
            executed.report(.submitting)
            executed.report(failure: MESClientError.engine(MESError(.policyUnmet, "No model satisfies the policy."), status: 422, retryAfter: nil))
            #expect(executed.refusedTerms.isEmpty, "other policy refusals are plain failures")
            #expect(executed.phase == .failed("422 policy_unmet: No model satisfies the policy."))
        }
    }

    @Test("A generated clip becomes extend's video input, the extended clip upscale's, and the clip carries over to interpolate")
    func resultsAsVideoInputs() async throws {
        try await serve(engineConfig(), engine: MockVideoEngine()) { port in
            let log = videoLog()
            defer { log.clear() }
            let acceptances = LicenseAcceptances()
            acceptances.accept(community)
            let workflow = try await videoWorkflow(port, log: log, acceptances: acceptances)

            let generate = try choose("video.generate", in: workflow)
            generate.form.text["prompt"] = "a red kite over a field"
            generate.form.model = "mock-ltx-compact"
            let generated = try #require(try await runToEnd(workflow).results.first)
            #expect(generated.isVideo)

            // Use as input: the clip fills extend's video slot, with the engine's facts (not probed).
            workflow.useAsInput(generated)
            let extend = try choose("video.extend", in: workflow)
            let source = try #require(extend.media["video"]?.first)
            #expect(source.file == generated.file && source.kind == .video && source.isVideo)
            #expect(source.videoFacts == generated.videoFacts && source.frames == 9 && source.fps == 24)
            #expect(extend.missingInputs.map(\.name) == ["prompt"], "the clip is given; extend still needs a prompt")
            extend.form.text["prompt"] = "the kite climbs into the clouds"
            extend.form.setValue(1.0, at: ["after_s"])
            let extended = try await runToEnd(workflow)
            #expect(extended.phase == .finished, "\(extended.phase)")
            let longer = try #require(extended.results.first?.videoFacts)
            #expect(longer.frames == 33 && longer.width == 256 && longer.sampleRate == 48_000, "\(longer)")

            // The extended clip, sent on: it fills upscale's video slot, in place of extend's input that would carry over.
            workflow.useAsInput(try #require(extended.results.first))
            #expect(workflow.carried?.file == extended.results.first?.file, "extend has finished, so the clip waits for the next operation")
            let upscale = try choose("video.upscale", in: workflow)
            #expect(upscale.media["video"]?.count == 1 && upscale.media["video"]?.first?.file == extended.results.first?.file)
            #expect(workflow.carried == nil)
            upscale.form.setValue(2, at: ["scale"])
            upscale.form.setValue("live_action", at: ["content"])
            let upscaled = try await runToEnd(workflow)
            #expect(upscaled.phase == .finished, "\(upscaled.phase)")
            let bigger = try #require(upscaled.results.first?.videoFacts)
            #expect(bigger.width == 512 && bigger.height == 512 && bigger.frames == 33 && bigger.sampleRate == 48_000, "\(bigger)")
            #expect(upscaled.results.first?.provenance?.model.id == "mock-seedvr2")

            // Carry-over: interpolate takes a `video` too, so the upscaled run's input comes along.
            let interpolate = try choose("video.interpolate", in: workflow)
            #expect(interpolate.media["video"]?.first?.file == extended.results.first?.file)
        }
    }

    @Test("pa-run --accept runs an offer whose terms bind its users, writes its previews, and prints the clip's facts; without it, says which --accept")
    func paRunAccept() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paRun = repo.appendingPathComponent(".build/debug/pa-run")
        try #require(FileManager.default.isExecutableFile(atPath: paRun.path), "build pa-run first (swift build --product pa-run)")
        try await serve(engineConfig(), engine: MockVideoEngine()) { port in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("pa-run-video-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: out) }
            let still = try fixture(Fixtures.png(width: 256, height: 256))
            let engine = "http://127.0.0.1:\(port)/mes/v0"
            let generate = ["--engine", engine, "--operation", "video.generate", "--model", "mock-ltx-standard",
                            "--text", "prompt=a lighthouse at dusk", "--file", "first_frame=\(still.path)", "--previews", "--out", out.path]

            let refused = try await Self.paRun(paRun, generate)
            #expect(refused.status != 0)
            #expect(refused.stderr.contains("--accept \(community.spdx)"), "\(refused.stderr)")

            let ran = try await Self.paRun(paRun, generate + ["--accept", community.spdx])
            #expect(ran.status == 0, "\(ran.stdout)\n\(ran.stderr)")
            #expect(ran.stdout.contains("video 256×256 · 24 fps · 9 frames"), "\(ran.stdout)")
            #expect(ran.stdout.contains("sound 48 kHz stereo"), "\(ran.stdout)")
            #expect(ran.stdout.contains("model mock-ltx-standard · \(community.spdx)"), "\(ran.stdout)")
            let previews = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("previews").path)
            #expect(previews.count == 1 && previews[0].hasPrefix("preview-") && previews[0].hasSuffix(".jpeg"), "\(previews)")
            let clip = try #require(try FileManager.default.contentsOfDirectory(atPath: out.path).first { $0.hasSuffix(".mp4") })

            // A video input by --file: the clip just made, upscaled.
            let upscaled = try await Self.paRun(paRun, ["--engine", engine, "--operation", "video.upscale",
                                                        "--file", "video=\(out.appendingPathComponent(clip).path)",
                                                        "--param", "scale=2", "--param", "content=live_action", "--out", out.appendingPathComponent("up").path])
            #expect(upscaled.status == 0, "\(upscaled.stdout)\n\(upscaled.stderr)")
            #expect(upscaled.stdout.contains("video 512×512 · 24 fps · 9 frames"), "\(upscaled.stdout)")
        }
    }

    @Test("Image workflows are unchanged: no policy without acceptance, and a client limited to image offers no video")
    func imageUnchanged() async throws {
        try await serve(engineConfig(), engine: MockVideoEngine()) { port in
            let log = videoLog()
            defer { log.clear() }
            let defaults = UserDefaults(suiteName: "run-video-image-\(UUID().uuidString)")!
            let directory = EngineDirectory(credentials: MemoryCredentialStore(), clientName: "Run Tests", defaults: defaults)
            let workflow = RunWorkflow(directory: directory, log: log, acceptances: LicenseAcceptances())
            workflow.profiles = ["image"]                            // Desktop
            await workflow.select(try await directory.add(url: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            #expect(workflow.operations.isEmpty && workflow.current == nil)
        }
        try await serve(engineConfig()) { port in
            let log = videoLog()
            defer { log.clear() }
            let run = try await session(port, "image.generate", log: log)
            run.form.text["prompt"] = "a lighthouse"
            #expect(run.needsAcceptance.isEmpty && run.draftRequest.policy == nil)
            let image = MediaItem(file: try fixture(Fixtures.png(width: 64, height: 48)))
            #expect(image.kind == .image && image.width == 64 && image.videoFacts == nil)
        }
    }

    /// Runs pa-run and returns its exit status and output.
    static func paRun(_ executable: URL, _ arguments: [String]) async throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        async let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        let (o, e) = await (stdout, stderr)
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}
