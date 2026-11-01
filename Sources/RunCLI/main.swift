import ArgumentParser
import Foundation
import MESClientKit
import MESCore
import PixelAgencyRun

/// `pa-run`: the run workflow without a window (it was Lite's `lite-run`). It does what a person does in a client
/// built on it (pick an operation, give inputs and controls, run, save the result) through the same `RunSession`, so
/// the MES client conformance suite can exercise the workflow's engine path (LITE-14):
///
///     mes-conformance client --command 'pa-run --engine {url} --operation image.generate --text prompt={prompt} --out {out}'
///
/// `--stream audio` asks for the output as it's made (Base §11): the chunks received are written to
/// `<out>/audio-stream.wav` as they arrive, the finished file is saved as usual, and the first chunk's latency is printed.
///
/// Video (Video 0.1): a clip is a `--file` like any medium (`--file video=clip.mp4`, `--file first_frame=still.png`,
/// keyframes as `--file keyframes=a.png --file keyframes=b.png` with `--param 'keyframe_times=[1,3]'`). A video result's
/// facts are printed (`video 1280×704 · 24 fps · 121 frames · 5.04 s · sound 48 kHz stereo`). `--previews` writes the
/// stills the engine sends while it runs to `<out>/previews/`. `--accept <spdx>` sends the licence in `policy.accepted`
/// (Base §10.2 rule 4): the user of this command accepts its terms. Without it an offer that needs it is refused, and
/// the command says which `--accept` to give.
@main
struct PARun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pa-run",
        abstract: "Run one operation the way the Pixel Agency run workflow does, and save its results.")

    @Option(help: "The engine's base URL (an open-mode engine, or a paired one with --token and --pin).") var engine: String
    @Option(help: "The operation, e.g. image.generate.") var operation: String
    @Option(help: "A text input as name=value. Repeatable.") var text: [String] = []
    @Option(help: "A media input as name=path. Repeatable.") var file: [String] = []
    @Option(help: "A data input as name=JSON (e.g. points for image.segment). Repeatable.") var data: [String] = []
    @Option(help: "A parameter as name=JSON (or a plain string). Repeatable.") var param: [String] = []
    @Option(help: "A model id from the descriptor.") var model: String?
    @Option(help: "A bearer token from pairing.") var token: String?
    @Option(help: "The engine certificate's SHA-256 (hex).") var pin: String?
    @Option(help: "Where to save the results.") var out: String
    @Option(help: "Stream this output as it's made (e.g. audio): write the chunks, then the final file.") var stream: String?
    @Option(help: "Accept a licence's terms (its spdx id), sent in policy.accepted. Repeatable.") var accept: [String] = []
    @Flag(help: "Write the stills the engine sends while it runs (job.preview) to <out>/previews/.") var previews = false

    @MainActor
    func run() async throws {
        guard let url = URL(string: engine) else { throw ValidationError("\(engine) isn't a URL.") }
        let connection = HTTPEngineConnection(baseURL: url, token: token, pinnedFingerprint: pin.flatMap(Self.hex))
        let info = try await connection.engineInfo()
        guard let descriptor = try await connection.operations().operations.first(where: { $0.operation == operation }) else {
            throw ValidationError("\(info.name) has no operation \(operation).")
        }
        let session = SessionLog()
        defer { session.clear() }
        let run = RunSession(engine: connection, engineInfo: info, descriptor: descriptor, folder: session.folder)
        for pair in text {
            let (name, value) = try Self.split(pair)
            run.form.text[name] = value
        }
        for pair in file {
            let (name, path) = try Self.split(pair)
            run.media[name, default: []].append(await MediaItem.reading(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
        }
        for pair in data {
            let (name, value) = try Self.split(pair)
            guard let json = try? MESJSON.decoder.decode(JSONValue.self, from: Data(value.utf8)) else {
                throw ValidationError("--data \(name) isn't JSON.")
            }
            run.data[name] = json
        }
        for pair in param {
            let (name, value) = try Self.split(pair)
            run.form.setValue((try? MESJSON.decoder.decode(JSONValue.self, from: Data(value.utf8))) ?? .string(value), at: [name])
        }
        run.form.model = model
        // Users' acceptance: what's given here is sent, whether or not the descriptor lists it.
        if !accept.isEmpty {
            for license in run.form.licencesNeedingAcceptance where accept.contains(license.spdx) { run.acceptances.accept(license) }
            run.form.policy.accepted = accept.sorted()
        }
        if let missing = run.missingInputs.first { throw ValidationError("\(operation) needs input '\(missing.name)'.") }
        let folder = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)

        // Streaming: only when asked for here (the workflow's default doesn't apply to a command).
        run.form.stream = stream != nil
        var writer: WAVStreamWriter?
        var problem: (any Error)?
        if let stream {
            guard run.form.streamableOutputs.contains(where: { $0.name == stream }) else {
                throw ValidationError("\(operation) has no output \(stream) that streams.")
            }
            guard run.form.canStream else { throw ValidationError("\(run.form.effectiveModel?.title ?? "No model") doesn't stream.") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            run.onChunk = { chunk in
                guard chunk.output == stream, problem == nil else { return }
                do {
                    if writer == nil, let format = chunk.format {
                        writer = try WAVStreamWriter(url: folder.appendingPathComponent("\(stream)-stream.wav"), format: format)
                    }
                    if let samples = chunk.samples { try writer?.append(samples) }
                } catch { problem = error }
            }
        }

        await run.run()
        if let stream {
            if let problem { FileHandle.standardError.write(Data("couldn't write the stream: \(problem)\n".utf8)) }
            if let s = run.streamed {
                if let after = s.firstChunkAfter { print("first chunk after \(Int((after * 1000).rounded())) ms") }
                print("streamed \(s.chunks) chunk\(s.chunks == 1 ? "" : "s"), \(String(format: "%.2f", s.seconds)) s\(s.finished ? "" : " (no final chunk)")")
            } else {
                print("no chunks of \(stream) arrived")
            }
            if let url = try writer?.finish() { print("saved \(url.path)") }
        }
        if previews, !run.framePreviews.frames.isEmpty {
            let dir = folder.appendingPathComponent("previews", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for frame in run.framePreviews.frames {
                let name = String(format: "preview-%08.3fs", frame.atSeconds) + (frame.frame.map { "-frame\($0)" } ?? "")
                let file = dir.appendingPathComponent("\(name).\(MediaType.fileExtension(frame.mediaType))")
                try frame.image.write(to: file)
                print("preview \(String(format: "%.3f", frame.atSeconds)) s\(frame.frame.map { " (frame \($0))" } ?? "") \(file.path)")
            }
        } else if previews {
            print("no previews arrived")
        }
        switch run.phase {
        case .finished:
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for result in run.results {
                print("saved \(try ResultExporter.save(result, to: folder).path)")
                if let facts = result.videoFacts { print("video \(facts.line)") }
            }
            if let p = run.results.first?.provenance { print("model \(p.model.id) · \(p.model.license.spdx)") }
            for warning in run.results.first?.job.warnings ?? [] { print("warning \(warning.code): \(warning.message)") }
        case .failed(let message):
            FileHandle.standardError.write(Data("failed: \(message)\n".utf8))
            if !run.refusedTerms.isEmpty {
                let flags = run.refusedTerms.map { "--accept \($0.spdx)" }.joined(separator: " ")
                FileHandle.standardError.write(Data("needs acceptance: read the terms (\(run.refusedTerms.compactMap(\.termsURL).joined(separator: ", "))), then add \(flags)\n".utf8))
            }
            throw ExitCode.failure
        case .cancelled:
            FileHandle.standardError.write(Data("cancelled\n".utf8))
            throw ExitCode.failure
        default:
            throw ExitCode.failure
        }
    }

    static func split(_ pair: String) throws -> (String, String) {
        guard let eq = pair.firstIndex(of: "=") else { throw ValidationError("Expected name=value, got '\(pair)'.") }
        return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
    }

    static func hex(_ s: String) -> Data? {
        var bytes = [UInt8]()
        var it = s.lowercased().makeIterator()
        while let a = it.next(), let b = it.next() { guard let v = UInt8(String([a, b]), radix: 16) else { return nil }; bytes.append(v) }
        return bytes.count == 32 ? Data(bytes) : nil
    }
}
