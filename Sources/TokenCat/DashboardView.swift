import AppKit
import SwiftUI

private struct CardBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return content
            .background(Color.primary.opacity(0.035), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.18 : 0.07), lineWidth: 1))
    }
}

extension View {
    fileprivate func card() -> some View { modifier(CardBackground()) }
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

struct StateChip: View {
    var state: SessionDisplayState
    var text: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(state.color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.primary).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2).frame(height: 17)
        .background(state.color.opacity(0.16), in: Capsule())
        .fixedSize()
    }
}

struct StateDot: View {
    var state: SessionDisplayState
    var body: some View {
        Group {
            switch state {
            case .interrupted: Circle().strokeBorder(.tertiary, lineWidth: 1.5)
            case .unfinished: Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [1.4, 1.4]))
            default: Circle().fill(state.color)
            }
        }.frame(width: 6, height: 6)
    }
}

/// Recorded volume bars: the base layer plus the buckets holding a record from the last 5 s in green.
struct RecordBars: View {
    var row: FlowSeries.Row?
    var count: Int
    var scale: Double
    var body: some View {
        let values = row?.buckets ?? Array(repeating: 0, count: count)
        ZStack {
            FlowBars(values: values, scale: scale).fill(Color.primary.opacity(0.4))
            FlowBars(values: values, scale: scale, mask: row?.fresh ?? []).fill(Color.green)
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
                if let prefix = slot.prefix { Text(prefix + " ").font(.system(size: 10)).foregroundStyle(.tertiary) }
                Text(slot.value).font(.system(size: numberSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(slot.prefix == nil && slot.recent ? HierarchicalShapeStyle.primary : .secondary)
                Text(" " + (slot.kind ?? "tok/s")).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(compactUnknown ? "—" : "— tok/s").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1).fixedSize().help(slot.help)
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var settings: () -> Void
    var quit: () -> Void
    var scrollsSessions = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            FlowCard(flow: model.flow, counts: model.sessions.counts, now: model.now, tokensSampledAt: model.tokensSampledAt)
                .padding(.top, 10)
            SessionsHeader(model: model).padding(.top, 12)
            SessionList(model: model, scrolls: scrollsSessions).padding(.top, 6)
            SystemStrip(system: model.system, cpuHistory: model.cpuHistory, hasSample: model.hasSample).padding(.top, 10)
            footer.padding(.top, 8)
        }
        .padding(.top, 12).padding(.horizontal, 14).padding(.bottom, 12)
        .frame(width: 420)
        .buttonStyle(HoverButtonStyle())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: Runner.brandImage()).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22).accessibilityHidden(true)
            Text("TokenCat").font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 2) {
                Button(action: settings) { Image(systemName: "slider.horizontal.3").font(.system(size: 13)).frame(width: 24, height: 24) }
                    .help("표시 항목·순서 설정").accessibilityLabel("설정").keyboardShortcut(",")
                Button(action: quit) { Image(systemName: "power").font(.system(size: 13)).frame(width: 24, height: 24) }
                    .help("TokenCat 종료").accessibilityLabel("종료").keyboardShortcut("q")
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

    private var footer: some View {
        HStack(spacing: 0) {
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) } label: {
                Label("활성 상태 보기", systemImage: "arrow.up.forward.app").font(.system(size: 11))
                    .padding(.horizontal, 5).frame(height: 18)
            }.padding(.leading, -5)
            Spacer(minLength: 8)
            if model.telemetrySetupNote != nil || !model.telemetryReady {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(Color.orange)
                    Text("속도 실측 연결 안 됨").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .help(model.telemetrySetupNote ?? model.telemetryStatus)
                .accessibilityElement(children: .combine)
                .padding(.trailing, 10)
            }
            let fresh = freshness
            HStack(spacing: 4) {
                Circle().fill(fresh.color).frame(width: 6, height: 6)
                Text(fresh.text).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .help("시스템과 AI 기록을 1초마다, 로그 변경 시 즉시 확인합니다\n\(model.telemetryStatus)")
            .accessibilityElement(children: .combine)
        }.frame(height: 18)
    }
}

// MARK: - Flow card

struct FlowCard: View {
    var flow: FlowSeries
    var counts: SessionCounts
    var now: Date
    var tokensSampledAt: Date?
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
    private var waitingMessage: String? {
        guard !loading, counts.liveGroups > 0 else { return nil }
        if let last = flow.last, now.timeIntervalSince(last.at) <= 30 { return nil }
        if counts.tool > 0 { return "도구 실행 중 · 응답이 끝나면 토큰이 기록됩니다" }
        if counts.working > 0 || counts.output > 0 { return "진행 중 · 응답이 끝나면 토큰이 기록됩니다" }
        let minutes = counts.waitingSince.map { max(1, Int(now.timeIntervalSince($0)) / 60) } ?? 1
        return "로그 대기 · \(minutes)분 동안 새 기록 없음"
    }
    private var providerSplit: String? {
        guard !loading, total > 0 else { return nil }
        let parts = [(TokenSource.codex, "Codex"), (.claude, "Claude")].compactMap { source, name -> String? in
            guard let value = flow.byProvider[source], value > 0 else { return nil }
            return "\(name) \(Format.compactTokens(value))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow.frame(height: 16)
            numberRow.frame(height: 26).padding(.top, 4)
            strip.frame(height: 34).padding(.top, 6)
            HStack {
                Text("5분 전")
                Spacer()
                Text("지금")
            }.font(.system(size: 10)).foregroundStyle(.tertiary).frame(height: 11).padding(.top, 3)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(height: 118)
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("최근 5분 출력 토큰 기록")
        .accessibilityValue(accessibilityValue)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text("출력 토큰").font(.system(size: 12, weight: .semibold))
            Text("최근 5분 · 로그 기록 기준").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if let providerSplit {
                Text(providerSplit).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
                .help(Self.help).accessibilityLabel("출력 토큰 설명")
        }
    }

    private var numberRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(loading ? "—" : Format.tokens(total))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(loading ? HierarchicalShapeStyle.tertiary : (total == 0 ? .secondary : .primary))
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
                        Text("—").foregroundStyle(.tertiary)
                    } else if let last = flow.last {
                        Circle().fill(Color.green).frame(width: 6, height: 6).opacity(lastIsFresh ? 1 : 0)
                        Text("+\(Format.tokens(last.tokens)) tok · \(Format.age(last.at, now: now))").foregroundStyle(.primary)
                    } else {
                        Text("기록 없음").foregroundStyle(.tertiary)
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
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).frame(height: 11)
                ZStack(alignment: .top) {
                    if !loading && total > 0 {
                        FlowBars(values: flow.hero, scale: scale).fill(Color.primary.opacity(0.4))
                        FlowBars(values: flow.hero, scale: scale, mask: flow.fresh).fill(Color.green)
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                    }
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                    }
                }
            }
            if let overlay {
                Text(overlay).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let waitingMessage {
                Text(waitingMessage).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.background))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var accessibilityValue: String {
        if loading { return "세션 기록 확인 중" }
        var parts = ["\(total.formatted()) 토큰"]
        if let last = flow.last { parts.append("마지막 기록 \(last.tokens.formatted()) 토큰, \(Format.age(last.at, now: now))") }
        else { parts.append("최근 5분 동안 출력 기록 없음") }
        parts.append("진행 중 세션 \(counts.runningGroups)개, 도구 실행 \(counts.tool)개")
        if counts.waiting > 0 { parts.append("로그 대기 \(counts.waiting)개") }
        parts.append("로그 기록 시점 기준이며 속도가 아닙니다")
        return parts.joined(separator: ". ")
    }
}

// MARK: - Sessions

struct SessionsHeader: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        let list = model.sessions
        let counts = list.counts
        let chips = [SessionDisplayState.output, .tool, .working, .waiting].filter { counts.count($0) > 0 }
        HStack(spacing: 6) {
            Text("세션").font(.system(size: 12, weight: .semibold))
            if model.tokensSampledAt == nil {
                EmptyView()
            } else if chips.isEmpty {
                Text("진행 중인 세션 없음").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(chips, id: \.self) { state in
                    StateChip(state: state, text: "\(state.chipTitle) \(counts.count(state))").help("\(state.title) 세션 \(counts.count(state))개")
                }
            }
            Spacer(minLength: 6)
            if list.hiddenGroups + list.hiddenChildren > 0 || model.sessionsExpanded {
                Button { model.sessionsExpanded.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(model.sessionsExpanded ? "접기" : (list.hiddenGroups > 0 ? "모두 \(counts.groups)개" : "하위 \(list.hiddenChildren)개 더"))
                        Image(systemName: model.sessionsExpanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 5).frame(height: 18)
                }
                .padding(.trailing, -5)
                .help("하위 에이전트 포함 \(counts.readings)개 기록")
                .accessibilityLabel(model.sessionsExpanded ? "세션 접기"
                                    : (list.hiddenGroups > 0 ? "세션 모두 보기, \(counts.groups)개" : "하위 에이전트 \(list.hiddenChildren)개 더 보기"))
            }
        }.frame(height: 18)
    }
}

struct SessionList: View {
    @ObservedObject var model: DashboardModel
    var scrolls: Bool
    /// Grow-only while the popover stays open so rows changing type do not resize it.
    @State private var viewportFloor: CGFloat = 0
    /// The group whose "+N 하위" row expanded the list; the header toggle scrolls to the top instead.
    @State private var focus: String?

    private var target: CGFloat { min(SessionListModel.maxViewport, model.sessions.contentHeight) }
    private var height: CGFloat { min(SessionListModel.maxViewport, max(target, viewportFloor)) }

    var body: some View {
        if model.tokensSampledAt == nil {
            Text("세션 기록을 읽는 중").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44).card()
        } else if model.sessions.blocks.isEmpty {
            VStack(spacing: 3) {
                Text("아직 Codex·Claude Code 세션 기록이 없습니다").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("새 세션을 시작하면 여기에 표시됩니다").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, minHeight: 56).card()
        } else {
            Group {
                if scrolls {
                    ScrollViewReader { proxy in
                        ScrollView { rows }
                            .onChange(of: model.sessionsExpanded) { _ in
                                viewportFloor = 0
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
            .card()
            .transaction { $0.animation = nil }
            .onAppear { viewportFloor = target }
            .onChange(of: target) { viewportFloor = max(viewportFloor, $0) }
            .onChange(of: model.popoverShownAt) { _ in viewportFloor = target }
        }
    }

    private var rows: some View {
        let list = model.sessions
        return VStack(spacing: 0) {
            Color.clear.frame(height: 0).id("session-list-top")
            ForEach(Array(list.blocks.enumerated()), id: \.element.id) { index, block in
                if index > 0 { Divider().padding(.horizontal, 10) }
                SessionBlockView(block: block, flow: model.flow, scale: list.rowScale, now: model.now) {
                    focus = block.id
                    model.sessionsExpanded = true
                }.id(block.id)
            }
        }
    }
}

struct SessionBlockView: View {
    var block: SessionBlock
    var flow: FlowSeries
    var scale: Double
    var now: Date
    var expand: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            switch block.lead.kind {
            case .live: LiveSessionRow(item: block.lead, childCount: block.childCount, row: flow.rows[block.lead.id], scale: scale, now: now)
            case .measurement: MeasurementRow(reading: block.lead.reading, now: now)
            default:
                IdleSessionRow(item: block.lead, childCount: block.childCount, groupState: block.state,
                               liveChildren: block.state.isRunning ? block.runningChildren : block.waitingChildren, now: now)
            }
            ForEach(block.children) { child in
                ChildSessionRow(item: child, parent: block.lead.reading, row: flow.rows[child.id], scale: scale, now: now)
            }
            if block.moreCount > 0 {
                Button(action: expand) {
                    HStack(spacing: 0) {
                        Text(block.moreText).font(.system(size: 11).monospacedDigit()).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    // Aligned with the child agent labels.
                    .padding(.leading, 48).padding(.trailing, 10)
                    .frame(height: SessionListModel.moreHeight)
                }
                .help("접힌 목록은 실행 중인 하위 에이전트를 모두 보여주고, 로그 대기 하위는 하위 행이 \(SessionListModel.collapsedChildren)개가 될 때까지만 보여줍니다")
                .accessibilityLabel("하위 에이전트 \(block.moreCount)개 더 보기")
                .accessibilityValue(block.moreText)
            }
        }
    }
}

private enum RowText {
    static let recordingNote = "Claude Code는 메시지 완료 시, Codex는 응답 완료 시 기록합니다"

    static func details(_ reading: TokenReading) -> String {
        let identity = [reading.project, reading.agentID.map { "에이전트 \($0)" }, reading.sessionID.map { "세션 \($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
        return [identity, reading.model.map { "모델 \($0)" }, reading.status,
                reading.speedMeasurement?.details ?? "속도 미측정 · 실측 데이터 연결 대기",
                reading.lastOutputTokens.map { "세션 출력 기록 \($0.formatted()) tokens" },
                reading.currentTurnOutputTokens.map { "현재 턴에서 확인된 출력 \($0.formatted()) tokens" }, recordingNote]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func source(_ reading: TokenReading) -> String { reading.source == .codex ? "Codex" : "Claude" }

    static func label(_ reading: TokenReading, children: Int) -> String {
        var parts = ["\(reading.project ?? "프로젝트 미확인") 세션", "\(reading.source.title) \(reading.model ?? "모델 미확인")"]
        if children > 0 { parts.append("하위 에이전트 \(children)개") }
        if reading.isSubagent { parts.append("하위 에이전트 \(SessionPresentation.agentLabel(reading))") }
        return parts.joined(separator: ", ")
    }

    static func output(_ reading: TokenReading) -> String {
        guard let output = reading.currentTurnOutputTokens else { return "누적 미확인" }
        return "이번 턴 출력 \(output.formatted()) 토큰"
    }
}

struct LiveSessionRow: View {
    var item: SessionRowItem
    var childCount: Int
    var row: FlowSeries.Row?
    var scale: Double
    var now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var reading: TokenReading { item.reading }

    private var pillOpacity: Double? {
        guard item.state == .output, let at = reading.lastOutputAt, let delta = reading.lastOutputDelta, delta > 0 else { return nil }
        let age = now.timeIntervalSince(at)
        if age <= 2 { return 1 }
        return age <= 5 ? 0.6 : nil
    }

    var body: some View {
        let speed = SessionPresentation.speed(reading, now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StateChip(state: item.state, text: item.state.title)
                if let model = reading.model {
                    Text(model).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                } else {
                    Text("모델 기록 대기").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
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
                Text(RowText.source(reading)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text(SessionPresentation.identity(reading, children: childCount)).font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(item.state == .waiting ? "활동 \(Format.age(reading.lastActivity, now: now))"
                     : "턴 \(Format.elapsed(reading.currentTurnStartedAt, at: now))")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }.frame(height: 15).padding(.top, 3)
            HStack(spacing: 10) {
                RecordBars(row: row, count: FlowSeries.rowCount, scale: scale).frame(height: 10).frame(maxWidth: .infinity)
                SpeedLabel(slot: speed)
            }.frame(height: 12).padding(.top, 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(height: item.height)
        .contentShape(Rectangle())
        .help(RowText.details(reading))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowText.label(reading, children: childCount))
        .accessibilityValue([item.state.title,
                             SessionPresentation.spokenDuration(reading.currentTurnStartedAt, now: now).map { "턴 경과 \($0)" },
                             RowText.output(reading), speed.spoken].compactMap { $0 }.joined(separator: ", "))
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
            Text("—").font(.system(size: 15, weight: .semibold)).foregroundStyle(.tertiary)
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
    private var reading: TokenReading { item.reading }
    private var age: String { Format.age(reading.lastActivity, now: now) }
    /// An idle lead whose subagents are live shows the group's state instead of its own age.
    private var followsGroup: Bool { !item.state.isLive && groupState.isLive && liveChildren > 0 }
    private var groupText: String { "하위 \(liveChildren)개 \(groupState.isRunning ? "진행 중" : "로그 대기")" }
    private var stateAge: String {
        if followsGroup { return groupText }
        switch item.state {
        case .interrupted: return "중단 \(age)"
        case .unfinished: return "종료 기록 없음 · \(age)"
        default: return age
        }
    }
    private var ageHelp: String {
        if followsGroup { return "\(item.state.title) · 마지막 활동 \(age)" }
        return item.state == .unfinished ? "턴 종료 기록 없음 · 마지막 활동 \(age)" : RowText.details(reading)
    }
    var body: some View {
        let speed = SessionPresentation.speed(reading, now: now)
        HStack(spacing: 6) {
            StateDot(state: followsGroup ? groupState : item.state)
            Text(reading.project ?? "프로젝트 미확인").font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail).layoutPriority(2)
            Text(SessionPresentation.shortID(reading)).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            if reading.isSubagent { Text("하위").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize() }
            if childCount > 0 { Text("하위 \(childCount)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary).fixedSize() }
            Spacer(minLength: 6)
            SpeedLabel(slot: speed, compactUnknown: true)
            Text(stateAge).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing).fixedSize()
                .help(ageHelp)
        }
        .padding(.horizontal, 10)
        .frame(height: item.height)
        .contentShape(Rectangle())
        .help(RowText.details(reading))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowText.label(reading, children: childCount))
        .accessibilityValue([item.state.title, "마지막 활동 \(age)", followsGroup ? groupText : nil, speed.spoken]
                                .compactMap { $0 }.joined(separator: ", "))
    }
}

struct ChildSessionRow: View {
    var item: SessionRowItem
    var parent: TokenReading
    var row: FlowSeries.Row?
    var scale: Double
    var now: Date
    private var reading: TokenReading { item.reading }
    var body: some View {
        let speed = SessionPresentation.speed(reading, now: now)
        let live = item.state.isLive
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 12)
            StateDot(state: item.state)
            HStack(spacing: 0) {
                Text(SessionPresentation.agentLabel(reading)).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                if let project = SessionPresentation.childProjectSuffix(reading, parent: parent) {
                    Text(" · \(project)").foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                }
            }.font(.system(size: 11.5))
            if item.state != .idle {
                Text(item.state.title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 6)
            if live {
                RecordBars(row: row, count: FlowSeries.rowCount, scale: scale).frame(width: 48, height: 8)
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    if let output = reading.currentTurnOutputTokens {
                        Text(Format.tokens(output)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(output == 0 ? HierarchicalShapeStyle.tertiary : .primary)
                        Text("tok").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text("—").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
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
        .help(RowText.details(reading) + "\n" + speed.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("하위 에이전트 \(SessionPresentation.agentLabel(reading)), \(reading.model ?? "모델 미확인")")
        .accessibilityValue([item.state.title, live ? RowText.output(reading) : "마지막 활동 \(Format.age(reading.lastActivity, now: now))",
                             speed.spoken].joined(separator: ", "))
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
        .help(RowText.details(reading))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.project ?? "모델 실측"), \(reading.source.title) \(reading.model ?? "모델 미확인")")
        .accessibilityValue("\(speed.spoken), 측정 \(age)")
    }
}

// MARK: - System strip

struct SystemStrip: View {
    var system: SystemSnapshot
    var cpuHistory: [Double]
    var hasSample: Bool

    private func ratio(_ used: UInt64?, _ total: UInt64?) -> Double? { hasSample ? Format.ratio(used, total) : nil }

    var body: some View {
        let memory = ratio(system.memoryUsedBytes, system.memoryTotalBytes)
        let disk = ratio(system.diskUsedBytes, system.diskTotalBytes)
        let upload = StatusBarContent.networkRate(hasSample ? system.uploadBytesPerSecond : nil)
        let download = StatusBarContent.networkRate(hasSample ? system.downloadBytesPerSecond : nil)
        HStack(spacing: 0) {
            cell("CPU", help: "CPU 사용률 \(Format.percent(hasSample ? system.cpuPercent : nil)) · 최근 30초") {
                HStack(spacing: 5) {
                    value(hasSample ? system.cpuPercent : nil)
                    Sparkline(values: Array(cpuHistory.suffix(30))).frame(width: 40, height: 12)
                }
            }.frame(width: 88, height: Self.cellHeight, alignment: .topLeading)
            separator
            capacity("메모리", memory, help: "메모리 \(Format.percent(memory)), \(Format.capacity(system.memoryUsedBytes, system.memoryTotalBytes))")
                .frame(width: 56, height: Self.cellHeight, alignment: .topLeading)
            separator
            capacity("저장 공간", disk, help: "저장 공간 \(Format.percent(disk)), \(Format.capacity(system.diskUsedBytes, system.diskTotalBytes))")
                .frame(width: 56, height: Self.cellHeight, alignment: .topLeading)
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
            .help("네트워크 업로드 \(upload), 다운로드 \(download)\n\(system.localIPs.isEmpty ? "IPv4 주소 미확인" : "IPv4 " + system.localIPs.joined(separator: " · "))")
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

    private func cell<Content: View>(_ title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            content()
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(help)
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

    private func capacity(_ title: String, _ percent: Double?, help: String) -> some View {
        cell(title, help: help) {
            value(percent)
            bar(percent, color: meterColor(percent))
        }
    }

    private var battery: some View {
        let percent = hasSample ? system.batteryPercent : nil
        let charging = system.isCharging == true
        let color: Color = {
            guard let percent, !charging else { return Color.primary.opacity(0.45) }
            return percent <= 10 ? .red : (percent <= 20 ? .orange : Color.primary.opacity(0.45))
        }()
        return cell("배터리", help: "배터리 \(Format.percent(percent)), \(Format.power(system))") {
            HStack(spacing: 2) {
                value(percent)
                if charging { Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(.secondary) }
            }
            bar(percent, color: color)
        }
    }
}
