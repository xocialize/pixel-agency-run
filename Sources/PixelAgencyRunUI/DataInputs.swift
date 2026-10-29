import AppKit
import DesignScaffold
import MESCore
import MESFormsUI
import PixelAgencyRun
import SwiftUI

/// One `data` input. The Image profile's `points` (`image.segment`) gets a picker on the run's image; any other data
/// input is typed as JSON.
struct DataSlot: View {
    @Bindable var run: RunSession
    let spec: InputSpec
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if spec.name == "points" {
                HStack {
                    Text(FormSchema.label(spec.name) + (spec.required ? "" : " (optional)"))
                    Spacer()
                    Button(points.isEmpty ? "Pick…" : "Edit…") { picking = true }.disabled(baseImage == nil)
                        .help(baseImage == nil ? "Add the image first" : "Click the object to select; add points to exclude")
                }
                Text(summary).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            } else {
                JSONEditor(label: FormSchema.label(spec.name) + (spec.required ? "" : " (optional)"),
                           value: Binding(get: { run.data[spec.name] }, set: { run.data[spec.name] = $0 }))
            }
        }
        .sheet(isPresented: $picking) {
            if let base = baseImage {
                PointPicker(base: base, points: points) { picked in
                    if let picked { run.data[spec.name] = picked.isEmpty ? nil : PointPicker.json(picked) }
                    picking = false
                }
            }
        }
    }

    var points: [PointPicker.Point] { run.data[spec.name].map(PointPicker.points) ?? [] }

    var summary: String {
        let include = points.filter(\.include).count, exclude = points.count - include
        if points.isEmpty { return "None yet" }
        return "\(include) to include" + (exclude > 0 ? ", \(exclude) to exclude" : "")
    }

    var baseImage: MediaItem? {
        run.descriptor.inputs.filter { $0.kind == .image }.lazy.compactMap { run.media[$0.name]?.first }.first
    }
}

/// Points on an image for `image.segment` (Image §5): `[{x, y, label: include|exclude}]`, normalized 0–1 from the
/// top left. Click to add a point in the chosen mode; click a point to remove it.
struct PointPicker: View {
    struct Point: Equatable, Identifiable {
        let id = UUID()
        var x: Double
        var y: Double
        var include: Bool
        static func == (a: Point, b: Point) -> Bool { a.x == b.x && a.y == b.y && a.include == b.include }
    }

    let base: MediaItem
    let done: ([Point]?) -> Void
    @State private var points: [Point]
    @State private var including = true

    init(base: MediaItem, points: [Point], done: @escaping ([Point]?) -> Void) {
        self.base = base
        self.done = done
        _points = State(initialValue: points)
    }

    var body: some View {
        VStack(spacing: Tokens.Space.m) {
            HStack {
                Text("Pick points").font(Tokens.Font.panelTitle)
                Spacer()
                Text("Click the object to select it; add exclude points to leave parts out.")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            }
            GeometryReader { geo in
                let fit = MaskEditor.fit(CGSize(width: Double(base.width ?? 512), height: Double(base.height ?? 512)), in: geo.size)
                canvas(fit).position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .frame(minWidth: 560, minHeight: 400)
            HStack(spacing: Tokens.Space.m) {
                Picker("Mode", selection: $including) {
                    Label("Include", systemImage: "plus.circle").tag(true)
                    Label("Exclude", systemImage: "minus.circle").tag(false)
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                Button("Clear") { points = [] }.disabled(points.isEmpty)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Use Points") { done(points) }.keyboardShortcut(.defaultAction).disabled(!points.contains(where: \.include))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(Tokens.Space.l)
        .frame(minWidth: 780, minHeight: 560)
    }

    /// The image at `fit`, with the points over it; a click adds one in the current mode.
    func canvas(_ fit: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let image = NSImage(contentsOf: base.file) { Image(nsImage: image).resizable().frame(width: fit.width, height: fit.height) }
            ForEach(points) { point in
                PointMark(point: point) { points.removeAll { $0.id == point.id } }
                    .position(x: point.x * fit.width, y: point.y * fit.height)
            }
        }
        .frame(width: fit.width, height: fit.height)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in add(tap.location, in: fit) })
        .accessibilityLabel("Image: click to add a point")
    }

    func add(_ location: CGPoint, in fit: CGSize) {
        let x = min(1, max(0, location.x / max(1, fit.width)))
        let y = min(1, max(0, location.y / max(1, fit.height)))
        points.append(Point(x: x, y: y, include: including))
    }

    static func json(_ points: [Point]) -> JSONValue {
        .array(points.map { ["x": .number($0.x), "y": .number($0.y), "label": .string($0.include ? "include" : "exclude")] })
    }

    static func points(_ value: JSONValue) -> [Point] {
        (value.arrayValue ?? []).compactMap { p in
            guard let x = p["x"]?.numberValue, let y = p["y"]?.numberValue else { return nil }
            return Point(x: x, y: y, include: p["label"]?.stringValue != "exclude")
        }
    }
}

/// One picked point: green to include, red to exclude. Clicking it removes it.
struct PointMark: View {
    let point: PointPicker.Point
    let remove: () -> Void

    var body: some View {
        let tint: Color = point.include ? Tokens.Color.ready : Tokens.Color.failure
        Button(action: remove) {
            Image(systemName: point.include ? "plus.circle.fill" : "minus.circle.fill")
                .font(.title2).foregroundStyle(.white, tint).shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(point.include ? "Include" : "Exclude") point at \(Int(point.x * 100))%, \(Int(point.y * 100))%; remove")
    }
}
