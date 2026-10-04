import AppKit

enum StatusBarLayout: String, CaseIterable, Identifiable {
    case compact, inline
    var id: String { rawValue }
    var title: String { self == .compact ? "두 줄 · 컴팩트" : "한 줄 · 아이콘" }
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

    static func metrics(system: SystemSnapshot, tokens: [TokenReading], preferences: Preferences,
                        hasSample: Bool, hasTokenSample: Bool) -> [StatusBarMetric] {
        let active = tokens.filter(\.active)
        let codexCount = active.filter { $0.source == .codex }.count
        let claudeCount = active.filter { $0.source == .claude }.count
        func percentage(_ number: Double?) -> String {
            guard hasSample, let number, number.isFinite else { return "—" }
            return String(format: "%.0f%%", number)
        }
        let upload = networkRate(hasSample ? system.uploadBytesPerSecond : nil)
        let download = networkRate(hasSample ? system.downloadBytesPerSecond : nil)
        return preferences.order.compactMap { id in
            guard preferences.visible.contains(id) else { return nil }
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
                let value = hasTokenSample ? String(active.count) : "—"
                let toolCount = active.filter { $0.activityState == .tool }.count
                let staleCount = tokens.filter { $0.activityState == .stale }.count
                let hasFreshOutput = active.contains { reading in
                    guard let at = reading.lastOutputAt, let sampled = reading.sampledAt,
                          let delta = reading.lastOutputDelta, delta > 0 else { return false }
                    let age = sampled.timeIntervalSince(at)
                    return age >= -5 && age <= 5
                }
                let phase: TokenActivityState = toolCount > 0 ? .tool : (hasFreshOutput ? .output : (active.isEmpty ? (staleCount > 0 ? .stale : .idle) : .working))
                let detail = hasTokenSample
                    ? "AI 최근 활동 \(active.count)개 · 도구 기록 \(toolCount)개 · 로그 대기 \(staleCount)개\nCodex \(codexCount), Claude Code \(claudeCount) · 상태는 최근 로그 기준"
                    : "AI 세션 기록 확인 중"
                return StatusBarMetric(id: id, label: "AI", value: value, symbol: "terminal",
                                       detail: detail, isActive: hasTokenSample && !active.isEmpty, activityState: phase)
            }
        }
    }
}

final class StatusBarContentView: NSView {
    private(set) var metrics: [StatusBarMetric] = []
    private(set) var layout: StatusBarLayout = .compact
    private(set) var showRunner = true
    private(set) var runnerFrame = 0
    var highlighted = false { didSet { if highlighted != oldValue { needsDisplay = true } } }
    private var symbolImages: [String: NSImage] = [:]
    private let edge: CGFloat = 4
    private let runnerSize = NSSize(width: 32, height: 20)

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: requiredWidth, height: 24) }

    var requiredWidth: CGFloat {
        if metrics.isEmpty && !showRunner { return 28 }
        let runnerWidth = showRunner ? runnerSize.width + (metrics.isEmpty ? 0 : 2) : 0
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

    func updateRunner(frame: Int) {
        guard frame != runnerFrame else { return }
        runnerFrame = frame
        if showRunner { setNeedsDisplay(runnerRect(in: bounds)) }
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawContent(in: NSRect(origin: .zero, size: size), dirtyRect: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    private func cellWidth(_ id: MetricID) -> CGFloat {
        switch layout {
        case .compact:
            switch id { case .network: return 66; case .ai: return 30; default: return 32 }
        case .inline:
            switch id { case .network: return 110; case .ai: return 34; default: return 50 }
        }
    }

    private func runnerRect(in rect: NSRect) -> NSRect {
        NSRect(x: edge, y: (rect.height - runnerSize.height) / 2, width: runnerSize.width, height: runnerSize.height)
    }

    private func group(_ id: MetricID) -> Int {
        switch id { case .network: return 1; case .ai: return 2; default: return 0 }
    }

    private func drawContent(in rect: NSRect, dirtyRect: NSRect) {
        let isHighlighted = highlighted || (superview as? NSStatusBarButton)?.isHighlighted == true
        let foreground = isHighlighted ? NSColor.white : NSColor.labelColor
        let secondary = isHighlighted ? NSColor.white.withAlphaComponent(0.82) : NSColor.secondaryLabelColor
        var x = edge
        if showRunner {
            let destination = runnerRect(in: rect)
            if destination.intersects(dirtyRect) {
                Runner.image(frame: runnerFrame).draw(in: destination, from: .zero, operation: .sourceOver,
                                                      fraction: 1, respectFlipped: true, hints: nil)
            }
            x += runnerSize.width + (metrics.isEmpty ? 0 : 2)
        }
        if metrics.isEmpty && !showRunner {
            drawText("TC", in: rect, font: .systemFont(ofSize: 11, weight: .semibold), color: foreground)
            return
        }
        for (index, metric) in metrics.enumerated() {
            let width = cellWidth(metric.id)
            let cell = NSRect(x: x, y: 0, width: width, height: rect.height)
            if cell.intersects(dirtyRect) {
                if index > 0 && group(metrics[index - 1].id) != group(metric.id) {
                    drawSeparator(x: x, height: rect.height, color: secondary.withAlphaComponent(0.26))
                }
                switch layout {
                case .compact: drawCompact(metric, in: cell, foreground: foreground, secondary: secondary)
                case .inline: drawInline(metric, in: cell, foreground: foreground, highlighted: isHighlighted)
                }
            }
            x += width
        }
    }

    private func drawCompact(_ metric: StatusBarMetric, in cell: NSRect, foreground: NSColor, secondary: NSColor) {
        let top = max(0, (cell.height - 22) / 2)
        if metric.id == .network {
            let values = metric.value.components(separatedBy: "\n")
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
            for (index, value) in values.prefix(2).enumerated() {
                drawText(value, in: NSRect(x: cell.minX + 3, y: top + CGFloat(index) * 11,
                                         width: cell.width - 6, height: 11), font: font, color: foreground)
            }
        } else {
            drawText(metric.label, in: NSRect(x: cell.minX + 1, y: top, width: cell.width - 2, height: 9),
                     font: .systemFont(ofSize: 8, weight: .medium), color: activityColor(metric, fallback: secondary))
            drawText(metric.value, in: NSRect(x: cell.minX + 1, y: top + 9, width: cell.width - 2, height: 13),
                     font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: foreground)
        }
    }

    private func drawInline(_ metric: StatusBarMetric, in cell: NSRect, foreground: NSColor, highlighted: Bool) {
        if metric.id == .network {
            drawText(metric.value.replacingOccurrences(of: "\n", with: " "),
                     in: cell.insetBy(dx: 3, dy: 0), font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                     color: foreground)
            return
        }
        let icon = symbol(metric.symbol, color: activityColor(metric, fallback: foreground), highlighted: highlighted,
            variant: metric.activityState.rawValue)
        let iconRect = NSRect(x: cell.minX + 2, y: (cell.height - 11) / 2, width: 11, height: 11)
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        drawText(metric.value, in: NSRect(x: cell.minX + 15, y: 0, width: cell.width - 17, height: cell.height),
                 font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: foreground)
    }

    private func activityColor(_ metric: StatusBarMetric, fallback: NSColor) -> NSColor {
        guard metric.id == .ai, !highlighted, (superview as? NSStatusBarButton)?.isHighlighted != true else { return fallback }
        switch metric.activityState {
        case .tool: return .systemBlue
        case .output: return .systemGreen
        case .stale: return .systemOrange
        default: return fallback
        }
    }

    private func symbol(_ name: String, color: NSColor, highlighted: Bool, variant: String) -> NSImage? {
        let key = name + (highlighted ? "/highlight" : "/normal/" + variant)
        if let image = symbolImages[key] { return image }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))?
            .withSymbolConfiguration(.init(paletteColors: [color])) else { return nil }
        image.isTemplate = false
        symbolImages[key] = image
        return image
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        var actualFont = font
        var attributes: [NSAttributedString.Key: Any] = [.font: actualFont, .foregroundColor: color, .paragraphStyle: paragraph]
        var string = NSAttributedString(string: text, attributes: attributes)
        // Fixed slots avoid width jitter; rare very large counts still fit.
        let naturalWidth = string.size().width
        if naturalWidth > rect.width && naturalWidth > 0 {
            actualFont = NSFont(descriptor: font.fontDescriptor, size: max(7.5, font.pointSize * rect.width / naturalWidth)) ?? font
            attributes[.font] = actualFont
            string = NSAttributedString(string: text, attributes: attributes)
        }
        let height = string.size().height
        let destination = NSRect(x: rect.minX, y: rect.minY + (rect.height - height) / 2,
                                 width: rect.width, height: max(rect.height, height))
        string.draw(in: destination)
    }

    private func drawSeparator(x: CGFloat, height: CGFloat, color: NSColor) {
        let scale = window?.backingScaleFactor ?? 2
        let lineX = (x * scale).rounded() / scale
        color.setFill()
        NSRect(x: lineX, y: 4, width: 1 / scale, height: max(0, height - 8)).fill()
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
    let suiteName = "dev.seuput.TokenCat.StatusBarChecks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        failures += ["loading and zero values", "battery omission", "selection and activity count", "tool activity", "recent output", "expired output", "stale logs", "stable layout width"]
            .map { "Status bar \($0): isolated preferences unavailable" }
        print("Status bar checks: \(cases.count + 8 - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
        return failures
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = Preferences(defaults: defaults)
    preferences.reset()
    var system = SystemSnapshot()
    system.cpuPercent = 0
    let loading = StatusBarContent.metrics(system: system, tokens: [], preferences: preferences, hasSample: false, hasTokenSample: false)
    let zero = StatusBarContent.metrics(system: system, tokens: [], preferences: preferences, hasSample: true, hasTokenSample: true)
    let waitingForTokens = StatusBarContent.metrics(system: system, tokens: [], preferences: preferences, hasSample: true, hasTokenSample: false)
    func check(_ name: String, _ passed: Bool) {
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

    preferences.order = [.ai, .cpu, .network, .memory, .disk, .battery]
    preferences.visible = [.ai, .cpu]
    let tokens = [
        TokenReading(source: .codex, id: "active-codex", model: "current-codex", measurementModel: "previous-codex",
                     turnAverageTokensPerSecond: 100, active: true),
        TokenReading(source: .claude, id: "active-claude", model: "current-claude", measurementModel: "previous-claude",
                     turnAverageTokensPerSecond: 200, active: true),
        TokenReading(source: .codex, id: "inactive-codex", turnAverageTokensPerSecond: 999, active: false)
    ]
    let selected = StatusBarContent.metrics(system: system, tokens: tokens, preferences: preferences, hasSample: true, hasTokenSample: true)
    check("selected order and activity count do not aggregate speed",
          selected.map(\.id) == [.ai, .cpu] && selected.first?.value == "2" && selected.first?.isActive == true)

    let at = Date()
    var output = TokenReading(source: .codex, id: "output", active: true, activityState: .output,
                              lastOutputAt: at, lastOutputDelta: 12, sampledAt: at)
    let tool = TokenReading(source: .claude, id: "tool", active: true, activityState: .tool, sampledAt: at)
    func ai(_ readings: [TokenReading]) -> StatusBarMetric? {
        StatusBarContent.metrics(system: system, tokens: readings, preferences: preferences,
                                 hasSample: true, hasTokenSample: true).first(where: { $0.id == .ai })
    }
    check("pending tool remains visible alongside output", ai([output, tool])?.activityState == .tool && ai([output, tool])?.value == "2")
    check("confirmed recent output is highlighted", ai([output])?.activityState == .output)
    output.sampledAt = at.addingTimeInterval(6)
    check("old output stops highlighting while turn remains active", ai([output])?.activityState == .working)
    let stale = TokenReading(source: .codex, id: "stale", active: false, activityState: .stale, sampledAt: at)
    check("stale logs are waiting rather than active", ai([stale])?.activityState == .stale && ai([stale])?.value == "0" && ai([stale])?.isActive == false)

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
    let missingMetrics = StatusBarContent.metrics(system: missing, tokens: [], preferences: preferences, hasSample: false, hasTokenSample: false)
    let maximumMetrics = StatusBarContent.metrics(system: maximum, tokens: tokens, preferences: preferences, hasSample: true, hasTokenSample: true)
    let view = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 0, height: 22))
    var stable = true
    for layout in StatusBarLayout.allCases {
        view.update(metrics: missingMetrics, layout: layout, showRunner: true)
        let width = view.requiredWidth
        view.update(metrics: maximumMetrics, layout: layout, showRunner: true)
        stable = stable && width == view.requiredWidth && width > 0
    }
    check("layout width is stable from unknown to maximum values", stable)
    print("Status bar checks: \(cases.count + 8 - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
