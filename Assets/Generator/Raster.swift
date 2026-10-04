import AppKit
import ImageIO
import UniformTypeIdentifiers

/// sRGB colour stored as 8-bit straight alpha.
struct RGBA: Equatable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(hex: UInt32) { self.init(r: UInt8(hex >> 16 & 0xFF), g: UInt8(hex >> 8 & 0xFF), b: UInt8(hex & 0xFF)) }
    var cg: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255) }
}

/// A plain pixel buffer (row 0 = top). Pixel art is composed here without any filtering.
struct Bitmap {
    let width: Int, height: Int
    var pixels: [RGBA]

    init(width: Int, height: Int, fill: RGBA = .clear) {
        self.width = width; self.height = height
        pixels = Array(repeating: fill, count: width * height)
    }

    subscript(x: Int, y: Int) -> RGBA {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    func scaledNearest(_ factor: Int) -> Bitmap {
        var out = Bitmap(width: width * factor, height: height * factor)
        for y in 0..<out.height { for x in 0..<out.width { out[x, y] = self[x / factor, y / factor] } }
        return out
    }

    /// Source-over composite (straight alpha) of `other` at an offset.
    mutating func draw(_ other: Bitmap, x ox: Int, y oy: Int) {
        for y in 0..<other.height { for x in 0..<other.width {
            let tx = ox + x, ty = oy + y
            guard tx >= 0, ty >= 0, tx < width, ty < height else { continue }
            let s = other[x, y]
            if s.a == 255 { self[tx, ty] = s; continue }
            if s.a == 0 { continue }
            let d = self[tx, ty]
            let sa = Double(s.a) / 255, da = Double(d.a) / 255
            let oa = sa + da * (1 - sa)
            func mix(_ sc: UInt8, _ dc: UInt8) -> UInt8 {
                UInt8(((Double(sc) * sa + Double(dc) * da * (1 - sa)) / oa).rounded())
            }
            self[tx, ty] = RGBA(r: mix(s.r, d.r), g: mix(s.g, d.g), b: mix(s.b, d.b), a: UInt8((oa * 255).rounded()))
        }}
    }

    func cgImage() -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (i, p) in pixels.enumerated() {
            bytes[i * 4] = p.r; bytes[i * 4 + 1] = p.g; bytes[i * 4 + 2] = p.b; bytes[i * 4 + 3] = p.a
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Reads a CGImage back as straight-alpha sRGB pixels.
    init(_ image: CGImage) {
        self.init(width: image.width, height: image.height)
        let context = Canvas(width: width, height: height)
        context.cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self = context.bitmap()
    }
}

/// Anti-aliased CoreGraphics drawing surface (y up, like CG) that converts to `Bitmap`.
final class Canvas {
    let cg: CGContext
    let width: Int, height: Int

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    func bitmap() -> Bitmap {
        var out = Bitmap(width: width, height: height)
        let data = cg.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4 // CGContext memory rows start at the top.
            let a = data[i + 3]
            func un(_ c: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (Double(c) * 255 / Double(a)).rounded())) }
            out[x, y] = RGBA(r: un(data[i]), g: un(data[i + 1]), b: un(data[i + 2]), a: a)
        }}
        return out
    }

    /// Draws text with AppKit (previews only).
    func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .medium) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                         .foregroundColor: color]).draw(at: NSPoint(x: x, y: y))
        NSGraphicsContext.restoreGraphicsState()
    }
}

enum PNG {
    static func write(_ bitmap: Bitmap, to path: String) { write(bitmap.cgImage(), to: path) }

    static func write(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("cannot write \(path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("cannot finalize \(path)") }
    }

    static func read(_ path: String) -> CGImage {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(path)") }
        return image
    }
}
