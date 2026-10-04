import AppKit

enum StatusBarLayout: String, CaseIterable, Identifiable {
    case minimal, compact, inline
    var id: String { rawValue }
    var title: String {
        switch self { case .minimal: return "최소"; case .compact: return "두 줄"; case .inline: return "한 줄" }
    }
    var summary: String {
        switch self {
        case .minimal: return "고양이와 AI 상태·세션 수만 표시합니다"
        case .compact: return "지표 이름 아래에 값을 표시합니다"
        case .inline: return "아이콘 옆에 값을 한 줄로 표시합니다"
        }
    }
}

struct StatusBarMetric {
    var id: MetricID
    var label: String
    var value: String
    var symbol: String
    var detail: String
    var isActive: Bool = false
    var activityState: TokenActivityState = .idle
}

/// Menu-bar AI summary, derived once per publish from the shared session groups.
struct StatusAISummary: Equatable {
    /// Top-level groups that are running or waiting for the person.
    var running = 0
    /// Top-level groups with a member waiting for the person (question or plan approval).
    var input = 0
    /// input > tool > output > working > stale (log wait) > idle.
    var phase: TokenActivityState = .idle

    init() {}
    init(groups: [SessionGroup], counts: SessionCounts) {
        let waiting = groups.filter { $0.members.contains { $0.reading.activityState == .input } }
        input = waiting.count
        running = counts.runningGroups + waiting.filter { !$0.state.isRunning }.count
        phase = input > 0 ? .input : counts.phase
    }

    static func phaseTitle(_ phase: TokenActivityState) -> String {
        switch phase {
        case .input: return "입력 필요"
        case .tool: return "도구 실행"
        case .output: return "출력 기록"
        case .working: return "진행"
        case .stale: return "로그 대기"
        default: return "활동 없음"
        }
    }
}

enum StatusBarContent {
    static func networkRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let units = ["B/s", "kB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s", "ZB/s", "YB/s"]
        var amount = value
        var unit = 0
        while amount >= 1_000 && unit < units.count - 1 {
            amount /= 1_000
            unit += 1
        }
        var precision = unit > 0 && amount < 10 ? 1 : 0
        var factor = precision == 1 ? 10.0 : 1.0
        var rounded = (amount * factor).rounded() / factor
        // Promote the unit when display rounding would produce 1000kB/s.
        if rounded >= 1_000 && unit < units.count - 1 {
            amount /= 1_000
            unit += 1
            precision = amount < 10 ? 1 : 0
            factor = precision == 1 ? 10 : 1
            rounded = (amount * factor).rounded() / factor
        }
        if rounded >= 1_000 { return "≥999\(units[unit])" }
        let number = String(format: precision == 1 ? "%.1f" : "%.0f", rounded)
        return (number.hasSuffix(".0") ? String(number.dropLast(2)) : number) + units[unit]
    }

    /// "1.5kB/s" → ("1.5", "kB/s"); units are drawn smaller but never dropped.
    static func splitRate(_ text: String) -> (number: String, unit: String) {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return (text, "") }
        return (String(text[..<index]), String(text[index...]))
    }

    /// `counts`, `ai` and `recorded` come from the popover's per-publish presentation so both show the same numbers.
    static func metrics(system: SystemSnapshot, counts: SessionCounts, ai: StatusAISummary, recorded: Int,
                        preferences: Preferences, layout: StatusBarLayout? = nil,
                        hasSample: Bool, hasTokenSample: Bool) -> [StatusBarMetric] {
        func percentage(_ number: Double?) -> String {
            guard hasSample, let number, number.isFinite else { return "—" }
            return String(format: "%.0f%%", number)
        }
        let upload = networkRate(hasSample ? system.uploadBytesPerSecond : nil)
        let download = networkRate(hasSample ? system.downloadBytesPerSecond : nil)
        let ids = (layout ?? preferences.statusBarLayout) == .minimal
            ? [MetricID.ai] : preferences.order.filter { preferences.visible.contains($0) }
        return ids.compactMap { id in
            switch id {
            case .cpu:
                let value = percentage(system.cpuPercent)
                return StatusBarMetric(id: id, label: "CPU", value: value, symbol: "cpu",
                                       detail: "CPU 사용률 \(value)")
            case .memory:
                let value = percentage(Format.ratio(system.memoryUsedBytes, system.memoryTotalBytes))
                return StatusBarMetric(id: id, label: "RAM", value: value, symbol: "memorychip",
                                       detail: "메모리 \(value) · \(Format.capacity(system.memoryUsedBytes, system.memoryTotalBytes))")
            case .disk:
                let value = percentage(Format.ratio(system.diskUsedBytes, system.diskTotalBytes))
                return StatusBarMetric(id: id, label: "DISK", value: value, symbol: "internaldrive",
                                       detail: "저장 공간 \(value) · \(Format.capacity(system.diskUsedBytes, system.diskTotalBytes))")
            case .battery:
                guard system.batteryPresent else { return nil }
                let value = percentage(system.batteryPercent)
                return StatusBarMetric(id: id, label: "BAT", value: value, symbol: "battery.75percent",
                                       detail: "배터리 \(value) · \(Format.power(system))")
            case .network:
                return StatusBarMetric(id: id, label: "NET", value: "↑\(upload)\n↓\(download)", symbol: "network",
                                       detail: "업로드 \(upload) · 다운로드 \(download)")
            case .ai:
                // The value equals the popover's live chips combined; the mark shape carries the phase.
                let value = hasTokenSample ? String(ai.running) : "—"
                let detail = hasTokenSample
                    ? "AI \(StatusAISummary.phaseTitle(ai.phase)) · \(aiCountLine(counts, ai))\n최근 5분 출력 기록 \(Format.tokens(recorded)) tok · Codex \(counts.running[.codex] ?? 0), Claude Code \(counts.running[.claude] ?? 0)"
                    : "AI 기록 확인 중"
                return StatusBarMetric(id: id, label: "AI", value: value, symbol: "", detail: detail,
                                       isActive: hasTokenSample && ai.running > 0,
                                       activityState: hasTokenSample ? ai.phase : .idle)
            }
        }
    }

    private static func aiCountLine(_ counts: SessionCounts, _ ai: StatusAISummary) -> String {
        "진행 중 \(ai.running)개 · 도구 실행 \(counts.toolMembers) · 하위 에이전트 \(counts.runningSubagents) · 로그 대기 \(counts.waiting)"
            + (ai.input > 0 ? " · 입력 필요 \(ai.input)" : "")
    }

    /// Tooltip holds only slow-changing context the bar does not show; live values stay in the AX value.
    static func tooltip(system: SystemSnapshot, counts: SessionCounts, ai: StatusAISummary,
                        hasSample: Bool, hasTokenSample: Bool) -> String {
        func capacity(_ used: UInt64?, _ total: UInt64?) -> String? {
            guard let used, let total, total > 0 else { return nil }
            let tera = total >= 1_099_511_627_776
            let factor = tera ? 1_099_511_627_776.0 : 1_073_741_824.0
            let format = tera ? "%.1f" : "%.0f"
            return String(format: format, Double(used) / factor) + " / " + String(format: format, Double(total) / factor) + (tera ? " TB" : " GB")
        }
        var lines = ["TokenCat"]
        if hasSample {
            let parts = [capacity(system.memoryUsedBytes, system.memoryTotalBytes).map { "메모리 \($0)" },
                         capacity(system.diskUsedBytes, system.diskTotalBytes).map { "저장 공간 \($0)" }].compactMap { $0 }
            if !parts.isEmpty { lines.append(parts.joined(separator: " · ")) }
        }
        lines.append(hasTokenSample ? "AI " + aiCountLine(counts, ai) : "AI 기록 확인 중")
        lines.append("클릭: 세션 상세 · 우클릭: 빠른 메뉴")
        return lines.joined(separator: "\n")
    }
}

final class StatusBarContentView: NSView {
    private(set) var metrics: [StatusBarMetric] = []
    private(set) var layout: StatusBarLayout = .compact
    private(set) var showRunner = true
    private(set) var runnerPose: RunnerPose = .sit
    private(set) var runnerFrame = 0
    /// Open popover or menu: the system draws the selection plate. Text keeps label colours;
    /// only the AI state colour is dropped (the mark shape stays).
    var highlighted = false { didSet { if highlighted != oldValue { needsDisplay = true } } }
    private var symbolImages: [String: NSImage] = [:]
    private var pixelScale: CGFloat?
    /// Snapshot-only record of each text run drawn: its text, origin x and shrink factor (1 = natural size).
    private(set) var drawnText: [(text: String, x: CGFloat, fit: CGFloat)] = []
    private let edge: CGFloat = 4
    static let runnerSlot = NSSize(width: 32, height: 20)

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: requiredWidth, height: 24) }

    var requiredWidth: CGFloat {
        if metrics.isEmpty && !showRunner { return 28 }
        let runnerWidth = showRunner ? Self.runnerSlot.width + (metrics.isEmpty ? 0 : 2) : 0
        return edge * 2 + runnerWidth + metrics.reduce(0) { $0 + cellWidth($1.id) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    // The native status button owns mouse input, highlight, tooltip and AX.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(metrics: [StatusBarMetric], layout: StatusBarLayout, showRunner: Bool) {
        let previousWidth = requiredWidth
        self.metrics = metrics
        self.layout = layout
        self.showRunner = showRunner
        if previousWidth != requiredWidth { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }

    func updateRunner(pose: RunnerPose, frame: Int) {
        guard pose != runnerPose || frame != runnerFrame else { return }
        runnerPose = pose
        runnerFrame = frame
        if showRunner { setNeedsDisplay(runnerRect(in: bounds)) }
    }

    /// Increase Contrast, Reduce Motion and similar display options changed.
    func displayOptionsChanged() {
        symbolImages.removeAll()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        symbolImages.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) { drawContent(in: bounds, dirtyRect: dirtyRect) }

    /// Rasterizes the same native view, with transparency, for export previews.
    func snapshotImage(scale: CGFloat = 2) -> NSImage? {
        guard scale.isFinite, scale > 0 else { return nil }
        let height = bounds.height.isFinite && bounds.height > 0 ? bounds.height : 24
        let size = NSSize(width: requiredWidth, height: height)
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)),
                                      height: Int(ceil(size.height * scale)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        pixelScale = scale
        drawnText = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawContent(in: NSRect(origin: .zero, size: size), dirtyRect: NSRect(origin: .zero, size: size))
        }
        pixelScale = nil
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    func cellWidth(_ id: MetricID) -> CGFloat {
        switch layout {
        case .minimal: return showRunner ? 30 : 41
        case .compact:
            switch id { case .network: return 66; case .ai: return 36; default: return 32 }
        case .inline:
            switch id { case .network: return 114; case .ai: return 46; default: return 52 }
        }
    }

    static func markWidth(_ state: TokenActivityState) -> CGFloat {
        switch state {
        case .input: return 8
        case .output, .tool, .working, .stale: return 6
        default: return 0
        }
    }
    /// Every AI state reserves the widest mark's slot, so the count never moves when the mark changes.
    static let markSlot: CGFloat = 8 + 3

    private func runnerRect(in rect: NSRect) -> NSRect {
        NSRect(x: edge, y: (rect.height - Self.runnerSlot.height) / 2, width: Self.runnerSlot.width, height: Self.runnerSlot.height)
    }

    private func group(_ id: MetricID) -> Int {
        switch id { case .network: return 1; case .ai: return 2; default: return 0 }
    }

    private struct Palette {
        var label: NSColor
        var secondary: NSColor
        var tertiary: NSColor
        var contrast: Bool
        var stateColours: Bool
    }

    private struct Run {
        var text: String
        var font: NSFont
        var color: NSColor
        var kern: CGFloat = 0
    }

    private var scale: CGFloat { pixelScale ?? window?.backingScaleFactor ?? 2 }
    private func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

    private func drawContent(in rect: NSRect, dirtyRect: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let isHighlighted = highlighted || (superview as? NSStatusBarButton)?.isHighlighted == true
        let palette = Palette(label: .labelColor,
                              secondary: contrast ? NSColor.labelColor.withAlphaComponent(0.7) : .secondaryLabelColor,
                              tertiary: contrast ? .secondaryLabelColor : .tertiaryLabelColor,
                              contrast: contrast, stateColours: !isHighlighted)
        var x = edge
        if showRunner {
            let slot = runnerRect(in: rect)
            if slot.intersects(dirtyRect) { drawRunner(in: slot) }
            x += Self.runnerSlot.width + (metrics.isEmpty ? 0 : 2)
        }
        if metrics.isEmpty && !showRunner {
            draw([Run(text: "TC", font: .systemFont(ofSize: 11, weight: .semibold), color: palette.label)],
                 centerY: rect.midY, in: rect.insetBy(dx: 2, dy: 0))
            return
        }
        for (index, metric) in metrics.enumerated() {
            let width = cellWidth(metric.id)
            let cell = NSRect(x: x, y: 0, width: width, height: rect.height)
            if cell.intersects(dirtyRect) {
                if index > 0 && group(metrics[index - 1].id) != group(metric.id) {
                    drawSeparator(x: x, height: rect.height, color: palette.secondary.withAlphaComponent(0.26))
                }
                switch layout {
                case .minimal: drawMinimal(metric, in: cell, palette)
                case .compact: drawCompact(metric, in: cell, palette)
                case .inline: drawInline(metric, in: cell, palette)
                }
            }
            x += width
        }
    }

    private func drawRunner(in slot: NSRect) {
        let image = Runner.image(pose: runnerPose, frame: runnerFrame)
        var size = image.size
        if size.width <= 0 || size.height <= 0 || size.width > slot.width || size.height > slot.height {
            let fit = size.width > 0 && size.height > 0 ? min(slot.width / size.width, slot.height / size.height) : 1
            size = size.width > 0 && size.height > 0 ? NSSize(width: size.width * fit, height: size.height * fit) : slot.size
        }
        let origin = NSPoint(x: snap(slot.midX - size.width / 2), y: snap(slot.midY - size.height / 2))
        image.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
    }

    private var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .medium) }
    private var labelFont: NSFont { .systemFont(ofSize: 8.5, weight: .semibold) }

    /// Digits in label colour; '%' smaller and secondary. Unknown stays "—".
    private func valueRuns(_ value: String, _ palette: Palette) -> [Run] {
        if value == "—" { return [Run(text: value, font: valueFont, color: palette.secondary)] }
        if value.hasSuffix("%") {
            return [Run(text: String(value.dropLast()), font: valueFont, color: palette.label),
                    Run(text: "%", font: .systemFont(ofSize: 8.5, weight: .medium), color: palette.secondary)]
        }
        return [Run(text: value, font: valueFont, color: palette.label)]
    }

    private func drawCompact(_ metric: StatusBarMetric, in cell: NSRect, _ palette: Palette) {
        let top = max(0, (cell.height - 22) / 2)
        if metric.id == .network {
            drawNetworkRows(metric, in: NSRect(x: cell.minX, y: top, width: cell.width, height: 22), palette)
            return
        }
        let inner = cell.insetBy(dx: 1, dy: 0)
        draw([Run(text: metric.label, font: labelFont, color: palette.secondary, kern: 0.3)], centerY: top + 4.5, in: inner)
        if metric.id == .ai {
            drawAI(metric, centerY: top + 15.5, in: inner, font: valueFont, palette, centered: true)
        } else {
            draw(valueRuns(metric.value, palette), centerY: top + 15.5, in: inner)
        }
    }

    private func drawInline(_ metric: StatusBarMetric, in cell: NSRect, _ palette: Palette) {
        if metric.id == .network {
            drawNetworkLine(metric, in: cell, palette)
            return
        }
        if metric.id == .ai {
            // 4 pt clear of the separator on both sides.
            drawAI(metric, centerY: cell.midY, in: NSRect(x: cell.minX + 4, y: 0, width: cell.width - 6, height: cell.height),
                   font: valueFont, palette, centered: false,
                   prefix: [Run(text: "AI", font: .systemFont(ofSize: 9, weight: .semibold), color: palette.secondary, kern: 0.3)])
            return
        }
        // Natural aspect at an 11pt height, trailing-aligned in a 16pt slot so each icon hugs its own value.
        let slot = NSRect(x: cell.minX + 2, y: cell.midY - 5.5, width: 16, height: 11)
        if let icon = symbol(metric.symbol, color: palette.secondary, key: palette.contrast ? "c" : "n"),
           icon.size.width > 0, icon.size.height > 0 {
            let fit = min(slot.height / icon.size.height, slot.width / icon.size.width)
            let size = NSSize(width: icon.size.width * fit, height: icon.size.height * fit)
            icon.draw(in: NSRect(x: snap(slot.maxX - size.width), y: snap(slot.midY - size.height / 2), width: size.width, height: size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        draw(valueRuns(metric.value, palette), centerY: cell.midY,
             in: NSRect(x: slot.maxX + 3, y: 0, width: cell.maxX - slot.maxX - 3, height: cell.height), alignment: .left)
    }

    private func drawMinimal(_ metric: StatusBarMetric, in cell: NSRect, _ palette: Palette) {
        let prefix = showRunner ? [] : [Run(text: "AI", font: .systemFont(ofSize: 9, weight: .semibold), color: palette.secondary, kern: 0.3)]
        drawAI(metric, centerY: cell.midY, in: cell,
               font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), palette, centered: true, prefix: prefix)
    }

    /// Mark slot (shape = state) then the count; 0 or unknown is tertiary with an empty slot.
    private func drawAI(_ metric: StatusBarMetric, centerY: CGFloat, in rect: NSRect, font: NSFont, _ palette: Palette,
                        centered: Bool, prefix: [Run] = []) {
        let count = [Run(text: metric.value, font: font, color: metric.isActive ? palette.label : palette.tertiary)]
        let countWidth = string(count).size().width
        let prefixWidth = prefix.isEmpty ? 0 : string(prefix).size().width + 3
        let total = prefixWidth + Self.markSlot + countWidth
        var x = centered ? max(rect.minX, rect.midX - total / 2) : rect.minX
        if !prefix.isEmpty {
            draw(prefix, centerY: centerY, in: NSRect(x: x, y: rect.minY, width: prefixWidth, height: rect.height), alignment: .left)
            x += prefixWidth
        }
        drawMark(metric.activityState, center: NSPoint(x: x + (Self.markSlot - 3) / 2, y: centerY), palette)
        x += Self.markSlot
        draw(count, centerY: centerY, in: NSRect(x: x, y: rect.minY, width: max(1, rect.maxX - x), height: rect.height), alignment: .left)
    }

    /// Filled dot output · rounded square tool · ring working · half ring log wait · '?' badge input.
    private func drawMark(_ state: TokenActivityState, center: NSPoint, _ palette: Palette) {
        let size = Self.markWidth(state)
        guard size > 0 else { return }
        let rect = NSRect(x: snap(center.x - size / 2), y: snap(center.y - size / 2), width: size, height: size)
        let colour: NSColor
        if !palette.stateColours { colour = palette.label } else {
            switch state {
            case .output: colour = .systemGreen
            case .tool: colour = .systemBlue
            case .stale: colour = .systemOrange
            case .input: colour = .systemYellow
            default: colour = palette.label
            }
        }
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
        ring.lineWidth = 1.2
        var outline: NSBezierPath?
        switch state {
        case .output:
            colour.setFill()
            outline = NSBezierPath(ovalIn: rect)
            outline?.fill()
        case .tool:
            colour.setFill()
            outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 1.4, yRadius: 1.4)
            outline?.fill()
        case .working:
            colour.setStroke()
            ring.stroke()
        case .stale:
            colour.setStroke()
            ring.stroke()
            let half = NSBezierPath()
            half.move(to: NSPoint(x: rect.midX, y: rect.minY))
            half.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: size / 2, startAngle: 270, endAngle: 90, clockwise: true)
            half.close()
            colour.setFill()
            half.fill()
        case .input:
            let glyph: NSColor
            if palette.stateColours {
                colour.setFill()
                outline = NSBezierPath(ovalIn: rect)
                outline?.fill()
                glyph = .black
            } else {
                colour.setStroke()
                ring.stroke()
                glyph = colour
            }
            draw([Run(text: "?", font: .systemFont(ofSize: 7, weight: .heavy), color: glyph)], centerY: rect.midY,
                 in: rect.insetBy(dx: -2, dy: 0))
        default:
            break
        }
        if palette.contrast, palette.stateColours, let outline {
            NSColor.labelColor.setStroke()
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    /// Fixed arrow column, numbers right-aligned to one column, units smaller and secondary.
    private func drawNetworkRows(_ metric: StatusBarMetric, in rect: NSRect, _ palette: Palette) {
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        let arrow: CGFloat = 7, number: CGFloat = 23, unit: CGFloat = 21
        let start = rect.minX + (rect.width - (arrow + number + 1 + unit)) / 2
        for (index, line) in metric.value.components(separatedBy: "\n").prefix(2).enumerated() {
            let centerY = rect.minY + 5.5 + CGFloat(index) * 11
            let parts = StatusBarContent.splitRate(String(line.dropFirst()))
            draw([Run(text: String(line.prefix(1)), font: .systemFont(ofSize: 8, weight: .semibold), color: palette.secondary)],
                 centerY: centerY, capFont: numberFont, in: NSRect(x: start, y: rect.minY, width: arrow, height: rect.height), alignment: .left)
            draw([Run(text: parts.number, font: numberFont, color: parts.unit.isEmpty ? palette.secondary : palette.label)],
                 centerY: centerY, in: NSRect(x: start + arrow, y: rect.minY, width: number, height: rect.height), alignment: .right)
            draw([Run(text: parts.unit, font: .systemFont(ofSize: 8, weight: .regular), color: palette.secondary)],
                 centerY: centerY, capFont: numberFont, in: NSRect(x: start + arrow + number + 1, y: rect.minY, width: unit, height: rect.height),
                 alignment: .left)
        }
    }

    private func drawNetworkLine(_ metric: StatusBarMetric, in cell: NSRect, _ palette: Palette) {
        let numberFont = valueFont
        for (index, line) in metric.value.components(separatedBy: "\n").prefix(2).enumerated() {
            let x = cell.minX + 5 + CGFloat(index) * 53
            let parts = StatusBarContent.splitRate(String(line.dropFirst()))
            draw([Run(text: String(line.prefix(1)), font: .systemFont(ofSize: 9, weight: .semibold), color: palette.secondary)],
                 centerY: cell.midY, capFont: numberFont, in: NSRect(x: x, y: 0, width: 8, height: cell.height), alignment: .left)
            draw([Run(text: parts.number, font: numberFont, color: parts.unit.isEmpty ? palette.secondary : palette.label)],
                 centerY: cell.midY, in: NSRect(x: x + 8, y: 0, width: 22, height: cell.height), alignment: .right)
            draw([Run(text: parts.unit, font: .systemFont(ofSize: 8.5, weight: .regular), color: palette.secondary)],
                 centerY: cell.midY, capFont: numberFont, in: NSRect(x: x + 31, y: 0, width: 21, height: cell.height), alignment: .left)
        }
    }

    private func symbol(_ name: String, color: NSColor, key: String) -> NSImage? {
        let cacheKey = name + "/" + key
        if let image = symbolImages[cacheKey] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        image.isTemplate = false
        symbolImages[cacheKey] = image
        return image
    }

    private func string(_ runs: [Run], scale: CGFloat = 1) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let result = NSMutableAttributedString()
        for run in runs {
            let font = scale < 1 ? NSFont(descriptor: run.font.fontDescriptor, size: max(7, run.font.pointSize * scale)) ?? run.font : run.font
            result.append(NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: run.color,
                                                                            .kern: run.kern, .paragraphStyle: paragraph]))
        }
        return result
    }

    /// Draws one line so the cap height of the largest (or given) font is centred on `centerY`.
    /// Fixed slots avoid width jitter; rare very large values shrink to fit.
    private func draw(_ runs: [Run], centerY: CGFloat, capFont: NSFont? = nil, in rect: NSRect,
                      alignment: NSTextAlignment = .center) {
        guard !runs.isEmpty else { return }
        var text = string(runs)
        var size = text.size()
        var fit: CGFloat = 1
        if size.width > rect.width, size.width > 0 {
            fit = rect.width / size.width
            text = string(runs, scale: fit)
            size = text.size()
        }
        let primary = capFont ?? runs.max { $0.font.pointSize < $1.font.pointSize }!.font
        let ascender = runs.map { $0.font.ascender }.max()! * fit
        let baseline = centerY + primary.capHeight * (capFont == nil ? fit : 1) / 2
        let x: CGFloat
        switch alignment {
        case .left: x = rect.minX
        case .right: x = rect.maxX - size.width
        default: x = rect.midX - size.width / 2
        }
        text.draw(at: NSPoint(x: x, y: baseline - ascender))
        if pixelScale != nil { drawnText.append((text.string, x, fit)) }
    }

    private func drawSeparator(x: CGFloat, height: CGFloat, color: NSColor) {
        color.setFill()
        NSRect(x: snap(x), y: 4, width: 1 / scale, height: max(0, height - 8)).fill()
    }
}

/// Menu-bar-like backdrops for settings previews and snapshots. The real bar is translucent; these approximate it.
enum MenuBarStrip {
    /// `outlined` adds a hairline in the strip's own appearance so it stands apart from a same-toned form row.
    static func backdrop(_ strip: NSImage, dark: Bool, highlighted: Bool = false, outlined: Bool = false, inset: CGFloat = 8) -> NSImage {
        let size = NSSize(width: strip.size.width + inset * 2, height: max(28, strip.size.height + 4))
        return NSImage(size: size, flipped: false) { rect in
            (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            if outlined, let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) {
                appearance.performAsCurrentDrawingAppearance {
                    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 5.75, yRadius: 5.75)
                    border.lineWidth = 0.5
                    NSColor.separatorColor.setStroke()
                    border.stroke()
                }
            }
            let content = NSRect(x: inset, y: (rect.height - strip.size.height) / 2, width: strip.size.width, height: strip.size.height)
            if highlighted {
                // Approximates the selection plate macOS draws behind an open status item.
                (dark ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.1)).setFill()
                NSBezierPath(roundedRect: content.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            strip.draw(in: content)
            return true
        }
    }

    static func preview(model: DashboardModel, preferences: Preferences) -> (images: [NSImage], width: CGFloat) {
        let counts = model.sessions.counts
        let metrics = StatusBarContent.metrics(system: model.system, counts: counts, ai: StatusAISummary(groups: model.groups, counts: counts),
                                               recorded: model.flow.total, preferences: preferences, hasSample: model.hasSample,
                                               hasTokenSample: model.tokensSampledAt != nil)
        var images: [NSImage] = []
        var width: CGFloat = 0
        for dark in [false, true] {
            let view = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.update(metrics: metrics, layout: preferences.statusBarLayout, showRunner: preferences.showRunner)
            view.frame.size.width = view.requiredWidth
            width = view.requiredWidth
            if let strip = view.snapshotImage() { images.append(backdrop(strip, dark: dark, outlined: true)) }
        }
        return (images, width)
    }

    static func png(_ image: NSImage, scale: CGFloat = 2) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(image.size.width * scale)),
                                         pixelsHigh: Int(ceil(image.size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

func runStatusBarChecks() -> [String] {
    let cases: [(String, Double?, String)] = [
        ("missing rate", nil, "—"), ("zero rate", 0, "0B/s"),
        ("byte rounding", 999.49, "999B/s"), ("byte unit crossover", 999.5, "1kB/s"),
        ("kilobyte unit", 1_000, "1kB/s"), ("kilobyte precision", 1_499, "1.5kB/s"),
        ("kilobyte rounding", 999_499, "999kB/s"), ("megabyte crossover", 999_500, "1MB/s"),
        ("gigabyte unit", 1_000_000_000, "1GB/s"), ("terabyte unit", 1_000_000_000_000, "1TB/s"),
        ("invalid rate", .infinity, "—"), ("negative rate", -1, "—")
    ]
    var failures = cases.compactMap { name, value, expected -> String? in
        let actual = StatusBarContent.networkRate(value)
        return actual == expected ? nil : "Status bar \(name): expected \(expected), got \(actual)"
    }
    var checks = cases.count
    let suiteName = "dev.seuput.TokenCat.StatusBarChecks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        failures.append("Status bar: isolated preferences unavailable")
        print("Status bar checks: \(checks + 1 - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
        return failures
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = Preferences(defaults: defaults)
    preferences.reset()
    var system = SystemSnapshot()
    system.cpuPercent = 0
    let at = Date()
    func summary(_ tokens: [TokenReading], now: Date) -> (SessionCounts, StatusAISummary) {
        let groups = SessionPresentation.groups(tokens, now: now)
        let counts = SessionCounts(groups)
        return (counts, StatusAISummary(groups: groups, counts: counts))
    }
    func metrics(_ system: SystemSnapshot, _ tokens: [TokenReading], now: Date = at, layout: StatusBarLayout? = nil,
                 hasSample: Bool = true, hasTokenSample: Bool = true) -> [StatusBarMetric] {
        let (counts, ai) = summary(tokens, now: now)
        return StatusBarContent.metrics(system: system, counts: counts, ai: ai, recorded: FlowSeries.make(tokens, now: now).total,
                                        preferences: preferences, layout: layout, hasSample: hasSample, hasTokenSample: hasTokenSample)
    }
    let loading = metrics(system, [], hasSample: false, hasTokenSample: false)
    let zero = metrics(system, [])
    let waitingForTokens = metrics(system, [], hasTokenSample: false)
    func check(_ name: String, _ passed: Bool) {
        checks += 1
        if !passed { failures.append("Status bar \(name)") }
    }
    check("loading differs from sampled zero",
          loading.first(where: { $0.id == .ai })?.value == "—" &&
          loading.first(where: { $0.id == .cpu })?.value == "—" &&
          waitingForTokens.first(where: { $0.id == .cpu })?.value == "0%" &&
          waitingForTokens.first(where: { $0.id == .ai })?.value == "—" &&
          zero.first(where: { $0.id == .ai })?.value == "0" &&
          zero.first(where: { $0.id == .cpu })?.value == "0%")
    check("absent battery is omitted", !zero.contains(where: { $0.id == .battery }) &&
          zero.count == MetricID.allCases.count - 1)
    check("idle AI has no mark and is not active", zero.first(where: { $0.id == .ai }).map {
        !$0.isActive && StatusBarContentView.markWidth($0.activityState) == 0 } == true)

    preferences.order = [.ai, .cpu, .network, .memory, .disk, .battery]
    preferences.visible = [.ai, .cpu]
    let tokens = [
        TokenReading(source: .codex, id: "active-codex", model: "current-codex", measurementModel: "previous-codex", active: true),
        TokenReading(source: .claude, id: "active-claude", model: "current-claude", measurementModel: "previous-claude", active: true),
        TokenReading(source: .codex, id: "inactive-codex", active: false)
    ]
    let selected = metrics(system, tokens)
    check("selected order and activity count do not aggregate speed",
          selected.map(\.id) == [.ai, .cpu] && selected.first?.value == "2" && selected.first?.isActive == true
          && selected.first?.detail.contains("tok/s") == false)

    var output = TokenReading(source: .codex, id: "output", active: true, activityState: .output,
                              lastOutputAt: at, lastOutputDelta: 12, sampledAt: at)
    let tool = TokenReading(source: .claude, id: "tool", active: true, activityState: .tool, sampledAt: at)
    func ai(_ readings: [TokenReading], now: Date = at, layout: StatusBarLayout? = nil) -> StatusBarMetric? {
        metrics(system, readings, now: now, layout: layout).first(where: { $0.id == .ai })
    }
    check("pending tool remains visible alongside output", ai([output, tool])?.activityState == .tool && ai([output, tool])?.value == "2")
    check("confirmed recent output is highlighted", ai([output])?.activityState == .output)
    output.sampledAt = at.addingTimeInterval(6)
    check("old output stops highlighting while turn remains active",
          ai([output], now: at.addingTimeInterval(6))?.activityState == .working)
    let stale = TokenReading(source: .codex, id: "stale", active: false, lastActivity: at.addingTimeInterval(-180),
                             activityState: .stale, sampledAt: at)
    check("stale logs are waiting rather than running",
          ai([stale])?.activityState == .stale && ai([stale])?.value == "0" && ai([stale])?.isActive == false)
    let unfinished = TokenReading(source: .codex, id: "unfinished", active: false, lastActivity: at.addingTimeInterval(-3_600),
                                  activityState: .unfinished, sampledAt: at)
    check("unfinished turns are neither counted nor marked",
          ai([unfinished])?.activityState == .idle && ai([unfinished])?.value == "0")
    check("a running session outranks waiting for the mark", ai([stale, tool])?.activityState == .tool && ai([stale, tool])?.value == "1")
    let question = TokenReading(source: .claude, id: "question", sessionID: "q1", active: true, activityState: .input, sampledAt: at)
    check("input outranks tool and counts once per group",
          ai([question, tool])?.activityState == .input && ai([question, tool])?.value == "2"
          && ai([question, tool])?.detail.contains("입력 필요 1") == true)
    var parent = TokenReading(source: .claude, id: "claude:parent", sessionID: "s1", active: true, activityState: .working, sampledAt: at)
    var child = TokenReading(source: .claude, id: "claude:child", sessionID: "s1", agentID: "a1", isSubagent: true,
                             active: true, activityState: .tool, sampledAt: at)
    check("subagents count once with their session", ai([parent, child])?.value == "1" && ai([parent, child])?.activityState == .tool
          && ai([parent, child])?.detail.contains("하위 에이전트 1") == true)
    parent.activityState = .complete
    parent.active = false
    child.parentSessionID = "s1"
    check("a running subagent keeps an idle parent's group running", ai([parent, child])?.value == "1")
    child.activityState = .input
    check("a subagent waiting for input marks its top-level group", ai([parent, child])?.activityState == .input
          && ai([parent, child])?.value == "1")

    preferences.visible = [.cpu]
    let minimal = metrics(system, [tool], layout: .minimal)
    check("minimal layout shows the AI item even when it is hidden from the list",
          minimal.map(\.id) == [.ai] && minimal.first?.value == "1")
    check("rate split keeps the unit", StatusBarContent.splitRate("1.5kB/s") == ("1.5", "kB/s")
          && StatusBarContent.splitRate("≥999GB/s") == ("≥999", "GB/s") && StatusBarContent.splitRate("—") == ("—", ""))
    var busy = system
    busy.cpuPercent = 37
    busy.uploadBytesPerSecond = 1_499
    busy.memoryUsedBytes = 19_000_000_000
    busy.memoryTotalBytes = 25_769_803_776
    let (busyCounts, busyAI) = summary([tool, question], now: at)
    let tip = StatusBarContent.tooltip(system: busy, counts: busyCounts, ai: busyAI, hasSample: true, hasTokenSample: true)
    busy.cpuPercent = 81
    busy.uploadBytesPerSecond = 88_000
    let laterTip = StatusBarContent.tooltip(system: busy, counts: busyCounts, ai: busyAI, hasSample: true, hasTokenSample: true)
    check("tooltip omits per-second values and names the quick menu",
          tip == laterTip && !tip.contains("%") && !tip.contains("B/s") && tip.contains("우클릭: 빠른 메뉴")
          && tip.contains("메모리 18 / 24 GB") && tip.contains("입력 필요 1"))

    preferences.reset()
    var missing = SystemSnapshot()
    missing.batteryPresent = true
    var maximum = missing
    maximum.cpuPercent = 100
    maximum.batteryPercent = 100
    maximum.memoryUsedBytes = .max
    maximum.memoryTotalBytes = .max
    maximum.diskUsedBytes = .max
    maximum.diskTotalBytes = .max
    maximum.uploadBytesPerSecond = .greatestFiniteMagnitude
    maximum.downloadBytesPerSecond = .greatestFiniteMagnitude
    let busyTokens = (0..<12).map { TokenReading(source: .codex, id: "busy-\($0)", sessionID: "b\($0)", active: true,
                                                   activityState: .tool, sampledAt: at) }
    let view = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 0, height: 22))
    var stable = true
    var widths: [String: CGFloat] = [:]
    for layout in StatusBarLayout.allCases {
        for runner in [true, false] {
            view.update(metrics: metrics(missing, [], layout: layout, hasSample: false, hasTokenSample: false), layout: layout, showRunner: runner)
            let width = view.requiredWidth
            view.update(metrics: metrics(maximum, busyTokens, layout: layout), layout: layout, showRunner: runner)
            stable = stable && width == view.requiredWidth && width > 0
            widths["\(layout.rawValue)/\(runner)"] = width
        }
    }
    check("layout width is stable from unknown to maximum values", stable)
    // edge 4+4, runner 32+2; compact cells 32 / NET 66 / AI 36; inline 52 / 114 / 46; minimal AI 30 (41 without the cat).
    let expected: [String: CGFloat] = ["compact/true": 272, "inline/true": 410, "minimal/true": 72, "minimal/false": 49]
    check("cell widths match the layout contract", expected.allSatisfy { widths[$0.key] == $0.value })
    check("minimal layout fits beside a notch", (46...72).contains(widths["minimal/true"] ?? 0)
          && (widths["minimal/true"] ?? 0) < (widths["compact/true"] ?? 0))

    // Common worst cases must draw at natural size; only rare values such as "≥999GB/s" may shrink.
    func metric(_ id: MetricID, _ value: String, _ state: TokenActivityState = .idle) -> StatusBarMetric {
        let real = metrics(maximum, busyTokens, layout: .compact).first { $0.id == id }
        return StatusBarMetric(id: id, label: real?.label ?? "", value: value, symbol: real?.symbol ?? "", detail: "",
                               isActive: state != .idle, activityState: state)
    }
    let worst = [metric(.cpu, "100%"), metric(.memory, "100%"), metric(.disk, "100%"), metric(.battery, "100%"),
                 metric(.network, "↑999MB/s\n↓125MB/s"), metric(.ai, "99", .input)]
    var shrunk: [String] = []
    var drifting: [String] = []
    for layout in StatusBarLayout.allCases {
        for runner in [true, false] {
            view.update(metrics: layout == .minimal ? [worst[5]] : worst, layout: layout, showRunner: runner)
            _ = view.snapshotImage()
            shrunk += view.drawnText.filter { $0.fit < 1 }.map { "\(layout.rawValue)/\(runner) '\($0.text)'" }
            // The count keeps its x whatever the mark (none, 6 pt shapes, 8 pt input badge).
            let xs = Set([metric(.ai, "0"), metric(.ai, "1", .working), metric(.ai, "1", .tool), metric(.ai, "1", .input)].compactMap { ai -> CGFloat? in
                view.update(metrics: [ai], layout: layout, showRunner: runner)
                _ = view.snapshotImage()
                return view.drawnText.last { $0.text == ai.value }?.x
            })
            if xs.count != 1 { drifting.append("\(layout.rawValue)/\(runner)") }
        }
    }
    check("worst-case values fit their slots without shrinking: \(shrunk.joined(separator: ", "))", shrunk.isEmpty)
    check("AI count stays put when its state mark changes: \(drifting.joined(separator: ", "))", drifting.isEmpty)
    print("Status bar checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
