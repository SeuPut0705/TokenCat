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
    /// "입력 필요 알림에 소리": off by default; `.sound` permission is asked only when it is turned on (P-5).
    @Published var notifyInputSound: Bool { didSet { persist() } }
    /// "새 버전 자동 확인": on by default; TokenCat's only internet request. Not part of "기본값으로 되돌리기".
    @Published var autoCheckUpdates: Bool { didSet { persist() } }
    /// "새 버전 알림": off by default like every notification; silent, once per version.
    @Published var notifyUpdate: Bool { didSet { persist() } }
    /// The version whose dashboard notice was closed with ✕; a newer version shows again.
    @Published var dismissedUpdateVersion: String? { didSet { persist() } }
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
        notifyInputSound = defaults.bool(forKey: "notifyInputSound")
        autoCheckUpdates = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        notifyUpdate = defaults.bool(forKey: "notifyUpdate")
        // An optional wrapped property already starts as nil; setting the wrapper keeps didSet (and its write) out of init.
        _dismissedUpdateVersion = Published(initialValue: defaults.string(forKey: "dismissedUpdateVersion"))
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
        defaults.set(notifyInputSound, forKey: "notifyInputSound")
        defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates")
        defaults.set(notifyUpdate, forKey: "notifyUpdate")
        defaults.set(dismissedUpdateVersion, forKey: "dismissedUpdateVersion")
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
    /// The display, cat and notification choices that "기본값으로 되돌리기" covers; login item and permission are not here.
    struct Snapshot: Equatable {
        var order: [MetricID], visible: Set<MetricID>, animationSource: RunnerMotion, showRunner: Bool
        var statusBarLayout: StatusBarLayout, notifyTurnComplete: Bool, notifyInput: Bool, notifyInputSound: Bool, notifyUpdate: Bool
    }
    static let defaultSnapshot = Snapshot(order: MetricID.allCases, visible: Set(MetricID.allCases), animationSource: .activity,
                                          showRunner: true, statusBarLayout: .compact, notifyTurnComplete: false, notifyInput: false,
                                          notifyInputSound: false, notifyUpdate: false)
    var snapshot: Snapshot {
        Snapshot(order: order, visible: visible, animationSource: animationSource, showRunner: showRunner, statusBarLayout: statusBarLayout,
                 notifyTurnComplete: notifyTurnComplete, notifyInput: notifyInput, notifyInputSound: notifyInputSound, notifyUpdate: notifyUpdate)
    }
    /// Applies `snapshot` and registers the previous values with `undoManager`, so ⌘Z (and ⇧⌘Z) step back and forth (T-6).
    func restore(_ snapshot: Snapshot, undoManager: UndoManager? = nil) {
        let previous = self.snapshot
        statusBarLayout = snapshot.statusBarLayout
        order = snapshot.order
        visible = snapshot.visible
        showRunner = snapshot.showRunner
        animationSource = snapshot.animationSource
        notifyTurnComplete = snapshot.notifyTurnComplete
        notifyInput = snapshot.notifyInput
        notifyInputSound = snapshot.notifyInputSound
        notifyUpdate = snapshot.notifyUpdate
        undoManager?.registerUndo(withTarget: self) { $0.restore(previous, undoManager: undoManager) }
        undoManager?.setActionName("기본값으로 되돌리기")
    }
    /// Display, cat and notification choices only; login item, automatic update checks and notification permission are untouched.
    func reset(undoManager: UndoManager? = nil) { restore(Self.defaultSnapshot, undoManager: undoManager) }
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
    /// Collector lifecycle from the in-process collector, or from the probe on the verification path
    /// (`.stopped` when no running TokenCat answers). Fixtures may pin it.
    @Published var telemetryState = TelemetryCollectorState.waiting
    /// When the collector's next automatic start runs; nil when none is scheduled and always on the probe path.
    @Published var telemetryNextRetryAt: Date?
    @Published var telemetrySetupNote: String?
    @Published var telemetrySetupFailure: TelemetrySetupFailure?
    /// The last successful connection's status line notes (skipped, original unknown or recreated). Fixtures pin it.
    @Published var telemetryConnectNotes: [TelemetrySetupNote] = []
    /// Whether Claude Code settings run the usage-limit bridge after the last connection; nil until one succeeds.
    @Published var claudeBridged: Bool?
    /// Clients whose config changed and that have not sent a reading since; they need a new launch.
    @Published var telemetryRestartNeeded: Set<TokenSource> = []
    /// Pending for more than 24 h: the client may never send telemetry in its current version.
    @Published private(set) var telemetryRestartExpired: Set<TokenSource> = []
    /// Newest telemetry reading time per client seen by this process.
    @Published private(set) var telemetryLastReceived: [TokenSource: Date] = [:]
    /// Newest batch per client seen by this process, decoded or not ("기록 수신 중 · 속도 형식 없음").
    @Published private(set) var telemetryBatches: [TokenSource: Date] = [:]
    /// Claude usage-limit windows from the status line bridge, kept across launches (numbers and times only). Fixtures pin it.
    @Published var claudeLimits = ClaudeUsageLimits()
    /// Whether ~/.codex/sessions or ~/.claude/projects exists. Checked every 5 s on the token queue, never in a
    /// view body; a folder that appears later restarts the log watcher. Fixtures pin it.
    @Published var logFoldersFound = true
    /// A top-level group (`SessionGroup.id`) the dashboard should select and scroll to, from a notification or the quick menu.
    @Published var focusRequest: String?
    /// Newest `lastOutputAt` across all readings, recomputed on every publish.
    @Published private(set) var newestOutputAt: Date?
    /// The menu-bar cat's quiet reference, shared with the popover header so both fall asleep together.
    @Published var runnerQuietSince: Date?
    @Published private(set) var telemetryReady = false
    /// The single clock for every age and elapsed value shown; views never read `Date()`.
    @Published private(set) var now = Date()
    @Published private(set) var flow = FlowSeries.empty
    @Published private(set) var sessions = SessionListModel.empty
    @Published var sessionsExpanded = false { didSet { if sessionsExpanded != oldValue { rebuildPresentation() } } }
    @Published var popoverShownAt: Date?
    /// Update check and install progress from the app shell's `Updater`; fixtures set it directly.
    @Published var update = UpdateState()
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
    private var lastFolderCheck: Date?
    private var folderCheckInFlight = false
    /// Log folders that existed at the previous check; nil until the first check after start.
    private var foldersSeen: Set<String>?
    static let samplingInterval: TimeInterval = 1
    static let folderCheckInterval: TimeInterval = 5
    /// File events can arrive many times per second while a client streams tool output.
    static let minimumTokenInterval: TimeInterval = 0.25
    private(set) var logEventCount = 0
    var onUpdate: (() -> Void)?
    /// Set by the app shell, so views can open Settings at a section without knowing about windows.
    var settingsRequest: ((SettingsFocus?) -> Void)?
    func showSettings(_ focus: SettingsFocus? = nil) { settingsRequest?(focus) }
    /// Set by the app shell; nil in fixtures and verification commands, where the update buttons do nothing.
    var updateRequest: ((UpdateCommand) -> Void)?
    func requestUpdate(_ command: UpdateCommand) { updateRequest?(command) }
    /// `telemetryProbe` reports whether the running app's collector answers, for verification commands
    /// that read it through `telemetryProvider`. Synthetic fixtures pass `restoresRestartState: false`.
    init(telemetryProvider: (() -> [TelemetryReading])? = nil, telemetryProbe: (() -> Bool)? = nil,
         restoresRestartState: Bool = true) {
        self.telemetryProvider = telemetryProvider
        self.telemetryProbe = telemetryProbe
        let stored = restoresRestartState
            ? UserDefaults.standard.dictionary(forKey: Self.pendingRestartKey) as? [String: Double] ?? [:] : [:]
        for (key, seconds) in stored { if let source = TokenSource(rawValue: key) { pendingRestart[source] = Date(timeIntervalSince1970: seconds) } }
        if restoresRestartState { claudeLimits = ClaudeUsageLimits.load(from: .standard) }
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
    /// Returns the pending focus request once and clears it.
    @discardableResult
    func consumeFocusRequest() -> String? {
        guard let id = focusRequest else { return nil }
        focusRequest = nil
        return id
    }
    /// "지금 다시 시도" (T-3): the collector's scheduled retry runs now; the new state shows on the next publish.
    func retryTelemetryNow() {
        guard telemetryProvider == nil else { return }
        telemetry.retryNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }
    /// "다시 확인": checks the log folders now instead of at the next 5 s tick.
    func recheckLogFolders() {
        guard running else { return }
        checkLogFolders()
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
        lastFolderCheck = nil
        foldersSeen = nil
    }
    private func checkLogFolders() {
        guard running, !folderCheckInFlight else { return }
        folderCheckInFlight = true
        lastFolderCheck = Date()
        let currentGeneration = generation
        tokenQueue.async { [weak self] in
            guard let self else { return }
            let existing = Set(self.tracker.watchedDirectories.map(\.path).filter { FileManager.default.fileExists(atPath: $0) })
            DispatchQueue.main.async {
                self.folderCheckInFlight = false
                guard self.running, self.generation == currentGeneration else { return }
                if self.logFoldersFound != !existing.isEmpty { self.logFoldersFound = !existing.isEmpty }
                let seen = self.foldersSeen
                self.foldersSeen = existing
                // A folder created after the watcher started (first Codex or Claude Code run): watch it and read it now.
                guard let seen, !existing.isSubset(of: seen) else { return }
                self.watcher?.start(directories: self.tracker.watchedDirectories)
                self.refreshTokens()
            }
        }
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
        if lastFolderCheck.map({ Date().timeIntervalSince($0) >= Self.folderCheckInterval }) ?? true { checkLogFolders() }
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
            let claudeLimits = self.telemetryProvider == nil ? self.telemetry.claudeLimits : ClaudeUsageLimits()
            // Verification commands read the running app's collector, never this unstarted one.
            let probed = self.telemetryProbe?()
            let telemetryState = probed.map { $0 ? (measurements.isEmpty ? .waiting : .receiving) : .stopped } ?? self.telemetry.state
            let telemetryStatus = probed == false ? "실측 꺼짐 · 실행 중인 TokenCat 수집기 없음" : telemetryState.status
            let nextRetryAt = probed == nil ? self.telemetry.nextRetryAt : nil
            let telemetryReady = probed ?? (self.telemetryProvider != nil || self.telemetry.isRunning)
            let measuredAt = Date()
            DispatchQueue.main.async {
                self.tokensInFlight = false
                guard self.running, self.generation == currentGeneration else { return }
                self.tokens = tokens
                self.tokensSampledAt = measuredAt
                self.telemetryStatus = telemetryStatus
                if self.telemetryState != telemetryState { self.telemetryState = telemetryState }
                if self.telemetryNextRetryAt != nextRetryAt { self.telemetryNextRetryAt = nextRetryAt }
                if self.telemetryReady != telemetryReady { self.telemetryReady = telemetryReady }
                let lastReceived = self.telemetryLastReceived.merging(received) { max($0, $1) }
                if lastReceived != self.telemetryLastReceived { self.telemetryLastReceived = lastReceived }
                let mergedBatches = self.telemetryBatches.merging(batches) { max($0, $1) }
                if mergedBatches != self.telemetryBatches { self.telemetryBatches = mergedBatches }
                let limits = self.claudeLimits.merged(claudeLimits)
                if limits != self.claudeLimits {
                    self.claudeLimits = limits
                    if self.ownsTelemetryState { limits.save(to: .standard) }
                }
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
        sessions = SessionListModel.make(tokens: tokens, now: now, expanded: sessionsExpanded, flow: flow, restart: telemetryRestartNeeded)
        let newest = tokens.filter { !SessionPresentation.isTelemetry($0) }.compactMap(\.lastOutputAt).max()
        if newest != newestOutputAt { newestOutputAt = newest }
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
    /// "3분 전" / "3m ago"; nil is "기록 없음" / "never".
    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return loc("기록 없음", "never") }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return ago(span(seconds, .second)) }
        if seconds < 3600 { return ago(span(seconds / 60, .minute)) }
        if seconds < 86_400 { return ago(span(seconds / 3600, .hour)) }
        return ago(span(seconds / 86_400, .day))
    }
    static func power(_ snapshot: SystemSnapshot) -> String {
        if snapshot.isCharging == true { return loc("충전 중", "Charging") }
        if snapshot.powerSource == "AC Power" { return loc("전원 어댑터 연결", "On power adapter") }
        if snapshot.powerSource == "Battery Power" { return loc("배터리 사용 중", "On battery") }
        return loc("전원 상태 미확인", "Power source unknown")
    }
    static func elapsed(_ date: Date?, at now: Date) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds >= 3_600 { return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}


/// VoiceOver announcements while the dashboard is visible (P-3): at most one per 5 s; a burst keeps its most urgent text.
struct AnnouncementGate {
    static let interval: TimeInterval = 5
    private(set) var lastAt: Date?
    private(set) var pending: (text: String, priority: Int)?

    /// Returns the text to post now, or how long until `flush` should post the merged one (only for the first held text).
    mutating func offer(_ text: String, priority: Int, now: Date) -> (post: String?, flushAfter: TimeInterval?) {
        if pending == nil, lastAt.map({ now.timeIntervalSince($0) >= Self.interval }) ?? true {
            lastAt = now
            return (text, nil)
        }
        if let held = pending {
            if priority > held.priority { pending = (text, priority) }
            return (nil, nil)
        }
        pending = (text, priority)
        return (nil, max(0, (lastAt ?? now).addingTimeInterval(Self.interval).timeIntervalSince(now)))
    }

    mutating func flush(now: Date) -> (text: String, priority: Int)? {
        guard let held = pending else { return nil }
        pending = nil
        lastAt = now
        return held
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    /// Payload-free hand-off from a second launch; the running instance opens its dashboard and acknowledges.
    static let openRequest = Notification.Name("dev.seuput.TokenCat.openPopover")
    static let openAcknowledged = Notification.Name("dev.seuput.TokenCat.openPopover.ack")
    /// Set while the panel is open; a panel open at quit comes back at launch without taking focus (P-1).
    static let panelWasOpenKey = "panelWasOpen"
    /// The minimum covers the fixed chrome (header, flow card with its speed and both limit rows, titles, system,
    /// footer ≈ 450 pt) plus one row.
    static let panelWidth: CGFloat = 420, panelMinimumHeight: CGFloat = 510
    let model = DashboardModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var statusView: StatusBarContentView?
    private var settingsWindow: NSWindow?
    private var settingsTabs: SettingsTabsController?
    private var panel: NSPanel?
    private var panelEffect: NSVisualEffectView?
    private let notifier = Notifier()
    private let updater = Updater()
    private lazy var settingsState = SettingsState(notifier: notifier)
    private var attention = AttentionTracker()
    private var latestSignals: [String: AttentionSignal] = [:]
    private var clearedStaleInput = false
    /// Turn ends that already played the cat's `content` (signal id and event time), newest last.
    private var playedContent: [String] = []
    private var announcements = AnnouncementGate()
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
    /// The app in front when the popover opened; it gets focus back when the popover closes on its own (M-6).
    private var previousApp: NSRunningApplication?
    private var terminating = false
    private var telemetrySetupInFlight = false
    private var telemetryConfigured = false
    private var updateNotificationStale = false

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
        animator.render = { [weak self] pose, frame, fx in self?.statusView?.updateRunner(pose: pose, frame: frame, fx: fx) }
        animator.replan = { [weak self] in self?.planRunner() }
        notifier.onOpen = { [weak self] group in self?.openDashboard(focus: group) }
        notifier.activate()
        model.onUpdate = { [weak self] in self?.publish() }
        model.settingsRequest = { [weak self] in self?.openSettings(focus: $0) }
        model.updateRequest = { [weak self] in self?.handleUpdate($0) }
        updater.onChange = { [weak self] state in
            guard let self else { return }
            self.model.update = state
            // A delivered "새 버전" notification goes once it no longer applies: nothing newer, installing, or just updated.
            let stale = state.available == nil || state.installing || state.updatedTo != nil
            if stale && !self.updateNotificationStale { self.notifier.removeUpdate() }
            self.updateNotificationStale = stale
        }
        updater.onDiscovered = { [weak self] in self?.updateDiscovered($0) }
        preferenceChanges = model.preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateStatus()
                self.planRunner()
                self.updater.setAutomatic(self.model.preferences.autoCheckUpdates)
            }
        }
        observeSystem()
        model.telemetry.start { [weak self] in
            DispatchQueue.main.async { self?.connectTelemetryAutomatically() }
        }
        model.start()
        updater.start(automatic: model.preferences.autoCheckUpdates)
        publish()
        if UserDefaults.standard.bool(forKey: Self.panelWasOpenKey) {
            // Restored behind the current app: ordered front, never activated or made key.
            model.popoverShownAt = Date()
            makePanel().orderFront(nil)
        }
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

    /// A quit during "설치 중…" waits for that step (a few seconds) so the app bundle is never left mid-swap.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updater.deferQuit { NSApp.reply(toApplicationShouldTerminate: true) } ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The panel's open state stays as it was at quit (windowWillClose must not clear it now).
        terminating = true
        animator.stop()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        updater.stop()
        model.stop()
        model.telemetry.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    /// Opening the app again while it runs shows Settings (the status item may be hidden by the notch).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func dashboardController(_ presentation: DashboardPresentation) -> NSHostingController<DashboardView> {
        let controller = NSHostingController(rootView: DashboardView(model: model, presentation: presentation, actions: dashboardActions))
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private var dashboardActions: DashboardActions {
        DashboardActions(settings: { [weak self] in self?.openSettings() },
                         quit: { NSApp.terminate(nil) },
                         about: { [weak self] in self?.showAbout() },
                         activityMonitor: { [weak self] in self?.openActivityMonitor() },
                         detach: { [weak self] in self?.openPanel() },
                         openTelemetrySettings: { [weak self] in self?.openSettings(focus: .telemetry) })
    }

    /// macOS 14 cooperative activation, the older call on 13.
    private func activateSelf() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
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
        on(workspace, NSWorkspace.didWakeNotification) { $0.updater.systemDidWake() }
        on(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.statusView?.displayOptionsChanged()
            $0.settingsState.refresh()
            $0.updatePanelMaterial()
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
        activity.known = model.tokensSampledAt != nil
        if activity.known { director.observe(activity, now: now) }
        let quiet = director.quietSince(activity)
        if model.runnerQuietSince != quiet { model.runnerQuietSince = quiet }
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
        if settingsWindow != nil, settingsState.runnerPose != animator.plan.pose { settingsState.runnerPose = animator.plan.pose }
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
        let next = Dictionary(signals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Answered (or gone): its "입력 필요" notification is removed, whatever the toggles say now; at the first
        // baseline also those an earlier run left behind.
        if !clearedStaleInput {
            clearedStaleInput = true
            notifier.removeStaleInput(keeping: Set(signals.filter(\.input).map { AttentionEvent.inputIdentifier($0.id) }))
        }
        for (id, before) in latestSignals where before.input && next[id]?.input != true { notifier.removeInput(id) }
        latestSignals = next
        // The baseline always advances, so turning a toggle on later never replays old transitions.
        for event in attention.update(signals) {
            switch event {
            case .input:
                announce("TokenCat 세션 입력 필요", priority: .high)
                guard model.preferences.notifyInput, !dashboardVisible else { continue }
                notifier.post(event, sound: model.preferences.notifyInputSound)
            case .finished(let signal):
                // A Stop hook can continue the turn right after a soft close; act only if it stayed closed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.latestSignals[signal.id]?.live != true else { return }
                    self.turnEnded(signal)
                    self.announce(signal.ended == .interrupted ? "턴 중단" : "턴 완료", priority: .medium)
                    guard self.model.preferences.notifyTurnComplete, !self.dashboardVisible else { return }
                    self.notifier.post(event)
                }
            }
        }
    }

    /// A confirmed turn end plays the cat's `content` once per signal and event time, whatever the notification toggles (K-5).
    private func turnEnded(_ signal: AttentionSignal) {
        let key = "\(signal.id)@\(signal.endedAt?.timeIntervalSince1970 ?? 0)"
        guard !playedContent.contains(key) else { return }
        playedContent.append(key)
        if playedContent.count > 64 { playedContent.removeFirst(playedContent.count - 64) }
        guard model.preferences.showRunner, model.preferences.animationSource == .activity else { return }
        animator.playContent()
    }

    private func announce(_ text: String, priority: NSAccessibilityPriorityLevel) {
        guard dashboardVisible, NSWorkspace.shared.isVoiceOverEnabled else { return }
        let decision = announcements.offer(text, priority: priority.rawValue, now: Date())
        if let text = decision.post { postAnnouncement(text, priority: priority.rawValue) }
        if let delay = decision.flushAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let held = self.announcements.flush(now: Date()), self.dashboardVisible else { return }
                self.postAnnouncement(held.text, priority: held.priority)
            }
        }
    }

    private func postAnnouncement(_ text: String, priority: Int) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority])
    }

    // MARK: Status item, popover and panel

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showQuickMenu() } else { togglePopover() }
    }

    @objc func togglePopover() {
        if let panel, panel.isVisible {
            activateSelf()
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
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        // Built right before showing and released on close, so a closed popover runs no SwiftUI updates (P-6).
        if popover.contentViewController == nil { popover.contentViewController = dashboardController(.popover) }
        activateSelf()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        statusView?.highlighted = true
    }

    /// `focus` (a top-level group id from a notification or the quick menu) is selected once the dashboard shows it.
    func openDashboard(focus: String? = nil) {
        if let focus { model.focusRequest = focus }
        if let panel, panel.isVisible {
            activateSelf()
            panel.makeKeyAndOrderFront(nil)
        } else if !popover.isShown {
            showPopover()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        model.popoverShownAt = Date()
        updater.dashboardOpened()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        // "…로 업데이트했습니다" shows for one showing of the dashboard.
        updater.clearUpdatedNote()
        statusItem.button?.highlight(false)
        statusView?.highlighted = false
        popover.contentViewController = nil
        returnFocus()
    }

    /// Esc or a second click on the item hands focus back to the app that was in front (M-6); not when another app was
    /// clicked (TokenCat is no longer active) or a TokenCat window (Settings, panel, About) is on screen.
    private func returnFocus() {
        guard let app = previousApp else { return }
        previousApp = nil
        guard NSApp.isActive, !app.isTerminated,
              !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
        if #available(macOS 14, *) { _ = app.activate(from: .current, options: []) } else { app.activate(options: []) }
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    /// Dragging the popover off the menu bar leaves the same dashboard in a panel that remembers its frame.
    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        previousApp = nil
        statusItem.button?.highlight(false)
        statusView?.highlighted = false
        model.popoverShownAt = Date()
        UserDefaults.standard.set(true, forKey: Self.panelWasOpenKey)
        return makePanel()
    }

    /// Resizable to the screen height at a fixed 420 pt width; the list fills the height (P-1). Its hosting view keeps
    /// no size constraints, so content changes never move or resize it.
    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let host = NSHostingView(rootView: DashboardView(model: model, presentation: .panel, actions: dashboardActions))
        host.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 560),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "TokenCat"
        // A normal window level: other apps' windows can cover it ("always on top" is not a feature).
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 560))
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
        panelEffect = effect
        updatePanelMaterial()
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        panel.contentMinSize = NSSize(width: Self.panelWidth, height: Self.panelMinimumHeight)
        panel.contentMaxSize = NSSize(width: Self.panelWidth, height: screen?.visibleFrame.height ?? 4_000)
        if panel.setFrameUsingName("TokenCatPanel") {
            let content = panel.contentRect(forFrameRect: panel.frame)
            if content.height < Self.panelMinimumHeight || content.width != Self.panelWidth {
                var frame = panel.frameRect(forContentRect: NSRect(x: content.minX, y: 0, width: Self.panelWidth,
                                                                   height: max(Self.panelMinimumHeight, content.height)))
                frame.origin.y = panel.frame.maxY - frame.height
                panel.setFrame(frame, display: false)
            }
        } else {
            // `fittingSize` is zero without sizing options; measure the popover layout's ideal height instead.
            let ideal = NSHostingController(rootView: DashboardView(model: model, actions: .none))
                .sizeThatFits(in: NSSize(width: Self.panelWidth, height: 10_000)).height
            placeNewPanel(panel, fitting: ideal, screen: screen)
        }
        panel.setFrameAutosaveName("TokenCatPanel")
        self.panel = panel
        return panel
    }

    /// First open: the panel's top-right corner 8 pt below the status item; later opens follow the autosaved frame.
    private func placeNewPanel(_ panel: NSPanel, fitting: CGFloat, screen: NSScreen?) {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let height = min(visible.height, max(Self.panelMinimumHeight, fitting > 0 ? fitting : 560))
        var frame = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: height))
        if let item = statusItem.button?.window?.frame {
            frame.origin = NSPoint(x: item.maxX - frame.width, y: item.minY - 8 - frame.height)
        } else {
            frame.origin = NSPoint(x: visible.maxX - frame.width - 8, y: visible.maxY - 8 - frame.height)
        }
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = max(frame.minY, visible.minY)
        panel.setFrame(frame, display: false)
    }

    /// Popover vibrancy; Reduce Transparency uses the window background.
    private func updatePanelMaterial() {
        panelEffect?.material = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .windowBackground : .popover
    }

    /// Returning from System Settings (login item approval, notification permission) re-reads the real status.
    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { settingsState.refresh() }
    }

    /// Closed windows are released so their SwiftUI views stop re-rendering on every model publish.
    /// Frames are remembered by their autosave names.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow?.contentViewController = nil
            settingsWindow = nil
            settingsTabs = nil
        } else if window === panel {
            if !terminating {
                UserDefaults.standard.set(false, forKey: Self.panelWasOpenKey)
                updater.clearUpdatedNote()
            }
            panel?.contentView = nil
            panel = nil
            panelEffect = nil
        }
    }

    @objc private func openPanel() {
        previousApp = nil
        popover.performClose(nil)
        let panel = makePanel()
        model.popoverShownAt = Date()
        updater.dashboardOpened()
        activateSelf()
        panel.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: Self.panelWasOpenKey)
    }

    // MARK: Updates

    /// Install is only ever started here, from a button or menu item.
    private func handleUpdate(_ command: UpdateCommand) {
        switch command {
        case .check:
            updater.checkNow()
        case .install:
            updater.install()
        case .openReleasePage:
            previousApp = nil
            NSWorkspace.shared.open(model.update.available?.page ?? UpdateClient.releases)
        case .dismiss:
            let preferences = model.preferences
            guard let notice = model.update.notice(dismissed: preferences.dismissedUpdateVersion) else { return }
            switch notice.kind {
            case .updated:
                updater.clearUpdatedNote()
            case .available, .failed:
                updater.clearFailure()
                if !notice.version.isEmpty { preferences.dismissedUpdateVersion = notice.version }
                model.objectWillChange.send()
            case .downloading, .installing:
                break
            }
        }
    }

    /// "새 버전 알림": silent, once per version, not while the dashboard already shows the notice.
    private func updateDiscovered(_ release: UpdateRelease) {
        let preferences = model.preferences
        guard preferences.notifyUpdate, !dashboardVisible, release.version != preferences.dismissedUpdateVersion else { return }
        notifier.postUpdate(release)
    }

    /// The quick menu item: an install opens the dashboard to show the progress; after a failure that blocks the
    /// install, the release page.
    @objc private func quickMenuUpdateAction() {
        switch model.update.quickMenuCommand {
        case .install?:
            updater.install()
            openDashboard()
        case let command?:
            handleUpdate(command)
        case nil:
            break
        }
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

    /// Invisible for an accessory app, but gives the popover, Settings and the panel ⌘, ⌘Q ⌘W, copy and undo.
    private func installMainMenu() {
        let main = NSMenu()
        let quit = NSMenuItem(title: "TokenCat 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu("TokenCat", [menuItem("TokenCat 정보", #selector(showAbout)), .separator(),
                                          menuItem("설정…", #selector(openSettingsAction), key: ","), .separator(), quit]))
        let redo = NSMenuItem(title: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(submenu("편집", [NSMenuItem(title: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z"), redo, .separator(),
                                     NSMenuItem(title: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                                     NSMenuItem(title: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")]))
        main.addItem(submenu("윈도우", [NSMenuItem(title: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")]))
        main.items.forEach { $0.submenu?.autoenablesItems = true }
        NSApp.mainMenu = main
    }

    /// Live summary first (M-5), then the controls. Built at open and not refreshed while the menu stays open.
    private func showQuickMenu() {
        if popover.isShown { popover.performClose(nil) }
        let preferences = model.preferences
        let menu = NSMenu()
        menu.autoenablesItems = false
        let summary = QuickMenuSummary.make(groups: model.groups, counts: model.sessions.counts,
                                            hasTokenSample: model.tokensSampledAt != nil, now: model.now)
        menu.addItem(menuItem(summary.headline, #selector(openDashboardAction), enabled: false))
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        for row in summary.rows {
            let item = menuItem(row.title, #selector(focusGroup(_:)), value: row.id)
            item.image = row.kind == .waiting ? StatusBarContentView.waitingGlyph(side: 10, contrast: contrast)
                : StateGlyph.image(row.kind, side: 10, highlighted: false, contrast: contrast)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = menuItem("열기", #selector(openDashboardAction))
        open.keyEquivalentModifierMask = []
        let asPanel = menuItem("패널로 열기", #selector(openPanel))
        asPanel.keyEquivalentModifierMask = [.option]
        asPanel.isAlternate = true
        menu.addItem(open)
        menu.addItem(asPanel)
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
        if let title = model.update.quickMenuTitle { menu.addItem(menuItem(title, #selector(quickMenuUpdateAction))) }
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
    @objc private func focusGroup(_ sender: NSMenuItem) { openDashboard(focus: sender.representedObject as? String) }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func toggleRunner() { model.preferences.setShowRunner(!model.preferences.showRunner) }
    @objc private func openActivityMonitor() {
        previousApp = nil
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
    @objc private func selectLayout(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let layout = StatusBarLayout(rawValue: raw) { model.preferences.statusBarLayout = layout }
    }
    @objc private func selectMotion(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let motion = RunnerMotion(rawValue: raw) { model.preferences.animationSource = motion }
    }
    @objc func showAbout() {
        previousApp = nil
        activateSelf()
        NSApp.orderFrontStandardAboutPanel(options: AppInfo.aboutOptions)
    }

    /// "처음 안내 다시 보기": the first-run card shows again in the dashboard.
    private func reshowOnboarding() {
        UserDefaults.standard.set(false, forKey: "onboardingSeen")
        openDashboard()
    }

    func openSettings(focus: SettingsFocus? = nil) {
        previousApp = nil
        popover.performClose(nil)
        settingsState.runnerPose = animator.plan.pose
        if settingsWindow == nil {
            let tabs = SettingsTabsController(preferences: model.preferences, model: model, state: settingsState,
                                              actions: SettingsActions(reshowOnboarding: { [weak self] in self?.reshowOnboarding() }))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsTabsController.width, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            SettingsTabsController.configure(window, with: tabs)
            window.delegate = self
            if !window.setFrameUsingName("TokenCatSettingsTabs") { window.center() }
            window.setFrameAutosaveName("TokenCatSettingsTabs")
            settingsWindow = window
            settingsTabs = tabs
        }
        if focus == .telemetry { settingsTabs?.select(.telemetry) }
        settingsState.refresh()
        activateSelf()
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
            "runnerDeepSleep": animator.isDeepSleep,
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
            var result: TelemetrySetupResult?
            do {
                result = try TelemetrySetup().connect()
                message = nil
            } catch {
                message = OnboardingCard.notePrefix + error.localizedDescription
                failure = (error as? TelemetrySetupError)?.failure ?? .writeFailed(restored: true)
            }
            DispatchQueue.main.async {
                self?.telemetrySetupInFlight = false
                self?.telemetryConfigured = message == nil
                self?.model.telemetrySetupNote = message
                self?.model.telemetrySetupFailure = failure
                // The status line notes are shown on the 실측 tab and decide the first-run card's sentence.
                self?.model.telemetryConnectNotes = result?.notes ?? []
                self?.model.claudeBridged = result?.bridged
                // Running clients keep their old config; remember to say so until each one reports.
                self?.model.noteTelemetryConnected(result?.restartRequired ?? [])
            }
        }
    }
}
