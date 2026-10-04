import AppKit
import Combine
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
    @Published var visible: Set<MetricID> { didSet { persist(); keepSomethingVisible() } }
    @Published var animationSource: RunnerMotion { didSet { persist() } }
    @Published var showRunner: Bool { didSet { persist(); keepSomethingVisible() } }
    @Published var statusBarLayout: StatusBarLayout { didSet { persist(); keepSomethingVisible() } }
    /// Opt-in notifications; both default off.
    @Published var notifyTurnComplete: Bool { didSet { persist() } }
    @Published var notifyInput: Bool { didSet { persist() } }
    /// Runtime only, from the system sampler; a battery item without a battery shows nothing.
    @Published var hasBattery = true { didSet { if hasBattery != oldValue { keepSomethingVisible() } } }
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
        // New installs, the legacy "tokens" value and an unconfirmed older "cpu" start on AI activity.
        animationSource = RunnerMotion.stored(defaults.string(forKey: "animationSource"),
                                              confirmed: defaults.bool(forKey: RunnerMotion.confirmedKey))
        showRunner = defaults.object(forKey: "showRunner") as? Bool ?? true
        statusBarLayout = StatusBarLayout(rawValue: defaults.string(forKey: "statusBarLayout") ?? "") ?? .compact
        notifyTurnComplete = defaults.bool(forKey: "notifyTurnComplete")
        notifyInput = defaults.bool(forKey: "notifyInput")
        // An older build could hide every item and the cat, leaving only a "TC" placeholder.
        if statusBarLayout != .minimal && !showRunner && shownItems.isEmpty { showRunner = true }
    }
    private func persist() {
        defaults.set(order.map(\.rawValue), forKey: "metricOrder")
        defaults.set(visible.map(\.rawValue), forKey: "visibleMetrics")
        defaults.set(animationSource.rawValue, forKey: "animationSource")
        defaults.set(true, forKey: RunnerMotion.confirmedKey)
        defaults.set(showRunner, forKey: "showRunner")
        defaults.set(statusBarLayout.rawValue, forKey: "statusBarLayout")
        defaults.set(notifyTurnComplete, forKey: "notifyTurnComplete")
        defaults.set(notifyInput, forKey: "notifyInput")
    }
    /// Items the compact and inline layouts actually draw.
    var shownItems: [MetricID] { order.filter { visible.contains($0) && ($0 != .battery || hasBattery) } }
    /// With the cat hidden, the last drawn item stays on. The minimal layout always draws the AI item.
    func canHide(_ id: MetricID) -> Bool { statusBarLayout == .minimal || showRunner || shownItems != [id] }
    var canHideRunner: Bool { statusBarLayout == .minimal || !shownItems.isEmpty }
    func setVisible(_ id: MetricID, _ on: Bool) {
        if on { visible.insert(id) } else if canHide(id) { visible.remove(id) }
    }
    func setShowRunner(_ on: Bool) { if on || canHideRunner { showRunner = on } }
    private func keepSomethingVisible() {
        if statusBarLayout != .minimal && !showRunner && shownItems.isEmpty { showRunner = true }
    }
    func move(_ id: MetricID, by delta: Int) {
        guard let index = order.firstIndex(of: id), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
    }
    /// Drag reordering: `id` takes `target`'s place (after it when moving down).
    func move(_ id: MetricID, onto target: MetricID) {
        guard id != target, let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return }
        order.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    }
    /// Display, cat and notification choices only; login item and notification permission are untouched.
    func reset() {
        order = MetricID.allCases
        visible = Set(MetricID.allCases)
        animationSource = .activity
        showRunner = true
        statusBarLayout = .compact
        notifyTurnComplete = false
        notifyInput = false
    }
}

/// Clients whose config TokenCat changed and that have not sent a reading since.
/// After 24 h without one the notice changes, since that client may never emit the metric.
struct TelemetryRestartState: Equatable {
    static let window: TimeInterval = 86_400
    var pending: [TokenSource: Date] = [:]
    var needed: Set<TokenSource> = []
    var expired: Set<TokenSource> = []

    /// `ran` is the newest log activity per client. A client never used since its config changed
    /// is not reported as failing; it stays quietly pending after the window.
    static func resolve(pending: [TokenSource: Date], received: [TokenSource: Date], ran: [TokenSource: Date] = [:],
                        now: Date) -> TelemetryRestartState {
        var state = TelemetryRestartState()
        for (source, connectedAt) in pending {
            if let at = received[source], at > connectedAt { continue }
            state.pending[source] = connectedAt
            if now.timeIntervalSince(connectedAt) < window { state.needed.insert(source) }
            else if let at = ran[source], at > connectedAt { state.expired.insert(source) }
        }
        return state
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
    @Published var telemetrySetupFailure: TelemetrySetupFailure?
    /// Clients whose config changed and that have not sent a reading since; they need a new launch.
    @Published var telemetryRestartNeeded: Set<TokenSource> = []
    /// Pending for more than 24 h: the client may never send telemetry in its current version.
    @Published private(set) var telemetryRestartExpired: Set<TokenSource> = []
    /// Newest telemetry reading time per client seen by this process.
    @Published private(set) var telemetryLastReceived: [TokenSource: Date] = [:]
    private var telemetryBatches: [TokenSource: Date] = [:]
    @Published private(set) var telemetryReady = false
    /// The single clock for every age and elapsed value shown; views never read `Date()`.
    @Published private(set) var now = Date()
    @Published private(set) var flow = FlowSeries.empty
    @Published private(set) var sessions = SessionListModel.empty
    @Published var sessionsExpanded = false { didSet { if sessionsExpanded != oldValue { rebuildPresentation() } } }
    @Published var popoverShownAt: Date?
    /// Top-level groups for this publish; the shell derives the menu bar, cat and notifications from them.
    private(set) var groups: [SessionGroup] = []
    let preferences = Preferences()
    private var pendingRestart: [TokenSource: Date] = [:]
    private static let pendingRestartKey = "telemetryPendingRestart"
    let telemetry = LocalTelemetryCollector()
    private let telemetryProvider: (() -> [TelemetryReading])?
    private let telemetryProbe: (() -> Bool)?
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
    /// Set by the app shell, so views can open Settings at a section without knowing about windows.
    var settingsRequest: ((SettingsFocus?) -> Void)?
    func showSettings(_ focus: SettingsFocus? = nil) { settingsRequest?(focus) }
    /// `telemetryProbe` reports whether the running app's collector answers, for verification commands
    /// that read it through `telemetryProvider`. Synthetic fixtures pass `restoresRestartState: false`.
    init(telemetryProvider: (() -> [TelemetryReading])? = nil, telemetryProbe: (() -> Bool)? = nil,
         restoresRestartState: Bool = true) {
        self.telemetryProvider = telemetryProvider
        self.telemetryProbe = telemetryProbe
        let stored = restoresRestartState
            ? UserDefaults.standard.dictionary(forKey: Self.pendingRestartKey) as? [String: Double] ?? [:] : [:]
        for (key, seconds) in stored { if let source = TokenSource(rawValue: key) { pendingRestart[source] = Date(timeIntervalSince1970: seconds) } }
        updateRestartState(now: Date())
    }
    /// Only the app's own model persists restart notices; verification commands read them.
    private var ownsTelemetryState: Bool { telemetryProvider == nil }
    func noteTelemetryConnected(_ sources: [TokenSource], at date: Date = Date()) {
        guard !sources.isEmpty else { return }
        for source in sources { pendingRestart[source] = date }
        savePendingRestart()
        updateRestartState(now: date)
    }
    private func updateRestartState(now: Date) {
        var ran: [TokenSource: Date] = [:]
        for reading in tokens where !SessionPresentation.isTelemetry(reading) {
            if let at = SessionPresentation.liveAt(reading) { ran[reading.source] = max(ran[reading.source] ?? at, at) }
        }
        let received = telemetryLastReceived.merging(telemetryBatches) { max($0, $1) }
        let state = TelemetryRestartState.resolve(pending: pendingRestart, received: received, ran: ran, now: now)
        if state.pending != pendingRestart {
            pendingRestart = state.pending
            savePendingRestart()
        }
        if state.needed != telemetryRestartNeeded { telemetryRestartNeeded = state.needed }
        if state.expired != telemetryRestartExpired { telemetryRestartExpired = state.expired }
    }
    private func savePendingRestart() {
        guard ownsTelemetryState else { return }
        if pendingRestart.isEmpty { UserDefaults.standard.removeObject(forKey: Self.pendingRestartKey); return }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: pendingRestart.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }),
                                  forKey: Self.pendingRestartKey)
    }
    func telemetryClientStatus(_ source: TokenSource) -> String {
        if telemetryRestartNeeded.contains(source) { return "\(source.title)를 새로 실행하면 실측이 표시됩니다" }
        if telemetryRestartExpired.contains(source) { return "이 버전에서 실측을 받지 못했습니다" }
        if let at = telemetryLastReceived[source] {
            return "최근 실측 " + (now.timeIntervalSince(at) < 60 ? "1분 이내" : Format.age(at, now: now))
        }
        return "이번 실행에서 받은 실측 없음"
    }
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
            var received: [TokenSource: Date] = [:]
            for measurement in measurements { received[measurement.provider] = max(received[measurement.provider] ?? measurement.at, measurement.at) }
            // Any batch from a restarted client clears its notice, even one TokenCat cannot decode yet.
            let batches = self.telemetryProvider == nil ? self.telemetry.lastBatchAt : [:]
            // Verification commands read the running app's collector, never this unstarted one.
            let probed = self.telemetryProbe?()
            let telemetryStatus = probed.map { $0 ? (measurements.isEmpty ? TelemetryCollectorState.waiting.status
                                                                          : TelemetryCollectorState.receiving.status)
                                               : "실측 꺼짐 · 실행 중인 TokenCat 수집기 없음" } ?? self.telemetry.status
            let telemetryReady = probed ?? (self.telemetryProvider != nil || self.telemetry.isRunning)
            let measuredAt = Date()
            DispatchQueue.main.async {
                self.tokensInFlight = false
                guard self.running, self.generation == currentGeneration else { return }
                self.tokens = tokens
                self.tokensSampledAt = measuredAt
                self.telemetryStatus = telemetryStatus
                if self.telemetryReady != telemetryReady { self.telemetryReady = telemetryReady }
                let lastReceived = self.telemetryLastReceived.merging(received) { max($0, $1) }
                if lastReceived != self.telemetryLastReceived { self.telemetryLastReceived = lastReceived }
                self.telemetryBatches = self.telemetryBatches.merging(batches) { max($0, $1) }
                self.updateRestartState(now: measuredAt)
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
                    if self.preferences.hasBattery != system.batteryPresent { self.preferences.hasBattery = system.batteryPresent }
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
        groups = SessionPresentation.groups(tokens, now: now)
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


final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    /// Payload-free hand-off from a second launch; the running instance opens its dashboard and acknowledges.
    static let openRequest = Notification.Name("dev.seuput.TokenCat.openPopover")
    static let openAcknowledged = Notification.Name("dev.seuput.TokenCat.openPopover.ack")
    let model = DashboardModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var statusView: StatusBarContentView?
    private var settingsWindow: NSWindow?
    private var panel: NSPanel?
    private var panelSize: NSKeyValueObservation?
    private let notifier = Notifier()
    private lazy var settingsState = SettingsState(notifier: notifier)
    private var attention = AttentionTracker()
    private var latestSignals: [String: AttentionSignal] = [:]
    private var director = RunnerDirector()
    private let animator = RunnerAnimator()
    private var activity = RunnerActivity()
    private var ai = StatusAISummary()
    private var lastToolTip: String?
    private var lastAccessibilityValue: String?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var preferenceChanges: AnyCancellable?
    private var screensAsleep = false
    private var sessionActive = true
    private var statusWindowVisible = true
    private var popoverClosedAt: Date?
    private var telemetrySetupInFlight = false
    private var telemetryConfigured = false

    /// Registered before the status item exists, so a second launch during startup is answered.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Self.openRequest, object: nil, queue: .main) { [weak self] _ in
            distributed.postNotificationName(Self.openAcknowledged, object: nil, userInfo: nil, deliverImmediately: true)
            guard let self, self.statusItem != nil else { return }
            self.openDashboard()
        }))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.title = ""
            button.image = nil
            let view = StatusBarContentView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
            button.setAccessibilityLabel("TokenCat")
            button.setAccessibilityHelp("클릭하면 세션별 상세를 열고, 우클릭하면 빠른 메뉴를 엽니다.")
            statusView = view
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = dashboardController()
        animator.render = { [weak self] pose, frame in self?.statusView?.updateRunner(pose: pose, frame: frame) }
        animator.replan = { [weak self] in self?.planRunner() }
        notifier.onOpen = { [weak self] in self?.openDashboard() }
        notifier.activate()
        model.onUpdate = { [weak self] in self?.publish() }
        model.settingsRequest = { [weak self] in self?.openSettings(focus: $0) }
        preferenceChanges = model.preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus(); self?.planRunner() }
        }
        observeSystem()
        model.telemetry.start { [weak self] in
            DispatchQueue.main.async { self?.connectTelemetryAutomatically() }
        }
        model.start()
        publish()
        if CommandLine.arguments.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.togglePopover() }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--open-settings") {
            let focus = CommandLine.arguments.indices.contains(index + 1) ? SettingsFocus(rawValue: CommandLine.arguments[index + 1]) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.openSettings(focus: focus) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--status-readback"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.writeStatusReadback(path: path) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        animator.stop()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        model.stop()
        model.telemetry.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    /// Opening the app again while it runs shows Settings (the status item may be hidden by the notch).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func dashboardController() -> NSHostingController<DashboardView> {
        let controller = NSHostingController(rootView: DashboardView(model: model, settings: { [weak self] in self?.openSettings() },
                                                                     quit: { NSApp.terminate(nil) }))
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil, _ handler: @escaping (AppDelegate) -> Void) {
            observers.append((center, center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                guard let self else { return }
                handler(self)
            }))
        }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true; $0.planRunner() }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false; $0.planRunner() }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionActive = false; $0.planRunner() }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionActive = true; $0.planRunner() }
        on(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.statusView?.displayOptionsChanged()
            $0.settingsState.refresh()
            $0.planRunner()
        }
        if let window = statusItem.button?.window {
            // Full-screen apps and hidden menu bars occlude the item; the cat stops until it is visible again.
            on(.default, NSWindow.didChangeOcclusionStateNotification, object: window) { delegate in
                delegate.statusWindowVisible = window.occlusionState.contains(.visible)
                delegate.planRunner()
            }
        }
    }

    /// Runs once per model publish: the menu bar, the cat's state and notification transitions.
    private func publish() {
        let groups = model.groups
        ai = StatusAISummary(groups: groups, counts: model.sessions.counts)
        updateStatus()
        let now = Date()
        activity = RunnerActivity(groups: groups, cpu: model.hasSample ? model.system.cpuPercent : nil, now: now)
        director.observe(activity, now: now)
        planRunner()
        // The baseline is the first real token sample, so sessions already waiting at launch are not announced.
        if model.tokensSampledAt != nil { handleAttention(groups) }
    }

    private func planRunner() {
        let preferences = model.preferences
        animator.paused = !preferences.showRunner || screensAsleep || !sessionActive || !statusWindowVisible
        guard preferences.showRunner else { return }
        animator.apply(director.plan(preferences.animationSource, activity: activity, now: Date(),
                                     reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    }

    func updateStatus() {
        guard let button = statusItem?.button, let statusView else { return }
        let preferences = model.preferences
        let metrics = StatusBarContent.metrics(system: model.system, counts: model.sessions.counts, ai: ai, recorded: model.flow.total,
            preferences: preferences, hasSample: model.hasSample, hasTokenSample: model.tokensSampledAt != nil)
        statusView.update(metrics: metrics, layout: preferences.statusBarLayout, showRunner: preferences.showRunner)
        if statusItem.length != statusView.requiredWidth { statusItem.length = statusView.requiredWidth }
        statusView.frame = NSRect(x: 0, y: 0, width: statusView.requiredWidth,
            height: button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness)
        // Reassigning an unchanged tooltip makes a hovering tooltip flicker; live values live in the AX value.
        let tip = StatusBarContent.tooltip(system: model.system, counts: model.sessions.counts, ai: ai,
                                           hasSample: model.hasSample, hasTokenSample: model.tokensSampledAt != nil)
        if tip != lastToolTip { button.toolTip = tip; lastToolTip = tip }
        let value = metrics.map(\.detail).joined(separator: "\n")
        if value != lastAccessibilityValue { button.setAccessibilityValue(value); lastAccessibilityValue = value }
    }

    /// A panel behind other windows or on another Space does not count, so its notifications still arrive.
    private var dashboardVisible: Bool {
        popover.isShown || panel.map { $0.isVisible && $0.occlusionState.contains(.visible) } == true
    }

    private func handleAttention(_ groups: [SessionGroup]) {
        let signals = AttentionSignal.make(groups)
        latestSignals = Dictionary(signals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The baseline always advances, so turning a toggle on later never replays old transitions.
        for event in attention.update(signals) {
            switch event {
            case .input:
                guard model.preferences.notifyInput, !dashboardVisible else { continue }
                notifier.post(event)
            case .finished(let signal):
                guard model.preferences.notifyTurnComplete else { continue }
                // A Stop hook can continue the turn right after a soft close; send only if it stayed closed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.latestSignals[signal.id]?.live != true,
                          self.model.preferences.notifyTurnComplete, !self.dashboardVisible else { return }
                    self.notifier.post(event)
                }
            }
        }
    }

    // MARK: Status item, popover and panel

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showQuickMenu() } else { togglePopover() }
    }

    @objc func togglePopover() {
        if let panel, panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        // A transient popover may already have closed on this click's mouse-down; do not reopen it on mouse-up.
        if let closed = popoverClosedAt, Date().timeIntervalSince(closed) < 0.3, NSApp.currentEvent?.type == .leftMouseUp { return }
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        statusView?.highlighted = true
    }

    func openDashboard() {
        if let panel, panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else if !popover.isShown {
            showPopover()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        model.popoverShownAt = Date()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        statusItem.button?.highlight(false)
        statusView?.highlighted = false
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    /// Dragging the popover off the menu bar leaves the same dashboard in a panel that remembers its frame.
    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        statusItem.button?.highlight(false)
        statusView?.highlighted = false
        model.popoverShownAt = Date()
        return makePanel()
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let controller = dashboardController()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = "TokenCat"
        // A normal window level: other apps' windows can cover it ("always on top" is not a feature).
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = controller
        if !panel.setFrameUsingName("TokenCatPanel") { panel.center() }
        panel.setFrameAutosaveName("TokenCatPanel")
        panelSize = controller.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self] controller, _ in
            let size = controller.preferredContentSize
            DispatchQueue.main.async { self?.fitPanel(to: size) }
        }
        self.panel = panel
        return panel
    }

    /// Keeps the panel's top edge fixed while the dashboard's height changes.
    private func fitPanel(to size: NSSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let content = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = panel.frame
        frame.origin.y += frame.height - content.height
        frame.size = content.size
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// Closed windows are released so their SwiftUI views stop re-rendering on every model publish.
    /// Frames are remembered by their autosave names.
    /// Returning from System Settings (login item approval, notification permission) re-reads the real status.
    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { settingsState.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow?.contentViewController = nil
            settingsWindow = nil
        } else if window === panel {
            panelSize = nil
            panel?.contentViewController = nil
            panel = nil
        }
    }

    @objc private func openPanel() {
        popover.performClose(nil)
        let panel = makePanel()
        model.popoverShownAt = Date()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Menus

    private func menuItem(_ title: String, _ action: Selector, key: String = "", value: String? = nil,
                          checked: Bool = false, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = value
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    /// Invisible for an accessory app, but gives Settings and the panel ⌘, ⌘W ⌘Q and copy.
    private func installMainMenu() {
        let main = NSMenu()
        let quit = NSMenuItem(title: "TokenCat 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu("TokenCat", [menuItem("TokenCat 정보", #selector(showAbout)), .separator(),
                                          menuItem("설정…", #selector(openSettingsAction), key: ","), .separator(), quit]))
        main.addItem(submenu("편집", [NSMenuItem(title: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                                     NSMenuItem(title: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")]))
        main.addItem(submenu("윈도우", [NSMenuItem(title: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")]))
        main.items.forEach { $0.submenu?.autoenablesItems = true }
        NSApp.mainMenu = main
    }

    private func showQuickMenu() {
        if popover.isShown { popover.performClose(nil) }
        let preferences = model.preferences
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem("열기", #selector(openDashboardAction)))
        menu.addItem(menuItem("패널로 열기", #selector(openPanel)))
        menu.addItem(.separator())
        menu.addItem(submenu("표시 방식", StatusBarLayout.allCases.map {
            menuItem($0.title, #selector(selectLayout(_:)), value: $0.rawValue, checked: preferences.statusBarLayout == $0)
        }))
        menu.addItem(menuItem("고양이 표시", #selector(toggleRunner), checked: preferences.showRunner,
                              enabled: !preferences.showRunner || preferences.canHideRunner))
        menu.addItem(submenu("움직임 기준", RunnerMotion.allCases.map {
            menuItem($0.title, #selector(selectMotion(_:)), value: $0.rawValue, checked: preferences.animationSource == $0)
        }))
        menu.addItem(.separator())
        menu.addItem(menuItem("설정…", #selector(openSettingsAction), key: ","))
        menu.addItem(menuItem("활성 상태 보기", #selector(openActivityMonitor)))
        menu.addItem(menuItem("TokenCat 정보", #selector(showAbout)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "TokenCat 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        // A temporary menu keeps the left click on the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openDashboardAction() { openDashboard() }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func toggleRunner() { model.preferences.setShowRunner(!model.preferences.showRunner) }
    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
    @objc private func selectLayout(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let layout = StatusBarLayout(rawValue: raw) { model.preferences.statusBarLayout = layout }
    }
    @objc private func selectMotion(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let motion = RunnerMotion(rawValue: raw) { model.preferences.animationSource = motion }
    }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: AppInfo.aboutOptions)
    }

    func openSettings(focus: SettingsFocus? = nil) {
        popover.performClose(nil)
        if let focus { settingsState.focus = focus }
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(preferences: model.preferences, model: model, state: settingsState,
                                                                        showAbout: { [weak self] in self?.showAbout() }))
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.title = "TokenCat 설정"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentMinSize = NSSize(width: SettingsView.width, height: 360)
            window.contentMaxSize = NSSize(width: SettingsView.width, height: 4_000)
            window.setContentSize(NSSize(width: SettingsView.width, height: 640))
            if !window.setFrameUsingName("TokenCatSettings") { window.center() }
            window.setFrameAutosaveName("TokenCatSettings")
            settingsWindow = window
        }
        settingsState.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func writeStatusReadback(path: String) {
        guard let button = statusItem.button, let statusView else { return }
        let metrics = StatusBarContent.metrics(system: model.system, counts: model.sessions.counts, ai: ai, recorded: model.flow.total,
            preferences: model.preferences, hasSample: model.hasSample, hasTokenSample: model.tokensSampledAt != nil)
        let report: [String: Any] = [
            "version": AppInfo.version,
            "layout": model.preferences.statusBarLayout.rawValue,
            "visible": statusItem.isVisible,
            "nativeWindowVisible": button.window?.isVisible ?? false,
            "nativeWindowFrame": button.window.map { NSStringFromRect($0.frame) } ?? "",
            "buttonWidth": button.bounds.width, "buttonHeight": button.bounds.height,
            "contentWidth": statusView.requiredWidth, "sampled": model.hasSample,
            "telemetryReady": model.telemetry.isRunning, "telemetryConfigured": telemetryConfigured,
            "runnerPose": animator.plan.pose.rawValue, "runnerTimer": animator.isTimerRunning,
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

    private func connectTelemetryAutomatically() {
        guard !telemetrySetupInFlight else { return }
        if !model.telemetry.isRunning {
            model.telemetrySetupNote = "수집기가 실행되지 않아 연결할 수 없습니다."
            model.telemetrySetupFailure = .unavailable
            return
        }
        telemetrySetupInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let message: String?
            var failure: TelemetrySetupFailure?
            var restart: [TokenSource] = []
            do {
                restart = try TelemetrySetup().connect().restartRequired
                message = nil
            } catch {
                message = "실측 연결: \(error.localizedDescription)"
                failure = (error as? TelemetrySetupError)?.failure ?? .writeFailed(restored: true)
            }
            DispatchQueue.main.async {
                self?.telemetrySetupInFlight = false
                self?.telemetryConfigured = message == nil
                self?.model.telemetrySetupNote = message
                self?.model.telemetrySetupFailure = failure
                // Running clients keep their old config; remember to say so until each one reports.
                self?.model.noteTelemetryConnected(restart)
            }
        }
    }
}
