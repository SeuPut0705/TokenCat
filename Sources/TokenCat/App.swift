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
    let preferences = Preferences()
    let telemetry = LocalTelemetryCollector()
    private let telemetryProvider: (() -> [TelemetryReading])?
    private let sampler = SystemSampler()
    private let tracker = TokenTracker()
    private let systemQueue = DispatchQueue(label: "dev.seuput.TokenCat.system", qos: .utility)
    private let tokenQueue = DispatchQueue(label: "dev.seuput.TokenCat.tokens", qos: .utility)
    private var timer: Timer?
    private var systemInFlight = false
    private var tokensInFlight = false
    private var running = false
    private var generation: UInt64 = 0
    static let samplingInterval: TimeInterval = 1
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
    }
    func stop() {
        running = false
        generation &+= 1
        timer?.invalidate()
        timer = nil
    }
    func refresh() {
        guard running else { return }
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
                    self.onUpdate?()
                }
            }
        }
        if !tokensInFlight {
            tokensInFlight = true
            tokenQueue.async { [weak self] in
                guard let self else { return }
                let logs = self.tracker.sample()
                let measurements = self.telemetryProvider?() ?? self.telemetry.snapshot()
                let tokens = TokenSpeed.apply(logs, measurements: measurements)
                let telemetryStatus = self.telemetry.status
                let measuredAt = Date()
                DispatchQueue.main.async {
                    self.tokensInFlight = false
                    guard self.running, self.generation == currentGeneration else { return }
                    self.tokens = tokens
                    self.tokensSampledAt = measuredAt
                    self.telemetryStatus = telemetryStatus
                    self.onUpdate?()
                }
            }
        }
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
    static func age(_ date: Date?) -> String {
        guard let date else { return "기록 없음" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
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

struct Sparkline: View {
    var values: [Double]
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                Path { path in
                    guard values.count > 1 else { return }
                    for (index, value) in values.enumerated() {
                        let point = CGPoint(x: geometry.size.width * Double(index) / Double(values.count - 1), y: (geometry.size.height - 2) * (1 - min(100, max(0, value)) / 100) + 1)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityLabel("최근 CPU 사용률")
    }
}

struct MetricTile: View {
    var icon: String
    var title: String
    var value: String
    var detail: String
    var fraction: Double? = nil
    var history: [Double]? = nil
    var height: CGFloat = 70
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 11, weight: .medium)).fixedSize()
                Spacer(minLength: 0)
                Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1)
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let history {
                Sparkline(values: history).frame(height: 15)
            } else if let fraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2).fill(fraction > 0.85 ? Color.orange : Color.accentColor)
                            .frame(width: geometry.size.width * min(1, max(0, fraction)))
                    }
                }.frame(height: 3)
            }
        }.padding(8).frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct NetworkTile: View {
    var system: SystemSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "network").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("네트워크").font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                Text("↑\(StatusBarContent.networkRate(system.uploadBytesPerSecond))  ↓\(StatusBarContent.networkRate(system.downloadBytesPerSecond))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
            }
            Text(system.localIPs.isEmpty ? "IPv4 주소 미확인" : system.localIPs.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.padding(8).frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .topLeading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SystemGrid: View {
    var system: SystemSnapshot
    var cpuHistory: [Double]
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                MetricTile(icon: "cpu", title: "CPU", value: Format.percent(system.cpuPercent), detail: "전체 코어 사용률", history: cpuHistory)
                MetricTile(icon: "memorychip", title: "메모리", value: Format.percent(Format.ratio(system.memoryUsedBytes, system.memoryTotalBytes)), detail: Format.capacity(system.memoryUsedBytes, system.memoryTotalBytes), fraction: Format.ratio(system.memoryUsedBytes, system.memoryTotalBytes).map { $0 / 100 })
                    .help("\(Format.bytes(system.memoryUsedBytes)) / \(Format.bytes(system.memoryTotalBytes))")
                MetricTile(icon: "internaldrive", title: "저장 공간", value: Format.percent(Format.ratio(system.diskUsedBytes, system.diskTotalBytes)), detail: Format.capacity(system.diskUsedBytes, system.diskTotalBytes), fraction: Format.ratio(system.diskUsedBytes, system.diskTotalBytes).map { $0 / 100 })
                    .help("\(Format.bytes(system.diskUsedBytes)) / \(Format.bytes(system.diskTotalBytes))")
            }
            HStack(spacing: 6) {
                if system.batteryPresent {
                    MetricTile(icon: "battery.75percent", title: "배터리", value: Format.percent(system.batteryPercent), detail: Format.power(system), height: 50)
                        .frame(width: 128)
                }
                NetworkTile(system: system)
            }
        }
    }
}

struct DashboardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

struct SessionRow: View {
    var reading: TokenReading
    var now: Date
    private var hasLiveStatus: Bool { reading.currentTurnStartedAt != nil || reading.active || reading.activityState == .stale }
    static func height(for reading: TokenReading) -> CGFloat {
        let live = reading.currentTurnStartedAt != nil || reading.active || reading.activityState == .stale
        let previous = reading.speedMeasurement?.tokensPerSecond != nil && reading.speedMeasurement?.model != reading.model
        return 44 + (live ? 17 : 0) + (previous ? 17 : 0)
    }
    private var activityTitle: String {
        switch reading.activityState {
        case .idle: return "기록 대기"
        case .working: return "진행"
        case .tool: return "도구 실행"
        case .output: return "출력 기록"
        case .complete: return "완료"
        case .interrupted: return "중단"
        case .stale: return "로그 대기"
        }
    }
    private var hasPreviousModel: Bool {
        reading.speedMeasurement?.tokensPerSecond != nil && reading.speedMeasurement?.model != reading.model
    }
    private var shortID: String {
        if reading.sessionID == nil && reading.agentID == nil && reading.speedMeasurement != nil { return "" }
        if let agent = reading.agentID, !agent.isEmpty {
            return agent.contains("/") ? URL(fileURLWithPath: agent).lastPathComponent : String(agent.prefix(8))
        }
        let identifier = reading.sessionID ?? URL(fileURLWithPath: reading.id).deletingPathExtension().lastPathComponent
        // UUIDv7 prefixes are timestamps shared by conversations created together.
        return String(identifier.suffix(8))
    }
    private var sessionLabel: String {
        var parts = [reading.project, shortID].compactMap { $0 }.filter { !$0.isEmpty }
        if reading.isSubagent { parts.append("하위 세션") }
        return parts.joined(separator: " · ")
    }
    private var identityDetails: String {
        [reading.project, reading.agentID.map { "에이전트 \($0)" }, reading.sessionID.map { "세션 \($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
    }
    private var details: String {
        [identityDetails, reading.status, reading.speedMeasurement?.details ?? "속도 미측정 · 실측 데이터 연결 대기", reading.lastOutputTokens.map { "세션 출력 기록 \($0.formatted()) tokens" }, reading.currentTurnOutputTokens.map { "현재 턴에서 확인된 출력 \($0.formatted()) tokens" }]
            .compactMap { $0 }.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(reading.activityState == .stale ? Color.orange : (reading.active ? Color.green : Color.secondary.opacity(0.3))).frame(width: 5, height: 5)
                    .accessibilityLabel(reading.active ? "최근 로그 활동 있음" : "최근 로그 활동 없음")
                Text(reading.source == .codex ? "Codex" : "Claude")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
                Text(reading.model ?? "모델 기록 대기").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .help(reading.model ?? "모델 미확인")
                Spacer(minLength: 4)
                Text(hasPreviousModel ? "—" : Format.tps(reading.speedMeasurement?.tokensPerSecond))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(reading.speedMeasurement?.kind?.title ?? "tok/s")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            }
            HStack(spacing: 6) {
                Text(sessionLabel).lineLimit(1).help(identityDetails)
                Spacer(minLength: 4)
                Text(reading.activityState == .interrupted
                     ? "중단 \(Format.age(reading.lastActivity))"
                     : "\(reading.speedMeasurement == nil ? "활동" : "측정") \(Format.age(reading.speedMeasurement?.at ?? reading.lastActivity))").fixedSize()
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            if hasLiveStatus {
                HStack(spacing: 6) {
                    Text("\(activityTitle) \(Format.elapsed(reading.currentTurnStartedAt, at: now))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(reading.activityState == .stale ? Color.orange : Color.accentColor)
                    if let output = reading.currentTurnOutputTokens {
                        Text(output > 0 ? "기록 \(output.formatted()) tok" : "출력 기록 대기").foregroundStyle(.secondary)
                    } else {
                        Text("누적 미확인").foregroundStyle(.secondary)
                            .help("현재 턴의 시작 또는 전체 토큰 구간을 읽지 못해 누적량을 계산할 수 없습니다. 최근 증가량은 별도로 표시합니다.")
                    }
                    Spacer(minLength: 0)
                    if let at = reading.lastOutputAt, let delta = reading.lastOutputDelta,
                       delta > 0, now.timeIntervalSince(at) >= -5, now.timeIntervalSince(at) <= 5 {
                        Text("+\(delta.formatted()) tok").foregroundStyle(.green)
                    }
                }.font(.system(size: 10)).lineLimit(1)
            }
            if hasPreviousModel {
                HStack(spacing: 4) {
                    Text("이전 \(reading.speedMeasurement?.model ?? "모델 미확인")").lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Format.tps(reading.speedMeasurement?.tokensPerSecond)) \(reading.speedMeasurement?.kind?.title ?? "tok/s")").fixedSize()
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 10).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.height(for: reading))
            .help(details).accessibilityElement(children: .combine).accessibilityHint(details)
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var settings: () -> Void
    var quit: () -> Void
    var scrollsSessions = true
    @State private var showAllSessions = false
    private func recentModelMeasurement(_ reading: TokenReading) -> Bool {
        guard reading.sessionID == nil, let measurement = reading.speedMeasurement,
              measurement.tokensPerSecond != nil else { return false }
        let age = model.system.sampledAt.timeIntervalSince(measurement.at)
        return age >= -5 && age < 120
    }
    private var sessions: [TokenReading] {
        model.tokens.sorted {
            let firstMeasured = recentModelMeasurement($0)
            let secondMeasured = recentModelMeasurement($1)
            if firstMeasured != secondMeasured { return firstMeasured }
            if $0.active != $1.active { return $0.active }
            if $0.active {
                if $0.project != $1.project { return ($0.project ?? "") < ($1.project ?? "") }
                return $0.id < $1.id
            }
            let first = $0.lastActivity ?? $0.measurementAt ?? .distantPast
            let second = $1.lastActivity ?? $1.measurementAt ?? .distantPast
            if first != second { return first > second }
            return $0.id < $1.id
        }
    }
    private var defaultSessionCount: Int { max(6, sessions.filter { $0.active || recentModelMeasurement($0) }.count) }
    private var displayedSessions: [TokenReading] { showAllSessions ? sessions : Array(sessions.prefix(defaultSessionCount)) }
    private var listHeight: CGFloat {
        var height: CGFloat = 0
        for reading in displayedSessions {
            let row = SessionRow.height(for: reading)
            let next = height + (height > 0 ? 1 : 0) + row
            if next > 190 { break }
            height = next
        }
        return height
    }
    private var sessionRows: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).id("session-list-top")
            ForEach(displayedSessions) { reading in
                SessionRow(reading: reading, now: model.system.sampledAt)
                if reading.id != displayedSessions.last?.id { Divider().padding(.horizontal, 10) }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(nsImage: Runner.brandImage()).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TokenCat").font(.system(size: 15, weight: .semibold))
                    Text("Mac · AI 활동").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: settings) { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 28) }.help("표시 항목·순서 설정").accessibilityLabel("설정")
                Button(action: quit) { Image(systemName: "power").frame(width: 24, height: 28) }.help("종료").accessibilityLabel("종료")
            }
            HStack {
                Text("AI 세션").font(.system(size: 12, weight: .semibold))
                    .help(model.telemetrySetupNote ?? model.telemetryStatus)
                Spacer()
                if sessions.count > defaultSessionCount {
                    Button(showAllSessions ? "접기" : "모두 \(sessions.count)개") { showAllSessions.toggle() }
                        .font(.system(size: 11))
                }
            }
            if sessions.isEmpty {
                Text("Codex·Claude Code 세션 기록을 기다리는 중")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            } else {
                Group {
                    if scrollsSessions {
                        ScrollViewReader { scroll in
                            ScrollView { sessionRows }
                                .onChange(of: showAllSessions) { _ in scroll.scrollTo("session-list-top", anchor: .top) }
                        }
                    } else {
                        // ImageRenderer cannot rasterize AppKit's scroll surface.
                        // Export the same rows at the same viewport without interaction.
                        sessionRows.fixedSize(horizontal: false, vertical: true)
                            .frame(height: listHeight, alignment: .top).clipped()
                    }
                }.frame(height: listHeight)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }
            HStack {
                Text("시스템").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("전체 Mac").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            SystemGrid(system: model.system, cpuHistory: model.cpuHistory)
            Divider()
            HStack {
                Button("활성 상태 보기") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
                Spacer()
                HStack(spacing: 4) {
                    let fresh = model.hasSample && Date().timeIntervalSince(model.system.sampledAt) < max(3, DashboardModel.samplingInterval * 3)
                    Circle().fill(fresh ? Color.green : Color.orange).frame(width: 4, height: 4)
                    Text(fresh ? "LIVE" : "수집 대기")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("시스템 측정 \(Format.age(model.system.sampledAt)) · AI 기록 수집 \(Format.age(model.tokensSampledAt))")
            }.font(.system(size: 11))
        }.padding(14).frame(width: 420).buttonStyle(DashboardButtonStyle())
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
            Spacer()
            Button("기본값으로 되돌리기") { preferences.reset(); changed() }
        }.padding(20).frame(width: 360, height: 450)
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
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model, settings: { [weak self] in self?.openSettings() }, quit: { NSApp.terminate(nil) }))
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
        let metrics = StatusBarContent.metrics(system: model.system, tokens: model.tokens,
            preferences: preferences, hasSample: model.hasSample, hasTokenSample: model.tokensSampledAt != nil)
        statusView.update(metrics: metrics, layout: preferences.statusBarLayout, showRunner: preferences.showRunner)
        statusItem.length = statusView.requiredWidth
        statusView.frame = NSRect(x: 0, y: 0, width: statusView.requiredWidth,
            height: button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness)
        statusView.updateRunner(frame: max(0, lastAnimationFrame))
        button.title = ""
        button.image = nil
        let details = metrics.map(\.detail).joined(separator: "\n")
        button.toolTip = "TokenCat\n\(details)\n속도는 세션 목록에서 확인할 수 있습니다."
        button.setAccessibilityValue(details)
        button.setAccessibilityHelp("메뉴를 열어 세션별 모델과 속도, 시스템 상세 수치를 확인합니다.")
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
        let metrics = StatusBarContent.metrics(system: model.system, tokens: model.tokens,
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
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: url.deletingPathExtension().appendingPathExtension("png"))
                }
            }
        } catch { print("메뉴 막대 확인 파일 저장 실패: \(error.localizedDescription)") }
    }
    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "TokenCat 설정"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreferencesView(preferences: model.preferences,
                changed: { [weak self] in self?.updateStatus() }))
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
