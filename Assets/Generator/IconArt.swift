import AppKit

/// App icon v2: the app-mark-v1 head (collar recoloured to the palette) on a calm indigo-to-slate squircle tile
/// (1024 canvas, 824 tile, 100 px margins), plus 16 and 32 px versions drawn from the sprite's pixel head.
/// `masterV3` is the vector redraw (CBM-10), rendered for the preview only until the switch is decided.
enum IconArt {
    static let canvas = 1024
    static let tileInset = 100.0
    static let top = RGBA(hex: 0x5361D6), bottom = RGBA(hex: 0x283246)

    /// Continuous-curvature tile: a superellipse (n = 5) whose diagonal matches a 185 px corner radius.
    static func tilePath(in rect: CGRect, exponent: Double = 5) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
        let steps = 1440
        for i in 0..<steps {
            let t = Double(i) / Double(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
            let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
            i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }

    static func gradient(_ colors: [RGBA], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors.map(\.cg) as CFArray, locations: locations)!
    }

    /// Tile background with gradient, a soft top glow and a thin inner highlight/shadow rim.
    static func drawTile(_ cg: CGContext, size: Double, effects: Bool, inset: Double? = nil) {
        let margin = inset ?? tileInset * size / Double(canvas)
        let rect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
        let scale = size / Double(canvas)
        let path = tilePath(in: rect)
        cg.saveGState()
        cg.addPath(path); cg.clip()
        cg.drawLinearGradient(gradient([top, RGBA(hex: 0x3B4787), bottom], [0, 0.55, 1]),
                              start: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY),
                              end: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        if effects {
            cg.drawRadialGradient(gradient([RGBA(r: 255, g: 255, b: 255, a: 46), RGBA(r: 255, g: 255, b: 255, a: 0)], [0, 1]),
                                  startCenter: CGPoint(x: rect.midX, y: rect.maxY), startRadius: 0,
                                  endCenter: CGPoint(x: rect.midX, y: rect.maxY), endRadius: rect.width * 0.75, options: [])
            // Inner rim: light along the top edge, dark along the bottom edge.
            let rim = max(1, 6 * scale)
            cg.addPath(path); cg.setLineWidth(rim * 2); cg.replacePathWithStrokedPath(); cg.clip()
            cg.drawLinearGradient(gradient([RGBA(r: 255, g: 255, b: 255, a: 70), RGBA(r: 255, g: 255, b: 255, a: 0),
                                            RGBA(r: 0, g: 0, b: 0, a: 0), RGBA(r: 0, g: 0, b: 0, a: 60)], [0, 0.35, 0.65, 1]),
                                  start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        cg.restoreGState()
    }

    /// 1024 master: tile + the brand mark scaled to 68 % of the tile width.
    static func master(mark: CGImage) -> Bitmap {
        let markBitmap = recolorCollar(Bitmap(mark))
        var minX = markBitmap.width, minY = markBitmap.height, maxX = 0, maxY = 0
        for y in 0..<markBitmap.height { for x in 0..<markBitmap.width where markBitmap[x, y].a > 32 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }}
        let crop = markBitmap.cgImage().cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
        let surface = Canvas(width: canvas, height: canvas)
        let cg = surface.cg
        cg.interpolationQuality = .high
        drawTile(cg, size: Double(canvas), effects: true)
        let width = 0.68 * (Double(canvas) - 2 * tileInset)
        let height = width * Double(crop.height) / Double(crop.width)
        let rect = CGRect(x: (Double(canvas) - width) / 2, y: (Double(canvas) - height) / 2 - 8, width: width, height: height)
        cg.saveGState()
        cg.addPath(tilePath(in: CGRect(x: tileInset, y: tileInset, width: 824, height: 824))); cg.clip()
        cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: RGBA(r: 8, g: 12, b: 28, a: 110).cg)
        cg.draw(crop, in: rect)
        cg.restoreGState()
        return surface.bitmap()
    }

    /// Interim palette fix for the raster mark (B-1): its saturated blues (hue 205–240°, saturation > 0.5) become the
    /// palette collar C, and the round tag T, keeping each pixel's alpha and relative brightness. Only the collar area
    /// of app-mark-v1.png (rows 1030–1170, tag centre (626, 1092) in its 1254 px grid) is touched.
    static func recolorCollar(_ mark: Bitmap) -> Bitmap {
        var out = mark
        let reference = 252.0 // brightness of the mark's flat collar blue #155AFC
        for y in 1030..<min(1170, mark.height) { for x in 0..<mark.width {
            let p = mark[x, y]
            guard p.a > 0 else { continue }
            let r = Double(p.r), g = Double(p.g), b = Double(p.b)
            let high = max(r, g, b), chroma = high - min(r, g, b)
            guard high > 0, chroma / high > 0.5, b == high else { continue }
            let hue = 240 + 60 * (r - g) / chroma
            guard (205...240).contains(hue) else { continue }
            let tag = hypot(Double(x - 626), Double(y - 1092)) <= 46
            let target = tag ? Palette.tag : Palette.collar, k = high / reference
            func scaled(_ c: UInt8) -> UInt8 { UInt8(min(255, (Double(c) * k).rounded())) }
            out[x, y] = RGBA(r: scaled(target.r), g: scaled(target.g), b: scaled(target.b), a: p.a)
        }}
        return out
    }

    // MARK: Small sizes: the sprite's 12 × 11 pixel head on the full-bleed tile (B-2)

    /// The 16 and 32 px tiles are full bleed: macOS 26+ puts 16/32 px images with the 1024 grid's
    /// proportional margin in a grey plate (checked with NSWorkspace icons on macOS 27), while a
    /// full-bleed squircle is masked and shadowed by the system like the larger sizes.
    /// 16 px: the head at (2, 3); 32 px: the same head doubled (24 × 22) at (4, 5).
    static func small(size: Int) -> Bitmap {
        let surface = Canvas(width: size, height: size)
        drawTile(surface.cg, size: Double(size), effects: size >= 32, inset: 0)
        var bitmap = surface.bitmap()
        let head = RunnerArt.bitmap(RunnerArt.headGrid(RunnerArt.head))
        bitmap.draw(size == 16 ? head : head.scaledNearest(2), x: size == 16 ? 2 : 4, y: size == 16 ? 3 : 5)
        return bitmap
    }

    // MARK: Vector master v3 (preview only, B-4). Geometry on the 1024 grid, y down.

    /// Rounded triangle through three corners.
    static func roundedPolygon(_ points: [CGPoint], radius: Double) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        path.move(to: CGPoint(x: (points[0].x + points[n - 1].x) / 2, y: (points[0].y + points[n - 1].y) / 2))
        for i in 0..<n { path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius) }
        path.closeSubpath()
        return path
    }

    /// The triangle shrunk by `inset` toward its incentre (homothety), for the inner ear.
    static func inset(_ p: [CGPoint], by inset: Double) -> [CGPoint] {
        func d(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        let a = d(p[1], p[2]), b = d(p[0], p[2]), c = d(p[0], p[1]), s = (a + b + c) / 2
        let centre = CGPoint(x: (a * p[0].x + b * p[1].x + c * p[2].x) / (2 * s), y: (a * p[0].y + b * p[1].y + c * p[2].y) / (2 * s))
        let inradius = sqrt((s - a) * (s - b) * (s - c) / s), k = (inradius - inset) / inradius
        return p.map { CGPoint(x: centre.x + ($0.x - centre.x) * k, y: centre.y + ($0.y - centre.y) * k) }
    }

    /// Native rendition at `size` px: tile, ground shadow, superellipse head (n = 2.6) with rounded ears that lean out,
    /// vertical oval eyes with a highlight, nose, collar and tag. The mouth only from 128 px; no brows, stripes or
    /// whiskers. Strokes never drop below 2 px. CBM-10's proposed numbers (600 × 500 head at n = 3.2, ear bases at
    /// y 480) hid all but a 60 px stub of each ear behind the head, so the head is smaller and the ears taller here.
    static func masterV3(size: Int) -> Bitmap {
        let surface = Canvas(width: size, height: size)
        let cg = surface.cg
        let scale = Double(size) / Double(canvas)
        drawTile(cg, size: Double(size), effects: true)
        // y-down 1024 grid → CG pixels.
        cg.translateBy(x: 0, y: Double(size)); cg.scaleBy(x: scale, y: -scale)
        func stroke(_ width: Double) -> Double { max(width, 2 / scale) }
        let head = tilePath(in: CGRect(x: 236, y: 360, width: 552, height: 450), exponent: 2.6)
        let ears = [[CGPoint(x: 300, y: 446), CGPoint(x: 284, y: 214), CGPoint(x: 478, y: 380)],
                    [CGPoint(x: 724, y: 446), CGPoint(x: 740, y: 214), CGPoint(x: 546, y: 380)]]
        let eyeY = 594.0, eyes = [418.0, 606.0], noseY = 668.0
        let collar = CGPath(roundedRect: CGRect(x: 384, y: 786, width: 256, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil)
        let tag = CGPath(ellipseIn: CGRect(x: 484, y: 800, width: 56, height: 56), transform: nil)
        func fill(_ path: CGPath, _ color: RGBA) { cg.addPath(path); cg.setFillColor(color.cg); cg.fillPath() }
        func outline(_ path: CGPath, _ width: Double) {
            cg.addPath(path); cg.setStrokeColor(Palette.outline.cg); cg.setLineWidth(2 * stroke(width)); cg.setLineJoin(.round); cg.strokePath()
        }
        cg.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 30 * scale, color: RGBA(r: 8, g: 12, b: 28, a: 110).cg)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        // Outlines sit outside the fills: stroke everything first, then fill on top.
        for ear in ears { outline(roundedPolygon(ear, radius: 30), 22) }
        outline(head, 22)
        for ear in ears { fill(roundedPolygon(ear, radius: 30), Palette.fur) }
        for ear in ears { fill(roundedPolygon(inset(ear, by: 34), radius: 12), Palette.shade) }
        fill(head, Palette.fur)
        for x in eyes {
            fill(CGPath(ellipseIn: CGRect(x: x - 30, y: eyeY - 44, width: 60, height: 88), transform: nil), Palette.outline)
            fill(CGPath(ellipseIn: CGRect(x: x - 12 - 11, y: eyeY - 22 - 11, width: 22, height: 22), transform: nil), Palette.fur)
        }
        fill(roundedPolygon([CGPoint(x: 490, y: noseY - 15), CGPoint(x: 534, y: noseY - 15), CGPoint(x: 512, y: noseY + 15)], radius: 7), Palette.outline)
        if size >= 128 {
            let mouth = CGMutablePath(), y = noseY + 15
            mouth.addArc(center: CGPoint(x: 488, y: y), radius: 24, startAngle: 0, endAngle: .pi * 0.92, clockwise: false)
            mouth.move(to: CGPoint(x: 536 + 24 * cos(.pi * 0.08), y: y + 24 * sin(.pi * 0.08)))
            mouth.addArc(center: CGPoint(x: 536, y: y), radius: 24, startAngle: .pi * 0.08, endAngle: .pi, clockwise: false)
            cg.addPath(mouth); cg.setStrokeColor(Palette.outline.cg); cg.setLineWidth(stroke(14)); cg.setLineCap(.round); cg.strokePath()
        }
        outline(collar, 14)
        fill(collar, Palette.collar)
        cg.addPath(tag); cg.setStrokeColor(Palette.outline.cg); cg.setLineWidth(2 * stroke(12)); cg.strokePath()
        fill(tag, Palette.tag)
        cg.endTransparencyLayer()
        return surface.bitmap()
    }
}
