import AppKit
import DesignScaffold
import MESCore
import MESFormsUI
import PixelAgencyRun
import SwiftUI

/// The middle of the workflow: the input picture while editing, live progress and previews while running (LITE-6),
/// the result when done (LITE-7), and the mask editor when painting a mask (LITE-5).
struct Canvas: View {
    @Bindable var workflow: RunWorkflow
    let saveFolder: URL?

    var body: some View {
        Group {
            if let run = workflow.current {
                RunCanvas(workflow: workflow, run: run, saveFolder: saveFolder)
            } else if workflow.isConnecting {
                ProgressView("Connecting to \(workflow.engine?.name ?? "the engine")…")
            } else {
                EmptyState(title: workflow.engine == nil ? "Choose an engine" : "Choose an operation",
                           detail: workflow.problem ?? workflow.pairingProblem ?? (workflow.engine == nil
                               ? "Engines on your network appear on the left. Add one by address with +."
                               : "Its controls come from the engine's own description of it."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Color.surface)
    }
}

struct EmptyState: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: Tokens.Space.s) {
            Text(title).font(Tokens.Font.panelTitle)
            Text(detail).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
    }
}

struct RunCanvas: View {
    let workflow: RunWorkflow
    @Bindable var run: RunSession
    let saveFolder: URL?
    @State private var selected = 0
    @State private var saved: URL?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch run.phase {
                case .finished: results
                case .submitting, .running, .collecting: progress
                case .failed(let message): ended("The run failed", message, symbol: "exclamationmark.triangle", tint: Tokens.Color.failure)
                case .cancelled: ended("Cancelled", "The engine stopped the job and discarded it.", symbol: "xmark.circle", tint: Tokens.Color.secondaryLabel)
                case .editing: editing
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Tokens.Space.l)
            if run.phase == .finished { resultBar }
        }
        .onChange(of: run.id) { selected = 0; saved = nil }
    }

    // MARK: Editing

    var editing: some View {
        Group {
            if let image = firstImage {
                PictureView(file: image.file, mask: maskFile)
            } else {
                EmptyState(title: run.descriptor.title,
                           detail: run.missingInputs.isEmpty ? "Set the controls on the right, then Run." : "Needs: \(run.missingInputs.map { FormSchema.label($0.name) }.joined(separator: ", ")).")
            }
        }
    }

    var firstImage: MediaItem? {
        run.descriptor.inputs.filter { $0.kind == .image }.lazy.compactMap { run.media[$0.name]?.first }.first
    }

    var maskFile: URL? {
        run.descriptor.inputs.first { $0.kind == .mask }.flatMap { run.media[$0.name]?.first?.file }
    }

    // MARK: Running

    var progress: some View {
        VStack(spacing: Tokens.Space.m) {
            if let preview = run.preview, let image = NSImage(data: preview) {
                Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
            } else if let image = firstImage {
                PictureView(file: image.file, mask: nil).opacity(0.35)
            }
            VStack(spacing: Tokens.Space.xs) {
                if case .running(_, _, let fraction?, _) = run.phase {
                    ProgressView(value: fraction).frame(maxWidth: 320)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(statusLine).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                Button("Cancel") { Task { await run.cancel() } }.keyboardShortcut(".", modifiers: .command)
            }
        }
    }

    var statusLine: String {
        switch run.phase {
        case .submitting: "Sending to \(run.engineInfo.name)…"
        case .running(let state, let stage, let fraction, let message):
            [message ?? (stage ?? .running).rawValue.capitalized, fraction.map { "\(Int($0 * 100))%" }, state == .waiting ? "waiting for the engine" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        case .collecting: "Collecting the results…"
        default: ""
        }
    }

    func ended(_ title: String, _ detail: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: Tokens.Space.s) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(tint)
            Text(title).font(Tokens.Font.panelTitle)
            Text(detail).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).multilineTextAlignment(.center)
                .frame(maxWidth: 420).textSelection(.enabled)
            Button("Run Again") { workflow.again() }
        }
    }

    // MARK: Results

    var results: some View {
        VStack(spacing: Tokens.Space.s) {
            if let result = current {
                if result.isImage {
                    PictureView(file: result.file, mask: nil)
                    Text([result.output.width.map { w in "\(w) × \(result.output.height ?? 0)" }, result.output.mediaType,
                          ByteCountFormatter.string(fromByteCount: Int64(result.output.bytes), countStyle: .file)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                } else {
                    ScrollView {
                        Text(Self.json(result)).font(Tokens.Font.mono).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(Tokens.Space.m)
                    }
                    .cardSurface()
                }
            }
            if run.results.count > 1 {
                HStack(spacing: Tokens.Space.s) {
                    ForEach(Array(run.results.enumerated()), id: \.offset) { i, r in
                        Button { selected = i } label: {
                            VStack(spacing: 2) {
                                Thumbnail(file: r.isImage ? r.file : nil, size: 44)
                                Text(r.output.name).font(Tokens.Font.caption)
                            }
                            .padding(3)
                            .background(i == selected ? Tokens.Color.selectionWash : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    var current: RunResult? { run.results.indices.contains(selected) ? run.results[selected] : run.results.first }

    var resultBar: some View {
        HStack(spacing: Tokens.Space.s) {
            if let result = current {
                Button { save(result) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .disabled(saveFolder == nil).help(saveFolder.map { "Save to \($0.lastPathComponent)" } ?? "Choose a working folder first")
                Button("Save As…") { saveAs(result) }
                ShareLink(item: result.file) { Label("Share", systemImage: "square.and.arrow.up") }
                if result.isImage {
                    Button { workflow.useAsInput(result) } label: { Label("Use as Input", systemImage: "arrow.uturn.right") }
                        .help("Send this result to the next operation you choose")
                }
                if let desktop = Self.desktopApp {
                    Button("Open in Desktop") { Self.open(result.file, in: desktop) }
                }
                Spacer()
                if let saved {
                    Button("Saved as \(saved.lastPathComponent)") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        .buttonStyle(.link).font(Tokens.Font.caption)
                } else if let problem {
                    Text(problem).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure)
                }
                Button("Run Again") { workflow.again() }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Tokens.Space.l).padding(.vertical, Tokens.Space.s)
        .background(.bar)
    }

    func save(_ result: RunResult) {
        guard let saveFolder else { return }
        do { saved = try ResultExporter.save(result, to: saveFolder); problem = nil } catch { problem = "Couldn't save: \(error.localizedDescription)" }
    }

    func saveAs(_ result: RunResult) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(result.job.operation.split(separator: ".").last ?? "result").\(result.file.pathExtension)"
        panel.directoryURL = saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: result.file, to: url)
            saved = url
        } catch { problem = "Couldn't save: \(error.localizedDescription)" }
    }

    /// LITE-15: offered only when Pixel Agency Desktop is installed (Lite OQ-4).
    static let desktopBundleID = "com.xocialize.pixelagency.desktop"

    /// Pixel Agency Desktop, when it's installed and this isn't it (Desktop embeds this view; its results are already
    /// in its library).
    static var desktopApp: URL? {
        guard Bundle.main.bundleIdentifier != desktopBundleID else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopBundleID)
    }

    static func open(_ file: URL, in app: URL) {
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func json(_ result: RunResult) -> String {
        let value = result.output.value ?? (try? MESJSON.decoder.decode(JSONValue.self, from: Data(contentsOf: result.file))) ?? .null
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? ""
    }
}

/// A picture fitted to the space, optionally with its mask overlaid (white = will change).
struct PictureView: View {
    let file: URL
    let mask: URL?

    var body: some View {
        if let image = NSImage(contentsOf: file) {
            Image(nsImage: image).resizable().scaledToFit()
                .overlay {
                    if let mask, let maskImage = NSImage(contentsOf: mask) {
                        Tokens.Color.accent.opacity(0.45)
                            .mask(Image(nsImage: maskImage).resizable().scaledToFit().luminanceToAlpha())
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
                .accessibilityLabel(file.lastPathComponent)
        } else {
            Text(file.lastPathComponent).foregroundStyle(Tokens.Color.secondaryLabel)
        }
    }
}
