import Accessibility
import AppKit
import SwiftUI

// MARK: - Shared styles

private struct HighContrastKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Increase Contrast, or forced by fixture snapshots because `colorSchemeContrast` cannot be injected.
    var tokenCatHighContrast: Bool {
        get { self[HighContrastKey.self] }
        set { self[HighContrastKey.self] = newValue }
    }
}

private struct CardBackground: ViewModifier {
    @Environment(\.tokenCatHighContrast) private var high
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return content
            .background(Color.primary.opacity(0.035), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(high ? 0.18 : 0.07), lineWidth: 1))
    }
}

/// `.tertiary` text, raised to `.secondary` under Increase Contrast.
private struct FaintText: ViewModifier {
    @Environment(\.tokenCatHighContrast) private var high
    func body(content: Content) -> some View { content.foregroundStyle(high ? HierarchicalShapeStyle.secondary : .tertiary) }
}

/// Copy and reveal only, mirrored as VoiceOver actions; file contents are never opened.
private struct RowActions: ViewModifier {
    var reading: TokenReading
    func body(content: Content) -> some View {
        let actions = SessionPresentation.rowActions(reading)
        return content
            .contextMenu { ForEach(actions) { action in Button(action.title) { Self.perform(action) } } }
            .accessibilityActions { ForEach(actions) { action in Button(action.title) { Self.perform(action) } } }
    }
    static func perform(_ action: SessionPresentation.RowAction) {
        switch action.kind {
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

extension View {
    fileprivate func card() -> some View { modifier(CardBackground()) }
    fileprivate func faint() -> some View { modifier(FaintText()) }
    fileprivate func rowActions(_ reading: TokenReading) -> some View { modifier(RowActions(reading: reading)) }
}

struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverLabel(configuration: configuration) }
    private struct HoverLabel: View {
        var configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? HierarchicalShapeStyle.primary : .secondary)
                .background(hovering ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovering = $0 }
        }
    }
}

struct Sparkline: View {
    var values: [Double]
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: geometry.size.width * Double(index) / Double(values.count - 1),
                                        y: (geometry.size.height - 2) * (1 - min(100, max(0, value)) / 100) + 1)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// State colour plus shape: input is a yellow "?" disc, an API retry is an arrow, the rest are dots.
struct StateMark: View {
    var state: SessionDisplayState
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        switch state {
        case .input:
            ZStack {
                Circle().fill(state.color)
                Circle().strokeBorder(Color.primary.opacity(high ? 0.5 : 0.25), lineWidth: 0.5)
                Text("?").font(.system(size: 8, weight: .heavy)).foregroundStyle(Color.black.opacity(0.8))
            }.frame(width: 10, height: 10)
        case .retrying:
            Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .bold)).foregroundStyle(state.color)
                .frame(width: 10, height: 10)
        case .interrupted:
            Circle().strokeBorder(high ? HierarchicalShapeStyle.secondary : .tertiary, lineWidth: 1.5).frame(width: 6, height: 6)
        case .unfinished:
            // Under Increase Contrast the dashed ring turns solid; the row text already says "종료 기록 없음".
            Circle().strokeBorder(high ? HierarchicalShapeStyle.secondary : .tertiary,
                                  style: StrokeStyle(lineWidth: 1.5, dash: high ? [] : [1.4, 1.4])).frame(width: 6, height: 6)
        default:
            Circle().fill(state.color).frame(width: 6, height: 6)
        }
    }
}

struct StateChip: View {
    var state: SessionDisplayState
    var text: String
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        HStack(spacing: 4) {
            StateMark(state: state)
            Text(text).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.primary).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2).frame(height: 17)
        .background(state.color.opacity(high ? 0.28 : 0.16), in: Capsule())
        .overlay { if high { Capsule().strokeBorder(state.color.opacity(0.6), lineWidth: 1) } }
        .fixedSize()
    }
}

private struct ListDivider: View {
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        Group {
            if high { Rectangle().fill(Color.primary.opacity(0.2)).frame(height: 1) } else { Divider() }
        }.padding(.horizontal, 10)
    }
}

/// Recorded volume bars: the base layer plus the buckets holding a record from the last 5 s in green.
struct RecordBars: View {
    var row: FlowSeries.Row?
    var count: Int
    var scale: Double
    var minHeight: CGFloat = 2
    var minWidth: CGFloat = 1
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        let values = row?.buckets ?? Array(repeating: 0, count: count)
        ZStack {
            FlowBars(values: values, scale: scale, minHeight: minHeight, minWidth: minWidth).fill(Color.primary.opacity(high ? 0.6 : 0.4))
            FlowBars(values: values, scale: scale, mask: row?.fresh ?? [], minHeight: minHeight, minWidth: minWidth).fill(Color.green)
        }.accessibilityHidden(true)
    }
}

struct SpeedLabel: View {
    var slot: SpeedSlot
    var numberSize: CGFloat = 11.5
    /// Idle rows show only "—" when nothing was measured.
    var compactUnknown = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if slot.known {
                if let prefix = slot.prefix { Text(prefix + " ").font(.system(size: 10)).faint() }
                Text(slot.value).font(.system(size: numberSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(slot.prefix == nil && slot.recent ? HierarchicalShapeStyle.primary : .secondary)
                Text(" " + (slot.kind ?? "tok/s")).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(compactUnknown ? "—" : "— tok/s").font(.system(size: 10.5).monospacedDigit()).faint()
            }
        }
        .lineLimit(1).fixedSize().help(slot.help)
    }
}

struct ContextLabel: View {
    var slot: ContextSlot
    var body: some View {
        HStack(spacing: 4) {
            if let fraction = slot.fraction {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(slot.warning ? Color.orange : Color.primary.opacity(0.45)).frame(width: max(1.5, 28 * fraction))
                }.frame(width: 28, height: 3)
            }
            Text(slot.text).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
        }
        .lineLimit(1).fixedSize().help(slot.help)
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var settings: () -> Void
    var quit: () -> Void
    /// False for ImageRenderer snapshots: no scroll surface and no first-run card.
    var scrollsSessions = true
    /// Fixtures pin this; nil checks the two log folders when the list is empty.
    var logFoldersFound: Bool? = nil
    @AppStorage("onboardingSeen") private var onboardingSeen = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tokenCatHighContrast) private var forcedContrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if scrollsSessions && !onboardingSeen {
                OnboardingCard(notice: telemetryNotice, note: setupNote, failure: model.telemetrySetupFailure, ready: model.telemetryReady,
                               settings: { onboardingSeen = true; model.showSettings(.telemetry) }, dismiss: { onboardingSeen = true }).padding(.top, 10)
            }
            FlowCard(flow: model.flow, counts: model.sessions.counts, now: model.now, tokensSampledAt: model.tokensSampledAt)
                .padding(.top, 10)
            if let limit = model.sessions.usageLimit, limit.isShown(now: model.now) {
                UsageLimitCard(limit: limit, now: model.now).padding(.top, 8)
            }
            SessionsHeader(model: model).padding(.top, 12)
            SessionList(model: model, scrolls: scrollsSessions, logFoldersFound: logFoldersFound).padding(.top, 6)
            SystemStrip(system: model.system, cpuHistory: model.cpuHistory, hasSample: model.hasSample).padding(.top, 10)
            footer.padding(.top, 8)
        }
        .padding(.top, 12).padding(.horizontal, 14).padding(.bottom, 12)
        .frame(width: 420)
        .buttonStyle(HoverButtonStyle())
        .environment(\.tokenCatHighContrast, forcedContrast || contrast == .increased)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: Runner.brandImage()).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22).accessibilityHidden(true)
            Text("TokenCat").font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 8) {
                Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 13)).frame(width: 24, height: 24) }
                    .help("설정 (⌘,)").accessibilityLabel("설정").keyboardShortcut(",")
                Button(action: quit) { Image(systemName: "power").font(.system(size: 13)).frame(width: 24, height: 24) }
                    .help("TokenCat 종료 (⌘Q) · 실측 수집도 멈춥니다").accessibilityLabel("종료").keyboardShortcut("q")
            }
        }.frame(height: 24)
    }

    private var freshness: (text: String, color: Color) {
        guard model.hasSample, let tokens = model.tokensSampledAt else { return ("수집 준비 중", Color.primary.opacity(0.3)) }
        let tokenDelay = Int(model.now.timeIntervalSince(tokens))
        let systemDelay = Int(model.now.timeIntervalSince(model.system.sampledAt))
        if tokenDelay > 3 { return ("AI 수집 지연 \(tokenDelay)초", .orange) }
        if systemDelay > 3 { return ("시스템 수집 지연 \(systemDelay)초", .orange) }
        return ("실시간", .green)
    }

    private var telemetryStatus: String { model.telemetryStatus }
    private var setupNote: String? { model.telemetrySetupNote }
    /// Per-client receipt and the clients still silent a day after their config changed.
    private var telemetryLastReceived: [TokenSource: Date] { model.telemetryLastReceived }
    private var telemetryRestartExpired: Set<TokenSource> { model.telemetryRestartExpired }
    private var telemetryNotice: TelemetryNotice? {
        SessionPresentation.telemetryNotice(ready: model.telemetryReady, status: telemetryStatus, note: setupNote, failure: model.telemetrySetupFailure,
                                            restart: model.telemetryRestartNeeded, expired: telemetryRestartExpired)
    }

    private var footer: some View {
        let notice = telemetryNotice
        let fresh = freshness
        return HStack(spacing: 0) {
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) } label: {
                Label("활성 상태 보기", systemImage: "arrow.up.forward.app").font(.system(size: 11))
                    .padding(.horizontal, 5).frame(height: 18)
            }.padding(.leading, -5)
            Spacer(minLength: 8)
            if let notice {
                Button { model.showSettings(.telemetry) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: notice.isProblem ? "exclamationmark.circle" : "arrow.clockwise.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(notice.isProblem ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        Text(notice.text).font(.system(size: 11)).lineLimit(1)
                    }
                    .padding(.horizontal, 5).frame(height: 18)
                }
                .fixedSize()
                .help(notice.help)
                .accessibilityLabel(notice.text)
                .accessibilityHint("설정을 엽니다")
                .padding(.trailing, 5)
            }
            HStack(spacing: 4) {
                Circle().fill(fresh.color).frame(width: 6, height: 6)
                Text(fresh.text).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .fixedSize()
            .help("시스템과 AI 기록을 1초마다, 로그 변경 시 즉시 확인합니다\n\(SessionPresentation.telemetryReceipt(telemetryLastReceived, now: model.now))\n\(telemetryStatus)")
            .accessibilityElement(children: .combine)
        }.frame(height: 18)
    }
}

// MARK: - First run

/// Shown once in the interactive popover, never in snapshots; dismissal is remembered.
/// The telemetry line says only what actually happened: collector down, setup skipped, still starting or added.
struct OnboardingCard: View {
    var notice: TelemetryNotice?
    var note: String?
    var failure: TelemetrySetupFailure?
    var ready = true
    var settings: () -> Void
    var dismiss: () -> Void
    static let backupPath = "~/Library/Application Support/TokenCat/telemetry-backups"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("TokenCat이 하는 일").font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 18) }
                    .help("안내 닫기").accessibilityLabel("안내 닫기")
            }
            bullet("Codex·Claude Code 로컬 기록에서 모델·토큰 수·도구 종류·프로젝트 폴더 같은 메타데이터만 사용하고 대화 본문은 저장하지 않습니다")
            if let notice, notice.collectorDown {
                bullet("실측 연결을 하지 않았습니다 · \(notice.text)")
            } else if let note {
                let reason = note.replacingOccurrences(of: "실측 연결: ", with: "")
                bullet((failure == .conflict || failure == .invalid ? "실측 연결을 건너뛰었습니다: " : "실측 연결을 완료하지 못했습니다: ") + reason)
            } else if !ready {
                bullet("실측 수집기를 준비하고 있습니다. 준비되면 Codex·Claude Code 설정에 로컬 전송을 추가합니다")
            } else {
                bullet("실측을 받으려고 Codex·Claude Code 설정에 로컬 전송을 추가했습니다", detail: "원본 백업 \(Self.backupPath)")
                bullet("다음에 새로 실행한 Codex·Claude Code부터 적용됩니다")
            }
            bullet("모델 호출·계정 로그인을 하지 않습니다. 로그인 시 열기와 알림은 직접 켠 경우에만 동작합니다")
            HStack(spacing: 6) {
                Spacer()
                Button(action: settings) { Text("설정 열기").font(.system(size: 11)).padding(.horizontal, 6).frame(height: 20) }
                Button(action: dismiss) { Text("확인").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).frame(height: 20) }
                    .keyboardShortcut(.defaultAction)
            }.padding(.top, 1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .card()
    }

    private func bullet(_ text: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("•").font(.system(size: 11)).faint()
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(.system(size: 10.5)).faint().lineLimit(1).truncationMode(.middle) }
            }
        }
    }
}

// MARK: - Flow card

/// The 60 hero buckets for VoiceOver's audio graph and data table.
struct FlowChartDescriptor: AXChartDescriptorRepresentable {
    var values: [Int]
    func makeChartDescriptor() -> AXChartDescriptor {
        let span = Double(max(0, values.count - 1)) * FlowSeries.bucketSeconds
        let x = AXNumericDataAxisDescriptor(title: "시간", range: -span...0, gridlinePositions: []) { value in
            value >= 0 ? "지금" : "\(Int(-value))초 전"
        }
        let y = AXNumericDataAxisDescriptor(title: "출력 토큰", range: 0...Double(max(values.max() ?? 0, 1)), gridlinePositions: []) { value in
            "\(Int(value)) 토큰"
        }
        let points = values.enumerated().map { index, value in
            AXDataPoint(x: Double(index - (values.count - 1)) * FlowSeries.bucketSeconds, y: Double(value))
        }
        return AXChartDescriptor(title: "최근 5분 출력 토큰 기록", summary: "5초 동안 로그에 기록된 출력 토큰 수이며 속도가 아닙니다",
                                 xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [AXDataSeriesDescriptor(name: "5초 기록량", isContinuous: false, dataPoints: points)])
    }
}

struct FlowCard: View {
    var flow: FlowSeries
    var counts: SessionCounts
    var now: Date
    var tokensSampledAt: Date?
    @Environment(\.tokenCatHighContrast) private var high
    static let help = "막대 하나는 5초 동안 로그에 기록된 출력 토큰 수입니다. Codex는 응답이 끝날 때, Claude Code는 메시지가 끝날 때 기록하므로 생성 중인 토큰은 아직 포함되지 않습니다. 속도로 환산하지 않습니다."

    private var loading: Bool { tokensSampledAt == nil }
    private var total: Int { flow.total }
    private var scale: Double { niceMax(Double(max(flow.peak, 200))) }
    private var collectionDelay: Int? {
        guard let tokensSampledAt else { return nil }
        let delay = Int(now.timeIntervalSince(tokensSampledAt))
        return delay > 3 ? delay : nil
    }
    private var lastIsFresh: Bool {
        guard let last = flow.last else { return false }
        return now.timeIntervalSince(last.at) <= FlowSeries.freshSeconds
    }
    private var overlay: String? {
        if loading { return "세션 기록 확인 중" }
        if total == 0 && counts.liveGroups == 0 { return "최근 5분 동안 출력 기록 없음" }
        return nil
    }
    private var notice: String? { loading ? nil : SessionPresentation.flowNotice(counts: counts, last: flow.last?.at, now: now) }
    private var providerSplit: String? {
        guard !loading, total > 0 else { return nil }
        let parts = TokenSource.allCases.compactMap { source -> String? in
            guard let value = flow.byProvider[source], value > 0 else { return nil }
            return "\(source.title) \(Format.compactTokens(value))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow.frame(height: 16)
            VStack(alignment: .leading, spacing: 0) {
                numberRow.frame(height: 26).padding(.top, 4)
                strip.frame(height: 34).padding(.top, 6)
                HStack {
                    Text("5분 전")
                    Spacer()
                    Text("지금")
                }.font(.system(size: 10)).faint().frame(height: 11).padding(.top, 3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("최근 5분 출력 토큰 기록")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(Self.help)
            .accessibilityChartDescriptor(FlowChartDescriptor(values: flow.hero))
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(height: 118)
        .card()
        .accessibilityElement(children: .contain)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text("출력 토큰").font(.system(size: 12, weight: .semibold)).fixedSize().accessibilityAddTraits(.isHeader)
            Text("최근 5분 · 로그 기록 기준").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if let providerSplit {
                Text(providerSplit).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Image(systemName: "info.circle").font(.system(size: 11)).faint()
                .help(Self.help).accessibilityLabel("출력 토큰 설명")
        }
    }

    private var numberRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(loading ? "—" : Format.tokens(total))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(loading ? (high ? HierarchicalShapeStyle.secondary : .tertiary) : (total == 0 ? .secondary : .primary))
                if !loading { Text("tok").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text("마지막 기록").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if let collectionDelay {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("AI 수집 지연 \(collectionDelay)초").foregroundStyle(.primary)
                    } else if loading {
                        Text("—").faint()
                    } else if let last = flow.last {
                        Circle().fill(Color.green).frame(width: 6, height: 6).opacity(lastIsFresh ? 1 : 0)
                        Text("+\(Format.tokens(last.tokens)) tok · \(Format.age(last.at, now: now))").foregroundStyle(.primary)
                    } else {
                        Text("기록 없음").faint()
                    }
                }.font(.system(size: 12, weight: .semibold).monospacedDigit()).lineLimit(1)
            }
        }
    }

    /// The scale label sits in its own band above the top gridline so tall bars never cover it.
    private var strip: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text(!loading && total > 0 ? Format.compactTokens(Int(scale)) : " ")
                    .font(.system(size: 10).monospacedDigit()).faint().frame(height: 11)
                ZStack(alignment: .top) {
                    if !loading && total > 0 {
                        FlowBars(values: flow.hero, scale: scale).fill(Color.primary.opacity(high ? 0.6 : 0.4))
                        FlowBars(values: flow.hero, scale: scale, mask: flow.fresh).fill(Color.green)
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                    }
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Color.primary.opacity(high ? 0.25 : 0.12)).frame(height: 1)
                    }
                }
            }
            if let overlay {
                Text(overlay).font(.system(size: 11)).faint()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let notice {
                Text(notice).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.background))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(high ? 0.25 : 0.08), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var accessibilityValue: String {
        if loading { return "세션 기록 확인 중" }
        var parts = ["\(total.formatted()) 토큰"]
        if let last = flow.last { parts.append("마지막 기록 \(last.tokens.formatted()) 토큰, \(Format.age(last.at, now: now))") }
        else { parts.append("최근 5분 동안 출력 기록 없음") }
        if counts.input > 0 { parts.append("입력 필요 \(counts.input)개") }
        if counts.retrying > 0 { parts.append("API 재시도 \(counts.retrying)개") }
        parts.append("진행 중 세션 \(counts.runningGroups)개, 도구 실행 \(counts.tool)개")
        if counts.waiting > 0 { parts.append("로그 대기 \(counts.waiting)개") }
        if let notice { parts.append(notice) }
        parts.append("로그 기록 시점 기준이며 속도가 아닙니다")
        return parts.joined(separator: ". ")
    }
}

// MARK: - Codex usage limit

/// The last logged Codex limit window, always with its record age; no forecast.
struct UsageLimitCard: View {
    var limit: UsageLimitSummary
    var now: Date
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        let expired = limit.expired(now: now)
        let percent = limit.usedPercent
        let color: Color = percent >= 95 ? .red : (percent >= 85 ? .orange : Color.primary.opacity(0.45))
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(limit.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize()
                Text(limit.value(now: now)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(expired ? (high ? HierarchicalShapeStyle.secondary : .tertiary) : (limit.isOld(now: now) ? .secondary : .primary))
                    .fixedSize()
                Spacer(minLength: 6)
                Text(limit.detail(now: now)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if !expired { Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, percent / 100))) }
                }
            }.frame(height: 3)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .card()
        .help(UsageLimitSummary.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.title)
        .accessibilityValue(limit.spoken(now: now))
    }
}

// MARK: - Sessions

struct SessionsHeader: View {
    @ObservedObject var model: DashboardModel
    /// Four or more chips beside the toggle would overflow 392pt; they keep only mark and number.
    static func compactChips(_ count: Int) -> Bool { count >= 4 }

    var body: some View {
        let list = model.sessions
        let counts = list.counts
        let chips = SessionDisplayState.liveOrder.filter { counts.count($0) > 0 }
        let compact = Self.compactChips(chips.count)
        HStack(spacing: 6) {
            Text("세션").font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if model.tokensSampledAt == nil {
                EmptyView()
            } else if chips.isEmpty {
                Text("진행 중인 세션 없음").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(chips, id: \.self) { state in
                    StateChip(state: state, text: compact ? "\(counts.count(state))" : "\(state.chipTitle) \(counts.count(state))")
                        .help(chipHelp(state, counts))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(state.title) 세션 \(counts.count(state))개")
                }
            }
            Spacer(minLength: 6)
            if list.hiddenGroups + list.hiddenChildren > 0 || model.sessionsExpanded {
                let expanded = model.sessionsExpanded
                Button { model.sessionsExpanded.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(expanded ? "접기" : (list.hiddenGroups > 0 ? "\(counts.groups)개 모두 보기" : "하위 \(list.hiddenChildren)개 더 보기"))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 5).frame(height: 18)
                }
                .fixedSize()
                .padding(.trailing, -5)
                .help("하위 에이전트 포함 \(counts.readings)개 기록" + (expanded || list.hiddenGroups == 0 ? "" : " · 접힌 세션 \(list.hiddenGroups)개"))
                .accessibilityLabel(expanded ? "세션 목록 접기" : (list.hiddenGroups > 0 ? "세션 목록 모두 보기" : "하위 에이전트 더 보기"))
                .accessibilityValue(expanded ? "" : "\(list.hiddenGroups > 0 ? counts.groups : list.hiddenChildren)개")
            }
        }.frame(height: 18)
    }

    private func chipHelp(_ state: SessionDisplayState, _ counts: SessionCounts) -> String {
        var text = "\(state.title) 세션 \(counts.count(state))개"
        if state == .tool {
            let parts = [ToolCategory.command, .file, .web, .agent, .mcp, .question, .other].compactMap { category -> String? in
                guard let n = counts.toolCategories[category], n > 0 else { return nil }
                return "\(SessionPresentation.toolTitle(category)) \(n)"
            }
            if !parts.isEmpty { text += "\n하위 에이전트 포함 " + parts.joined(separator: " · ") }
        }
        if state == .input { text += "\n질문이나 계획 승인을 기다립니다. 권한 확인 요청은 로그에 남지 않아 표시하지 않습니다" }
        return text
    }
}

struct SessionList: View {
    @ObservedObject var model: DashboardModel
    var scrolls: Bool
    var logFoldersFound: Bool?
    /// Grow-only while the popover stays open so rows changing type do not resize it.
    @State private var viewportFloor: CGFloat = 0
    /// The group whose "+N 하위" row expanded the list; the header toggle scrolls to the top instead.
    @State private var focus: String?
    @State private var showOlder = false

    private var list: SessionListModel { model.sessions }
    private var target: CGFloat { list.viewport(showOlder: showOlder) }
    private var height: CGFloat { min(SessionListModel.maxViewport, max(target, viewportFloor)) }
    private var overflows: Bool { list.height(showOlder: showOlder) > height + 0.5 }

    static func logFoldersExist(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        [".codex/sessions", ".claude/projects"].contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
    }

    var body: some View {
        if model.tokensSampledAt == nil {
            Text("세션 기록을 읽는 중").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44).card()
        } else if list.blocks.isEmpty {
            emptyState(foldersFound: logFoldersFound ?? Self.logFoldersExist())
        } else {
            Group {
                if scrolls {
                    ScrollViewReader { proxy in
                        ScrollView { rows }
                            .onChange(of: model.sessionsExpanded) { _ in
                                viewportFloor = 0
                                showOlder = false
                                let target = focus ?? "session-list-top"
                                focus = nil
                                // Wait for the expanded rows to lay out before scrolling to the focused group.
                                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                            }
                    }
                } else {
                    // ImageRenderer cannot rasterize AppKit's scroll surface; export the same viewport.
                    rows.fixedSize(horizontal: false, vertical: true).frame(height: height, alignment: .top).clipped()
                }
            }
            .frame(height: height)
            // A short fade at the cut says the list continues; overlay scrollers are hidden at rest.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                        .frame(height: overflows ? 14 : 0)
                }
            }
            .card()
            .transaction { $0.animation = nil }
            .onAppear { viewportFloor = target }
            .onChange(of: target) { viewportFloor = max(viewportFloor, $0) }
            .onChange(of: model.popoverShownAt) { _ in showOlder = false; viewportFloor = list.viewport(showOlder: false) }
        }
    }

    private func emptyState(foldersFound: Bool) -> some View {
        VStack(spacing: 3) {
            Text(foldersFound ? "아직 Codex·Claude Code 세션 기록이 없습니다" : "Codex·Claude Code 기록 폴더를 찾지 못했습니다")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(foldersFound ? "새 세션을 시작하면 여기에 표시됩니다" : "~/.codex/sessions · ~/.claude/projects를 확인합니다")
                .font(.system(size: 10.5)).faint()
            Text("Claude 웹·데스크톱 채팅은 수집하지 않습니다").font(.system(size: 10.5)).faint()
        }
        .frame(maxWidth: .infinity, minHeight: 66).card()
        .accessibilityElement(children: .combine)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).id("session-list-top")
            ForEach(list.entries(showOlder: showOlder)) { entry in
                switch entry {
                case .divider: ListDivider()
                case .caption(let title):
                    Text(title).font(.system(size: 10, weight: .medium)).faint()
                        .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: SessionListModel.captionHeight, alignment: .bottom)
                        .accessibilityAddTraits(.isHeader)
                case .older(let count):
                    Button { showOlder = true } label: {
                        HStack(spacing: 3) {
                            Text("이전 기록 \(count)개 더 보기").font(.system(size: 11).monospacedDigit())
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).frame(height: SessionListModel.moreHeight)
                    }
                    .accessibilityLabel("이전 기록 더 보기").accessibilityValue("\(count)개")
                case .block(let block):
                    SessionBlockView(block: block, flow: model.flow, scale: list.rowScale, now: model.now,
                                     restart: model.telemetryRestartNeeded) {
                        focus = block.id
                        model.sessionsExpanded = true
                    }.id(block.id)
                }
            }
            // Lets the last row scroll clear of the fade.
            if scrolls && overflows { Color.clear.frame(height: 10) }
        }
    }
}

struct SessionBlockView: View {
    var block: SessionBlock
    var flow: FlowSeries
    var scale: Double
    var now: Date
    var restart: Set<TokenSource>
    var expand: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            let lead = block.lead.reading
            switch block.lead.kind {
            case .live:
                LiveSessionRow(item: block.lead, childCount: block.childCount, row: flow.rows[block.lead.id], scale: scale, now: now,
                               restartNeeded: restart.contains(lead.source))
            case .measurement: MeasurementRow(reading: lead, now: now)
            default:
                // Input and retry children are running, so every one of them is in `children`.
                let urgent = block.state == .input || block.state == .retrying
                IdleSessionRow(item: block.lead, childCount: block.childCount, groupState: block.state,
                               liveChildren: urgent ? block.children.filter { $0.state == block.state }.count
                                   : (block.state.isRunning ? block.runningChildren : block.waitingChildren), now: now,
                               restartNeeded: restart.contains(lead.source))
            }
            ForEach(block.children) { child in
                ChildSessionRow(item: child, parent: lead, row: flow.rows[child.id], scale: scale, now: now,
                                restartNeeded: restart.contains(child.reading.source))
            }
            if block.moreCount > 0 {
                Button(action: expand) {
                    HStack(spacing: 0) {
                        Text(block.moreText).font(.system(size: 11).monospacedDigit()).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    // Aligned with the child agent labels.
                    .padding(.leading, 52).padding(.trailing, 10)
                    .frame(height: SessionListModel.moreHeight)
                }
                .help("실행 중인 하위 에이전트는 모두 보여주고, 로그 대기 하위는 실행 중인 하위가 없을 때만 \(SessionListModel.collapsedChildren)개까지 보여줍니다")
                .accessibilityLabel("하위 에이전트 \(block.moreCount)개 더 보기")
                .accessibilityValue(block.moreText)
            }
        }
    }
}

private enum RowText {
    static let recordingNote = "Claude Code는 메시지 완료 시, Codex는 응답 완료 시 기록합니다"
    static let actionsNote = "우클릭: ID 복사 · Finder에서 보기"

    /// Help text: no per-second values, so the tooltip does not reset every tick.
    static func details(_ reading: TokenReading, state: SessionDisplayState, speed: SpeedSlot, now: Date) -> String {
        var lines: [String?] = [reading.project, SessionPresentation.roleLabel(reading.agentRole).map { "역할 \($0)" },
                                reading.agentID.map { "에이전트 \($0)" },
                                reading.sessionID.map { "세션 \($0)" },
                                reading.model.map { "모델 \($0)" + (SessionPresentation.effortLabel(reading).map { " · \($0)" } ?? "") }]
        if SessionPresentation.isTelemetry(reading) { lines.append(reading.status) }
        switch state {
        case .tool:
            lines.append("도구: \(SessionPresentation.toolTitle(reading.toolCategory))" + (reading.toolName.map { " · \($0)" } ?? ""))
        case .input:
            lines.append("\(SessionPresentation.inputTitle(reading)) · 질문 내용은 표시하지 않습니다")
            lines.append("권한 확인 요청은 로그에 기록되지 않아 표시하지 않습니다")
        case .retrying:
            lines.append("API 재시도 기록 · 오류 내용은 저장하지 않습니다")
        default: break
        }
        lines.append(speed.help)
        lines.append(SessionPresentation.lastTurnSummary(reading))
        lines.append(reading.currentTurnOutputTokens.map { "현재 턴에서 확인된 출력 \(Format.tokens($0)) tok" })
        lines.append(recordingNote)
        if !SessionPresentation.rowActions(reading).isEmpty { lines.append(actionsNote) }
        return lines.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func label(_ reading: TokenReading, children: Int) -> String {
        var parts = ["\(reading.project ?? "프로젝트 미확인") 세션", "\(reading.source.title) \(reading.model ?? "모델 미확인")"]
        if children > 0 { parts.append("하위 에이전트 \(children)개") }
        if reading.isSubagent { parts.append("하위 에이전트 \(SessionPresentation.agentLabel(reading))") }
        return parts.joined(separator: ", ")
    }

    static func output(_ reading: TokenReading) -> String {
        guard let output = reading.currentTurnOutputTokens else { return "이번 턴 누적 미확인" }
        return "이번 턴 출력 \(output.formatted()) 토큰"
    }

    /// The live-row state word: tool category, input kind or retry progress.
    static func spokenState(_ reading: TokenReading, _ state: SessionDisplayState, now: Date) -> String {
        switch state {
        case .input: return "입력 필요, \(SessionPresentation.inputTitle(reading))"
        case .retrying: return reading.retry.map { "API " + SessionPresentation.retryText($0, now: now) } ?? state.title
        default: return SessionPresentation.stateTitle(state, reading)
        }
    }
}

struct LiveSessionRow: View {
    var item: SessionRowItem
    var childCount: Int
    var row: FlowSeries.Row?
    var scale: Double
    var now: Date
    var restartNeeded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var reading: TokenReading { item.reading }

    private var pillOpacity: Double? {
        guard item.state == .output, let at = reading.lastOutputAt, let delta = reading.lastOutputDelta, delta > 0 else { return nil }
        let age = now.timeIntervalSince(at)
        if age <= 2 { return 1 }
        return age <= 5 ? 0.6 : nil
    }

    private var trailing: String {
        switch item.state {
        case .waiting: return "활동 \(Format.age(SessionPresentation.liveAt(reading), now: now))"
        case .input: return "입력 대기 \(Format.elapsed(reading.lastActivity, at: now))"
        case .retrying: return reading.retry.map { SessionPresentation.retryText($0, now: now) } ?? item.state.title
        default: return "턴 \(Format.elapsed(reading.currentTurnStartedAt, at: now))"
        }
    }

    var body: some View {
        let speed = SessionPresentation.speed(reading, now: now, restartNeeded: restartNeeded)
        let context = SessionPresentation.context(reading, now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StateChip(state: item.state, text: SessionPresentation.stateTitle(item.state, reading))
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let model = reading.model {
                        Text(model).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    } else {
                        Text("모델 기록 대기").font(.system(size: 12.5, weight: .medium)).faint().lineLimit(1)
                    }
                    if let effort = SessionPresentation.effortLabel(reading) {
                        Text(" · \(effort)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
                Spacer(minLength: 6)
                if let opacity = pillOpacity, let delta = reading.lastOutputDelta {
                    Text("+\(Format.tokens(delta))").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .opacity(opacity).fixedSize()
                }
                primaryNumber.frame(minWidth: 86, alignment: .trailing)
            }.frame(height: 18)
            HStack(spacing: 4) {
                Text(reading.source.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize()
                Text("·").font(.system(size: 11)).faint()
                Text(SessionPresentation.identity(reading, children: childCount)).font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(trailing).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(item.state == .input || item.state == .retrying ? HierarchicalShapeStyle.primary : .secondary)
                    .fixedSize()
            }.frame(height: 15).padding(.top, 3)
            if item.showsDetail {
                HStack(spacing: 10) {
                    RecordBars(row: row, count: FlowSeries.rowCount, scale: scale).frame(height: 10).frame(maxWidth: .infinity)
                    if let context { ContextLabel(slot: context) }
                    SpeedLabel(slot: speed)
                }.frame(height: 12).padding(.top, 4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, item.showsDetail ? 5 : 4)
        .frame(height: item.height)
        .contentShape(Rectangle())
        .help(RowText.details(reading, state: item.state, speed: speed, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowText.label(reading, children: childCount))
        .accessibilityValue([RowText.spokenState(reading, item.state, now: now),
                             SessionPresentation.effortLabel(reading).map { "추론 \($0)" },
                             SessionPresentation.spokenDuration(reading.currentTurnStartedAt, now: now).map { "턴 경과 \($0)" },
                             RowText.output(reading), context?.spoken, speed.spoken].compactMap { $0 }.joined(separator: ", "))
        .rowActions(reading)
    }

    @ViewBuilder private var primaryNumber: some View {
        if let output = reading.currentTurnOutputTokens {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(Format.tokens(output)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(output == 0 ? HierarchicalShapeStyle.tertiary : (item.state == .waiting ? .secondary : .primary))
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: output)
                Text("tok").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .lineLimit(1).fixedSize()
            .help(output == 0 ? "현재 턴에서 아직 기록된 출력이 없습니다" : "현재 턴에서 기록된 출력 토큰")
        } else {
            Text("—").font(.system(size: 15, weight: .semibold)).faint()
                .help("현재 턴 시작 부분을 읽지 못해 이번 턴 누적량을 알 수 없습니다. 최근 증가량은 막대에 표시됩니다")
        }
    }
}

struct IdleSessionRow: View {
    var item: SessionRowItem
    var childCount: Int
    var groupState: SessionDisplayState
    var liveChildren: Int
    var now: Date
    var restartNeeded = false
    private var reading: TokenReading { item.reading }
    private var age: String { Format.age(reading.lastActivity, now: now) }
    /// An idle lead whose subagents are live shows the group's state instead of its own age.
    private var followsGroup: Bool { !item.state.isLive && groupState.isLive && liveChildren > 0 }
    private var groupText: String { SessionPresentation.childGroupText(groupState, count: liveChildren) }
    private var stateAge: String {
        if followsGroup { return groupText }
        switch item.state {
        case .interrupted: return "중단 \(age)"
        case .unfinished: return "종료 기록 없음 · \(age)"
        default: return age
        }
    }
    private var ageHelp: String {
        let minutes = SessionPresentation.helpAge(reading.lastActivity, now: now)
        if followsGroup { return "\(item.state.title) · 마지막 활동 \(minutes)" }
        return item.state == .unfinished ? "턴 종료 기록 없음 · 마지막 활동 \(minutes)" : "\(item.state.title) · 마지막 활동 \(minutes)"
    }
    var body: some View {
        let speed = SessionPresentation.speed(reading, now: now, restartNeeded: restartNeeded)
        HStack(spacing: 6) {
            StateMark(state: followsGroup ? groupState : item.state).frame(width: 10)
            Text(reading.project ?? "프로젝트 미확인").font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail).layoutPriority(2)
            Text(SessionPresentation.shortID(reading)).font(.system(size: 11)).faint().lineLimit(1)
            if reading.isSubagent { Text("하위").font(.system(size: 10.5)).faint().fixedSize() }
            if childCount > 0 { Text("하위 \(childCount)").font(.system(size: 10.5).monospacedDigit()).faint().fixedSize() }
            Spacer(minLength: 6)
            SpeedLabel(slot: speed, compactUnknown: true)
            Text(stateAge).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing).fixedSize()
                .help(ageHelp)
        }
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(height: item.height)
        .contentShape(Rectangle())
        .help(RowText.details(reading, state: item.state, speed: speed, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowText.label(reading, children: childCount))
        .accessibilityValue([item.state.title, "마지막 활동 \(age)", followsGroup ? groupText : nil,
                             SessionPresentation.lastTurnSummary(reading), speed.spoken]
                                .compactMap { $0 }.joined(separator: ", "))
        .rowActions(reading)
    }
}

struct ChildSessionRow: View {
    var item: SessionRowItem
    var parent: TokenReading
    var row: FlowSeries.Row?
    var scale: Double
    var now: Date
    var restartNeeded = false
    private var reading: TokenReading { item.reading }
    private var stateWord: String {
        if item.state == .retrying, let retry = reading.retry { return SessionPresentation.retryText(retry, now: now) }
        return SessionPresentation.stateTitle(item.state, reading)
    }
    var body: some View {
        let speed = SessionPresentation.speed(reading, now: now, restartNeeded: restartNeeded)
        let live = item.state.isLive
        let title = SessionPresentation.childTitle(reading)
        let project = SessionPresentation.childProjectSuffix(reading, parent: parent)
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).faint().frame(width: 12)
            StateMark(state: item.state).frame(width: 10)
            // Each part shows whole or not at all (the project drops first, then the detail); never a cut "a7b…".
            ViewThatFits(in: .horizontal) {
                nameLine(title.title, [title.detail, project])
                nameLine(title.title, [title.detail])
                Text(title.title).lineLimit(1).truncationMode(.middle).fixedSize(horizontal: title.title.count <= 8, vertical: false)
            }
            .font(.system(size: 11.5)).layoutPriority(1)
            if item.state != .idle {
                Text(stateWord).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 6)
            if live {
                // Bars only for a record in the 2-minute window; otherwise the slot stays empty.
                Group {
                    if row != nil { RecordBars(row: row, count: FlowSeries.rowCount, scale: scale, minHeight: 3, minWidth: 1.5) }
                    else { Color.clear }
                }.frame(width: 48, height: 8)
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    if let output = reading.currentTurnOutputTokens {
                        // A child waiting for a log is not producing; its total stays quiet.
                        Text(Format.tokens(output))
                            .font(.system(size: 12, weight: item.state == .waiting ? .regular : .semibold).monospacedDigit())
                            .foregroundStyle(output == 0 ? HierarchicalShapeStyle.tertiary : (item.state == .waiting ? .secondary : .primary))
                        Text("tok").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text("—").font(.system(size: 12, weight: .semibold)).faint()
                    }
                }.lineLimit(1).fixedSize().frame(minWidth: 56, alignment: .trailing)
            } else {
                Text(Format.age(reading.lastActivity, now: now)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing).fixedSize()
            }
        }
        .padding(.leading, 18).padding(.trailing, 10)
        .frame(height: item.height)
        .contentShape(Rectangle())
        .help(RowText.details(reading, state: item.state, speed: speed, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("하위 에이전트, \(reading.model ?? "모델 미확인")")
        .accessibilityValue([RowText.spokenState(reading, item.state, now: now),
                             live ? RowText.output(reading) : "마지막 활동 \(Format.age(reading.lastActivity, now: now))",
                             speed.spoken, SessionPresentation.roleLabel(reading.agentRole).map { "역할 \($0)" },
                             "ID \(SessionPresentation.agentLabel(reading))"].compactMap { $0 }.joined(separator: ", "))
        .rowActions(reading)
    }

    private func nameLine(_ name: String, _ parts: [String?]) -> some View {
        HStack(spacing: 0) {
            Text(name).foregroundStyle(.primary)
            ForEach(Array(parts.compactMap { $0 }.enumerated()), id: \.offset) { Text(" · \($0.element)").faint() }
        }.lineLimit(1).fixedSize()
    }
}

struct MeasurementRow: View {
    var reading: TokenReading
    var now: Date
    var body: some View {
        let speed = SessionPresentation.speed(reading, now: now)
        let age = Format.age(reading.speedMeasurement?.at ?? reading.lastActivity, now: now)
        HStack(spacing: 6) {
            Image(systemName: "speedometer").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 12)
            Text(reading.project ?? "모델 실측").font(.system(size: 12.5)).lineLimit(1).fixedSize()
            Text(reading.model ?? "모델 미확인").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            SpeedLabel(slot: speed, numberSize: 12)
            Text("측정 \(age)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .contentShape(Rectangle())
        .help(RowText.details(reading, state: .measurement, speed: speed, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.project ?? "모델 실측"), \(reading.source.title) \(reading.model ?? "모델 미확인")")
        .accessibilityValue("\(speed.spoken), 측정 \(age)")
        .rowActions(reading)
    }
}

// MARK: - System strip

/// `kern.memorystatus_vm_pressure_level`: the memory bar colour follows pressure, not the used %.
enum MemoryPressure: Equatable {
    case normal, warning, critical, unknown
    init(_ level: Int?) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
    var title: String {
        switch self {
        case .normal: return "정상"
        case .warning: return "경고"
        case .critical: return "위험"
        case .unknown: return "미확인"
        }
    }
    var color: Color {
        switch self {
        case .warning: return .orange
        case .critical: return .red
        default: return Color.primary.opacity(0.45)
        }
    }
}

struct SystemStrip: View {
    var system: SystemSnapshot
    var cpuHistory: [Double]
    var hasSample: Bool

    private func ratio(_ used: UInt64?, _ total: UInt64?) -> Double? { hasSample ? Format.ratio(used, total) : nil }

    var body: some View {
        let memory = ratio(system.memoryUsedBytes, system.memoryTotalBytes)
        let disk = ratio(system.diskUsedBytes, system.diskTotalBytes)
        let pressure = MemoryPressure(hasSample ? system.memoryPressure : nil)
        let upload = StatusBarContent.networkRate(hasSample ? system.uploadBytesPerSecond : nil)
        let download = StatusBarContent.networkRate(hasSample ? system.downloadBytesPerSecond : nil)
        let cpu = hasSample ? system.cpuPercent : nil
        HStack(spacing: 0) {
            cell("CPU", help: "CPU 전체 코어 사용률 · 최근 30초 추이", value: "\(Format.percent(cpu)), 최근 30초") {
                HStack(spacing: 5) {
                    self.value(cpu)
                    Sparkline(values: Array(cpuHistory.suffix(30))).frame(width: 40, height: 12)
                }
            }.frame(width: 88, height: Self.cellHeight, alignment: .topLeading)
            separator
            cell("메모리", help: "메모리: 앱·유선·압축 사용량 / 실제 메모리\n막대 색은 메모리 압력 기준 · 현재 \(pressure.title)",
                 value: "\(Format.percent(memory)), \(Format.capacity(system.memoryUsedBytes, system.memoryTotalBytes)), 메모리 압력 \(pressure.title)") {
                self.value(memory)
                bar(memory, color: pressure.color)
            }.frame(width: 56, height: Self.cellHeight, alignment: .topLeading)
            separator
            cell("저장 공간", help: "저장 공간: 홈 폴더가 있는 볼륨의 사용량 / 전체 용량",
                 value: "\(Format.percent(disk)), \(Format.capacity(system.diskUsedBytes, system.diskTotalBytes))") {
                self.value(disk)
                bar(disk, color: meterColor(disk))
            }.frame(width: 56, height: Self.cellHeight, alignment: .topLeading)
            if system.batteryPresent {
                separator
                battery.frame(width: 52, height: Self.cellHeight, alignment: .topLeading)
            }
            separator
            VStack(alignment: .leading, spacing: 1) {
                Text("↑\(upload)")
                Text("↓\(download)")
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit()).lineLimit(1)
            .foregroundStyle(hasSample ? HierarchicalShapeStyle.primary : .tertiary)
            .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
            .help("네트워크: Wi-Fi·Ethernet 합산, VPN·루프백 제외\n\(system.localIPs.isEmpty ? "IPv4 주소 미확인" : "IPv4 " + system.localIPs.joined(separator: " · "))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("네트워크")
            .accessibilityValue("업로드 \(upload), 다운로드 \(download)")
        }
        .frame(height: Self.cellHeight)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .card()
    }

    private static let cellHeight: CGFloat = 34
    private var separator: some View { Divider().frame(height: 26).padding(.horizontal, 6) }

    private func value(_ percent: Double?) -> some View {
        Text(Format.percent(percent)).font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(percent == nil ? HierarchicalShapeStyle.tertiary : .primary).lineLimit(1).fixedSize()
    }

    /// Help is static so the tooltip does not reset every second; live values go to VoiceOver only.
    private func cell<Content: View>(_ title: String, help: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            content()
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func bar(_ percent: Double?, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, (percent ?? 0) / 100)))
            }
        }.frame(height: 2)
    }

    private func meterColor(_ percent: Double?) -> Color {
        guard let percent else { return Color.primary.opacity(0.45) }
        return percent >= 95 ? .red : (percent >= 85 ? .orange : Color.primary.opacity(0.45))
    }

    private var battery: some View {
        let percent = hasSample ? system.batteryPercent : nil
        let charging = system.isCharging == true
        let color: Color = {
            guard let percent, !charging else { return Color.primary.opacity(0.45) }
            return percent <= 10 ? .red : (percent <= 20 ? .orange : Color.primary.opacity(0.45))
        }()
        return cell("배터리", help: "배터리 잔량 · \(Format.power(system))", value: "\(Format.percent(percent)), \(Format.power(system))") {
            HStack(spacing: 2) {
                value(percent)
                if charging { Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(.secondary) }
            }
            bar(percent, color: color)
        }
    }
}
