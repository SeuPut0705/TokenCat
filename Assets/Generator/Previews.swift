import AppKit

/// Inspection images written to work/ (not shipped).
enum RunnerPreview {
    static let light = RGBA(hex: 0xECECEE), dark = RGBA(hex: 0x222326)

    static func contactSheet(to path: String, scale: Int = 8) {
        let frames = RunnerArt.poses.map { ($0.name, $0.frames.map { RunnerArt.bitmap(RunnerArt.compose($0)) }) }
        let columns = frames.map(\.1.count).max()!
        let cw = RunnerArt.cell.width * scale, ch = RunnerArt.cell.height * scale, gap = scale * 2
        let sheetWidth = gap + columns * (cw + gap)
        let rowHeight = ch * 2 + gap * 3
        var sheet = Bitmap(width: sheetWidth * 1, height: frames.count * rowHeight, fill: RGBA(hex: 0x8A8D93))
        for (row, item) in frames.enumerated() {
            for (backgroundIndex, background) in [light, dark].enumerated() {
                let y = row * rowHeight + gap + backgroundIndex * (ch + gap)
                for (column, frame) in item.1.enumerated() {
                    let x = gap + column * (cw + gap)
                    sheet.draw(Bitmap(width: cw, height: ch, fill: background), x: x, y: y)
                    sheet.draw(frame.scaledNearest(scale), x: x, y: y)
                    // Faint cell grid every 1 px of art.
                    for gy in stride(from: 0, to: ch, by: scale) { for gx in 0..<cw where sheet[x + gx, y + gy] == background {
                        sheet[x + gx, y + gy] = backgroundIndex == 0 ? RGBA(hex: 0xE0E0E3) : RGBA(hex: 0x2C2D31) } }
                    for gx in stride(from: 0, to: cw, by: scale) { for gy in 0..<ch where sheet[x + gx, y + gy] == background {
                        sheet[x + gx, y + gy] = backgroundIndex == 0 ? RGBA(hex: 0xE0E0E3) : RGBA(hex: 0x2C2D31) } }
                }
            }
        }
        PNG.write(sheet, to: path)
    }

    /// Menu bar mock: every frame at true size on light and dark bars, @1x and @2x, plus a 3× zoom of it.
    static func menuBar(to path: String, zoomPath: String) {
        let frames = RunnerArt.poses.flatMap { $0.frames.map { RunnerArt.bitmap(RunnerArt.compose($0)) } }
        let bars: [(scale: Int, background: RGBA, text: NSColor)] = [
            (1, RGBA(hex: 0xF4F4F6), NSColor(white: 0.1, alpha: 1)), (1, RGBA(hex: 0x1E1F22), NSColor(white: 0.95, alpha: 1)),
            (2, RGBA(hex: 0xF4F4F6), NSColor(white: 0.1, alpha: 1)), (2, RGBA(hex: 0x1E1F22), NSColor(white: 0.95, alpha: 1)),
            (2, RGBA(hex: 0x6E86B8), NSColor(white: 1, alpha: 1)),   // tinted wallpaper through a translucent bar
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
                let art = s == 1 ? frame : frame.scaledNearest(2)
                bitmap.draw(art, x: (8 + index * slot + 1) * s, y: y + (barHeight - art.height) / 2)
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
