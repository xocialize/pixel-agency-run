import AppKit
import DesignScaffold
import DesignScaffoldControls
import PixelAgencyRun
import SwiftUI

/// The mask brush (LITE-5, Lite OQ-1): paint where the engine may change the picture, or start from "select subject"
/// (`image.matte` on the engine). Produces the profile's mask: 8-bit grey, the image's size, white = change.
struct MaskEditor: View {
    let workflow: RunWorkflow
    let base: MediaItem
    let existing: MediaItem?
    let done: (MediaItem?) -> Void

    @State private var mask: MaskRaster
    @State private var stroke: [CGPoint] = []
    @State private var radius: Double = 24
    @State private var erasing = false
    @State private var selecting = false
    @State private var problem: String?
    @State private var revision = 0

    init(workflow: RunWorkflow, base: MediaItem, existing: MediaItem?, done: @escaping (MediaItem?) -> Void) {
        self.workflow = workflow
        self.base = base
        self.existing = existing
        self.done = done
        let (w, h) = (base.width ?? 512, base.height ?? 512)
        let start = existing.flatMap { try? Data(contentsOf: $0.file) }.flatMap { MaskRaster(image: $0, width: w, height: h) }
        _mask = State(initialValue: start ?? MaskRaster(width: w, height: h))
    }

    var body: some View {
        VStack(spacing: Tokens.Space.m) {
            HStack {
                Text("Paint the mask").font(Tokens.Font.panelTitle)
                Spacer()
                Text("White areas change; the rest stays exactly as it is.").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            }
            GeometryReader { geo in
                let fit = Self.fit(CGSize(width: mask.width, height: mask.height), in: geo.size)
                ZStack(alignment: .topLeading) {
                    if let image = NSImage(contentsOf: base.file) { Image(nsImage: image).resizable().frame(width: fit.width, height: fit.height) }
                    Tokens.Color.accent.opacity(0.5)
                        .mask(Image(decorative: overlay, scale: 1).resizable().luminanceToAlpha())
                        .frame(width: fit.width, height: fit.height)
                        .id(revision)
                }
                .frame(width: fit.width, height: fit.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let scale = CGFloat(mask.width) / max(1, fit.width)
                    let point = CGPoint(x: value.location.x * scale, y: value.location.y * scale)
                    let segment = (stroke.last.map { [$0] } ?? []) + [point]
                    stroke.append(point)
                    mask.paint([.init(points: segment, radius: radius * scale, erases: erasing)])
                    revision += 1
                }.onEnded { _ in stroke = [] })
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .accessibilityLabel("Mask canvas")
            }
            .frame(minWidth: 560, minHeight: 400)
            HStack(spacing: Tokens.Space.m) {
                Picker("Brush", selection: $erasing) {
                    Text("Paint").tag(false)
                    Text("Erase").tag(true)
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                LabeledSlider("Brush size", value: $radius, in: 4...120, step: 1, decimals: 0, unit: "px").frame(width: 200)
                Button("Invert") { mask.invert(); revision += 1 }
                Button("Clear") { mask.clear(); revision += 1 }
                if workflow.canSelectSubject {
                    Button(selecting ? "Selecting…" : "Select Subject") { selectSubject() }.disabled(selecting).fixedSize()
                        .help("Ask the engine to find the main subject (image.matte)")
                }
                Spacer()
                if let problem { Text(problem).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure) }
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Use Mask") {
                    do { done(try mask.mediaItem(in: workflow.log.folder)) } catch { problem = "\(error.localizedDescription)" }
                }
                .keyboardShortcut(.defaultAction).disabled(mask.isEmpty)
            }
            .controlSize(.small)
            .fixedSize(horizontal: false, vertical: true)
            .buttonStyle(.bordered)
        }
        .padding(Tokens.Space.l)
        .frame(minWidth: 780, minHeight: 560)
    }

    /// The mask as an image for display (grey; shown through `luminanceToAlpha`).
    var overlay: CGImage {
        var pixels = mask.pixels
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: mask.width, height: mask.height, bitsPerComponent: 8, bytesPerRow: mask.width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
        }
    }

    func selectSubject() {
        selecting = true
        problem = nil
        Task {
            do {
                if let selected = try await workflow.selectSubject(of: base) { mask = selected; revision += 1 }
                else { problem = "The engine found no subject." }
            } catch { problem = "\(error)" }
            selecting = false
        }
    }

    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        let scale = min(box.width / max(1, size.width), box.height / max(1, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
