import AppKit
import SwiftUI

enum MetricID: String, CaseIterable, Codable, Identifiable {
    case cpu, memory, disk, battery, network, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "메모리"
        case .disk: return "저장 공간"
        case .battery: return "배터리"
        case .network: return "네트워크"
        case .ai: return "AI 세션"
        }
    }
}

final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var order: [MetricID] { didSet { persist() } }
    @Published var visible: Set<MetricID> { didSet { persist() } }
    @Published var animationSource: String { didSet { persist() } }
    @Published var showRunner: Bool { didSet { persist() } }
    @Published var statusBarLayout: StatusBarLayout { didSet { persist() } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Preserve custom order and visibility when the two provider fields become one.
        func migrated(_ name: String) -> MetricID? {
            if name == "codex" || name == "claude" { return .ai }
            return MetricID(rawValue: name)
        }
        let saved = (defaults.stringArray(forKey: "metricOrder") ?? []).compactMap(migrated)
        var ordered: [MetricID] = []
        for id in saved + MetricID.allCases where !ordered.contains(id) { ordered.append(id) }
        order = ordered
        visible = Set((defaults.stringArray(forKey: "visibleMetrics") ?? MetricID.allCases.map(\.rawValue)).compactMap(migrated))
        animationSource = defaults.string(forKey: "animationSource") ?? "cpu"
        showRunner = defaults.object(forKey: "showRunner") as? Bool ?? true
        statusBarLayout = StatusBarLayout(rawValue: defaults.string(forKey: "statusBarLayout") ?? "") ?? .compact
    }
    private func persist() {
        defaults.set(order.map(\.rawValue), forKey: "metricOrder")
        defaults.set(visible.map(\.rawValue), forKey: "visibleMetrics")
        defaults.set(animationSource, forKey: "animationSource")
        defaults.set(showRunner, forKey: "showRunner")
        defaults.set(statusBarLayout.rawValue, forKey: "statusBarLayout")
    }
    func move(_ id: MetricID, by delta: Int) {
        guard let index = order.firstIndex(of: id), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
    }
    func reset() {
        order = MetricID.allCases
        visible = Set(MetricID.allCases)
        animationSource = "cpu"
        showRunner = true
        statusBarLayout = .compact
    }
}

final class DashboardModel: ObservableObject {
    @Published var system = SystemSnapshot()
    @Published var tokens: [TokenReading] = []
    @Published var cpuHistory: [Double] = []
    @Published var hasSample = false
    @Published var tokensSampledAt: Date?
    @Published var telemetryStatus = "실측 수신 대기"
    @Published var telemetrySetupNote: String?
    @Published private(set) var telemetryReady = false
    /// The single clock for every age and elapsed value shown; views never read `Date()`.
    @Published private(set) var now = Date()
    @Published private(set) var flow = FlowSeries.empty
    @Published private(set) var sessions = SessionListModel.empty
    @Published var sessionsExpanded = false { didSet { if sessionsExpanded != oldValue { rebuildPresentation() } } }
    @Published var popoverShownAt: Date?
    let preferences = Preferences()
    let telemetry = LocalTelemetryCollector()
    private let telemetryProvider: (() -> [TelemetryReading])?
    private let sampler = SystemSampler()
    private let tracker = TokenTracker()
    private let systemQueue = DispatchQueue(label: "dev.seuput.TokenCat.system", qos: .utility)
    private let tokenQueue = DispatchQueue(label: "dev.seuput.TokenCat.tokens", qos: .utility)
    private var timer: Timer?
    private var watcher: LogWatcher?
    private var systemInFlight = false
    private var tokensInFlight = false
    private var tokenRefreshPending = false
    private var tokenRefreshScheduled = false
    private var lastTokenSampleStart: Date?
    private var changedPaths: [String] = []
    private var running = false
    private var generation: UInt64 = 0
    static let samplingInterval: TimeInterval = 1
    /// File events can arrive many times per second while a client streams tool output.
    static let minimumTokenInterval: TimeInterval = 0.25
    private(set) var logEventCount = 0
    var onUpdate: (() -> Void)?
    init(telemetryProvider: (() -> [TelemetryReading])? = nil) { self.telemetryProvider = telemetryProvider }
    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        refresh()
        let interval = Self.samplingInterval
        let next = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        next.tolerance = interval * 0.1
        RunLoop.main.add(next, forMode: .common)
        timer = next
        let watcher = LogWatcher { [weak self] paths in
            DispatchQueue.main.async { self?.logsChanged(paths) }
        }
        watcher.start(directories: tracker.watchedDirectories)
        self.watcher = watcher
    }
    func stop() {
        running = false
        generation &+= 1
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        changedPaths.removeAll()
        tokenRefreshPending = false
    }
    private func logsChanged(_ paths: [String]) {
        guard running else { return }
        changedPaths.append(contentsOf: paths.filter { $0.hasSuffix(".jsonl") }.prefix(64))
        if changedPaths.count > 256 { changedPaths.removeFirst(changedPaths.count - 256) }
        logEventCount += 1
        refreshTokens()
    }
    func refresh() {
        guard running else { return }
        refreshSystem()
        refreshTokens()
    }
    private func refreshTokens() {
        guard running else { return }
        if tokensInFlight { tokenRefreshPending = true; return }
        if let last = lastTokenSampleStart, Date().timeIntervalSince(last) < Self.minimumTokenInterval {
            guard !tokenRefreshScheduled else { return }
            tokenRefreshScheduled = true
            let currentGeneration = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.minimumTokenInterval - Date().timeIntervalSince(last)) { [weak self] in
                guard let self else { return }
                self.tokenRefreshScheduled = false
                guard self.generation == currentGeneration else { return }
                self.refreshTokens()
            }
            return
        }
        let currentGeneration = generation
        let paths = changedPaths
        changedPaths.removeAll()
        lastTokenSampleStart = Date()
        tokensInFlight = true
        tokenQueue.async { [weak self] in
            guard let self else { return }
            self.tracker.noteChanged(paths: paths)
            let logs = self.tracker.sample()
            let measurements = self.telemetryProvider?() ?? self.telemetry.snapshot()
            let tokens = TokenSpeed.apply(logs, measurements: measurements)
            let telemetryStatus = self.telemetry.status
            // Verification commands read the running app's collector through the provider.
            let telemetryReady = self.telemetryProvider != nil || self.telemetry.isRunning
            let measuredAt = Date()
            DispatchQueue.main.async {
                self.tokensInFlight = false
                guard self.running, self.generation == currentGeneration else { return }
                self.tokens = tokens
                self.tokensSampledAt = measuredAt
                self.telemetryStatus = telemetryStatus
                if self.telemetryReady != telemetryReady { self.telemetryReady = telemetryReady }
                self.rebuildPresentation()
                self.onUpdate?()
                if self.tokenRefreshPending {
                    self.tokenRefreshPending = false
                    self.refreshTokens()
                }
            }
        }
    }
    private func refreshSystem() {
        let currentGeneration = generation
        if !systemInFlight {
            systemInFlight = true
            systemQueue.async { [weak self] in
                guard let self else { return }
                let system = self.sampler.sample()
                DispatchQueue.main.async {
                    self.systemInFlight = false
                    guard self.running, self.generation == currentGeneration else { return }
                    self.system = system
                    self.hasSample = true
                    if let cpu = system.cpuPercent {
                        self.cpuHistory.append(cpu)
                        self.cpuHistory = Array(self.cpuHistory.suffix(90))
                    }
                    self.rebuildPresentation()
                    self.onUpdate?()
                }
            }
        }
    }
    private func rebuildPresentation() {
        let now = max(system.sampledAt, tokensSampledAt ?? .distantPast)
        if now != self.now { self.now = now }
        let flow = FlowSeries.make(tokens, now: now)
        if flow != self.flow { self.flow = flow }
        sessions = SessionListModel.make(tokens: tokens, now: now, expanded: sessionsExpanded, flow: flow)
    }
}

enum Format {
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }
    static func tps(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
    static func ratio(_ used: UInt64?, _ total: UInt64?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }
    static func capacity(_ used: UInt64?, _ total: UInt64?) -> String {
        guard let used, let total else { return "—" }
        let factor = total >= 1_099_511_627_776 ? 1_099_511_627_776.0 : 1_073_741_824.0
        let unit = total >= 1_099_511_627_776 ? "TB" : "GB"
        func number(_ value: UInt64) -> String {
            let text = String(format: "%.1f", Double(value) / factor)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        return "\(number(used)) / \(number(total)) \(unit)"
    }
    /// Grouped below 100,000 so recent counts stay exact; abbreviated above.
    static func tokens(_ value: Int) -> String {
        if value < 100_000 { return value.formatted(.number.locale(Locale(identifier: "ko_KR"))) }
        if value < 999_950 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(format: "%.2fM", Double(value) / 1_000_000)
    }
    static func compactTokens(_ value: Int) -> String {
        func trimmed(_ number: Double, _ unit: String) -> String {
            let text = String(format: "%.1f", number)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if value < 1_000 { return String(value) }
        if value < 999_950 { return trimmed(Double(value) / 1_000, "k") }
        return trimmed(Double(value) / 1_000_000, "M")
    }
    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "기록 없음" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)초 전" }
        if seconds < 3600 { return "\(seconds / 60)분 전" }
        if seconds < 86_400 { return "\(seconds / 3600)시간 전" }
        return "\(seconds / 86_400)일 전"
    }
    static func power(_ snapshot: SystemSnapshot) -> String {
        if snapshot.isCharging == true { return "충전 중" }
        if snapshot.powerSource == "AC Power" { return "전원 어댑터 연결" }
        if snapshot.powerSource == "Battery Power" { return "배터리 사용 중" }
        return "전원 상태 미확인"
    }
    static func elapsed(_ date: Date?, at now: Date) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds >= 3_600 { return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    var changed: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(nsImage: Runner.brandImage()).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28).accessibilityHidden(true)
                Text("메뉴바 표시").font(.system(size: 16, weight: .semibold))
            }
            Text("표시할 항목을 선택하고 순서를 바꾸세요.").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("표시 방식", selection: $preferences.statusBarLayout) {
                ForEach(StatusBarLayout.allCases) { layout in Text(layout.title).tag(layout) }
            }.pickerStyle(.segmented).onChange(of: preferences.statusBarLayout) { _ in changed() }
            VStack(spacing: 0) {
                ForEach(preferences.order) { id in
                    HStack {
                        Toggle(id.title, isOn: Binding(get: { preferences.visible.contains(id) }, set: { value in
                            if value { preferences.visible.insert(id) } else { preferences.visible.remove(id) }; changed()
                        }))
                        Spacer()
                        Button(action: { preferences.move(id, by: -1); changed() }) { Image(systemName: "chevron.up") }.disabled(preferences.order.first == id).help("\(id.title) 위로 이동").accessibilityLabel("\(id.title) 위로 이동")
                        Button(action: { preferences.move(id, by: 1); changed() }) { Image(systemName: "chevron.down") }.disabled(preferences.order.last == id).help("\(id.title) 아래로 이동").accessibilityLabel("\(id.title) 아래로 이동")
                    }.font(.system(size: 12)).frame(height: 28)
                }
            }.padding(8).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            Divider()
            Toggle("고양이 표시", isOn: $preferences.showRunner).onChange(of: preferences.showRunner) { _ in changed() }
            Picker("움직임 기준", selection: $preferences.animationSource) {
                Text("CPU 사용률").tag("cpu")
                Text("AI 실측 속도").tag("tokens")
            }.onChange(of: preferences.animationSource) { _ in changed() }
                .help("AI 실측 속도: 최근 5초 안에 받은 실측 속도에만 반응합니다. 실측이 없으면 천천히 걷습니다")
            Button("기본값으로 되돌리기") { preferences.reset(); changed() }
        }.padding(20).frame(width: 360).fixedSize(horizontal: false, vertical: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = DashboardModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var statusView: StatusBarContentView?
    private var settingsWindow: NSWindow?
    private var telemetrySetupInFlight = false
    private var telemetryConfigured = false
    private var animationTimer: Timer?
    private var animationPhase = 0.0
    private var lastAnimationFrame: Int = -1
    private let animationInterval = 0.08
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        if let button = statusItem.button {
            let view = StatusBarContentView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
            button.setAccessibilityLabel("TokenCat")
            statusView = view
        }
        popover.behavior = .transient
        popover.delegate = self
        let content = NSHostingController(rootView: DashboardView(model: model, settings: { [weak self] in self?.openSettings() }, quit: { NSApp.terminate(nil) }))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        model.onUpdate = { [weak self] in self?.updateStatus() }
        model.telemetry.start { [weak self] in
            DispatchQueue.main.async { self?.connectTelemetryAutomatically() }
        }
        model.start()
        updateStatus()
        animationTimer = Timer.scheduledTimer(withTimeInterval: animationInterval, repeats: true) { [weak self] _ in self?.animate() }
        animationTimer?.tolerance = 0.015
        if CommandLine.arguments.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.togglePopover() }
        }
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.openSettings() }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--status-readback"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.writeStatusReadback(path: path) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        animationTimer?.invalidate()
        model.stop()
        model.telemetry.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
    private func animate() {
        guard model.preferences.showRunner else { return }
        let speed: Double
        if model.preferences.animationSource == "tokens" {
            let recent = model.tokens.filter {
                guard $0.model == $0.speedMeasurement?.model, let at = $0.speedMeasurement?.at else { return false }
                let age = Date().timeIntervalSince(at)
                return age >= -5 && age < 5
            }
            speed = recent.compactMap { $0.speedMeasurement?.tokensPerSecond }.max().map { min(1.5, max(0.3, $0 / 50)) } ?? 0.2
        } else {
            speed = min(1.5, max(0.2, (model.system.cpuPercent ?? 0) / 60))
        }
        animationPhase = (animationPhase + speed * animationInterval).truncatingRemainder(dividingBy: 1)
        let frame = Int(animationPhase * Double(Runner.frameCount)) % Runner.frameCount
        if frame != lastAnimationFrame {
            statusView?.updateRunner(frame: frame)
            lastAnimationFrame = frame
        }
    }
    func updateStatus() {
        guard let button = statusItem.button, let statusView else { return }
        let preferences = model.preferences
        let metrics = StatusBarContent.metrics(system: model.system, counts: model.sessions.counts, recorded: model.flow.total,
            preferences: preferences, hasSample: model.hasSample, hasTokenSample: model.tokensSampledAt != nil)
        statusView.update(metrics: metrics, layout: preferences.statusBarLayout, showRunner: preferences.showRunner)
        statusItem.length = statusView.requiredWidth
        statusView.frame = NSRect(x: 0, y: 0, width: statusView.requiredWidth,
            height: button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness)
        statusView.updateRunner(frame: max(0, lastAnimationFrame))
        button.title = ""
        button.image = nil
        let details = metrics.map(\.detail).joined(separator: "\n")
        button.toolTip = "TokenCat\n\(details)\n클릭하면 세션별 상세를 엽니다"
        button.setAccessibilityValue(details)
        button.setAccessibilityHelp("메뉴를 열어 세션별 모델과 속도, 시스템 상세 수치를 확인합니다.")
    }
    func popoverWillShow(_ notification: Notification) {
        model.popoverShownAt = Date()
    }
    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            button.highlight(true)
            statusView?.highlighted = true
        }
    }
    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        statusView?.highlighted = false
    }
    private func writeStatusReadback(path: String) {
        guard let button = statusItem.button, let statusView else { return }
        let metrics = StatusBarContent.metrics(system: model.system, counts: model.sessions.counts, recorded: model.flow.total,
            preferences: model.preferences, hasSample: model.hasSample, hasTokenSample: model.tokensSampledAt != nil)
        let report: [String: Any] = [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "layout": model.preferences.statusBarLayout.rawValue,
            "visible": statusItem.isVisible,
            "nativeWindowVisible": button.window?.isVisible ?? false,
            "nativeWindowFrame": button.window.map { NSStringFromRect($0.frame) } ?? "",
            "buttonWidth": button.bounds.width, "buttonHeight": button.bounds.height,
            "contentWidth": statusView.requiredWidth, "sampled": model.hasSample,
            "telemetryReady": model.telemetry.isRunning, "telemetryConfigured": telemetryConfigured,
            "metrics": metrics.map { ["id": $0.id.rawValue, "label": $0.label, "value": $0.value] }
        ]
        do {
            let url = URL(fileURLWithPath: path)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: bitmap)
                // The status button is transparent; composite it onto a menu-bar-like backdrop.
                let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let canvas = NSImage(size: button.bounds.size)
                canvas.lockFocus()
                NSColor(white: dark ? 0.13 : 0.94, alpha: 1).setFill()
                NSRect(origin: .zero, size: button.bounds.size).fill()
                bitmap.draw(in: NSRect(origin: .zero, size: button.bounds.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
                canvas.unlockFocus()
                if let tiff = canvas.tiffRepresentation, let opaque = NSBitmapImageRep(data: tiff),
                   let png = opaque.representation(using: .png, properties: [:]) {
                    try png.write(to: url.deletingPathExtension().appendingPathExtension("png"))
                }
            }
        } catch { print("메뉴 막대 확인 파일 저장 실패: \(error.localizedDescription)") }
    }
    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let content = NSHostingView(rootView: PreferencesView(preferences: model.preferences,
                changed: { [weak self] in self?.updateStatus() }))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "TokenCat 설정"
            window.isReleasedWhenClosed = false
            window.contentView = content
            window.setContentSize(content.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func connectTelemetryAutomatically() {
        guard !telemetrySetupInFlight else { return }
        if !model.telemetry.isRunning {
            model.telemetrySetupNote = "수집기가 실행되지 않아 연결할 수 없습니다."
            return
        }
        telemetrySetupInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let message: String?
            do {
                let setup = TelemetrySetup()
                _ = try setup.connect()
                message = nil
            } catch { message = "실측 연결: \(error.localizedDescription)" }
            DispatchQueue.main.async {
                self?.telemetrySetupInFlight = false
                self?.telemetryConfigured = message == nil
                self?.model.telemetrySetupNote = message
            }
        }
    }
}
