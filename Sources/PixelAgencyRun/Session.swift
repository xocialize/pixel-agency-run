import CoreGraphics
import Foundation
import ImageIO
import MESCore
import Observation
import UniformTypeIdentifiers

/// This session's runs and their results (LITE-11). Nothing is kept across launches: the folder holding collected
/// results is deleted when the session ends, so a result survives only if the user saves it (Lite OQ-2).
@MainActor @Observable
public final class SessionLog {
    public private(set) var runs: [RunSession] = []
    /// Where collected outputs live until saved.
    public let folder: URL

    public init(folder: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PixelAgencyLite-session-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)) {
        self.folder = folder
    }

    /// A new run, listed in the session.
    public func add(_ run: RunSession) { runs.insert(run, at: 0) }

    public var results: [RunResult] { runs.flatMap(\.results) }

    /// Ends the session: forgets the runs and deletes the collected files.
    public func clear() {
        runs = []
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Saving results (LITE-7): into the working folder by default, or a folder the user picks. Never overwrites.
public enum ResultExporter {
    /// Copies `result` into `folder` as `<operation>-<yyyyMMdd-HHmmss>[-n].<ext>` and returns the new file.
    @discardableResult
    public static func save(_ result: RunResult, to folder: URL, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let op = result.job.operation.split(separator: ".").last.map(String.init) ?? "result"
        let base = "\(op)-\(formatter.string(from: date))\(result.output.index > 0 ? "-\(result.output.index)" : "")"
        let ext = result.file.pathExtension
        var target = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        try FileManager.default.copyItem(at: result.file, to: target)
        return target
    }
}

/// The working folder (README APP-3–5): chosen at first launch, kept as an app-scope security-scoped bookmark,
/// resolved and opened at every launch, released at quit. Problems are reported, never silent.
@MainActor @Observable
public final class WorkingFolder {
    public enum Status: Equatable {
        case notChosen
        case ready(URL)
        /// The bookmark no longer resolves (moved, renamed, or on a volume that's gone).
        case unavailable(String)
    }

    public private(set) var status: Status = .notChosen
    let defaults: UserDefaults
    /// The defaults key the bookmark is kept under. An app keeping several folders (Desktop: the working folder and
    /// the models folder) uses one key each.
    let key: String
    /// The app's name, for messages.
    let appName: String
    public static let workingFolderKey = "PixelAgency.workingFolderBookmark"
    private var accessing: URL?

    public init(defaults: UserDefaults = .standard, key: String = WorkingFolder.workingFolderKey, appName: String = "Pixel Agency Lite") {
        self.defaults = defaults
        self.key = key
        self.appName = appName
        resolve()
    }

    public var url: URL? { if case .ready(let url) = status { url } else { nil } }

    /// Resolves the bookmark and starts accessing the folder (APP-4).
    public func resolve() {
        guard let data = defaults.data(forKey: key) else { status = .notChosen; return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() || FileManager.default.isWritableFile(atPath: url.path) else {
                status = .unavailable("\(appName) can't open \(url.path) any more.")
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                url.stopAccessingSecurityScopedResource()
                status = .unavailable("\(url.path) is missing. Its volume may not be connected.")
                return
            }
            accessing = url
            if stale { try? store(url) }                          // refresh a stale-but-resolvable bookmark
            status = .ready(url)
        } catch {
            status = .unavailable("The working folder can't be found: \(error.localizedDescription)")
        }
    }

    /// Sets the working folder (APP-3, APP-5) from a URL the user chose in an open panel.
    public func choose(_ url: URL) throws {
        stop()
        try store(url)
        resolve()
    }

    /// Stops accessing the folder (at quit).
    public func stop() {
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
    }

    func store(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: key)
    }
}

/// A mask for `fill`, `erase` and `extend` (LITE-5; Image profile §1.6): 8-bit grey, the image's size, white where
/// the engine may change pixels. Painted with a brush, or taken from `image.matte` ("select subject", Lite OQ-1).
public struct MaskRaster: Sendable, Equatable {
    public struct Stroke: Sendable, Equatable {
        /// Points in image pixels, top-left origin.
        public var points: [CGPoint]
        public var radius: CGFloat
        /// Erasing paints black (keep) instead of white (change).
        public var erases: Bool
        public init(points: [CGPoint], radius: CGFloat, erases: Bool = false) {
            self.points = points; self.radius = radius; self.erases = erases
        }
    }

    public let width: Int
    public let height: Int
    /// One byte per pixel, row by row from the top.
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width; self.height = height
        pixels = [UInt8](repeating: 0, count: width * height)
    }

    /// A mask from an image (a matte, or a mask file), resampled to `width` × `height` and reduced to grey.
    public init?(image data: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(width: width, height: height)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Paints strokes: round brushes along each path.
    public mutating func paint(_ strokes: [Stroke]) {
        let (w, h) = (width, height)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))                 // top-left origin, like the image
            ctx.scaleBy(x: 1, y: -1)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for stroke in strokes {
                ctx.setStrokeColor(gray: stroke.erases ? 0 : 1, alpha: 1)
                ctx.setFillColor(gray: stroke.erases ? 0 : 1, alpha: 1)
                ctx.setLineWidth(stroke.radius * 2)
                if stroke.points.count == 1, let p = stroke.points.first {
                    ctx.fillEllipse(in: CGRect(x: p.x - stroke.radius, y: p.y - stroke.radius, width: stroke.radius * 2, height: stroke.radius * 2))
                } else if let first = stroke.points.first {
                    ctx.move(to: first)
                    for p in stroke.points.dropFirst() { ctx.addLine(to: p) }
                    ctx.strokePath()
                }
            }
        }
    }

    public mutating func invert() { pixels = pixels.map { 255 - $0 } }
    public mutating func clear() { pixels = [UInt8](repeating: 0, count: width * height) }
    public var isEmpty: Bool { !pixels.contains { $0 > 0 } }
    public func value(_ x: Int, _ y: Int) -> UInt8 { pixels[y * width + x] }

    /// The mask as an 8-bit grey PNG.
    public func png() -> Data {
        var copy = pixels
        let image = copy.withUnsafeMutableBytes { buffer -> CGImage in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            return ctx.makeImage()!
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Writes the PNG into `folder` and returns it as a media input.
    public func mediaItem(in folder: URL) throws -> MediaItem {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("mask-\(UUID().uuidString.prefix(8)).png")
        try png().write(to: file)
        return MediaItem(file: file, mediaType: "image/png", name: "Mask")
    }
}
