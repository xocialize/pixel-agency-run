import Foundation
import MESClientKit
import MESCore
import MESEngineKit
import MockEngineCore
@testable import PixelAgencyRun
import Testing

// Audio in the run workflow (MES Audio 0.1, AB-A-0234), against the mock's audio engine: a streamed speak with a
// voice, barge-in, an edit with an audio input and its transcript, generate with count 2, compose with timestamps,
// an audio result as the next input, and pa-run --stream.

/// A WAV of a tone: `seconds` long at `rate`, mono.
func toneWAV(seconds: Double = 4, rate: Int = 24_000, hz: Double = 196) throws -> URL {
    let n = Int(seconds * Double(rate))
    let samples = (0..<n).map { Int16(9000 * sin(2 * Double.pi * hz * Double($0) / Double(rate))) }
    return try fixture(WAVFile(sampleRate: rate, channels: 1, samples: samples).data, "wav")
}

/// A session log of its own: `SessionLog()`'s default folder is per process, and the image suite runs alongside.
@MainActor
func audioLog() -> SessionLog {
    SessionLog(folder: FileManager.default.temporaryDirectory.appendingPathComponent("run-audio-\(UUID().uuidString)", isDirectory: true))
}

@Suite("Audio in the run workflow (AB-A-0234)", .serialized)
@MainActor
struct AudioRunTests {
    @Test("Speak: the voice list comes from the engine; a cloned voice streams as pcm_s16le, chunks in order, and the final file is collected")
    func streamedSpeak() async throws {
        try await serve(engineConfig(), engine: MockAudioEngine()) { port in
            let log = audioLog()
            defer { log.clear() }

            // Preset voices: the form's voice widget picks from the engine's list, with samples.
            let presets = try await session(port, "audio.speak", log: log)
            #expect(presets.form.voiceSource != nil)
            await presets.form.loadVoices()
            #expect(presets.form.voiceChoices.voices.map(\.id) == ["mock-alto", "mock-tenor", "mock-bass"])
            #expect(presets.form.voiceChoices.sample != nil)
            #expect(!presets.form.stream, "the default offer (mock-presets) doesn't stream, so streaming is off")
            presets.form.text["text"] = "Hello from a preset voice."
            presets.form.setValue("mock-tenor", at: ["voice"])
            await presets.run()
            #expect(presets.phase == .finished, "\(presets.phase)")
            #expect(presets.results.first?.provenance?.voice?.id == "mock-tenor")
            #expect(presets.streamed == nil)

            // A cloned voice on the offer that streams: on by default once it's the model, asked for as pcm_s16le.
            let run = try await session(port, "audio.speak", log: log)
            run.form.model = "mock-clone"
            run.streamByDefault()
            #expect(run.form.stream)
            run.form.text["text"] = "Streaming arrives a quarter second at a time, and plays as it comes."
            run.media["voice_ref"] = [MediaItem(file: try toneWAV())]
            #expect(run.media["voice_ref"]?.first?.isAudio == true && run.media["voice_ref"]?.first?.sampleRate == 24_000)
            #expect(run.media["voice_ref"]?.first?.width == nil, "audio isn't probed as an image")
            #expect(run.draftRequest.stream == [StreamRequest(output: "audio", encoding: .pcmS16LE)])
            #expect(run.canRun, "\(run.missingInputs.map(\.name)) \(run.form.issues)")

            var passed: [OutputChunk] = []
            run.onChunk = { passed.append($0) }
            let early = run.chunks()                                 // a view listening before the run starts
            let listened = Task { @MainActor in
                var chunks: [OutputChunk] = []
                for await chunk in early { chunks.append(chunk) }
                return chunks
            }
            await run.run()
            #expect(run.phase == .finished, "\(run.phase)")
            let heard = await listened.value

            let format = StreamPlan(output: "audio", encoding: .pcmS16LE, sampleRate: 22_050, channels: 1)
            #expect(passed.count > 2 && passed.map(\.index) == Array(0..<passed.count))
            #expect(passed.last?.final == true && passed.allSatisfy { $0.format == format })
            #expect(heard == passed, "a listener gets every chunk, in order")
            let streamed = try #require(run.streamed)
            #expect(streamed.finished && streamed.chunks == passed.count && streamed.format == format)
            #expect((streamed.firstChunkAfter ?? -1) >= 0)

            // The final file is still collected, and it's the stream's samples.
            let result = try #require(run.results.first)
            #expect(result.isAudio && !result.isImage && result.output.mediaType == "audio/wav")
            let wav = try WAVFile(Data(contentsOf: result.file))
            #expect(wav.pcm == passed.reduce(into: Data()) { $0.append($1.samples ?? Data()) })
            #expect(result.output.sampleRate == 22_050 && result.output.channels == 1 && result.output.durationSeconds != nil)
            #expect(result.audioFacts?.contains("mono") == true)
            #expect(abs(streamed.seconds - (result.output.durationSeconds ?? 0)) < 0.01)
            #expect(run.job?.state == .purged, "confirmed at once")

            // A view joining after the run has nothing to play.
            var late = 0
            for await _ in run.chunks() { late += 1 }
            #expect(late == 0)
        }
    }

    @Test("Barge-in: releasing a streaming run stops it within a chunk, here and on the engine")
    func bargeIn() async throws {
        try await serve(engineConfig(), engine: MockAudioEngine(chunkDelay: .milliseconds(150))) { port in
            let log = audioLog()
            defer { log.clear() }
            let run = try await session(port, "audio.speak", log: log)
            run.form.model = "mock-clone"
            run.streamByDefault()
            run.form.text["text"] = String(repeating: "A long line to say, and then some more of it. ", count: 8)
            run.media["voice_ref"] = [MediaItem(file: try toneWAV())]
            var passed = 0
            run.onChunk = { _ in
                passed += 1
                if passed == 1 { Task { await run.cancel() } }
            }
            run.start()
            for _ in 0..<100 where run.phase.isActive || run.phase == .editing {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(run.phase == .cancelled, "\(run.phase)")
            #expect(passed <= 2, "nothing is passed on after the release: \(passed)")
            #expect(run.results.isEmpty)
            let id = try #require(run.job?.id)
            let final = try await run.engine.job(id, wait: 0)
            #expect(final.outcome == .cancelled)
            var made = 0
            for try await event in run.engine.events(job: id, after: 0) where event.type == .outputChunk { made += 1 }
            #expect(made <= passed + 1, "the engine stopped within a chunk: it made \(made)")
            #expect(made < 10, "the whole line would be far more chunks")
        }
    }

    @Test("Edit speech: an audio input and the transcript in, the edited take and its transcript out, shown as text")
    func editSpeech() async throws {
        try await serve(engineConfig(), engine: MockAudioEngine()) { port in
            let log = audioLog()
            defer { log.clear() }
            let run = try await session(port, "audio.edit_speech", log: log)
            #expect(run.descriptor.inputs.first { $0.name == "audio" }?.kind == .audio)
            #expect(!run.form.stream, "edit_speech has nothing to stream")
            #expect(run.missingInputs.contains { $0.name == "audio" })
            run.media["audio"] = [MediaItem(file: try toneWAV(seconds: 2))]
            run.form.text["transcript"] = "Hello there"
            run.form.setValue(["kind": "add_cue", "cue": "laugh", "at": "end"], at: ["edit"])
            #expect(run.canRun, "\(run.missingInputs.map(\.name)) \(run.form.issues)")
            #expect(run.draftRequest.stream == nil)
            await run.run()
            #expect(run.phase == .finished, "\(run.phase)")
            let audio = try #require(run.results.first { $0.output.name == "audio" })
            #expect(audio.isAudio && audio.output.sampleRate == 24_000)
            let transcript = try #require(run.results.first { $0.output.name == "transcript" })
            #expect(transcript.isText && !transcript.isAudio)
            #expect(transcript.text == "Hello there [laugh]")
        }
    }

    @Test("Generate with count 2: two sounds, each its own result with its facts")
    func generateTwo() async throws {
        try await serve(engineConfig(), engine: MockAudioEngine()) { port in
            let log = audioLog()
            defer { log.clear() }
            let run = try await session(port, "audio.generate", log: log)
            run.form.text["prompt"] = "Rain on a tin roof, steady, with distant thunder."
            run.form.setValue(1.5, at: ["duration_s"])
            run.form.setValue(2, at: ["count"])
            run.form.setValue(11, at: ["seed"])
            #expect(run.canRun, "\(run.missingInputs.map(\.name)) \(run.form.issues)")
            await run.run()
            #expect(run.phase == .finished, "\(run.phase)")
            #expect(run.results.count == 2 && run.results.allSatisfy(\.isAudio))
            #expect(Set(run.results.map(\.id)).count == 2 && Set(run.results.map(\.file)).count == 2)
            for result in run.results {
                #expect(result.output.durationSeconds == 1.5 && result.output.sampleRate == 48_000)
                #expect(FileManager.default.fileExists(atPath: result.file.path))
                let saved = try ResultExporter.save(result, to: log.folder.appendingPathComponent("saved", isDirectory: true).creating())
                #expect(saved.pathExtension == "wav")
            }
        }
    }

    @Test("Compose: a stereo song, and its lyric timestamps kept as a result and shown as timed lines")
    func compose() async throws {
        try await serve(engineConfig(), engine: MockAudioEngine()) { port in
            let log = audioLog()
            defer { log.clear() }
            let run = try await session(port, "audio.compose", log: log)
            run.form.text["caption"] = "Upbeat synth-pop with a bright female vocal and a driving beat."
            run.form.text["lyrics"] = "[verse]\nLights on the water\nWe follow the line\n[chorus]\nRun all night\n"
            run.form.setValue(8, at: ["duration_s"])
            run.form.setValue("en", at: ["language"])
            run.form.setValue(true, at: ["timestamps"])
            #expect(run.canRun, "\(run.missingInputs.map(\.name)) \(run.form.issues)")
            await run.run()
            #expect(run.phase == .finished, "\(run.phase)")
            let song = try #require(run.results.first { $0.output.name == "song" })
            #expect(song.isAudio && song.output.channels == 2 && song.output.sampleRate == 48_000)
            #expect(song.audioFacts?.contains("stereo") == true)
            let timestamps = try #require(run.results.first { $0.output.name == "timestamps" })
            #expect(timestamps.isText && timestamps.value?["lines"]?.arrayValue?.count == 3)
            #expect(timestamps.text.split(separator: "\n").first == "[1.0–2.8 s] Lights on the water", "\(timestamps.text)")
        }
    }

    @Test("An audio result goes to the next operation's audio slot (speak → edit speech), without probing it as an image")
    func audioAsInput() async throws {
        try await serve(engineConfig(), engine: MockAudioEngine()) { port in
            let log = audioLog()
            defer { log.clear() }
            let defaults = UserDefaults(suiteName: "run-audio-test-\(UUID().uuidString)")!
            let directory = EngineDirectory(credentials: MemoryCredentialStore(), clientName: "Run Tests", defaults: defaults)
            let workflow = RunWorkflow(directory: directory, log: log)
            await workflow.select(try await directory.add(url: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let speak = try #require(workflow.operations.first { $0.operation == "audio.speak" })
            workflow.choose(speak)
            let run = try #require(workflow.current)
            run.form.text["text"] = "Hello there"
            workflow.start()
            for _ in 0..<100 where run.phase != .finished { try await Task.sleep(for: .milliseconds(50)) }
            let result = try #require(run.results.first)
            workflow.useAsInput(result)
            workflow.choose(try #require(workflow.operations.first { $0.operation == "audio.edit_speech" }))
            let item = try #require(workflow.current?.media["audio"]?.first)
            #expect(item.file == result.file && item.isAudio && item.kind == .audio)
            #expect(item.sampleRate == 24_000 && item.durationSeconds == result.output.durationSeconds)
        }
    }

    @Test("Image runs ask for no stream and keep their requests")
    func imageUnchanged() async throws {
        try await serve(engineConfig()) { port in
            let log = audioLog()
            defer { log.clear() }
            let run = try await session(port, "image.generate", log: log)
            run.form.text["prompt"] = "a lighthouse"
            #expect(!run.form.stream && run.draftRequest.stream == nil)
            #expect(run.draftRequest == run.form.request(media: [:]))
        }
    }

    @Test("pa-run --stream audio writes the chunks and the final file, and reports the first chunk's latency")
    func paRunStream() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paRun = repo.appendingPathComponent(".build/debug/pa-run")
        try #require(FileManager.default.isExecutableFile(atPath: paRun.path), "build pa-run first (swift build --product pa-run)")
        try await serve(engineConfig(), engine: MockAudioEngine()) { port in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("pa-run-stream-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: out) }
            let clip = try toneWAV()
            let process = Process()
            process.executableURL = paRun
            process.arguments = ["--engine", "http://127.0.0.1:\(port)/mes/v0", "--operation", "audio.speak", "--model", "mock-clone",
                                 "--text", "text=Streaming from the command line.", "--file", "voice_ref=\(clip.path)",
                                 "--stream", "audio", "--out", out.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let stdout = String(decoding: await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value, as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(stdout)")
            #expect(stdout.contains("first chunk after "), "\(stdout)")
            #expect(stdout.contains("streamed "), "\(stdout)")
            let files = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
            let streamed = try #require(files.first { $0 == "audio-stream.wav" })
            let final = try #require(files.first { $0.hasPrefix("speak-") && $0.hasSuffix(".wav") })
            let a = try WAVFile(Data(contentsOf: out.appendingPathComponent(streamed)))
            let b = try WAVFile(Data(contentsOf: out.appendingPathComponent(final)))
            #expect(a.pcm == b.pcm && a.sampleRate == 22_050 && !a.pcm.isEmpty, "the chunks make the final file's samples")
        }
    }
}

extension URL {
    func creating() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
