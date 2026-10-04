import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Drawing helpers for the README preview generator. CoreGraphics + CoreText + ImageIO only.
// Every rect and point here is in pixels with (0, 0) at the TOP-LEFT; `Canvas` converts to CoreGraphics space.

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

enum Theme: String, CaseIterable { case dark, light }

/// Image language ("ko" or "en"), set by main per pass. `loc` picks the generator's own labels like the app's `loc`.
var language = "ko"
func loc(_ korean: String, _ english: String) -> String { language == "en" ? english : korean }

// MARK: - Files

func readPNG(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("이미지를 읽지 못함: \(path)") }
    return image
}

/// PNG with 144 dpi so Preview/Quick Look show the 2x images at point size.
func writePNG(_ image: CGImage, _ path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { fail("PNG를 만들지 못함: \(path)") }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fail("PNG를 쓰지 못함: \(path)") }
}

/// Looping GIF. Delays are rounded on the cumulative timeline (centiseconds) so rounding never drifts.
func writeGIF(_ frames: [(image: CGImage, seconds: Double)], _ path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "com.compuserve.gif" as CFString,
                                                            frames.count, nil) else { fail("GIF를 만들지 못함: \(path)") }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    var elapsed = 0.0
    for frame in frames {
        let start = (elapsed * 100).rounded()
        elapsed += frame.seconds
        let delay = ((elapsed * 100).rounded() - start) / 100
        CGImageDestinationAddImage(destination, frame.image, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
        ]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { fail("GIF를 쓰지 못함: \(path)") }
}

/// Crop in top-left pixel coordinates (CGImage cropping already uses the image's top-left grid).
func cropImage(_ image: CGImage, _ rect: CGRect) -> CGImage {
    guard let out = image.cropping(to: rect.integral) else { fail("자르기 범위 오류: \(rect)") }
    return out
}

/// High-quality downscale by repeated halving, then a final resample.
func downscale(_ image: CGImage, to size: Int) -> CGImage {
    var current = image
    while current.width / 2 >= size {
        let canvas = Canvas(current.width / 2, current.height / 2)
        canvas.draw(current, CGRect(x: 0, y: 0, width: current.width / 2, height: current.height / 2))
        current = canvas.image()
    }
    if current.width == size { return current }
    let canvas = Canvas(size, size * current.height / current.width)
    canvas.draw(current, CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
    return canvas.image()
}

// MARK: - Backdrops

struct Glow { let x: CGFloat, y: CGFloat, radius: CGFloat, hex: UInt32, alpha: CGFloat }

/// Diagonal multi-stop gradient (top-left → bottom-right) plus soft glows, rasterised per pixel and rounded without dithering.
/// CoreGraphics gradients are dithered, which made these PNGs about six times larger.
/// Glow `x`/`y` are relative to the canvas and `radius` to its longer side.
func wallpaper(width: Int, height: Int, stops: [UInt32], glows: [Glow] = []) -> CGImage {
    func components(_ hex: UInt32) -> SIMD3<Double> {
        SIMD3(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
    }
    let colors = stops.map(components)
    let w = Double(width), h = Double(height), length = w * w + h * h, side = Double(max(width, height))
    let lights = glows.map { (x: Double($0.x) * w, y: Double($0.y) * h, radius: Double($0.radius) * side,
                              color: components($0.hex), alpha: Double($0.alpha)) }
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let t = min(max((Double(x) * w + Double(y) * h) / length, 0), 1) * Double(colors.count - 1)
            let index = min(Int(t), colors.count - 2)
            var pixel = colors[index] + (colors[index + 1] - colors[index]) * (t - Double(index))
            for light in lights {
                let dx = Double(x) - light.x, dy = Double(y) - light.y
                let d = (dx * dx + dy * dy).squareRoot() / light.radius
                guard d < 1 else { continue }
                let s = 1 - d
                pixel += (light.color - pixel) * (light.alpha * s * s * (3 - 2 * s))
            }
            let i = (y * width + x) * 4
            bytes[i] = UInt8(pixel.x.rounded()); bytes[i + 1] = UInt8(pixel.y.rounded()); bytes[i + 2] = UInt8(pixel.z.rounded())
        }
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGB,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

// MARK: - Pixel access for layout detection

struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w; height = h; bytes = buffer
    }

    /// 0xRRGGBB at (x, y), top-left origin. Inputs are opaque snapshots.
    func rgb(_ x: Int, _ y: Int) -> UInt32 {
        let i = (y * width + x) * 4
        return UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
    }
}

/// Index runs where `isContent` holds. Gaps up to `mergeGap` are bridged; runs shorter than `minLength` are dropped.
func bands(_ count: Int, mergeGap: Int, minLength: Int, _ isContent: (Int) -> Bool) -> [Range<Int>] {
    var raw: [Range<Int>] = []
    var start: Int?
    for i in 0...count {
        let on = i < count && isContent(i)
        if on, start == nil { start = i }
        if !on, let s = start { raw.append(s..<i); start = nil }
    }
    var merged: [Range<Int>] = []
    for run in raw {
        if let last = merged.last, run.lowerBound - last.upperBound <= mergeGap {
            merged[merged.count - 1] = last.lowerBound..<run.upperBound
        } else {
            merged.append(run)
        }
    }
    return merged.filter { $0.count >= minLength }
}

// MARK: - Canvas

enum Align { case left, center, right }

final class Canvas {
    let context: CGContext
    let width: Int, height: Int

    init(_ width: Int, _ height: Int) {
        self.width = width; self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.setShouldSmoothFonts(false)
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    func image() -> CGImage { context.makeImage()! }

    /// Top-left rect → CoreGraphics rect.
    func cg(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height) }
    func cg(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: CGFloat(height) - point.y) }
    /// Flips a path built in top-left coordinates.
    func cg(_ path: CGPath) -> CGPath {
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
        return path.copy(using: &flip)!
    }

    func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: cg(rect), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    func fill(_ path: CGPath, _ fill: CGColor) {
        context.addPath(path); context.setFillColor(fill); context.fillPath()
    }

    func fill(_ rect: CGRect, _ fill: CGColor) { context.setFillColor(fill); context.fill(cg(rect)) }

    func stroke(_ path: CGPath, _ stroke: CGColor, width: CGFloat) {
        context.addPath(path); context.setStrokeColor(stroke); context.setLineWidth(width); context.strokePath()
    }

    func clipped(_ path: CGPath, _ body: () -> Void) {
        context.saveGState(); context.addPath(path); context.clip(); body(); context.restoreGState()
    }

    /// Drop shadow cast by `path` (filled with `fill`, which the caller usually covers afterwards).
    func shadow(_ path: CGPath, fill: CGColor, offsetY: CGFloat, blur: CGFloat, _ shade: CGColor) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -offsetY), blur: blur, color: shade)
        self.fill(path, fill)
        context.restoreGState()
    }

    func draw(_ image: CGImage, _ rect: CGRect, quality: CGInterpolationQuality = .high) {
        context.saveGState()
        context.interpolationQuality = quality
        context.draw(image, in: cg(rect))
        context.restoreGState()
    }

    // MARK: Text (system font with the image language's cascade)

    static func line(_ string: String, size: CGFloat, bold: Bool, color: CGColor) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, language as CFString)!
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    static func measure(_ string: String, size: CGFloat, bold: Bool = false) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(string, size: size, bold: bold, color: color(0)), nil, nil, nil))
    }

    /// Draws one line with its baseline at `baseline`; returns the drawn width.
    @discardableResult
    func text(_ string: String, x: CGFloat, baseline: CGFloat, size: CGFloat, bold: Bool = false, color: CGColor,
              align: Align = .left) -> CGFloat {
        let line = Canvas.line(string, size: size, bold: bold, color: color)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let left: CGFloat
        switch align {
        case .left: left = x
        case .center: left = x - width / 2
        case .right: left = x - width
        }
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: left.rounded(), y: CGFloat(height) - baseline)
        CTLineDraw(line, context)
        context.restoreGState()
        return width
    }
}

// MARK: - Shapes

/// Rounded rectangle with a popover arrow on its top edge, in top-left coordinates (flip with `Canvas.cg`).
func popoverPath(_ rect: CGRect, radius r: CGFloat, arrowX ax: CGFloat, arrowHalfWidth aw: CGFloat, arrowHeight ah: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
    path.move(to: CGPoint(x: x0 + r, y: y0))
    path.addLine(to: CGPoint(x: ax - aw, y: y0))
    path.addCurve(to: CGPoint(x: ax, y: y0 - ah), control1: CGPoint(x: ax - aw * 0.45, y: y0), control2: CGPoint(x: ax - aw * 0.22, y: y0 - ah))
    path.addCurve(to: CGPoint(x: ax + aw, y: y0), control1: CGPoint(x: ax + aw * 0.22, y: y0 - ah), control2: CGPoint(x: ax + aw * 0.45, y: y0))
    path.addLine(to: CGPoint(x: x1 - r, y: y0))
    path.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y1), radius: r)
    path.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x0, y: y1), radius: r)
    path.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y0), radius: r)
    path.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x1, y: y0), radius: r)
    path.closeSubpath()
    return path
}

/// Draws `image` in a rounded frame with a soft shadow and a hairline border.
/// `base` is the image's edge colour, so the anti-aliased rim never shows a different fill.
func framed(_ canvas: Canvas, _ image: CGImage, _ rect: CGRect, radius: CGFloat, base: CGColor, look: Look,
            shadowOffset: CGFloat = 10, shadowBlur: CGFloat = 30) {
    let path = canvas.rounded(rect, radius)
    canvas.shadow(path, fill: base, offsetY: shadowOffset, blur: shadowBlur, look.shadow)
    canvas.clipped(path) { canvas.draw(image, rect) }
    canvas.stroke(canvas.rounded(rect.insetBy(dx: 0.75, dy: 0.75), radius - 0.75), look.border, width: 1.5)
}

/// Rounds the outer corners of a finished canvas (transparent outside).
func roundCorners(_ canvas: Canvas, radius: CGFloat) -> CGImage {
    let out = Canvas(canvas.width, canvas.height)
    out.clipped(out.rounded(out.bounds, radius)) { out.draw(canvas.image(), out.bounds, quality: .none) }
    return out.image()
}
