import CoreGraphics
import CoreText
import Foundation

// Compositions for docs/images. Calm indigo/slate backdrops only (no provider brand colours).

struct Look {
    let theme: Theme
    let wall: [UInt32]           // backdrop gradient, top-left → bottom-right
    let glows: [Glow]            // relative to the canvas; radius × the longer side
    let text: CGColor, secondary: CGColor
    let border: CGColor
    let shadow: CGColor
    let menuGlyph: CGColor       // menu bar label colour (hero clock and status glyphs)
    let menuHairline: CGColor
    let neutral: [UInt32]        // icon showcase background

    static func of(_ theme: Theme) -> Look {
        switch theme {
        case .dark:
            return Look(theme: theme,
                        wall: [0x141830, 0x222852, 0x353C74],
                        glows: [Glow(x: 0.10, y: 0.95, radius: 0.60, hex: 0x5060D6, alpha: 0.42),
                                Glow(x: 0.90, y: 0.12, radius: 0.48, hex: 0x6C5BBE, alpha: 0.30),
                                Glow(x: 0.55, y: 0.55, radius: 0.50, hex: 0x2C3A80, alpha: 0.25)],
                        text: color(0xF2F2F7), secondary: color(0xA7A9B8),
                        border: color(0xFFFFFF, 0.13), shadow: color(0x05060C, 0.60),
                        menuGlyph: color(0xFFFFFF, 0.90), menuHairline: color(0x000000, 0.55),
                        neutral: [0x26272C, 0x18191C])
        case .light:
            return Look(theme: theme,
                        wall: [0xF0F2FB, 0xDCE0F5, 0xC6CDEF],
                        glows: [Glow(x: 0.10, y: 0.95, radius: 0.60, hex: 0x98A4F0, alpha: 0.50),
                                Glow(x: 0.92, y: 0.10, radius: 0.48, hex: 0xCDBEF3, alpha: 0.45),
                                Glow(x: 0.45, y: 0.35, radius: 0.50, hex: 0xFFFFFF, alpha: 0.40)],
                        text: color(0x1D1D1F), secondary: color(0x5E6070),
                        border: color(0x000000, 0.11), shadow: color(0x1C2452, 0.26),
                        menuGlyph: color(0x000000, 0.85), menuHairline: color(0x000000, 0.08),
                        neutral: [0xF6F7F9, 0xE6E8EE])
        }
    }

    func paintWall(_ canvas: Canvas, glowScale: CGFloat = 1) {
        let scaled = glows.map { Glow(x: $0.x, y: $0.y, radius: $0.radius, hex: $0.hex, alpha: $0.alpha * glowScale) }
        canvas.draw(wallpaper(width: canvas.width, height: canvas.height, stops: wall, glows: scaled), canvas.bounds, quality: .none)
    }
}

// MARK: - Hero

/// Desktop-like product shot: menu bar strip with the TokenCat item (open state) and its popover hanging below.
/// The minimal item is used because the menu bar and popover fixtures carry different system values.
/// `window` (the 고양이 settings tab) sits at the lower left, bottom-aligned with the popover.
/// The canvas is at least 1080 px tall and grows with the popover, keeping a 64 px margin under it.
func hero(_ theme: Theme, popover sheet: FixtureSheet, menu: MenuMatrix, window: CGImage) -> CGImage {
    let look = Look.of(theme)
    let scale: CGFloat = 0.8, u = 2 * scale            // u = pixels per point

    // Layout: bar, then the popover (arrow + body) under the item; the window shares the popover's bottom edge.
    let state = MenuMatrix.stateNames.firstIndex(of: "입력 필요")!
    let item = menu.slice(state, MenuMatrix.column(theme, open: true))
    let popover = sheet.crop(theme, sheet.rows(.all))
    let barHeight = CGFloat(item.height) * scale
    let arrowHeight = 9 * u
    let popoverTop = barHeight + 3 * u + arrowHeight
    let popoverSize = CGSize(width: CGFloat(popover.width) * scale, height: CGFloat(popover.height) * scale)
    let popoverBottom = popoverTop + popoverSize.height

    let width = 1600, height = max(1080, Int((popoverBottom + 64).rounded(.up)))
    let canvas = Canvas(width, height)
    look.paintWall(canvas)

    // Menu bar
    canvas.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: barHeight), color(menu.bar[theme]!))
    canvas.fill(CGRect(x: 0, y: barHeight, width: CGFloat(width), height: 1), look.menuHairline)
    let mid = barHeight / 2
    var right = CGFloat(width) - 14 * u
    let clockSize = 13 * u
    let clock = loc("10월 5일 (월) 오전 9:41", "Mon Oct 5  9:41 AM")
    canvas.text(clock, x: right, baseline: mid + clockSize * 0.36, size: clockSize, color: look.menuGlyph, align: .right)
    right -= Canvas.measure(clock, size: clockSize) + 17 * u
    right -= controlCenterGlyph(canvas, right: right, mid: mid, u: u, look.menuGlyph) + 17 * u
    right -= searchGlyph(canvas, right: right, mid: mid, u: u, look.menuGlyph) + 17 * u
    right -= wifiGlyph(canvas, right: right, mid: mid, u: u, look.menuGlyph) + 17 * u
    right -= batteryGlyph(canvas, right: right, mid: mid, u: u, level: 0.58, look.menuGlyph) + 12 * u
    let itemWidth = CGFloat(item.width) * scale
    let itemRect = CGRect(x: right - itemWidth, y: 0, width: itemWidth, height: barHeight)
    canvas.draw(item, itemRect)

    // Settings window behind, lower left
    let windowScale: CGFloat = 0.7
    let windowSize = CGSize(width: CGFloat(window.width) * windowScale, height: CGFloat(window.height) * windowScale)
    let windowRect = CGRect(origin: CGPoint(x: 44, y: popoverBottom - windowSize.height), size: windowSize)
    framed(canvas, window, windowRect, radius: 10 * u * windowScale / scale, base: color(Pixels(window).rgb(4, 4)), look: look,
           shadowOffset: 14, shadowBlur: 44)

    // Popover under the item
    let arrowX = itemRect.midX
    let left = min(max(arrowX - popoverSize.width / 2, 40), CGFloat(width) - 40 - popoverSize.width)
    let rect = CGRect(origin: CGPoint(x: left, y: popoverTop), size: popoverSize)
    guard popoverBottom < CGFloat(height) - 32, windowRect.maxX < rect.minX else { fail("히어로 배치가 캔버스에 맞지 않음") }
    let outline = canvas.cg(popoverPath(rect, radius: 12 * u, arrowX: arrowX, arrowHalfWidth: 13 * u, arrowHeight: arrowHeight))
    let base = color(sheet.background[theme]!)
    canvas.shadow(outline, fill: base, offsetY: 20, blur: 64, look.shadow)
    canvas.fill(outline, base)
    canvas.clipped(canvas.rounded(rect, 12 * u)) { canvas.draw(popover, rect) }
    canvas.stroke(outline, look.border, width: 1.5)
    return roundCorners(canvas, radius: 32)
}

// Generic status glyphs (plain shapes, no logos). Each returns its width.

private func controlCenterGlyph(_ canvas: Canvas, right: CGFloat, mid: CGFloat, u: CGFloat, _ tint: CGColor) -> CGFloat {
    let w = 15 * u, h = 6.4 * u
    for (index, y) in [mid - 7.4 * u, mid + 1 * u].enumerated() {
        let rect = CGRect(x: right - w, y: y, width: w, height: h)
        canvas.stroke(canvas.rounded(rect.insetBy(dx: 0.7 * u, dy: 0.7 * u), h / 2 - 0.7 * u), tint, width: 1.4 * u)
        let knobX = index == 0 ? rect.minX + h / 2 : rect.maxX - h / 2
        canvas.fill(canvas.rounded(CGRect(x: knobX - 2.1 * u, y: rect.midY - 2.1 * u, width: 4.2 * u, height: 4.2 * u), 2.1 * u), tint)
    }
    return w
}

private func searchGlyph(_ canvas: Canvas, right: CGFloat, mid: CGFloat, u: CGFloat, _ tint: CGColor) -> CGFloat {
    let w = 14 * u, radius = 4.6 * u
    let center = CGPoint(x: right - w + radius + 1 * u, y: mid - 1.6 * u)
    canvas.stroke(canvas.rounded(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), radius),
                  tint, width: 1.7 * u)
    let handle = CGMutablePath()
    handle.move(to: CGPoint(x: center.x + 3.6 * u, y: center.y + 3.6 * u))
    handle.addLine(to: CGPoint(x: center.x + 7.4 * u, y: center.y + 7.4 * u))
    canvas.context.setLineCap(.round)
    canvas.stroke(canvas.cg(handle), tint, width: 2 * u)
    return w
}

private func wifiGlyph(_ canvas: Canvas, right: CGFloat, mid: CGFloat, u: CGFloat, _ tint: CGColor) -> CGFloat {
    let w = 17 * u
    let center = canvas.cg(CGPoint(x: right - w / 2, y: mid + 6 * u))
    let context = canvas.context
    context.saveGState()
    context.setLineCap(.round)
    context.setStrokeColor(tint)
    context.setLineWidth(2.1 * u)
    for radius in [6.8 * u, 10.6 * u] {
        context.addArc(center: center, radius: radius, startAngle: .pi / 4, endAngle: .pi * 3 / 4, clockwise: false)
        context.strokePath()
    }
    context.move(to: center)
    context.addArc(center: center, radius: 3.6 * u, startAngle: .pi / 4, endAngle: .pi * 3 / 4, clockwise: false)
    context.closePath()
    context.setFillColor(tint)
    context.fillPath()
    context.restoreGState()
    return w
}

private func batteryGlyph(_ canvas: Canvas, right: CGFloat, mid: CGFloat, u: CGFloat, level: CGFloat, _ tint: CGColor) -> CGFloat {
    let bodyWidth = 23 * u, bodyHeight = 11.5 * u, nub = 1.6 * u
    let body = CGRect(x: right - nub - 0.8 * u - bodyWidth, y: mid - bodyHeight / 2, width: bodyWidth, height: bodyHeight)
    let faint = tint.copy(alpha: tint.alpha * 0.45)!
    canvas.stroke(canvas.rounded(body.insetBy(dx: 0.5 * u, dy: 0.5 * u), 3.2 * u), faint, width: 1 * u)
    canvas.fill(canvas.rounded(CGRect(x: body.maxX + 0.8 * u, y: mid - 2 * u, width: nub, height: 4 * u), 0.8 * u), faint)
    let inner = body.insetBy(dx: 2 * u, dy: 2 * u)
    canvas.fill(canvas.rounded(CGRect(x: inner.minX, y: inner.minY, width: inner.width * level, height: inner.height), 1.6 * u), tint)
    return bodyWidth + nub + 0.8 * u
}

// MARK: - Feature shots

/// One popover region on the backdrop, in a rounded frame.
func featureShot(_ theme: Theme, _ sheet: FixtureSheet, _ region: FixtureSheet.Region) -> CGImage {
    let look = Look.of(theme)
    let image = sheet.crop(theme, sheet.rows(region))
    let pad: CGFloat = 48
    let canvas = Canvas(image.width + Int(pad) * 2, image.height + Int(pad) * 2)
    look.paintWall(canvas, glowScale: 0.8)
    framed(canvas, image, CGRect(x: pad, y: pad, width: CGFloat(image.width), height: CGFloat(image.height)), radius: 24,
           base: color(sheet.background[theme]!), look: look)
    return roundCorners(canvas, radius: 28)
}

// MARK: - Menu bar

/// Draws a fixture cell on a fresh rounded bar (the grey matrix background never shows).
private func menuTile(_ canvas: Canvas, _ menu: MenuMatrix, state: Int, theme: Theme, at origin: CGPoint, look: Look) {
    let cell = menu.cell(state, MenuMatrix.column(theme))
    let rect = CGRect(origin: origin, size: cell.size)
    let bar = color(menu.bar[theme]!)
    canvas.shadow(canvas.rounded(rect, 12), fill: bar, offsetY: 3, blur: 12, look.shadow.copy(alpha: look.shadow.alpha * 0.6)!)
    canvas.clipped(canvas.rounded(rect.insetBy(dx: 3, dy: 3), 12)) {
        canvas.draw(menu.inner(state, MenuMatrix.column(theme)), rect.insetBy(dx: 3, dy: 3), quality: .none)
    }
    canvas.stroke(canvas.rounded(rect.insetBy(dx: 0.5, dy: 0.5), 11.5), look.border, width: 1)
}

/// The three display layouts, each as a menu bar strip with the item at its right end.
func menubarLayouts(_ theme: Theme, minimal: MenuMatrix, twoLine: MenuMatrix, oneLine: MenuMatrix) -> CGImage {
    let look = Look.of(theme)
    let state = MenuMatrix.stateNames.firstIndex(of: "도구 실행")!
    let entries: [(title: String, note: String, menu: MenuMatrix)] = [
        (loc("최소", "Minimal"), loc("고양이 · AI 상태 · 세션 수", "Cat · AI status · session count"), minimal),
        (loc("두 줄 · 기본", "Two Lines · default"), loc("시스템 지표와 AI를 두 줄로", "System stats and AI on two lines"), twoLine),
        (loc("한 줄", "One Line"), loc("모든 항목을 한 줄로", "Everything on one line"), oneLine),
    ]
    let slices = entries.map { $0.menu.slice(state, MenuMatrix.column(theme)) }
    let pad: CGFloat = 48, captionHeight: CGFloat = 40, rowGap: CGFloat = 30, sliceInset: CGFloat = 14
    let barWidth = CGFloat(slices.map(\.width).max()!) + 2 * sliceInset + 96
    let barHeight = CGFloat(slices[0].height)
    let rowHeight = captionHeight + barHeight
    let canvas = Canvas(Int(barWidth + pad * 2), Int(pad * 2 + rowHeight * 3 + rowGap * 2))
    look.paintWall(canvas, glowScale: 0.8)
    for (index, entry) in entries.enumerated() {
        let y = pad + CGFloat(index) * (rowHeight + rowGap)
        let titleWidth = canvas.text(entry.title, x: pad + 4, baseline: y + 24, size: 24, bold: true, color: look.text)
        canvas.text(entry.note, x: pad + 4 + titleWidth + 14, baseline: y + 24, size: 21, color: look.secondary)
        let bar = CGRect(x: pad, y: y + captionHeight, width: barWidth, height: barHeight)
        let fill = color(entry.menu.bar[theme]!)
        canvas.shadow(canvas.rounded(bar, 14), fill: fill, offsetY: 4, blur: 16, look.shadow.copy(alpha: look.shadow.alpha * 0.7)!)
        canvas.fill(canvas.rounded(bar, 14), fill)
        let slice = slices[index]
        canvas.draw(slice, CGRect(x: bar.maxX - sliceInset - CGFloat(slice.width), y: bar.minY, width: CGFloat(slice.width),
                                  height: barHeight), quality: .none)
        canvas.stroke(canvas.rounded(bar.insetBy(dx: 0.5, dy: 0.5), 13.5), look.border, width: 1)
    }
    return roundCorners(canvas, radius: 28)
}

/// Legend: the minimal item in each AI state with its meaning.
func menubarStates(_ theme: Theme, minimal: MenuMatrix) -> CGImage {
    let look = Look.of(theme)
    let legend: [(state: String, title: String, note: String)] = [
        ("진행", "Working", loc("보라 링 · 걷기", "Purple ring · walk")),
        ("도구 실행", "Running tool", loc("파란 사각 · 걷기", "Blue square · walk")),
        ("방금 기록", "Just recorded", loc("출력 기록 · 달리기", "Output recorded · run")),
        ("입력 필요", "Input needed", loc("노란 ? · 정면 앉기", "Yellow ? · sit facing you")),
        ("로그 대기", "Waiting for log", loc("회색 반원 · 앉기", "Grey half circle · sit")),
        ("활동 없음", "No activity", loc("흐린 0 · 잠", "Faint 0 · sleep")),
    ]
    let cell = minimal.cell(0, .light).size
    let pad: CGFloat = 48, gap: CGFloat = 48
    let width = pad * 2 + CGFloat(legend.count) * cell.width + CGFloat(legend.count - 1) * gap
    let canvas = Canvas(Int(width), Int(pad + cell.height + 92 + pad - 8))
    look.paintWall(canvas, glowScale: 0.8)
    for (index, entry) in legend.enumerated() {
        let x = pad + CGFloat(index) * (cell.width + gap)
        menuTile(canvas, minimal, state: MenuMatrix.stateNames.firstIndex(of: entry.state)!, theme: theme,
                 at: CGPoint(x: x, y: pad), look: look)
        let center = x + cell.width / 2
        canvas.text(loc(entry.state, entry.title), x: center, baseline: pad + cell.height + 40, size: 23, bold: true, color: look.text, align: .center)
        canvas.text(entry.note, x: center, baseline: pad + cell.height + 72, size: 19, color: look.secondary, align: .center)
    }
    return roundCorners(canvas, radius: 28)
}

// MARK: - Architecture

/// Where TokenCat's numbers come from. Drawn here because GitHub's Mermaid frame clips wide flowcharts.
func architecture(_ theme: Theme, menu: MenuMatrix, assets: String) -> CGImage {
    let look = Look.of(theme)
    let dark = theme == .dark
    let card = dark ? color(0xFFFFFF, 0.07) : color(0xFFFFFF, 0.72)
    let group = dark ? color(0xFFFFFF, 0.03) : color(0xFFFFFF, 0.30)
    let wire = dark ? color(0xC9CCF2, 0.60) : color(0x3B4277, 0.50)
    let pill = dark ? color(0x262B57) : color(0xF4F5FC)
    let pad: CGFloat = 56, leftWidth: CGFloat = 470, leftGap: CGFloat = 340, midWidth: CGFloat = 280
    let rightGap: CGFloat = 96, rightWidth: CGFloat = 380
    let groupLabel: CGFloat = 60, cardGap: CGFloat = 16, groupInset: CGFloat = 24, systemGap: CGFloat = 28
    let jsonl = CGRect(x: pad + groupInset, y: pad + groupLabel, width: leftWidth - 2 * groupInset, height: 136)
    let otlp = CGRect(x: jsonl.minX, y: jsonl.maxY + cardGap, width: jsonl.width, height: 136)
    let codeGroup = CGRect(x: pad, y: pad, width: leftWidth, height: otlp.maxY + 22 - pad)
    let system = CGRect(x: pad, y: codeGroup.maxY + systemGap, width: leftWidth, height: 112)
    let canvas = Canvas(Int(pad * 2 + leftWidth + leftGap + midWidth + rightGap + rightWidth), Int(system.maxY + pad))
    look.paintWall(canvas, glowScale: 0.8)

    func box(_ rect: CGRect, _ fill: CGColor, radius: CGFloat = 18) {
        canvas.fill(canvas.rounded(rect, radius), fill)
        canvas.stroke(canvas.rounded(rect.insetBy(dx: 0.75, dy: 0.75), radius - 0.75), look.border, width: 1.5)
    }
    func source(_ rect: CGRect, _ title: String, _ lines: [String]) {
        box(rect, card)
        canvas.text(title, x: rect.minX + 24, baseline: rect.minY + 44, size: 24, bold: true, color: look.text)
        for (index, line) in lines.enumerated() {
            canvas.text(line, x: rect.minX + 24, baseline: rect.minY + 80 + CGFloat(index) * 28, size: 20, color: look.secondary)
        }
    }
    /// Flat-ended curve with an arrowhead; the optional label sits in a pill at the midpoint.
    func wireTo(_ start: CGPoint, _ end: CGPoint, label: String? = nil) {
        let bend = (end.x - start.x) * 0.5, tip = CGPoint(x: end.x - 2, y: end.y)
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: CGPoint(x: tip.x - 10, y: tip.y), control1: CGPoint(x: start.x + bend, y: start.y),
                      control2: CGPoint(x: tip.x - 10 - bend, y: tip.y))
        canvas.stroke(canvas.cg(path), wire, width: 2.5)
        let head = CGMutablePath()
        head.addLines(between: [tip, CGPoint(x: tip.x - 14, y: tip.y - 8), CGPoint(x: tip.x - 14, y: tip.y + 8)])
        head.closeSubpath()
        canvas.fill(canvas.cg(head), wire)
        guard let label else { return }
        let mid = CGPoint(x: (start.x + tip.x - 10) / 2, y: (start.y + tip.y) / 2)
        let width = Canvas.measure(label, size: 18) + 28
        box(CGRect(x: mid.x - width / 2, y: mid.y - 18, width: width, height: 36), pill, radius: 18)
        canvas.text(label, x: mid.x, baseline: mid.y + 6.5, size: 18, color: look.text, align: .center)
    }

    // Sources.
    box(codeGroup, group, radius: 24)
    canvas.text("Codex · Claude Code", x: codeGroup.minX + 24, baseline: codeGroup.minY + 40, size: 21, bold: true,
                color: look.secondary)
    source(jsonl, loc("로컬 JSONL 기록", "Local JSONL logs"), ["~/.codex/sessions", "~/.claude/projects"])
    // Both reach the same loopback collector: OTLP for speeds, the Claude Code status line bridge for usage limits.
    source(otlp, loc("OTLP 실측 · 상태 표시줄", "OTLP telemetry · status line"),
           [loc("HTTP/JSON · 속도 실측", "HTTP/JSON · measured speed"), loc("Claude Code 상태 표시줄 · 사용 한도", "Claude Code status line · usage limits")])
    source(system, loc("macOS 시스템 지표", "macOS system stats"), [loc("CPU · 메모리 · 저장 공간 · 배터리 · 네트워크", "CPU · memory · storage · battery · network")])

    // Menu bar item (the app's own render) shown inside the output card.
    let state = MenuMatrix.stateNames.firstIndex(of: "입력 필요")!
    let item = menu.slice(state, MenuMatrix.column(theme))
    let barHeight = CGFloat(item.height), cardHeight = 70 + barHeight + 100
    let midY = (CGFloat(canvas.height) - cardHeight) / 2
    let app = CGRect(x: pad + leftWidth + leftGap, y: midY, width: midWidth, height: cardHeight)
    let output = CGRect(x: app.maxX + rightGap, y: midY, width: rightWidth, height: cardHeight)

    // TokenCat.
    box(app, card, radius: 24)
    let iconSize: CGFloat = 112
    canvas.draw(downscale(readPNG(assets + "/app-icon-v2-1024.png"), to: Int(iconSize)),
                CGRect(x: app.midX - iconSize / 2, y: app.minY + 14, width: iconSize, height: iconSize))
    canvas.text("TokenCat", x: app.midX, baseline: app.maxY - 58, size: 30, bold: true, color: look.text, align: .center)
    canvas.text(loc("이 Mac 안에서 처리", "Processed on this Mac"), x: app.midX, baseline: app.maxY - 26, size: 20, color: look.secondary, align: .center)

    // Output.
    box(output, card, radius: 24)
    canvas.text(loc("메뉴 막대 · 상세 화면", "Menu bar · dashboard"), x: output.minX + 24, baseline: output.minY + 44, size: 24, bold: true, color: look.text)
    let bar = CGRect(x: output.minX + 24, y: output.minY + 66, width: output.width - 48, height: barHeight)
    canvas.clipped(canvas.rounded(bar, 12)) {
        canvas.fill(bar, color(menu.bar[theme]!))
        canvas.draw(item, CGRect(x: bar.maxX - 14 - CGFloat(item.width), y: bar.minY, width: CGFloat(item.width),
                                 height: barHeight), quality: .none)
    }
    canvas.stroke(canvas.rounded(bar.insetBy(dx: 0.5, dy: 0.5), 11.5), look.border, width: 1)
    canvas.text(loc("세션 상태 · 출력 토큰 · 사용 한도", "Sessions · output tokens · usage limits"), x: output.minX + 24, baseline: bar.maxY + 42, size: 20, color: look.secondary)
    canvas.text(loc("알림은 켠 경우에만", "Notifications only if turned on"), x: output.minX + 24, baseline: bar.maxY + 72, size: 20, color: look.secondary)

    // Wires: each source lands on its own height of the TokenCat card.
    wireTo(CGPoint(x: jsonl.maxX, y: jsonl.midY), CGPoint(x: app.minX, y: app.midY - 52), label: loc("파일 변경 감지 · 추가분만 읽기", "File changes · new lines only"))
    wireTo(CGPoint(x: otlp.maxX, y: otlp.midY), CGPoint(x: app.minX, y: app.midY), label: "127.0.0.1:16493")
    wireTo(CGPoint(x: system.maxX, y: system.midY), CGPoint(x: app.minX, y: app.midY + 52))
    wireTo(CGPoint(x: app.maxX, y: app.midY), CGPoint(x: output.minX, y: output.midY))
    return roundCorners(canvas, radius: 28)
}

// MARK: - Settings

/// All five settings tabs in tab order, in two columns (일반 + 메뉴 막대 | 고양이 + 실측 + 정보). Windows are 40 apart in
/// both columns; the shorter column is centred in the taller one's height.
func settingsCollage(_ theme: Theme, panes: [String: CGImage]) -> CGImage {
    let look = Look.of(theme)
    let columns = [["general", "menubar"], ["cat", "telemetry", "about"]]
    let scale: CGFloat = 0.75, pad: CGFloat = 56, gap: CGFloat = 40
    let windowWidth = CGFloat(panes["general"]!.width) * scale
    func height(_ name: String) -> CGFloat { CGFloat(panes[name]!.height) * scale }
    let columnHeights = columns.map { names in names.map(height).reduce(0, +) + gap * CGFloat(names.count - 1) }
    let tallest = columnHeights.max()!
    let canvas = Canvas(Int(pad * 2 + windowWidth * 2 + gap), Int(pad * 2 + tallest))
    look.paintWall(canvas, glowScale: 0.8)
    for (column, names) in columns.enumerated() {
        var y = pad + ((tallest - columnHeights[column]) / 2).rounded()
        for name in names {
            let image = panes[name]!
            let rect = CGRect(x: pad + CGFloat(column) * (windowWidth + gap), y: y, width: windowWidth, height: height(name))
            let base = color(Pixels(image).rgb(4, 4))
            framed(canvas, image, rect, radius: 18, base: base, look: look, shadowOffset: 12, shadowBlur: 36)
            y += rect.height + gap
        }
    }
    return roundCorners(canvas, radius: 28)
}

// MARK: - App icon

/// 1024 master at 256 / 128 / 64 px, the 32 / 16 px pixel-head icons at 1:1, and both magnified.
/// The master keeps macOS's transparent margin (100/1024 per side), so spacing and bottoms follow the visible tile.
func iconShowcase(_ theme: Theme, assets: String) -> CGImage {
    let look = Look.of(theme)
    let master = readPNG(assets + "/app-icon-v2-1024.png")
    let small32 = readPNG(assets + "/app-icon-v2-32.png"), small16 = readPNG(assets + "/app-icon-v2-16.png")
    struct Item { let image: CGImage, size: CGFloat, label: String, nearest: Bool; var margin: CGFloat { nearest ? 0 : size * 100 / 1024 } }
    let items = [
        Item(image: downscale(master, to: 256), size: 256, label: "256 px", nearest: false),
        Item(image: downscale(master, to: 128), size: 128, label: "128", nearest: false),
        Item(image: downscale(master, to: 64), size: 64, label: "64", nearest: false),
        Item(image: small32, size: 32, label: "32", nearest: true),
        Item(image: small16, size: 16, label: "16", nearest: true),
    ]
    let zoomed = [
        Item(image: small32, size: 192, label: "32 px · 6×", nearest: true),
        Item(image: small16, size: 192, label: "16 px · 12×", nearest: true),
    ]
    let all = items + zoomed
    let pad: CGFloat = 64, gap: CGFloat = 52, separator: CGFloat = 96
    let visible = all.map { $0.size - 2 * $0.margin }.reduce(0, +)
    let width = pad * 2 + visible + gap * CGFloat(all.count - 2) + separator
    let baseline: CGFloat = 64 + 206
    let canvas = Canvas(Int(width), Int(baseline + 96))
    canvas.draw(wallpaper(width: canvas.width, height: canvas.height, stops: look.neutral), canvas.bounds, quality: .none)
    var x = pad                                            // left edge of the next visible tile
    for (index, item) in all.enumerated() {
        if index == items.count {
            x += separator - gap
            canvas.fill(CGRect(x: x - separator / 2, y: baseline - 200, width: 1.5, height: 200 + 48), look.border)
        }
        let rect = CGRect(x: x - item.margin, y: baseline - item.size + item.margin, width: item.size, height: item.size)
        canvas.draw(item.image, rect, quality: item.nearest ? .none : .high)
        canvas.text(item.label, x: rect.midX, baseline: baseline + 44, size: 21, color: look.secondary, align: .center)
        x += item.size - 2 * item.margin + gap
    }
    return roundCorners(canvas, radius: 28)
}
