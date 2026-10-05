import AppKit

/// Inspection images written to work/ (not shipped).
enum RunnerPreview {
    static let light = RGBA(hex: 0xECECEE), dark = RGBA(hex: 0x222326)
    /// Approximate secondaryLabelColor on light and dark bars (the z is drawn in it, K-2).
    static let labelOnLight = RGBA(r: 0, g: 0, b: 0, a: 128), labelOnDark = RGBA(r: 255, g: 255, b: 255, a: 140)

    /// What the menu bar shows, step by step: every sheet frame, with sleep expanded to its breathing steps
    /// A (frame 0) · B (frame 1 + zS) · C (frame 0 + zL). Returns the sprite and its fx mask per step.
    static func steps(_ character: RunnerArt.CharacterArt = RunnerArt.characters[0]) -> [(name: String, frames: [(art: Bitmap, fx: Bitmap?)])] {
        character.poses.ordered.map { pose in
            let art = pose.frames.map { RunnerArt.bitmap(RunnerArt.compose($0), palette: character.palette) }
            let fx = RunnerArt.fx.filter { $0.pose == pose.name }
            guard !fx.isEmpty else { return (pose.name, art.map { ($0, nil) }) }
            return (pose.name, (0...fx.map(\.step).max()!).map { step in
                var mask = Bitmap(width: RunnerArt.cell.width, height: RunnerArt.cell.height)
                for entry in fx where entry.step == step {
                    mask.draw(RunnerArt.mask(RunnerArt.glyphs.first { $0.name == entry.glyph }!.rows), x: entry.x, y: entry.y)
                }
                return (art[step == 1 ? 1 : 0], step == 0 ? nil : mask)
            })
        }
    }

    /// The mask's opaque pixels in `color`.
    static func tint(_ mask: Bitmap, _ color: RGBA) -> Bitmap {
        var out = mask
        for i in out.pixels.indices where out.pixels[i].a > 0 { out.pixels[i] = color }
        return out
    }

    static func contactSheet(_ character: RunnerArt.CharacterArt, to path: String, scale: Int = 8) {
        let frames = steps(character)
        let columns = frames.map(\.frames.count).max()!
        let cw = RunnerArt.cell.width * scale, ch = RunnerArt.cell.height * scale, gap = scale * 2
        let sheetWidth = gap + columns * (cw + gap)
        let rowHeight = ch * 2 + gap * 3
        var sheet = Bitmap(width: sheetWidth, height: frames.count * rowHeight, fill: RGBA(hex: 0x8A8D93))
        for (row, item) in frames.enumerated() {
            for (backgroundIndex, background) in [light, dark].enumerated() {
                let y = row * rowHeight + gap + backgroundIndex * (ch + gap)
                for (column, frame) in item.frames.enumerated() {
                    let x = gap + column * (cw + gap)
                    sheet.draw(Bitmap(width: cw, height: ch, fill: background), x: x, y: y)
                    sheet.draw(frame.art.scaledNearest(scale), x: x, y: y)
                    if let fx = frame.fx { sheet.draw(tint(fx, backgroundIndex == 0 ? labelOnLight : labelOnDark).scaledNearest(scale), x: x, y: y) }
                    // Faint cell grid every 1 px of art.
                    let line = backgroundIndex == 0 ? RGBA(hex: 0xE0E0E3) : RGBA(hex: 0x2C2D31)
                    for gy in stride(from: 0, to: ch, by: scale) { for gx in 0..<cw where sheet[x + gx, y + gy] == background { sheet[x + gx, y + gy] = line } }
                    for gx in stride(from: 0, to: cw, by: scale) { for gy in 0..<ch where sheet[x + gx, y + gy] == background { sheet[x + gx, y + gy] = line } }
                }
            }
        }
        PNG.write(sheet, to: path)
    }

    /// Every character side by side: one band per character and background (light, dark), each pose's still frame
    /// (sleep with its zL) at 4× and then at true @1x size, in registry order.
    static func lineup(to path: String, scale: Int = 4) {
        let cw = RunnerArt.cell.width, ch = RunnerArt.cell.height, gap = 8
        let stills = RunnerArt.characters.map { steps($0).map { $0.name == "sleep" ? $0.frames.last! : $0.frames[0] } } // sleep still: zL step
        let poseCount = stills[0].count
        let bandHeight = ch * scale + 2 * gap
        let width = gap + poseCount * (cw * scale + gap) + gap + poseCount * (cw + 4) + gap
        var sheet = Bitmap(width: width, height: stills.count * 2 * bandHeight, fill: RGBA(hex: 0x8A8D93))
        for (index, frames) in stills.enumerated() {
            for (backgroundIndex, background) in [light, dark].enumerated() {
                let y = (index * 2 + backgroundIndex) * bandHeight
                sheet.draw(Bitmap(width: width, height: bandHeight - 2, fill: background), x: 0, y: y)
                let label = backgroundIndex == 0 ? labelOnLight : labelOnDark
                for (column, frame) in frames.enumerated() {
                    for (s, x) in [(scale, gap + column * (cw * scale + gap)), (1, gap + poseCount * (cw * scale + gap) + gap + column * (cw + 4))] {
                        let top = y + gap + (s == 1 ? (ch * scale - ch) / 2 : 0)
                        sheet.draw(frame.art.scaledNearest(s), x: x, y: top)
                        if let fx = frame.fx { sheet.draw(tint(fx, label).scaledNearest(s), x: x, y: top) }
                    }
                }
            }
        }
        PNG.write(sheet, to: path)
    }

    /// Menu bar mock (the cat): every step at true size on light and dark bars, @1x and @2x, plus a 3× zoom of it.
    static func menuBar(to path: String, zoomPath: String) {
        let frames = steps().flatMap(\.frames)
        let bars: [(scale: Int, background: RGBA, text: NSColor, label: RGBA)] = [
            (1, RGBA(hex: 0xF4F4F6), NSColor(white: 0.1, alpha: 1), labelOnLight), (1, RGBA(hex: 0x1E1F22), NSColor(white: 0.95, alpha: 1), labelOnDark),
            (2, RGBA(hex: 0xF4F4F6), NSColor(white: 0.1, alpha: 1), labelOnLight), (2, RGBA(hex: 0x1E1F22), NSColor(white: 0.95, alpha: 1), labelOnDark),
            (2, RGBA(hex: 0x6E86B8), NSColor(white: 1, alpha: 1), labelOnDark), // tinted wallpaper through a translucent bar
        ]
        let slot = 32 + 6
        let width = (8 + frames.count * slot + 60) * 2
        let height = bars.reduce(0) { $0 + 24 * $1.scale + 4 }
        let canvas = Canvas(width: width, height: height)
        var bitmap = Bitmap(width: width, height: height, fill: RGBA(hex: 0x8A8D93))
        var y = 0
        var labels: [(String, CGFloat, CGFloat, CGFloat, NSColor)] = []
        for bar in bars {
            let s = bar.scale, barHeight = 24 * s
            bitmap.draw(Bitmap(width: width, height: barHeight, fill: bar.background), x: 0, y: y)
            for (index, frame) in frames.enumerated() {
                let origin = (x: (8 + index * slot + 1) * s, y: y + (barHeight - RunnerArt.cell.height * s) / 2)
                bitmap.draw(frame.art.scaledNearest(s), x: origin.x, y: origin.y)
                if let fx = frame.fx { bitmap.draw(tint(fx, bar.label).scaledNearest(s), x: origin.x, y: origin.y) }
            }
            labels.append(("CPU 12%  AI 2", CGFloat((8 + frames.count * slot) * s), CGFloat(height - y - barHeight + 6 * s), CGFloat(11 * s), bar.text))
            y += barHeight + 4
        }
        canvas.cg.draw(bitmap.cgImage(), in: CGRect(x: 0, y: 0, width: width, height: height))
        for (text, x, ty, size, color) in labels { canvas.text(text, x: x, y: ty, size: size, color: color) }
        let result = canvas.bitmap()
        PNG.write(result, to: path)
        PNG.write(result.scaledNearest(3), to: zoomPath)
    }

    /// Pixel heads as the popover header draws them (2 pt per art pixel at @1x and @2x) on light and dark
    /// popovers, the 1 pt/px first-run size, and an 8× zoom.
    static func heads(to path: String) {
        let heads = RunnerArt.heads.map { RunnerArt.bitmap(RunnerArt.headGrid($0.rows)) }
        let w = RunnerArt.headSize.width, h = RunnerArt.headSize.height, gap = 16
        let cellWidth = w * 8 + gap, rowHeight = h * 8 + gap
        var sheet = Bitmap(width: gap + heads.count * cellWidth, height: gap + 2 * (rowHeight + h * 4 + gap), fill: RGBA(hex: 0x8A8D93))
        for (row, background) in [RGBA(hex: 0xF6F6F8), RGBA(hex: 0x2A2A2D)].enumerated() {
            let top = gap + row * (rowHeight + h * 4 + gap)
            sheet.draw(Bitmap(width: sheet.width, height: rowHeight + h * 4 + gap, fill: background), x: 0, y: top - gap / 2)
            for (index, head) in heads.enumerated() {
                let x = gap + index * cellWidth
                sheet.draw(head.scaledNearest(8), x: x, y: top)
                // 1 pt/px (first-run card), 2 pt/px @1x (24 × 22), 2 pt/px @2x (48 × 44).
                sheet.draw(head, x: x, y: top + h * 8 + 4)
                sheet.draw(head.scaledNearest(2), x: x + w + 6, y: top + h * 8 + 4)
                sheet.draw(head.scaledNearest(4), x: x + 3 * w + 12, y: top + h * 8 + 4)
            }
        }
        PNG.write(sheet, to: path)
    }
}

/// Icon sizes at 1:1 and zoomed, on light and dark backgrounds, read from the iconset build.sh made.
enum IconPreview {
    static func sheet(iconset: String, to path: String) {
        let files = [("icon_16x16.png", 16), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
                     ("icon_128x128.png", 128), ("icon_512x512.png", 512)]
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: iconset + "/" + $0.0) }) else {
            print("icon preview skipped: run ./build.sh first (\(iconset))")
            return
        }
        let icons = files.map { (Bitmap(PNG.read(iconset + "/" + $0.0)), $0.1) }
        let gap = 24
        let actualWidth = icons.reduce(gap) { $0 + $1.1 + gap }
        let zoomed = [(icons[0].0.scaledNearest(8)), icons[1].0.scaledNearest(4), icons[2].0.scaledNearest(2)]
        let rowHeight = 512 + 2 * gap
        var sheet = Bitmap(width: actualWidth, height: rowHeight * 2 + (128 + 2 * gap) * 2)
        var y = 0
        for background in [RunnerPreview.light, RunnerPreview.dark] {
            sheet.draw(Bitmap(width: actualWidth, height: rowHeight, fill: background), x: 0, y: y)
            var x = gap
            for (icon, size) in icons { sheet.draw(icon, x: x, y: y + rowHeight - gap - size); x += size + gap }
            y += rowHeight
        }
        for background in [RunnerPreview.light, RunnerPreview.dark] {
            sheet.draw(Bitmap(width: actualWidth, height: 128 + 2 * gap, fill: background), x: 0, y: y)
            for (index, zoom) in zoomed.enumerated() { sheet.draw(zoom, x: gap + index * (128 + gap), y: y + gap) }
            y += 128 + 2 * gap
        }
        PNG.write(sheet, to: path)
    }

    /// High-quality downscale (like `sips -z`).
    static func resized(_ image: CGImage, _ size: Int) -> Bitmap {
        let canvas = Canvas(width: size, height: size)
        canvas.cg.interpolationQuality = .high
        canvas.cg.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return canvas.bitmap()
    }

    /// v2 (shipping: pixel heads at 16 · 32, the raster master above) next to the v3 vector master rendered natively
    /// at every size from 64 px, on light and dark, 16–512 at 1:1 and both 1024 masters, plus 4× zooms of 64 and 128.
    static func v3(current assets: String, to path: String) {
        let sizes = [16, 32, 64, 128, 256, 512], gap = 24
        let master = PNG.read(assets + "/app-icon-v2-1024.png")
        let small = [16: Bitmap(PNG.read(assets + "/app-icon-v2-16.png")), 32: Bitmap(PNG.read(assets + "/app-icon-v2-32.png"))]
        let v2 = sizes.map { small[$0] ?? resized(master, $0) }
        let v3 = sizes.map { small[$0] ?? IconArt.masterV3(size: $0) }
        let big = (v2: Bitmap(master), v3: IconArt.masterV3(size: 1024))
        let rowHeight = 512 + 2 * gap, zoomHeight = 128 * 4 + 2 * gap
        let width = 4 * (512 + gap) + gap
        var sheet = Bitmap(width: width, height: 2 * (2 * rowHeight + zoomHeight) + 1024 + 2 * gap)
        var y = 0
        for background in [RunnerPreview.light, RunnerPreview.dark] {
            for row in [v2, v3] {
                sheet.draw(Bitmap(width: width, height: rowHeight, fill: background), x: 0, y: y)
                var x = gap
                for (icon, size) in zip(row, sizes) { sheet.draw(icon, x: x, y: y + rowHeight - gap - size); x += size + gap }
                y += rowHeight
            }
            sheet.draw(Bitmap(width: width, height: zoomHeight, fill: background), x: 0, y: y)
            for (index, icon) in [v2[2], v3[2], v2[3], v3[3]].enumerated() {
                let zoom = icon.scaledNearest(icon.width == 64 ? 8 : 4)
                sheet.draw(zoom, x: gap + index * (512 + gap), y: y + gap)
            }
            y += zoomHeight
        }
        sheet.draw(Bitmap(width: width / 2, height: 1024 + 2 * gap, fill: RunnerPreview.light), x: 0, y: y)
        sheet.draw(Bitmap(width: width - width / 2, height: 1024 + 2 * gap, fill: RunnerPreview.dark), x: width / 2, y: y)
        sheet.draw(big.v2, x: gap, y: y + gap)
        sheet.draw(big.v3, x: width - gap - 1024, y: y + gap)
        PNG.write(sheet, to: path)
    }

    /// What macOS itself draws for the built bundle (NSWorkspace, @2x pixels, zoomed 2×), so a grey plate around
    /// an icon the system does not accept shows up. A fresh copy keeps Icon Services from answering from its cache.
    static func system(app: String, to path: String) {
        let copy = (path as NSString).deletingLastPathComponent + "/icon-check-\(UUID().uuidString).app"
        guard (try? FileManager.default.copyItem(atPath: app, toPath: copy)) != nil else {
            print("system icon skipped: run ./build.sh first (\(app))")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: copy) }
        let icon = NSWorkspace.shared.icon(forFile: copy)
        let sizes = [16, 32, 64, 128], gap = 24, zoom = 2
        let width = sizes.reduce(gap) { $0 + $1 * 2 * zoom + gap }, rowHeight = 128 * 2 * zoom + 2 * gap
        var sheet = Bitmap(width: width, height: rowHeight * 2)
        for (row, background) in [RunnerPreview.light, RunnerPreview.dark].enumerated() {
            sheet.draw(Bitmap(width: width, height: rowHeight, fill: background), x: 0, y: row * rowHeight)
            var x = gap
            for size in sizes {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size * 2, pixelsHigh: size * 2, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = NSSize(width: size, height: size) // size pt at 2× like a Retina display
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
                let art = Bitmap(rep.cgImage!).scaledNearest(zoom)
                sheet.draw(art, x: x, y: row * rowHeight + rowHeight - gap - art.height)
                x += art.width + gap
            }
        }
        PNG.write(sheet, to: path)
    }
}
