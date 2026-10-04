import AppKit

/// App icon v2: the unchanged app-mark-v1 head on a calm indigo-to-slate squircle tile
/// (1024 canvas, 824 tile, 100 px margins), plus hand-tuned 16 and 32 px pixel versions.
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

    /// 1024 master: tile + the existing brand mark scaled to 68 % of the tile width.
    static func master(mark: CGImage) -> Bitmap {
        let markBitmap = Bitmap(mark)
        var minX = markBitmap.width, minY = markBitmap.height, maxX = 0, maxY = 0
        for y in 0..<markBitmap.height { for x in 0..<markBitmap.width where markBitmap[x, y].a > 32 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }}
        let crop = mark.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
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

    // MARK: Small sizes. K outline, W fur, S inner ear, C collar, T tag, E eye highlight.

    static let colors: [Character: RGBA] = [
        "K": RGBA(hex: 0x1F2128), "W": RGBA(hex: 0xF8F9FB), "S": RGBA(hex: 0xB9BECB),
        "C": RGBA(hex: 0x1F55F0), "T": RGBA(hex: 0x9DB4FF), "E": RGBA(hex: 0xF8F9FB),
    ]

    /// 16 px: no stripes or whiskers, 1 px outline, 2 × 2 eyes, collar kept.
    static let head16 = [
        ".K......K.",
        "KWK....KWK",
        "KWWK..KWWK",
        "KWWWKKWWWK",
        "KWWWWWWWWK",
        "KWKKWWKKWK",
        "KWKKWWKKWK",
        "KWWWWWWWWK",
        ".KWWWWWWK.",
        "..KCCCCK..",
    ]

    /// 32 px: the 16 px head doubled by hand (2 px outline, 4 × 4 eyes with a rounded bottom and
    /// a 1 px highlight one pixel in from the upper left of each eye, so both catch the same light),
    /// plus inner ears, a two-pixel nose and the collar tag.
    static let head32 = [
        "..KK............KK..",
        ".KKWK..........KWKK.",
        "KKWWKK........KKWWKK",
        "KKWSWKK......KKWSWKK",
        "KKWSSWKK....KKWSSWKK",
        "KKWSSWWKK..KKWWSSWKK",
        "KKWWWWWWKKKKWWWWWWKK",
        "KKWWWWWWWWWWWWWWWWKK",
        "KKWWWWWWWWWWWWWWWWKK",
        "KKWWWWWWWWWWWWWWWWKK",
        "KKWWKKKKWWWWKKKKWWKK",
        "KKWWKEKKWWWWKEKKWWKK",
        "KKWWKKKKWWWWKKKKWWKK",
        "KKWWWKKWWWWWWKKWWWKK",
        "KKWWWWWWWKKWWWWWWWKK",
        "KKWWWWWWWWWWWWWWWWKK",
        ".KKWWWWWWWWWWWWWWKK.",
        "..KKKWWWWWWWWWWKKK..",
        "...KKCCCCTTCCCCKK...",
        "....KKCCCTTCCCKK....",
    ]

    /// The 16 and 32 px tiles are full bleed: macOS 26+ puts 16/32 px images with the 1024 grid's
    /// proportional margin in a grey plate (checked with NSWorkspace icons on macOS 27), while a
    /// full-bleed squircle is masked and shadowed by the system like the larger sizes.
    static func small(size: Int) -> Bitmap {
        let surface = Canvas(width: size, height: size)
        drawTile(surface.cg, size: Double(size), effects: size >= 32, inset: 0)
        var bitmap = surface.bitmap()
        let head = size == 16 ? head16 : head32
        let w = head[0].count, h = head.count
        let ox = (size - w) / 2, oy = (size - h) / 2 + (size == 16 ? 0 : 1)
        for (y, row) in head.enumerated() { for (x, ch) in row.enumerated() where ch != "." { bitmap[ox + x, oy + y] = colors[ch]! } }
        return bitmap
    }
}
