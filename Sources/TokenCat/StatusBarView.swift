import AppKit

enum StatusBarLayout: String, CaseIterable, Identifiable {
    case minimal, compact, inline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .minimal: return loc("최소", "Minimal")
        case .compact: return loc("두 줄", "Two Lines")
        case .inline: return loc("한 줄", "One Line")
        }
    }
    var summary: String {
        switch self {
        case .minimal: return loc("캐릭터와 AI 상태·세션 수만 표시합니다", "Shows only the character, AI status and session count")
        case .compact: return loc("지표 이름 아래에 값을 표시합니다", "Shows each value under its name")
        case .inline: return loc("아이콘 옆에 값을 한 줄로 표시합니다", "Shows values on one line beside their icons")
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
    /// Top-level groups waiting for a log; the count shown (secondary, half-disc mark) only while nothing runs (M-2).
    var waiting = 0
    /// `SessionCounts.phase`, with input forced: input > tool > working (API retry included) > stale (log wait) > idle.
    /// A fresh output record is an event (the cat's run), never a phase.
    var phase: TokenActivityState = .idle

    init() {}
    init(groups: [SessionGroup], counts: SessionCounts) {
        let waiting = groups.filter { $0.members.contains { $0.reading.activityState == .input } }
        input = waiting.count
        running = counts.runningGroups + waiting.filter { !$0.state.isRunning }.count
        self.waiting = counts.waiting
        phase = input > 0 ? .input : counts.phase
    }

    static func phaseTitle(_ phase: TokenActivityState) -> String {
        switch phase {
        case .input: return loc("입력 필요", "Input needed")
        case .tool: return loc("도구 실행", "Running tool")
        case .working: return loc("진행", "Working")
        case .stale: return loc("로그 대기", "Waiting for log")
        default: return loc("활동 없음", "No activity")
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
        // kB/s and above keep one decimal below 10 ("1.0kB/s"), so the popover and the bar read the same string (M-4).
        func round(_ amount: Double, _ unit: Int) -> (value: Double, precision: Int) {
            let tenths = (amount * 10).rounded() / 10
            return unit > 0 && tenths < 10 ? (tenths, 1) : (amount.rounded(), 0)
        }
        var rounded = round(amount, unit)
        // Promote the unit when display rounding would produce 1000kB/s.
        if rounded.value >= 1_000 && unit < units.count - 1 {
            amount /= 1_000
            unit += 1
            rounded = round(amount, unit)
        }
        if rounded.value >= 1_000 { return "≥999\(units[unit])" }
        return String(format: rounded.precision == 1 ? "%.1f" : "%.0f", rounded.value) + units[unit]
    }

    /// "1.5kB/s" → ("1.5", "kB/s"); units are drawn smaller but never dropped.
    static func splitRate(_ text: String) -> (number: String, unit: String) {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return (text, "") }
        return (String(text[..<index]), String(text[index...]))
    }

    /// Each client's "지금 속도" by the dashboard's rule (`SessionPresentation.currentSpeed`); a client without one is absent.
    static func speeds(_ list: SessionListModel, now: Date, restart: Set<TokenSource>) -> [TokenSource: Double] {
        Dictionary(uniqueKeysWithValues: TokenSource.allCases.compactMap { source in
            SessionPresentation.currentSpeed(list, source: source, now: now, restart: restart).map { (source, $0.rate) }
        })
    }

    /// `counts`, `ai`, `recorded` and `speeds` come from the popover's per-publish presentation so both show the same numbers.
    static func metrics(system: SystemSnapshot, counts: SessionCounts, ai: StatusAISummary, recorded: Int,
                        speeds: [TokenSource: Double], preferences: Preferences, layout: StatusBarLayout? = nil,
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
                                       detail: loc("CPU 사용률 \(value)", "CPU usage \(value)"))
            case .memory:
                let value = percentage(Format.ratio(system.memoryUsedBytes, system.memoryTotalBytes))
                return StatusBarMetric(id: id, label: "RAM", value: value, symbol: "memorychip",
                                       detail: loc("메모리 ", "Memory ") + "\(value) · \(Format.capacity(system.memoryUsedBytes, system.memoryTotalBytes))")
            case .disk:
                let value = percentage(Format.ratio(system.diskUsedBytes, system.diskTotalBytes))
                return StatusBarMetric(id: id, label: "DISK", value: value, symbol: "internaldrive",
                                       detail: loc("저장 공간 ", "Storage ") + "\(value) · \(Format.capacity(system.diskUsedBytes, system.diskTotalBytes))")
            case .battery:
                guard system.batteryPresent else { return nil }
                let value = percentage(system.batteryPercent)
                // "battery.N", not "battery.Npercent": the latter names exist from macOS 14, the former alias them there.
                return StatusBarMetric(id: id, label: "BAT", value: value, symbol: "battery.\(Int(((system.batteryPercent ?? 100) / 25).rounded()) * 25)",
                                       detail: loc("배터리 ", "Battery ") + "\(value) · \(Format.power(system))")
            case .network:
                return StatusBarMetric(id: id, label: "NET", value: "↑\(upload)\n↓\(download)", symbol: "network",
                                       detail: loc("업로드 \(upload) · 다운로드 \(download)", "Upload \(upload) · Download \(download)"))
            case .ai:
                // Running groups with their phase mark; with none running, the log-wait groups (secondary, half disc);
                // otherwise a tertiary "0" without a mark (M-2).
                let waitingOnly = ai.running == 0 && ai.waiting > 0
                let value = hasTokenSample ? String(waitingOnly ? ai.waiting : ai.running) : "—"
                let state: TokenActivityState = !hasTokenSample ? .idle : ai.running > 0 ? ai.phase : waitingOnly ? .stale : .idle
                let phase = StatusAISummary.phaseTitle(ai.running > 0 ? ai.phase : .idle)
                let headline = waitingOnly ? loc("AI 로그 대기 \(ai.waiting)개", "AI: \(ai.waiting) waiting for log") : loc("AI \(phase)", "AI: \(phase)")
                let detail = hasTokenSample
                    ? "\(headline) · \(aiCountLine(counts, ai))\n"
                        + loc("최근 5분 출력 기록 \(Format.tokens(recorded)) tok", "Output in the last 5 min: \(Format.tokens(recorded)) tok")
                        + " · Codex \(counts.running[.codex] ?? 0), Claude Code \(counts.running[.claude] ?? 0)"
                    : loc("AI 기록 확인 중", "Reading AI records")
                return StatusBarMetric(id: id, label: "AI", value: value, symbol: "", detail: detail,
                                       isActive: hasTokenSample && ai.running > 0, activityState: state)
            case .codexSpeed, .claudeSpeed:
                // A glyph (`SpeedGlyph`) stands in for the label; the unit is split off and drawn smaller like "%".
                let rate = id.speedSource.flatMap { speeds[$0] }.map(Format.tps)
                return StatusBarMetric(id: id, label: "", value: rate.map { $0 + "tok/s" } ?? "—", symbol: "",
                                       detail: id.title + " " + (rate.map { loc("\($0) 토큰/초", "\($0) tokens per second") }
                                                                 ?? loc("측정 없음", "no measurement")))
            }
        }
    }

    private static func aiCountLine(_ counts: SessionCounts, _ ai: StatusAISummary) -> String {
        // Working + input needed = the bar's count, matching the popover header.
        loc("진행 중 \(ai.running - ai.input)개 · 도구 실행 \(counts.toolMembers) · 하위 에이전트 \(counts.runningSubagents) · 로그 대기 \(counts.waiting)",
            "Working \(ai.running - ai.input) · Running tool \(counts.toolMembers) · Subagents \(counts.runningSubagents) · Waiting for log \(counts.waiting)")
            + (ai.input > 0 ? loc(" · 입력 필요 \(ai.input)", " · Input needed \(ai.input)") : "")
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
            let parts = [capacity(system.memoryUsedBytes, system.memoryTotalBytes).map { loc("메모리 ", "Memory ") + $0 },
                         capacity(system.diskUsedBytes, system.diskTotalBytes).map { loc("저장 공간 ", "Storage ") + $0 }].compactMap { $0 }
            if !parts.isEmpty { lines.append(parts.joined(separator: " · ")) }
        }
        lines.append(hasTokenSample ? loc("AI ", "AI: ") + aiCountLine(counts, ai) : loc("AI 기록 확인 중", "Reading AI records"))
        lines.append(loc("클릭: 상세 화면 · 우클릭: 빠른 메뉴", "Click: details · Right-click: quick menu"))
        return lines.joined(separator: "\n")
    }
}

/// The quick menu's live summary (M-5), built when the menu opens and not refreshed while it stays open.
struct QuickMenuSummary: Equatable {
    struct Row: Equatable {
        /// `SessionGroup.id`, handed to `DashboardModel.focusRequest`.
        var id: String
        var kind: StateGlyph.Kind
        var title: String
    }
    var headline: String
    /// Up to three live top-level groups in urgency order.
    var rows: [Row] = []

    static func make(groups: [SessionGroup], counts: SessionCounts, hasTokenSample: Bool, now: Date) -> QuickMenuSummary {
        guard hasTokenSample else { return QuickMenuSummary(headline: loc("AI 기록 확인 중", "Reading AI records")) }
        let parts = [(loc("입력", "Input"), counts.input), (loc("재시도", "Retry"), counts.retrying), (loc("도구", "Tool"), counts.tool),
                     (loc("진행", "Working"), counts.working), (loc("로그 대기", "Waiting for log"), counts.waiting)]
            .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        let live = groups.filter { $0.state.isLive && $0.state != .measurement }.sorted {
            let a = SessionDisplayState.liveOrder.firstIndex(of: $0.state) ?? 99, b = SessionDisplayState.liveOrder.firstIndex(of: $1.state) ?? 99
            return a != b ? a < b : ($0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id)
        }
        let rows = live.prefix(3).compactMap { group -> Row? in
            guard let kind = StateGlyph.Kind(group.state) else { return nil }
            var project = group.lead.reading.project.flatMap { $0.isEmpty ? nil : $0 } ?? loc("프로젝트 미확인", "Unknown project")
            if project.count > 28 { project = String(project.prefix(27)) + "…" }
            return Row(id: group.id, kind: kind, title: "\(project) — \(detail(group, now: now))")
        }
        return QuickMenuSummary(headline: parts.isEmpty ? loc("진행 중인 세션 없음", "No active sessions")
                                    : ([loc("AI 세션", "AI sessions")] + parts).joined(separator: " · "), rows: rows)
    }

    /// "입력 대기 3분", "명령 실행 · 턴 7분", "로그 대기 · 3분째 기록 없음": minutes only, never seconds.
    static func detail(_ group: SessionGroup, now: Date) -> String {
        let member = group.members.first { $0.state == group.state }?.reading ?? group.lead.reading
        let turn = group.members.compactMap(\.reading.currentTurnStartedAt).min().map { loc(" · 턴 ", " · turn ") + minutes(now.timeIntervalSince($0)) } ?? ""
        switch group.state {
        case .input:
            let since = member.lastActivity.map { loc(" ", " · ") + minutes(now.timeIntervalSince($0)) } ?? ""
            return (SessionPresentation.isPlanApproval(member) ? loc("계획 승인 대기", "Waiting for plan approval") : loc("입력 대기", "Waiting for input")) + since
        case .retrying: return loc("API 재시도", "API retry") + turn
        case .tool: return SessionPresentation.toolTitle(member.toolCategory) + turn
        case .working: return loc("진행", "Working") + turn
        default:
            guard let at = SessionPresentation.liveAt(member), now.timeIntervalSince(at) >= 60 else { return loc("로그 대기", "Waiting for log") }
            let quiet = minutes(now.timeIntervalSince(at))
            return loc("로그 대기 · \(quiet)째 기록 없음", "Waiting for log · no record for \(quiet)")
        }
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds)) / 60
        if total < 1 { return loc("1분 미만", "<1m") }
        return total >= 60 ? Format.span(total / 60, .hour) + " " + Format.span(total % 60, .minute) : Format.span(total, .minute)
    }
}

final class StatusBarContentView: NSView {
    private(set) var metrics: [StatusBarMetric] = []
    private(set) var layout: StatusBarLayout = .compact
    private(set) var showRunner = true
    private(set) var runnerPose: RunnerPose = .sit
    private(set) var runnerFrame = 0
    /// `Runner.fxMask` step drawn over the sprite (the sleep z); nil draws none.
    private(set) var runnerFX: Int?
    /// The effect-layer source; checks substitute a synthetic mask until the assets ship.
    var fxMask: (RunnerPose, Int) -> NSImage? = { Runner.fxMask(pose: $0, step: $1) }
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

    func updateRunner(pose: RunnerPose, frame: Int, fx: Int? = nil) {
        guard pose != runnerPose || frame != runnerFrame || fx != runnerFX else { return }
        runnerPose = pose
        runnerFrame = frame
        runnerFX = fx
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
        // Speed items fit "9999.9 tok/s" (an 11 pt value, a thin space and an 8.5 pt unit: 62 pt), so a 4-digit rate never shrinks.
        case .compact:
            switch id { case .network: return 66; case .ai: return 36; case .codexSpeed, .claudeSpeed: return 66; default: return 32 }
        case .inline:
            switch id { case .network: return 114; case .ai: return 46; case .codexSpeed, .claudeSpeed: return 80; default: return 52 }
        }
    }

    /// Speed glyph sides: the two-line label row, and beside the value on one line.
    static let glyphSide: (compact: CGFloat, inline: CGFloat) = (8, 10)

    /// `StateGlyph` sizes in the bar: 7 pt, the input disc 8 pt (A0-3).
    static func markWidth(_ state: TokenActivityState) -> CGFloat {
        switch state {
        case .input: return 8
        case .tool, .working, .stale: return 7
        default: return 0
        }
    }
    /// Every AI state reserves the widest mark's slot, so the count never moves when the mark changes.
    static let markSlot: CGFloat = 8 + 3

    private func runnerRect(in rect: NSRect) -> NSRect {
        NSRect(x: edge, y: (rect.height - Self.runnerSlot.height) / 2, width: Self.runnerSlot.width, height: Self.runnerSlot.height)
    }

    private func group(_ id: MetricID) -> Int {
        switch id { case .network: return 1; case .ai, .codexSpeed, .claudeSpeed: return 2; default: return 0 }
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
                              secondary: Self.secondaryColor(contrast: contrast),
                              tertiary: NSColor.labelColor.withAlphaComponent(contrast ? 0.72 : 0.45),
                              contrast: contrast, stateColours: !isHighlighted)
        var x = edge
        if showRunner {
            let slot = runnerRect(in: rect)
            if slot.intersects(dirtyRect) { drawRunner(in: slot, palette) }
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

    private func drawRunner(in slot: NSRect, _ palette: Palette) {
        let image = Runner.image(pose: runnerPose, frame: runnerFrame)
        var size = image.size
        if size.width <= 0 || size.height <= 0 || size.width > slot.width || size.height > slot.height {
            let fit = size.width > 0 && size.height > 0 ? min(slot.width / size.width, slot.height / size.height) : 1
            size = size.width > 0 && size.height > 0 ? NSSize(width: size.width * fit, height: size.height * fit) : slot.size
        }
        let rect = NSRect(origin: NSPoint(x: snap(slot.midX - size.width / 2), y: snap(slot.midY - size.height / 2)), size: size)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        // The z is a label-coloured template at the sprite's own snapped origin, never resampled (K-2).
        guard let step = runnerFX, let mask = fxMask(runnerPose, step), let context = NSGraphicsContext.current else { return }
        let colour: NSColor = palette.contrast || !palette.stateColours ? .labelColor : palette.secondary
        context.saveGraphicsState()
        context.imageInterpolation = .none
        context.cgContext.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        colour.setFill()
        rect.fill(using: .sourceIn)
        context.cgContext.endTransparencyLayer()
        context.restoreGraphicsState()
    }

    private var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .medium) }
    private var labelFont: NSFont { .systemFont(ofSize: 8.5, weight: .semibold) }

    /// Digits in label colour; '%' or a letter unit ("tok/s", after a thin space) smaller and secondary. Unknown stays "—".
    private func valueRuns(_ value: String, _ palette: Palette) -> [Run] {
        if value == "—" { return [Run(text: value, font: valueFont, color: palette.secondary)] }
        let parts = value.hasSuffix("%") ? (number: String(value.dropLast()), unit: "%") : StatusBarContent.splitRate(value)
        guard !parts.unit.isEmpty else { return [Run(text: value, font: valueFont, color: palette.label)] }
        return [Run(text: parts.number, font: valueFont, color: palette.label),
                Run(text: (parts.unit == "%" ? "" : "\u{2009}") + parts.unit, font: .systemFont(ofSize: 8.5, weight: .medium), color: palette.secondary)]
    }

    /// A speed item's glyph, centred on `center` in the labels' secondary tone.
    private func drawGlyph(_ source: TokenSource, side: CGFloat, center: NSPoint, _ palette: Palette) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = CGRect(x: snap(center.x - side / 2), y: snap(center.y - side / 2), width: side, height: side)
        context.saveGState()
        context.setFillColor(palette.secondary.cgColor)
        context.addPath(SpeedGlyph.path(source, in: rect))
        context.fillPath()
        context.restoreGState()
    }

    private func drawCompact(_ metric: StatusBarMetric, in cell: NSRect, _ palette: Palette) {
        let top = max(0, (cell.height - 22) / 2)
        if metric.id == .network {
            drawNetworkRows(metric, in: NSRect(x: cell.minX, y: top, width: cell.width, height: 22), palette)
            return
        }
        let inner = cell.insetBy(dx: 1, dy: 0)
        if let source = metric.id.speedSource {
            drawGlyph(source, side: Self.glyphSide.compact, center: NSPoint(x: inner.midX, y: top + 4.5), palette)
        } else {
            draw([Run(text: metric.label, font: labelFont, color: palette.secondary, kern: 0.3)], centerY: top + 4.5, in: inner)
        }
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
        if let source = metric.id.speedSource {
            // Like the "AI" caption: 4 pt clear of the cell's leading edge, then the value 3 pt after the glyph.
            let side = Self.glyphSide.inline
            drawGlyph(source, side: side, center: NSPoint(x: cell.minX + 4 + side / 2, y: cell.midY), palette)
            let x = cell.minX + 4 + side + 3
            draw(valueRuns(metric.value, palette), centerY: cell.midY, in: NSRect(x: x, y: 0, width: cell.maxX - x, height: cell.height),
                 alignment: .left)
            return
        }
        // Natural aspect at an 11pt height, trailing-aligned in a 16pt slot so each icon hugs its own value.
        // An opaque label-coloured symbol dimmed once by `fraction`, so it reads like the "AI" caption (M-3).
        let slot = NSRect(x: cell.minX + 2, y: cell.midY - 5.5, width: 16, height: 11)
        if let icon = symbol(metric.symbol, contrast: palette.contrast), icon.size.width > 0, icon.size.height > 0 {
            let fit = min(slot.height / icon.size.height, slot.width / icon.size.width)
            let size = NSSize(width: icon.size.width * fit, height: icon.size.height * fit)
            icon.draw(in: NSRect(x: snap(slot.maxX - size.width), y: snap(slot.midY - size.height / 2), width: size.width, height: size.height),
                      from: .zero, operation: .sourceOver, fraction: Self.symbolFraction(contrast: palette.contrast),
                      respectFlipped: true, hints: nil)
        }
        draw(valueRuns(metric.value, palette), centerY: cell.midY,
             in: NSRect(x: slot.maxX + 3, y: 0, width: cell.maxX - slot.maxX - 3, height: cell.height), alignment: .left)
    }

    private func drawMinimal(_ metric: StatusBarMetric, in cell: NSRect, _ palette: Palette) {
        let prefix = showRunner ? [] : [Run(text: "AI", font: .systemFont(ofSize: 9, weight: .semibold), color: palette.secondary, kern: 0.3)]
        drawAI(metric, centerY: cell.midY, in: cell,
               font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), palette, centered: true, prefix: prefix)
    }

    /// Mark slot (shape = state) then the count: label while running, secondary for log wait or before the
    /// first sample ("—"), tertiary "0" with an empty slot (M-2).
    private func drawAI(_ metric: StatusBarMetric, centerY: CGFloat, in rect: NSRect, font: NSFont, _ palette: Palette,
                        centered: Bool, prefix: [Run] = []) {
        let tone = metric.isActive ? palette.label : metric.value == "—" || metric.activityState == .stale ? palette.secondary : palette.tertiary
        let count = [Run(text: metric.value, font: font, color: tone)]
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

    /// `StateGlyph` marks: purple ring working, blue rounded square tool, neutral half disc log wait, yellow "?" input.
    /// Output has no mark: it is an event. An open item drops the state colour and keeps the shape in the label colour.
    private func drawMark(_ state: TokenActivityState, center: NSPoint, _ palette: Palette) {
        let size = Self.markWidth(state)
        guard size > 0, let kind = StateGlyph.Kind(phase: state), let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = NSRect(x: snap(center.x - size / 2), y: snap(center.y - size / 2), width: size, height: size)
        guard kind == .waiting, palette.stateColours else {
            StateGlyph.draw(kind, in: rect, context: context, highlighted: !palette.stateColours, contrast: palette.contrast)
            // Increase Contrast: the filled yellow and blue marks get a label-colour edge on a light bar.
            if palette.contrast, palette.stateColours, kind == .tool || kind == .input {
                context.saveGState()
                context.setStrokeColor(NSColor.labelColor.cgColor)
                context.setLineWidth(1)
                context.addPath(StateGlyph.drawing(kind, in: rect.insetBy(dx: 0.5, dy: 0.5)).path)
                context.strokePath()
                context.restoreGState()
            }
            return
        }
        Self.fillWaiting(in: rect, color: palette.secondary, context: context)
    }

    /// The bar's secondary tone (labels, units, the log-wait half disc). A custom-drawn status item gets no vibrancy, so
    /// secondaryLabelColor reads as flat grey on tinted bars; labelColor follows the bar's light/dark appearance instead.
    static func secondaryColor(contrast: Bool) -> NSColor { NSColor.labelColor.withAlphaComponent(contrast ? 0.8 : 0.72) }

    private static func fillWaiting(in rect: NSRect, color: NSColor, context: CGContext) {
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.addPath(StateGlyph.drawing(.waiting, in: rect).path)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    /// The quick menu's log-wait glyph, drawn like the bar's mark; the colour resolves against the menu's appearance.
    static func waitingGlyph(side: CGFloat, contrast: Bool) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            fillWaiting(in: rect, color: secondaryColor(contrast: contrast), context: context)
            return true
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

    /// The inline symbols' only dimming (M-3), the captions' alpha (`secondaryColor`): 0.72, Increase Contrast 0.8.
    static func symbolFraction(contrast: Bool) -> CGFloat { contrast ? 0.8 : 0.72 }

    /// Opaque label colour of the current drawing appearance; the cache key carries the appearance and contrast.
    private func symbol(_ name: String, contrast: Bool) -> NSImage? {
        let appearance = NSAppearance.currentDrawing()
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let cacheKey = "\(name)/\(dark ? "dark" : "light")/\(contrast ? "contrast" : "normal")"
        if let image = symbolImages[cacheKey] { return image }
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance { color = (NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor).withAlphaComponent(1) }
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

/// The speed items' glyphs: generic symbols, not the clients' logos. Coordinates in a 10 × 10 box, y-down, scaled to the
/// centred square of `rect`; each is one fill (nonzero winding).
/// - Codex, a terminal prompt ">_": the polyline (1, 1.75) (4.75, 5) (1, 8.25) and the line (5.75, 8.25) (9, 8.25), stroked
///   1.5 wide with round caps and joins.
/// - Claude, a four-point sparkle "✦": tips (5, 0) (10, 5) (5, 10) (0, 5) joined clockwise by quadratic curves whose controls
///   sit 0.6 from the centre toward the corner between them: (5.6, 4.4) (5.6, 5.6) (4.4, 5.6) (4.4, 4.4).
enum SpeedGlyph {
    static func path(_ source: TokenSource, in rect: CGRect) -> CGPath {
        let unit = min(rect.width, rect.height) / 10
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.midX + (x - 5) * unit, y: rect.midY + (y - 5) * unit) }
        let path = CGMutablePath()
        switch source {
        case .codex:
            path.addLines(between: [p(1, 1.75), p(4.75, 5), p(1, 8.25)])
            path.addLines(between: [p(5.75, 8.25), p(9, 8.25)])
            return path.copy(strokingWithWidth: 1.5 * unit, lineCap: .round, lineJoin: .round, miterLimit: 10)
        case .claude:
            path.move(to: p(5, 0))
            path.addQuadCurve(to: p(10, 5), control: p(5.6, 4.4))
            path.addQuadCurve(to: p(5, 10), control: p(5.6, 5.6))
            path.addQuadCurve(to: p(0, 5), control: p(4.4, 5.6))
            path.addQuadCurve(to: p(5, 0), control: p(4.4, 4.4))
            path.closeSubpath()
            return path
        }
    }

    /// A template image for the Settings item list; the list tints it.
    static func image(_ source: TokenSource, side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(path(source, in: rect))
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
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

    /// Light and dark strips of the real status content with the cat's planned pose, frame 0 (T-5).
    static func preview(metrics: [StatusBarMetric], preferences: Preferences, pose: RunnerPose) -> (images: [NSImage], width: CGFloat) {
        var images: [NSImage] = []
        var width: CGFloat = 0
        for dark in [false, true] {
            let view = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.update(metrics: metrics, layout: preferences.statusBarLayout, showRunner: preferences.showRunner)
            view.updateRunner(pose: pose, frame: 0, fx: RunnerAnimator.stillFX(pose))
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

/// Settings preview memo (T-5): a preference or pose change rebuilds at once; value-only changes (CPU %, network)
/// rebuild at most once a second, so the open Settings window does not rasterize on every publish.
final class MenuBarPreviewCache {
    private var structure: String?
    private var values: [String] = []
    private var builtAt = Date.distantPast
    private(set) var result: (images: [NSImage], width: CGFloat) = ([], 0)
    private(set) var builds = 0

    func preview(model: DashboardModel, preferences: Preferences, pose: RunnerPose, now: Date = Date()) -> (images: [NSImage], width: CGFloat) {
        let counts = model.sessions.counts
        let metrics = StatusBarContent.metrics(system: model.system, counts: counts, ai: StatusAISummary(groups: model.groups, counts: counts),
                                               recorded: model.flow.total,
                                               speeds: StatusBarContent.speeds(model.sessions, now: model.now, restart: model.telemetryRestartNeeded),
                                               preferences: preferences, hasSample: model.hasSample, hasTokenSample: model.tokensSampledAt != nil)
        return preview(metrics: metrics, preferences: preferences, pose: pose, now: now)
    }

    func preview(metrics: [StatusBarMetric], preferences: Preferences, pose: RunnerPose, now: Date) -> (images: [NSImage], width: CGFloat) {
        let key = [preferences.statusBarLayout.rawValue, "\(preferences.showRunner)", preferences.character.rawValue, preferences.order.map(\.rawValue).joined(separator: ","),
                   preferences.visible.map(\.rawValue).sorted().joined(separator: ","), pose.rawValue].joined(separator: "|")
        let current = metrics.map { "\($0.id.rawValue)=\($0.value)/\($0.activityState.rawValue)/\($0.isActive)" }
        if key == structure && (current == values || now.timeIntervalSince(builtAt) < 1) { return result }
        structure = key
        values = current
        builtAt = now
        builds += 1
        result = MenuBarStrip.preview(metrics: metrics, preferences: preferences, pose: pose)
        return result
    }
}

func runStatusBarChecks() -> [String] {
    let cases: [(String, Double?, String)] = [
        ("missing rate", nil, "—"), ("zero rate", 0, "0B/s"),
        ("byte rounding", 999.49, "999B/s"), ("byte unit crossover", 999.5, "1.0kB/s"),
        ("kilobyte unit", 1_000, "1.0kB/s"), ("kilobyte precision", 1_499, "1.5kB/s"),
        ("ten kilobytes drop the decimal", 9_960, "10kB/s"), ("two-digit kilobytes", 12_345, "12kB/s"),
        ("kilobyte rounding", 999_499, "999kB/s"), ("megabyte crossover", 999_500, "1.0MB/s"),
        ("gigabyte unit", 1_000_000_000, "1.0GB/s"), ("terabyte unit", 1_000_000_000_000, "1.0TB/s"),
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
                 hasSample: Bool = true, hasTokenSample: Bool = true, speeds: [TokenSource: Double]? = nil) -> [StatusBarMetric] {
        let (counts, ai) = summary(tokens, now: now)
        let speeds = speeds ?? StatusBarContent.speeds(SessionListModel.make(tokens: tokens, now: now, expanded: false), now: now, restart: [])
        return StatusBarContent.metrics(system: system, counts: counts, ai: ai, recorded: FlowSeries.make(tokens, now: now).total, speeds: speeds,
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
          zero.count == MetricID.standard.count - 1)
    check("idle AI has no mark and is not active", zero.first(where: { $0.id == .ai }).map {
        !$0.isActive && StatusBarContentView.markWidth($0.activityState) == 0 } == true)

    preferences.order = [.ai, .cpu, .network, .memory, .disk, .battery]
    preferences.visible = [.ai, .cpu]
    let tokens = [
        TokenReading(source: .codex, id: "active-codex", model: "current-codex", active: true),
        TokenReading(source: .claude, id: "active-claude", model: "current-claude", active: true),
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
    check("a fresh record is an event: the mark stays working", ai([output])?.activityState == .working
          && ai([output])?.isActive == true && ai([output])?.value == "1")
    // The cat's 1.2 s run reads `lastOutputAt` within 5 s, not a display state.
    let fresh = SessionPresentation.groups([output], now: at)
    var runner = RunnerDirector()
    let freshActivity = RunnerActivity(groups: fresh, cpu: nil, now: at)
    runner.observe(freshActivity, now: at)
    check("a fresh record still runs the cat", freshActivity.newestOutputAt == at
          && runner.plan(.activity, activity: freshActivity, now: at, reduceMotion: false).pose == .run)
    output.sampledAt = at.addingTimeInterval(6)
    check("old output keeps the working mark while the turn remains active",
          ai([output], now: at.addingTimeInterval(6))?.activityState == .working)
    let stale = TokenReading(source: .codex, id: "stale", active: false, lastActivity: at.addingTimeInterval(-180),
                             activityState: .stale, sampledAt: at)
    check("with nothing running, log-wait groups show their count and the half-disc mark, not as running",
          ai([stale])?.activityState == .stale && ai([stale])?.value == "1" && ai([stale])?.isActive == false
          && ai([stale])?.detail.hasPrefix("AI 로그 대기 1개") == true)
    let unfinished = TokenReading(source: .codex, id: "unfinished", active: false, lastActivity: at.addingTimeInterval(-3_600),
                                  activityState: .unfinished, sampledAt: at)
    check("unfinished turns are neither counted nor marked",
          ai([unfinished])?.activityState == .idle && ai([unfinished])?.value == "0")
    check("a running session outranks waiting for the mark and the count", ai([stale, tool])?.activityState == .tool
          && ai([stale, tool])?.value == "1" && ai([stale, tool])?.isActive == true)
    check("marks are 7 pt glyphs, the input disc 8 pt, in the unchanged 11 pt slot",
          StatusBarContentView.markWidth(.tool) == 7 && StatusBarContentView.markWidth(.working) == 7 && StatusBarContentView.markWidth(.stale) == 7
          && StatusBarContentView.markWidth(.input) == 8 && StatusBarContentView.markWidth(.output) == 0 && StatusBarContentView.markSlot == 11)
    let question = TokenReading(source: .claude, id: "question", sessionID: "q1", active: true, activityState: .input, sampledAt: at)
    check("input outranks tool and counts once per group",
          ai([question, tool])?.activityState == .input && ai([question, tool])?.value == "2"
          && ai([question, tool])?.detail.contains("진행 중 1개") == true && ai([question, tool])?.detail.contains("입력 필요 1") == true)
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
    // Speed items: each client's own "지금 속도" (`Format.tps`, then a smaller "tok/s"), "—" without one, spoken per client.
    preferences.order = MetricID.allCases
    preferences.visible = [.codexSpeed, .claudeSpeed]
    var timed = TokenReading(source: .codex, id: "timed", sessionID: "t1", model: "g1", active: true, activityState: .working, sampledAt: at)
    var measurement = TokenSpeedMeasurement(TelemetryReading(provider: .codex, at: at.addingTimeInterval(-3)))
    measurement.model = "g1"
    measurement.serverTokenIntervalMs = 18
    timed.speedMeasurement = measurement
    let untimed = TokenReading(source: .claude, id: "untimed", sessionID: "u1", model: "m1", active: true, activityState: .working, sampledAt: at)
    let speedItems = metrics(system, [timed, untimed])
    check("speed items show each client's own rate with its unit, or a dash: \(speedItems.map(\.value)) / \(speedItems.map(\.detail))",
          speedItems.map(\.id) == [.codexSpeed, .claudeSpeed] && speedItems.map(\.value) == ["55.6tok/s", "—"]
          && speedItems.map(\.detail) == ["Codex 속도 55.6 토큰/초", "Claude 속도 측정 없음"]
          && StatusBarContent.speeds(SessionListModel.make(tokens: [timed, untimed], now: at, expanded: false), now: at, restart: [.codex]).isEmpty
          && metrics(system, [timed], layout: .minimal).map(\.id) == [.ai] && StatusBarContent.splitRate("55.6tok/s") == ("55.6", "tok/s"))
    AppLanguage.with(.en) {
        check("English speed items are spoken per client",
              metrics(system, [timed, untimed]).map(\.detail) == ["Codex speed 55.6 tokens per second", "Claude speed no measurement"])
    }
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
    for items in [MetricID.standard, MetricID.allCases] {
        preferences.visible = Set(items)
        for layout in StatusBarLayout.allCases {
            for runner in [true, false] {
                view.update(metrics: metrics(missing, [], layout: layout, hasSample: false, hasTokenSample: false), layout: layout, showRunner: runner)
                let width = view.requiredWidth
                view.update(metrics: metrics(maximum, busyTokens, layout: layout, speeds: [.codex: 999.94, .claude: 99_999]),
                            layout: layout, showRunner: runner)
                stable = stable && width == view.requiredWidth && width > 0
                widths["\(layout.rawValue)/\(runner)" + (items == MetricID.standard ? "" : "/speed")] = width
            }
        }
    }
    check("layout width is stable from unknown to maximum values", stable)
    // edge 4+4, runner 32+2; compact cells 32 / NET 66 / AI 36; inline 52 / 114 / 46; minimal AI 30 (41 without the cat);
    // each speed item 66 on two lines, 80 on one.
    let expected: [String: CGFloat] = ["compact/true": 272, "inline/true": 410, "minimal/true": 72, "minimal/false": 49,
                                       "compact/true/speed": 404, "inline/true/speed": 570, "minimal/true/speed": 72]
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
                 metric(.network, "↑999MB/s\n↓125MB/s"), metric(.ai, "99", .input),
                 metric(.codexSpeed, "9999.9tok/s"), metric(.claudeSpeed, "9999.9tok/s")]
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

    // Rendered pixels on a light menu-bar backdrop (0.94 white), 2× scale.
    func render(_ view: StatusBarContentView) -> (pixel: (Int, Int) -> (luma: Double, rgb: [Double]), width: Int, height: Int)? {
        guard let image = view.snapshotImage(scale: 2), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.94, green: 0.94, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: cg.width * cg.height * 4))
        let width = cg.width
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return ({ x, y in
            let i = (y * width + x) * 4
            let rgb = (0..<3).map { Double(bytes[i + $0]) / 255 }
            return (0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2]), rgb)
        }, cg.width, cg.height)
    }
    func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
    let lightView = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
    lightView.appearance = NSAppearance(named: .aqua)
    lightView.update(metrics: [metric(.cpu, "37%")], layout: .inline, showRunner: false)
    lightView.frame.size.width = lightView.requiredWidth
    var symbolContrast = 0.0
    if let pixels = render(lightView) {
        // The CPU symbol's 16 × 11 pt slot starts 2 pt into the cell, after the 4 pt edge.
        let background = pixels.pixel(1, 1).luma
        for x in 12..<44 { for y in 0..<pixels.height { symbolContrast = max(symbolContrast, contrast(background, pixels.pixel(x, y).luma)) } }
    }
    check("the inline symbol reaches 3.5:1 on a light bar (got \(String(format: "%.2f", symbolContrast)):1), dimmed once by 0.72 (0.8 contrast)",
          symbolContrast >= 3.5 && StatusBarContentView.symbolFraction(contrast: false) == 0.72
          && StatusBarContentView.symbolFraction(contrast: true) == 0.8)
    // Speed items on one line: the glyph (8–18 pt: 4 pt edge, 4 pt into the cell) and "—" in the secondary tone, digits in
    // the label tone, so the darkest glyph or dash pixel stays clearly lighter than the darkest digit pixel.
    func darkest(_ metric: StatusBarMetric, columns: Range<Int>) -> Double {
        let speedView = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
        speedView.appearance = NSAppearance(named: .aqua)
        speedView.update(metrics: [metric], layout: .inline, showRunner: false)
        speedView.frame.size.width = speedView.requiredWidth
        guard let pixels = render(speedView) else { return 1 }
        return columns.flatMap { x in (0..<pixels.height).map { pixels.pixel(x, $0).luma } }.min() ?? 1
    }
    let glyphTone = darkest(metric(.claudeSpeed, "—"), columns: 16..<36), dashTone = darkest(metric(.claudeSpeed, "—"), columns: 42..<80)
    let codexGlyphTone = darkest(metric(.codexSpeed, "55.6tok/s"), columns: 16..<36)
    let digitTone = darkest(metric(.codexSpeed, "55.6tok/s"), columns: 42..<60)
    check("speed glyphs and dashes are secondary, digits label-toned (luma \([glyphTone, codexGlyphTone, dashTone, digitTone]))",
          [glyphTone, codexGlyphTone, dashTone].allSatisfy { $0 < 0.5 && $0 > digitTone * 1.5 })

    // The sleep z: a template mask at the sprite's snapped origin, label-coloured, nothing outside the mask (K-2).
    let fxView = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
    fxView.appearance = NSAppearance(named: .aqua)
    fxView.update(metrics: [], layout: .minimal, showRunner: true)
    fxView.frame.size.width = fxView.requiredWidth
    let mask = NSImage(size: Runner.size, flipped: true) { _ in
        NSColor.black.setFill()
        NSRect(x: 27, y: 1, width: 3, height: 3).fill()
        return true
    }
    fxView.fxMask = { pose, step in pose == .sleep && step == RunnerAnimator.largeZ ? mask : nil }
    fxView.updateRunner(pose: .sleep, frame: 0)
    let plain = render(fxView)
    fxView.updateRunner(pose: .sleep, frame: 0, fx: RunnerAnimator.largeZ)
    let withZ = render(fxView)
    var fxPainted = false, fxOutside = false
    if let plain, let withZ {
        // Sprite slot origin x = 4 pt edge, y = (22 - 20) / 2 = 1 pt; the mask square sits at (27, 1)–(30, 4) pt.
        let inside = withZ.pixel((4 + 28) * 2 + 1, (1 + 2) * 2 + 1)
        fxPainted = plain.pixel((4 + 28) * 2 + 1, (1 + 2) * 2 + 1).luma > 0.8 && inside.luma < 0.4
        for x in 0..<withZ.width { for y in 0..<withZ.height where !(62...67).contains(x) || !(4...9).contains(y) {
            if abs(withZ.pixel(x, y).luma - plain.pixel(x, y).luma) > 0.01 { fxOutside = true }
        } }
    }
    check("the effect mask is filled in the secondary label colour only where the mask is opaque", fxPainted && !fxOutside)
    // `Runner.fxMask` steps follow the manifest (0 no z, 1 zS, 2 zL); manifest cell (22, 3) / (25, 0) plus the 1 pt frame inset.
    func opaque(_ image: NSImage) -> (count: Int, origin: (Int, Int))? {
        let width = Int(Runner.size.width), height = Int(Runner.size.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = Runner.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: NSRect(origin: .zero, size: Runner.size))
        NSGraphicsContext.restoreGraphicsState()
        let points = (0..<height).flatMap { y in (0..<width).filter { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.5 }.map { ($0, y) } }
        return (points.count, (points.map(\.0).min() ?? -1, points.map(\.1).min() ?? -1))
    }
    var skipped = 0
    if let small = Runner.fxMask(pose: .sleep, step: RunnerAnimator.smallZ).flatMap(opaque),
       let large = Runner.fxMask(pose: .sleep, step: RunnerAnimator.largeZ).flatMap(opaque) {
        check("fx steps follow the manifest's sleep order: zS 8 px at (23, 4) = \(small), zL 10 px at (26, 1) = \(large)",
              small.count == 8 && small.origin == (23, 4) && large.count == 10 && large.origin == (26, 1))
    } else { skipped += 1 }

    // The quick menu's log-wait glyph is the bar's secondary half disc, not neutral 0.45: ≥ 3:1 on a light menu (A0-2, M-1).
    var menuGlyphContrast = 0.0
    if let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data {
        context.setFillColor(CGColor(srgbRed: 0.94, green: 0.94, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            StatusBarContentView.waitingGlyph(side: 10, contrast: false).draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))
        }
        NSGraphicsContext.restoreGraphicsState()
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        func luma(_ i: Int) -> Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(Double(bytes[i]) / 255) + 0.7152 * linear(Double(bytes[i + 1]) / 255) + 0.0722 * linear(Double(bytes[i + 2]) / 255)
        }
        menuGlyphContrast = (0..<400).map { contrast(luma(0), luma($0 * 4)) }.max() ?? 0
    }
    check("the quick menu's log-wait glyph reaches 3:1 on a light menu (got \(String(format: "%.2f", menuGlyphContrast)):1)", menuGlyphContrast >= 3)

    // Quick menu (M-5): headline counts and up to three groups in urgency order, minutes only.
    func live(_ id: String, _ project: String?, _ state: TokenActivityState, tool: ToolCategory? = nil, turn: TimeInterval? = nil,
              last: TimeInterval = -2) -> TokenReading {
        var reading = TokenReading(source: .claude, id: id, sessionID: id, project: project, active: state != .stale,
                                   lastActivity: at.addingTimeInterval(last), activityState: state, sampledAt: at)
        reading.toolCategory = tool
        reading.currentTurnStartedAt = turn.map { at.addingTimeInterval(-$0) }
        return reading
    }
    let menuReadings = [live("w", "web", .working, turn: 30), live("t", "api-server", .tool, tool: .command, turn: 420),
                        live("q", "TokenCat", .input, last: -185), live("s", nil, .stale, last: -190),
                        live("z", "zz", .working, turn: 5)]
    let menuGroups = SessionPresentation.groups(menuReadings, now: at)
    let quick = QuickMenuSummary.make(groups: menuGroups, counts: SessionCounts(menuGroups), hasTokenSample: true, now: at)
    check("the quick menu summarises live groups by urgency: \(quick.headline) / \(quick.rows.map(\.title))",
          quick.headline == "AI 세션 · 입력 1 · 도구 1 · 진행 2 · 로그 대기 1"
          && quick.rows.map(\.title) == ["TokenCat — 입력 대기 3분", "api-server — 명령 실행 · 턴 7분", "web — 진행 · 턴 1분 미만"]
          && quick.rows.map(\.kind) == [.input, .tool, .working] && quick.rows.first?.id == "q")
    let waitingOnly = SessionPresentation.groups([live("s", nil, .stale, last: -190)], now: at)
    check("quiet and loading quick menus say so",
          QuickMenuSummary.make(groups: [], counts: SessionCounts(), hasTokenSample: true, now: at).headline == "진행 중인 세션 없음"
          && QuickMenuSummary.make(groups: menuGroups, counts: SessionCounts(menuGroups), hasTokenSample: false, now: at)
            == QuickMenuSummary(headline: "AI 기록 확인 중")
          && QuickMenuSummary.make(groups: waitingOnly, counts: SessionCounts(waitingOnly), hasTokenSample: true, now: at).rows.first?.title
            == "프로젝트 미확인 — 로그 대기 · 3분째 기록 없음")
    AppLanguage.with(.en) {
        let quick = QuickMenuSummary.make(groups: menuGroups, counts: SessionCounts(menuGroups), hasTokenSample: true, now: at)
        let tip = StatusBarContent.tooltip(system: busy, counts: busyCounts, ai: busyAI, hasSample: true, hasTokenSample: true)
        check("English quick menu, tooltip and AI value: \(quick.headline) / \(quick.rows.map(\.title)) / \(tip)",
              quick.headline == "AI sessions · Input 1 · Tool 1 · Working 2 · Waiting for log 1"
              && quick.rows.first?.title == "TokenCat — Waiting for input · 3m" && quick.rows.last?.title == "web — Working · turn <1m"
              && QuickMenuSummary.minutes(3_900) == "1h 5m"
              && QuickMenuSummary.make(groups: waitingOnly, counts: SessionCounts(waitingOnly), hasTokenSample: true, now: at).rows.first?.title
                == "Unknown project — Waiting for log · no record for 3m"
              && tip.hasSuffix("AI: Working 1 · Running tool 1 · Subagents 0 · Waiting for log 0 · Input needed 1\nClick: details · Right-click: quick menu")
              && tip.contains("Memory 18 / 24 GB") && ai([stale])?.detail.hasPrefix("AI: 1 waiting for log · Working 0 ·") == true)
    }

    // Settings preview memo (T-5): preferences and pose rebuild at once, values at most once a second.
    let cache = MenuBarPreviewCache()
    let base = [metric(.cpu, "10%"), metric(.ai, "1", .working)]
    _ = cache.preview(metrics: base, preferences: preferences, pose: .walk, now: at)
    _ = cache.preview(metrics: base, preferences: preferences, pose: .walk, now: at.addingTimeInterval(0.2))
    _ = cache.preview(metrics: [metric(.cpu, "11%"), base[1]], preferences: preferences, pose: .walk, now: at.addingTimeInterval(0.5))
    let throttled = cache.builds
    _ = cache.preview(metrics: [metric(.cpu, "11%"), base[1]], preferences: preferences, pose: .sit, now: at.addingTimeInterval(0.6))
    _ = cache.preview(metrics: [metric(.cpu, "12%"), base[1]], preferences: preferences, pose: .sit, now: at.addingTimeInterval(1.7))
    check("the settings preview rebuilds on a pose change at once and on value changes at most once a second",
          throttled == 1 && cache.builds == 3 && cache.result.images.count == 2)
    print("Status bar checks: \(checks - failures.count) PASS / \(failures.count) FAIL / \(skipped) SKIP")
    return failures
}
