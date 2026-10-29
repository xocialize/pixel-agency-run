import AppKit
import DesignScaffold
import DesignScaffoldMedia
import MESCore
import MESFormsUI
import PixelAgencyRun
import SwiftUI
import UniformTypeIdentifiers

/// The right of the workflow: the operation's controls, drawn from its descriptor by MESFormsUI (LITE-4), with
/// Lite's media slots (LITE-5); the Run button; and, after a run, what happened (LITE-8).
struct Inspector: View {
    @Bindable var workflow: RunWorkflow

    var body: some View {
        if let run = workflow.current {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Space.l) {
                        OperationFormContent(form: run.form) { spec in InputSlot(workflow: workflow, run: run, spec: spec) }
                            .disabled(run.phase != .editing)
                        if run.phase == .finished, let result = run.results.first { WhatHappened(run: run, result: result) }
                    }
                    .padding(Tokens.Space.l)
                }
                RunBar(workflow: workflow, run: run)
            }
        } else {
            EmptyState(title: "Controls", detail: "An operation's controls appear here, drawn from the engine's descriptor.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Run, and why it can't run yet.
struct RunBar: View {
    let workflow: RunWorkflow
    @Bindable var run: RunSession

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if run.phase == .editing {
                if let missing = run.missingInputs.first {
                    Text("Needs \(FormSchema.label(missing.name).lowercased()).").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                } else if let issue = run.form.issues.first {
                    Text("\(FormSchema.label(issue.key)): \(issue.value)").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure)
                }
            }
            HStack {
                if run.phase.isActive {
                    Button("Cancel") { Task { await run.cancel() } }
                    Spacer()
                    ProgressView().controlSize(.small)
                } else if run.phase == .editing {
                    Spacer()
                    Button { workflow.start() } label: { Label("Run", systemImage: "play.fill") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!run.canRun)
                } else {
                    Spacer()
                    Button("Run Again") { workflow.again() }
                }
            }
        }
        .padding(Tokens.Space.m)
        .background(.bar)
    }
}

/// One non-text input: media, or data.
struct InputSlot: View {
    let workflow: RunWorkflow
    @Bindable var run: RunSession
    let spec: InputSpec

    var body: some View {
        if spec.kind == .data { DataSlot(run: run, spec: spec) } else { MediaSlot(workflow: workflow, run: run, spec: spec) }
    }
}

/// One media input (LITE-5): drop, open or paste files; a mask input also gets a brush and "select subject".
struct MediaSlot: View {
    let workflow: RunWorkflow
    @Bindable var run: RunSession
    let spec: InputSpec
    @State private var painting = false
    @State private var problem: String?

    var items: [MediaItem] { run.media[spec.name] ?? [] }
    var allowsMultiple: Bool { (spec.max ?? 1) > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack {
                Text(FormSchema.label(spec.name) + (spec.required ? "" : " (optional)"))
                Spacer()
                if spec.kind == .mask {
                    Button("Paint…") { painting = true }.disabled(baseImage == nil)
                        .help(baseImage == nil ? "Add the image first" : "Paint where the engine may change the picture")
                }
            }
            MediaWell(allowsMultiple ? "Drop images, or click to choose" : "Drop \(spec.kind == .mask ? "a mask" : "an image"), or click to choose",
                      systemImage: spec.kind == .mask ? "circle.lefthalf.filled" : "photo",
                      isEmpty: items.isEmpty, allowing: [.image], allowsMultiple: allowsMultiple,
                      onPick: add, onReject: { _ in problem = "That isn't an image." }) {
                HStack(spacing: Tokens.Space.s) {
                    ForEach(items) { item in
                        ZStack(alignment: .topTrailing) {
                            Thumbnail(file: item.file, size: 56)
                            Button { run.media[spec.name]?.removeAll { $0.id == item.id } } label: {
                                Image(systemName: Tokens.Symbol.cancel)
                            }
                            .buttonStyle(.borderless).foregroundStyle(.white, .black.opacity(0.6))
                            .accessibilityLabel("Remove \(item.name)")
                        }
                    }
                }
            }
            .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg], perform: paste)
            if let size = items.first.flatMap({ i in i.width.map { "\($0) × \(i.height ?? 0)" } }) {
                Text(size).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            }
            if let problem { Text(problem).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure) }
        }
        .sheet(isPresented: $painting) {
            if let base = baseImage {
                MaskEditor(workflow: workflow, base: base, existing: items.first) { mask in
                    if let mask { run.media[spec.name] = [mask] }
                    painting = false
                }
            }
        }
    }

    /// The image a mask belongs to: the run's first image input.
    var baseImage: MediaItem? {
        run.descriptor.inputs.filter { $0.kind == .image }.lazy.compactMap { run.media[$0.name]?.first }.first
    }

    func add(_ urls: [URL]) {
        problem = nil
        let new = urls.map { MediaItem(file: $0) }
        run.media[spec.name] = allowsMultiple ? Array((items + new).prefix(spec.max ?? 1)) : Array(new.prefix(1))
    }

    /// Pasted images are written to the session folder first (they have no file of their own).
    func paste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in add([url]) } }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage, let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    Task { @MainActor in
                        let folder = workflow.log.folder
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let file = folder.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
                        try? png.write(to: file)
                        add([file])
                    }
                }
            }
        }
    }
}

/// What happened (LITE-8): the model and its licence, the effective parameters, warnings, and any remote provider.
struct WhatHappened: View {
    let run: RunSession
    let result: RunResult

    /// Effective values for people: sizes as `W × H`, objects as `key: value`, the rest as the forms show them.
    static func display(_ value: JSONValue) -> String {
        if let w = value["width"]?.intValue, let h = value["height"]?.intValue, value.objectValue?.count == 2 { return "\(w) × \(h)" }
        if let object = value.objectValue {
            return object.sorted { $0.key < $1.key }.map { "\(FormSchema.label($0.key).lowercased()): \(display($0.value))" }.joined(separator: ", ")
        }
        if let array = value.arrayValue { return array.map(display).joined(separator: ", ") }
        return FormSchema.display(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            SectionHeader("What happened")
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                if let p = result.provenance {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.model.title ?? p.model.id)
                        LicenseLine(license: p.model.license)
                        if p.model.license.commercialUse != .yes {
                            Text("This result may not be used commercially.").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.degraded)
                        }
                    }
                    if let remote = p.remoteProvider {
                        Text("Ran remotely on \(remote.name)\(remote.billed ? " (billed)" : "")").font(Tokens.Font.caption)
                    }
                }
                if !result.effective.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(result.effective.sorted { $0.key < $1.key }, id: \.key) { key, value in
                            HStack(alignment: .firstTextBaseline) {
                                Text(FormSchema.label(key)).foregroundStyle(Tokens.Color.secondaryLabel)
                                Spacer()
                                Text(Self.display(value)).font(Tokens.Font.mono).lineLimit(2).multilineTextAlignment(.trailing)
                            }
                            .font(Tokens.Font.caption)
                        }
                    }
                }
                ForEach(result.job.warnings, id: \.code) { w in
                    Label("\(w.message) (\(w.code))", systemImage: "exclamationmark.triangle")
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.degraded)
                }
                if let t = result.provenance?.timings, let ms = t.runMs {
                    Text("\(run.engineInfo.name) · ran in \(ms) ms\(t.queueMs.map { ", queued \($0) ms" } ?? "")")
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.tertiaryLabel)
                }
            }
            .padding(Tokens.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}
