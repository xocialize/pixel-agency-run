import AppKit
import AVFoundation
import DesignScaffold
import MESClientKit
import MESCore
import MESFormsUI
import PixelAgencyRun
import SwiftUI

/// The middle of the workflow: the input picture while editing, live progress and previews while running (LITE-6),
/// the result when done (LITE-7), and the mask editor when painting a mask (LITE-5). A streamed output plays as it
/// arrives (Base §11); audio results play, and data results show as text. A video plays with its facts: a running job's
/// stills show as they come (Video §1.14), and a result's frames under it.
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
    @State private var listener = StreamListener()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch run.phase {
                case .finished: results
                case .submitting, .running, .collecting: progress
                case .failed(let message):
                    if !run.refusedTerms.isEmpty {
                        TermsNeeded(workflow: workflow, run: run)
                    } else {
                        ended("The run failed", message, symbol: "exclamationmark.triangle", tint: Tokens.Color.failure)
                    }
                case .cancelled: ended("Cancelled", "The engine stopped the job and discarded it.", symbol: "xmark.circle", tint: Tokens.Color.secondaryLabel)
                case .editing: editing
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Tokens.Space.l)
            if listener.isPlaying && !run.phase.isActive { streamBar }
            if run.phase == .finished { resultBar }
        }
        .onChange(of: run.id) { selected = 0; saved = nil }
        // A streamed run plays as it arrives; the listener joins before the run starts, or late with what came.
        .task(id: run.id) { await listener.follow(run) }
    }

    // MARK: Editing

    var editing: some View {
        Group {
            if let image = firstImage {
                PictureView(file: image.file, mask: maskFile)
            } else if let clip = firstVideo {
                VideoPlayerView(file: clip.file, title: clip.name, facts: clip.videoFacts).frame(maxWidth: 720)
            } else {
                EmptyState(title: run.descriptor.title,
                           detail: run.missingInputs.isEmpty ? "Set the controls on the right, then Run." : "Needs: \(run.missingInputs.map { FormSchema.label($0.name) }.joined(separator: ", ")).")
            }
        }
    }

    var firstImage: MediaItem? {
        run.descriptor.inputs.filter { $0.kind == .image }.lazy.compactMap { run.media[$0.name]?.first }.first
    }

    var firstVideo: MediaItem? {
        run.descriptor.inputs.filter { $0.kind == .video }.lazy.compactMap { run.media[$0.name]?.first }.first
    }

    var maskFile: URL? {
        run.descriptor.inputs.first { $0.kind == .mask }.flatMap { run.media[$0.name]?.first?.file }
    }

    // MARK: Running

    var progress: some View {
        VStack(spacing: Tokens.Space.m) {
            if let streamed = run.streamed {
                StreamingView(streamed: streamed, playing: listener.isPlaying)
            } else if let latest = run.framePreviews.frames.last, let image = NSImage(data: latest.image) {
                // A video's stills, as the engine sends them: the newest large, all of them in time order below.
                Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
                FramePreviewStrip(frames: run.framePreviews.frames)
            } else if let preview = run.preview, let image = NSImage(data: preview) {
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
                if run.streamed != nil {
                    // Barge-in: the sound stops now, and the engine stops the job within a chunk.
                    Button { stopStream() } label: { Label("Stop", systemImage: "stop.fill") }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Cancel") { Task { await run.cancel() } }.keyboardShortcut(".", modifiers: .command)
                }
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

    func stopStream() {
        listener.stop()
        Task { await run.cancel() }
    }

    /// The stream still playing out after its run ended.
    var streamBar: some View {
        HStack(spacing: Tokens.Space.s) {
            Image(systemName: "waveform").foregroundStyle(Tokens.Color.accent)
            Text("Playing the stream as it arrived").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            Spacer()
            Button { listener.stop() } label: { Label("Stop", systemImage: "stop.fill") }
        }
        .controlSize(.small)
        .padding(.horizontal, Tokens.Space.l).padding(.vertical, Tokens.Space.xs)
        .background(.bar)
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
                } else if result.isVideo {
                    VideoPlayerView(file: result.file, title: FormSchema.label(result.output.name), facts: result.videoFacts)
                    FramePreviewStrip(file: result.file, count: 8)
                    Text([result.output.mediaType, ByteCountFormatter.string(fromByteCount: Int64(result.output.bytes), countStyle: .file)]
                        .joined(separator: " · "))
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                } else if result.isAudio {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: Tokens.Space.s) {
                        AudioPlayerView(file: result.file, title: FormSchema.label(result.output.name))
                        Text([result.audioFacts, result.output.mediaType,
                              ByteCountFormatter.string(fromByteCount: Int64(result.output.bytes), countStyle: .file)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                    }
                    .padding(Tokens.Space.m)
                    .frame(maxWidth: 520)
                    .cardSurface()
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        Text(result.text).font(Self.isProse(result) ? Tokens.Font.body : Tokens.Font.mono).textSelection(.enabled)
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
                                ResultThumbnail(result: r, size: 44)
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
                if result.isImage || result.isAudio || result.isVideo {
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

    /// A transcript, timed lines or a text output reads as text; other data as JSON.
    static func isProse(_ result: RunResult) -> Bool {
        if result.output.kind == .text { return true }
        guard let object = result.value?.objectValue, object.count == 1 else { return false }
        return object["text"] != nil || object["lines"] != nil
    }
}

/// A streamed output arriving: how much sound has come, and how soon the first of it did.
struct StreamingView: View {
    let streamed: StreamedOutput
    let playing: Bool

    var body: some View {
        VStack(spacing: Tokens.Space.s) {
            Image(systemName: playing ? "waveform" : "waveform.slash")
                .font(.system(size: 36)).foregroundStyle(playing ? Tokens.Color.accent : Tokens.Color.secondaryLabel)
                .symbolEffect(.variableColor.iterative, isActive: playing && !streamed.finished)
            Text("\(FormSchema.label(streamed.output)) streaming").font(Tokens.Font.panelTitle)
            Text([String(format: "%.1f s received", streamed.seconds),
                  "\(streamed.chunks) chunk\(streamed.chunks == 1 ? "" : "s")",
                  streamed.firstChunkAfter.map { "first after \(Int(($0 * 1000).rounded())) ms" },
                  streamed.format.map { AudioFacts.line(duration: nil, sampleRate: $0.sampleRate, channels: $0.channels) ?? "" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).monospacedDigit()
        }
    }
}

/// Plays a run's streamed output as it arrives (MESFormsUI's PCMStreamPlayer), and lets what's scheduled play out
/// after the run ends. Stopping silences it at once.
@MainActor @Observable
final class StreamListener {
    private(set) var isPlaying = false
    @ObservationIgnored private var player: PCMStreamPlayer?

    func follow(_ run: RunSession) async {
        stop()
        for await chunk in run.chunks() {
            if player == nil, let format = chunk.format { player = try? PCMStreamPlayer(format: format) }
            guard let player else { continue }
            try? player.enqueue(chunk)
            isPlaying = player.scheduledFrames > 0
        }
        // Only a stream that got its final chunk plays out; a released one (barge-in) stops now.
        guard !Task.isCancelled, run.streamed?.finished == true, let player, player.scheduledFrames > 0 else { stop(); return }
        player.finish()
        while !Task.isCancelled, isPlaying, !player.isDone { try? await Task.sleep(for: .milliseconds(100)) }
        if self.player === player { stop() }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}

/// A result's thumbnail: the picture, the sound's waveform, or a document for text.
struct ResultThumbnail: View {
    let result: RunResult
    let size: CGFloat

    var body: some View {
        if result.isAudio {
            WaveformThumbnail(file: result.file, size: size)
        } else if result.isVideo {
            VideoThumbnail(file: result.file, size: size)
        } else if result.isText {
            Image(systemName: "doc.text").foregroundStyle(Tokens.Color.tertiaryLabel).frame(width: size, height: size)
        } else {
            Thumbnail(file: result.isImage ? result.file : nil, size: size)
        }
    }
}

/// A clip's first frame, small, marked as video.
struct VideoThumbnail: View {
    let file: URL
    let size: CGFloat
    @State private var still: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let still {
                Image(nsImage: still).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(Tokens.Color.tertiaryLabel)
            }
            Image(systemName: "play.fill").font(.system(size: max(7, size / 5))).foregroundStyle(.white)
                .shadow(radius: 1).padding(2)
        }
        .frame(width: size, height: size)
        .background(Tokens.Color.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: file) {
            still = (try? await FrameThumbnails.make(file, count: 1, maxSide: size * 2))?.first.flatMap { NSImage(data: $0.image) }
        }
        .accessibilityLabel("Video: \(file.lastPathComponent)")
    }
}

/// A run the engine refused for terms its user hasn't accepted (Base §10.3): each licence with its notice and Accept,
/// then the run again.
struct TermsNeeded: View {
    let workflow: RunWorkflow
    let run: RunSession

    var body: some View {
        VStack(spacing: Tokens.Space.m) {
            Image(systemName: "checkmark.seal").font(.system(size: 28)).foregroundStyle(Tokens.Color.degraded)
            Text("This model needs your acceptance").font(Tokens.Font.panelTitle)
            Text("Its licence binds each person who uses it. Read the terms, accept them, then run again.")
                .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).multilineTextAlignment(.center)
            ForEach(run.refusedTerms, id: \.spdx) { license in
                LicenseAcceptanceView(license: license, title: Self.title(of: license, in: run), acceptances: run.acceptances)
            }
            Button("Run Again") { workflow.again() }
                .buttonStyle(.borderedProminent)
                .disabled(!run.needsAcceptance.isEmpty)
        }
        .frame(maxWidth: 460)
    }

    /// The offers under `license`, by title.
    static func title(of license: License, in run: RunSession) -> String {
        let titles = run.descriptor.models.filter { $0.license.spdx == license.spdx }.map(\.title)
        return titles.isEmpty ? "This model" : titles.joined(separator: ", ")
    }
}

/// A sound's waveform, small: peaks across the file.
struct WaveformThumbnail: View {
    let file: URL
    let size: CGFloat
    @State private var peaks: [Float] = []

    var body: some View {
        SwiftUI.Canvas { context, area in
            guard !peaks.isEmpty else { return }
            let step = area.width / CGFloat(peaks.count)
            for (i, peak) in peaks.enumerated() {
                let h = max(1, CGFloat(peak) * area.height * 0.9)
                context.fill(Path(CGRect(x: CGFloat(i) * step + step * 0.15, y: (area.height - h) / 2, width: step * 0.7, height: h)),
                             with: .color(Tokens.Color.accent))
            }
        }
        .frame(width: size, height: size)
        .background(Tokens.Color.fieldFill, in: RoundedRectangle(cornerRadius: 4))
        .overlay { if peaks.isEmpty { Image(systemName: "waveform").foregroundStyle(Tokens.Color.tertiaryLabel) } }
        .task(id: file) { peaks = await Self.peaks(file, bars: 16) }
        .accessibilityLabel("Sound: \(file.lastPathComponent)")
    }

    /// The loudest sample of each of `bars` stretches of the file, normalized to the loudest.
    nonisolated static func peaks(_ file: URL, bars: Int) async -> [Float] {
        guard let audio = try? AVAudioFile(forReading: file), audio.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(min(audio.length, 48_000 * 600))),
              (try? audio.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength), per = max(1, frames / bars)
        var peaks = (0..<bars).map { bar -> Float in
            let range = (bar * per)..<min(frames, (bar + 1) * per)
            return range.isEmpty ? 0 : range.reduce(0) { max($0, abs(data[0][$1])) }
        }
        let loudest = peaks.max() ?? 0
        if loudest > 0 { peaks = peaks.map { $0 / loudest } }
        return peaks
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
