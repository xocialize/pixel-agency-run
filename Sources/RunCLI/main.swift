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
            run.media[name, default: []].append(MediaItem(file: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
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
        if let missing = run.missingInputs.first { throw ValidationError("\(operation) needs input '\(missing.name)'.") }

        await run.run()
        switch run.phase {
        case .finished:
            let folder = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for result in run.results { print("saved \(try ResultExporter.save(result, to: folder).path)") }
            if let p = run.results.first?.provenance { print("model \(p.model.id) · \(p.model.license.spdx)") }
        case .failed(let message):
            FileHandle.standardError.write(Data("failed: \(message)\n".utf8))
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
