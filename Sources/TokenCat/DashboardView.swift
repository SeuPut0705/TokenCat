import Accessibility
import AppKit
import SwiftUI

// MARK: - Shared styles

private struct HighContrastKey: EnvironmentKey { static let defaultValue = false }

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Increase Contrast, or forced by fixture snapshots because `colorSchemeContrast` cannot be injected.
    var tokenCatHighContrast: Bool {
        get { self[HighContrastKey.self] }
        set { self[HighContrastKey.self] = newValue }
    }
    /// ImageRenderer snapshots: AppKit-backed controls (menus, bordered buttons) are drawn as static look-alikes.
    var tokenCatSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

/// The 4 pt grid (A0-5). Popover 420 wide, gutters 16, content 388; x values inside a container are container coordinates.
enum DashboardLayout {
    static let width: CGFloat = 420
    static let gutter: CGFloat = 16
    /// Between top-level blocks.
    static let block: CGFloat = 12
    /// Section title to its content.
    static let titleGap: CGFloat = 8
    /// Container inner padding: 12 horizontal, 10 vertical; inner width 364.
    static let inset: CGFloat = 12
    static let insetVertical: CGFloat = 10
    /// Glyph column x = 12–22 (centre 17), text column x = 28, trailing edge x = 376.
    static let glyphX: CGFloat = 12
    static let textX: CGFloat = 28
    /// Child rows: tree guide x = 17, glyph x = 28–38, text x = 44.
    static let guideX: CGFloat = 17
    static let childTextX: CGFloat = 44
    /// Hover and selection fill x = 4–384, radius 6.
    static let rowInset: CGFloat = 4
}

/// The two containers (A0-4): radius 10; dark white 0.05, light white 0.72 + 0.5 pt black 0.06 rule,
/// Increase Contrast 1 pt primary 0.25 in both. `tint` is the first-run card: accent 0.08, no rule.
private struct ContainerBackground: ViewModifier {
    var tint = false
    @Environment(\.tokenCatHighContrast) private var high
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let fill = tint ? Color.accentColor.opacity(0.08) : Color.white.opacity(scheme == .dark ? 0.05 : 0.72)
        return content
            .background(fill, in: shape)
            .overlay {
                if high { shape.strokeBorder(TCColor.primary(0.25), lineWidth: 1) }
                else if !tint && scheme == .light { shape.strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5) }
            }
    }
}

/// Informational secondary text and decoration-only tertiary text, raised under Increase Contrast.
private struct TextTone: ViewModifier {
    var tertiary = false
    @Environment(\.tokenCatHighContrast) private var high
    func body(content: Content) -> some View {
        content.foregroundStyle(tertiary ? TCColor.textTertiary(contrast: high) : TCColor.textSecondary(contrast: high))
    }
}

/// Copy and reveal only, mirrored as VoiceOver actions; file contents are never opened.
private struct RowActions: ViewModifier {
    var reading: TokenReading
    func body(content: Content) -> some View {
        let actions = SessionPresentation.rowActions(reading)
        let copies = actions.filter { !$0.isReveal }, reveals = actions.filter(\.isReveal)
        return content
            .contextMenu {
                ForEach(copies) { action in Button { Self.perform(action) } label: { Label(action.title, systemImage: action.symbol) } }
                if !copies.isEmpty && !reveals.isEmpty { Divider() }
                ForEach(reveals) { action in Button { Self.perform(action) } label: { Label(action.title, systemImage: action.symbol) } }
            }
            .accessibilityActions { ForEach(actions) { action in Button(action.title) { Self.perform(action) } } }
    }
    static func perform(_ action: SessionPresentation.RowAction) {
        switch action.kind {
        case .copy(let text): copyToPasteboard(text)
        case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Hover and keyboard selection for one row: x = 4–384, radius 6, no animation. The fill alone is under 3:1 against the
/// container, so the selection, the list's only keyboard indicator, also gets a 1.5 pt accent border.
private struct RowChrome: ViewModifier {
    var selected: Bool
    @State private var hovering = false
    @Environment(\.tokenCatHighContrast) private var high
    @Environment(\.controlActiveState) private var active
    func body(content: Content) -> some View {
        let fill = selected ? TCColor.selection(keyWindow: active == .key) : (hovering ? TCColor.hover(contrast: high) : Color.clear)
        return content
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill).padding(.horizontal, DashboardLayout.rowInset))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 1.5)
                        .padding(.horizontal, DashboardLayout.rowInset)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The system draws its own ring on a focused list on macOS 14; the selection fill is the indicator here.
private struct NoFocusEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.focusEffectDisabled() } else { content }
    }
}

extension View {
    /// Internal so fixtures can frame component previews the same way.
    func container(tint: Bool = false) -> some View { modifier(ContainerBackground(tint: tint)) }
    fileprivate func toneSecondary() -> some View { modifier(TextTone()) }
    fileprivate func toneTertiary() -> some View { modifier(TextTone(tertiary: true)) }
    fileprivate func rowActions(_ reading: TokenReading) -> some View { modifier(RowActions(reading: reading)) }
    fileprivate func rowChrome(selected: Bool) -> some View { modifier(RowChrome(selected: selected)) }
}

/// Secondary-tone text: hover makes it primary. Icon buttons hover inside a circle; text buttons inside a 5 pt rounded
/// rectangle. Keyboard focus draws a 2 pt focus-indicator ring in the same shape; `ring: false` inside the focusable
/// session list, where `isFocused` reports the list's focus rather than the button's.
struct HoverButtonStyle: ButtonStyle {
    var circle = false
    var ring = true
    func makeBody(configuration: Configuration) -> some View { HoverLabel(configuration: configuration, circle: circle, ring: ring) }
    private struct HoverLabel: View {
        var configuration: Configuration
        var circle: Bool
        var ring: Bool
        @State private var hovering = false
        @Environment(\.isFocused) private var focused
        @Environment(\.tokenCatHighContrast) private var high
        var body: some View {
            let shape = circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            let fill = configuration.isPressed ? TCColor.pressed(contrast: high) : (hovering ? TCColor.hover(contrast: high) : Color.clear)
            return configuration.label
                .foregroundStyle(hovering || configuration.isPressed ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                                 : AnyShapeStyle(TCColor.textSecondary(contrast: high)))
                .background(fill, in: shape)
                .overlay { if focused && ring { shape.stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2) } }
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

/// `.bordered` `.small` in the app. ImageRenderer cannot draw AppKit buttons, so snapshots get a look-alike.
struct SmallBorderedButton: View {
    var title: String
    var action: () -> Void
    @Environment(\.tokenCatSnapshot) private var snapshot
    var body: some View {
        if snapshot {
            Text(title).font(.system(size: 11)).padding(.horizontal, 8).frame(height: 20)
                .background(TCColor.primary(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .fixedSize()
        } else {
            Button(title, action: action).buttonStyle(.bordered).controlSize(.small).fixedSize()
        }
    }
}

/// A 4 pt meter: `track` behind, the fill in `color`.
struct Meter: View {
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(TCColor.track)
                if fraction > 0 { Capsule().fill(color).frame(width: max(geometry.size.height, geometry.size.width * min(1, fraction))) }
            }
        }
        .accessibilityHidden(true)
    }

    /// Neutral below 85 %, warning from 85 %, critical from 95 %.
    static func color(_ percent: Double?) -> Color {
        guard let percent else { return TCColor.neutral }
        return percent >= 95 ? TCColor.critical : (percent >= 85 ? TCColor.warning : TCColor.neutral)
    }
}

/// Where the dashboard is shown. The panel lets the session list fill its height and hides "패널로 분리".
enum DashboardPresentation {
    case popover, panel
}

/// Everything the dashboard asks of the app shell; views never reach windows or apps themselves.
struct DashboardActions {
    var settings: () -> Void
    var quit: () -> Void
    var about: () -> Void
    var activityMonitor: () -> Void
    /// Move the popover's content into the detached panel.
    var detach: () -> Void
    /// Settings, opened at the telemetry section.
    var openTelemetrySettings: () -> Void

    /// For snapshots and fixtures: every action does nothing.
    static let none = DashboardActions(settings: {}, quit: {}, about: {}, activityMonitor: {}, detach: {}, openTelemetrySettings: {})
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var presentation: DashboardPresentation = .popover
    var actions: DashboardActions
    /// False for ImageRenderer snapshots: no scroll surface, no menu, no first-run card, no timers.
    var scrollsSessions = true
    /// Fixture snapshots only: a keyboard-selected row and an open detail, by row id.
    var selection: String? = nil
    var detail: String? = nil
    @AppStorage("onboardingSeen") private var onboardingSeen = false
    @AppStorage(TelemetrySetup.optOutKey) private var telemetryOptedOut = false
    /// The flow card had records during this showing; it collapses again only at the next showing (F-5).
    @State private var flowOpened = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tokenCatHighContrast) private var forcedContrast

    private var loading: Bool { model.tokensSampledAt == nil }
    private var flowEmpty: Bool { !loading && model.flow.total == 0 && model.sessions.counts.liveGroups == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardHeader(model: model, presentation: presentation, actions: actions, interactive: scrollsSessions)
            if scrollsSessions && !onboardingSeen {
                // "감쌌습니다(출력 그대로)" only while the original status line command is known.
                OnboardingCard(outcome: OnboardingCard.outcome(notice: telemetryNotice, note: model.telemetrySetupNote,
                                                               failure: model.telemetrySetupFailure, state: model.telemetryState,
                                                               bridged: model.claudeBridged == true
                                                                   && !model.telemetryConnectNotes.contains(.originalUnknown),
                                                               optedOut: telemetryOptedOut),
                               settings: actions.openTelemetrySettings, dismiss: { onboardingSeen = true })
                    .padding(.top, DashboardLayout.block)
            }
            VStack(spacing: 0) {
                FlowCard(flow: model.flow, counts: model.sessions.counts, now: model.now, loading: loading,
                         newestOutputAt: model.newestOutputAt, collapsed: flowEmpty && !flowOpened,
                         speed: loading ? nil : SessionPresentation.speedHeadline(model.sessions, now: model.now,
                                                                                  restart: model.telemetryRestartNeeded))
                if let limit = model.sessions.usageLimit, limit.isShown(now: model.now) {
                    UsageLimitRow(limit: limit, now: model.now)
                }
                if let limit = SessionPresentation.claudeUsageLimit(model.claudeLimits, now: model.now), limit.isShown(now: model.now) {
                    UsageLimitRow(limit: limit, now: model.now)
                }
            }
            .container()
            .padding(.top, DashboardLayout.block)
            SessionsHeader(model: model).padding(.top, DashboardLayout.block)
            SessionList(model: model, scrolls: scrollsSessions, presentation: presentation, selection: selection, detail: detail)
                .padding(.top, DashboardLayout.titleGap)
            SystemArea(system: model.system, cpuHistory: model.cpuHistory, hasSample: model.hasSample, open: actions.activityMonitor)
                .padding(.top, DashboardLayout.block)
            DashboardFooter(status: footerStatus, notice: telemetryNotice, help: footerHelp, open: actions.openTelemetrySettings,
                            update: model.update.notice(dismissed: model.preferences.dismissedUpdateVersion), updateAction: model.requestUpdate)
                .padding(.top, DashboardLayout.block)
        }
        .padding(.top, 12).padding(.horizontal, DashboardLayout.gutter).padding(.bottom, 12)
        .frame(width: DashboardLayout.width)
        // A panel shorter than the content clips the list's end, never the header (no centring).
        .frame(maxHeight: presentation == .panel ? .infinity : nil, alignment: .top)
        .buttonStyle(HoverButtonStyle())
        .environment(\.tokenCatHighContrast, forcedContrast || contrast == .increased)
        .environment(\.tokenCatSnapshot, !scrollsSessions)
        .onAppear { flowOpened = !flowEmpty }
        .onChange(of: flowEmpty) { empty in if !empty { flowOpened = true } }
        .onChange(of: model.popoverShownAt) { _ in flowOpened = !flowEmpty }
    }

    private var telemetryNotice: TelemetryNotice? {
        SessionPresentation.telemetryNotice(state: model.telemetryState, status: model.telemetryStatus, note: model.telemetrySetupNote,
                                            failure: model.telemetrySetupFailure, restart: model.telemetryRestartNeeded,
                                            expired: model.telemetryRestartExpired)
    }

    private var footerStatus: FooterStatus {
        let tokenDelay = model.tokensSampledAt.map { Int(model.now.timeIntervalSince($0)) } ?? 0
        return SessionPresentation.footerStatus(loading: !model.hasSample || loading, tokenDelay: tokenDelay,
                                                systemDelay: Int(model.now.timeIntervalSince(model.system.sampledAt)), notice: telemetryNotice)
    }

    private var footerHelp: String {
        loc("시스템과 AI 기록을 1초마다, 로그 변경 시 즉시 확인합니다", "Checks system and AI records every second, and right away when a log changes")
            + "\n\(SessionPresentation.telemetryReceipt(model.telemetryLastReceived, now: model.now))\n\(model.telemetryStatus)"
    }
}

// MARK: - Header

/// Pixel head, state glyph and the one status sentence (H-1–H-3); settings and the ⋯ menu on the right.
struct DashboardHeader: View {
    @ObservedObject var model: DashboardModel
    var presentation: DashboardPresentation
    var actions: DashboardActions
    var interactive: Bool
    @State private var blinking = false
    @State private var blink: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tokenCatHighContrast) private var high

    var body: some View {
        let status = header(spoken: false)
        HStack(spacing: 0) {
            Image(nsImage: Runner.headImage(blinking ? .blink : status.head))
                .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 22).accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let glyph = status.glyph { StateGlyphView(kind: glyph, side: 8, contrast: high).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 } }
                sentence(status).lineLimit(1).truncationMode(.tail)
            }
            .padding(.leading, 8)
            .help(status.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(loc("세션 상태", "Session status"))
            .accessibilityValue(header(spoken: true).spoken)
            .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 8)
            Button(action: actions.settings) { Image(systemName: "gearshape").font(.system(size: 14)).frame(width: 24, height: 24) }
                .buttonStyle(HoverButtonStyle(circle: true))
                .help(loc("설정 (⌘,)", "Settings (⌘,)")).accessibilityLabel(loc("설정", "Settings"))
            menu.padding(.leading, 4)
        }
        .frame(height: 28)
        .onAppear(perform: scheduleBlink)
        .onChange(of: model.popoverShownAt) { _ in scheduleBlink() }
        .onDisappear { blink?.cancel(); blinking = false }
    }

    private func header(spoken: Bool) -> HeaderStatus {
        SessionPresentation.headerStatus(counts: model.sessions.counts, loading: model.tokensSampledAt == nil, now: model.now,
                                         quietSince: model.runnerQuietSince, spoken: spoken)
    }

    private func sentence(_ status: HeaderStatus) -> Text {
        let secondary = TCColor.textSecondary(contrast: high)
        return Text(status.sentence).font(TCFont.title).foregroundColor(status.muted ? secondary : nil)
            + Text(status.suffix).font(TCFont.meta).foregroundColor(secondary)
    }

    @ViewBuilder private var menu: some View {
        let icon = Image(systemName: "ellipsis.circle").font(.system(size: 14))
        if interactive {
            Menu {
                if presentation == .popover { Button(loc("패널로 분리", "Detach as Panel"), action: actions.detach) }
                Button(loc("설정…", "Settings…"), action: actions.settings).keyboardShortcut(",")
                Button(loc("활성 상태 보기", "Activity Monitor"), action: actions.activityMonitor)
                Button(loc("TokenCat 정보", "About TokenCat"), action: actions.about)
                Divider()
                Button(loc("TokenCat 종료", "Quit TokenCat"), action: actions.quit).keyboardShortcut("q")
            } label: { icon }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            // The gear beside it is secondary; the menu button would otherwise take the body colour.
            .tint(TCColor.textSecondary(contrast: high))
            .frame(width: 24, height: 24)
            .help(loc("더 보기", "More")).accessibilityLabel(loc("더 보기", "More"))
        } else {
            // ImageRenderer cannot draw an AppKit menu button.
            icon.frame(width: 24, height: 24).toneSecondary()
        }
    }

    /// One 0.12 s blink 0.35 s after the dashboard shows; never in snapshots or with Reduce Motion.
    private func scheduleBlink() {
        blink?.cancel()
        blinking = false
        guard interactive, !reduceMotion else { return }
        blink = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            blinking = true
            try? await Task.sleep(nanoseconds: 120_000_000)
            blinking = false
        }
    }
}

// MARK: - First run

/// Shown once in the interactive popover, never in snapshots; only ✕ dismisses it.
/// The telemetry line says only what actually happened: collector down, setup skipped or failed, still starting, or added
/// (with the Claude Code status line wrapped or not); "설정 열기" at its end stands out when something did not apply.
struct OnboardingCard: View {
    enum Outcome: Equatable { case added(bridged: Bool), skipped(String), failed(String), collectorDown(String), preparing }
    var outcome: Outcome
    var settings: () -> Void
    var dismiss: () -> Void
    static let backupPath = "~/Library/Application Support/TokenCat/telemetry-backups"

    /// `bridged`: Claude Code settings run the usage-limit bridge with a known original command.
    /// Starts the connect failure note (App.swift), which the card strips to show only the reason.
    static var notePrefix: String { loc("실측 연결: ", "Telemetry: ") }

    static func outcome(notice: TelemetryNotice?, note: String?, failure: TelemetrySetupFailure?, state: TelemetryCollectorState,
                        bridged: Bool = false, optedOut: Bool = false) -> Outcome {
        if let notice, notice.collectorDown { return .collectorDown(notice.text) }
        if optedOut { return .skipped(loc("--disconnect-telemetry로 연결을 해제한 상태입니다", "Disconnected with --disconnect-telemetry")) }
        if let note {
            let reason = note.replacingOccurrences(of: notePrefix, with: "")
            return failure == .conflict || failure == .invalid ? .skipped(reason) : .failed(reason)
        }
        return state == .starting ? .preparing : .added(bridged: bridged)
    }

    /// `tail` ends the detail ("A · B" on one line); when the line is too long it starts the second line, before the links.
    private var telemetry: (title: String, detail: String, tail: String?) {
        switch outcome {
        case .added(let bridged):
            return (loc("실측을 위해 Codex·Claude Code 설정에 로컬 전송을 추가했습니다",
                        "Added local telemetry to Codex and Claude Code settings"),
                    bridged ? loc("Claude Code 상태 표시줄도 한도만 읽도록 감쌌습니다(출력 그대로)",
                                  "Also wrapped the Claude Code status line to read limits (output unchanged)")
                        : loc("새로 실행할 때부터 적용됩니다", "Applies from the next launch"),
                    bridged ? loc("새로 실행할 때부터 적용", "Applies from the next launch") : nil)
        case .skipped(let reason): return (loc("실측 연결을 건너뛰었습니다", "Skipped connecting telemetry"), reason, nil)
        case .failed(let reason): return (loc("실측 연결을 완료하지 못했습니다", "Couldn't finish connecting telemetry"), reason, nil)
        case .collectorDown(let text): return (loc("실측 연결을 하지 않았습니다", "Didn't connect telemetry"), text, nil)
        case .preparing: return (loc("실측 수집기를 준비하고 있습니다", "Preparing the telemetry collector"),
                                 loc("준비되면 Codex·Claude Code 설정에 로컬 전송을 추가합니다",
                                     "Adds local telemetry to Codex and Claude Code settings when it's ready"), nil)
        }
    }

    private var added: Bool { if case .added = outcome { return true } else { return false } }

    /// Skipped, failed or collector down: the way to Settings is the next step.
    private var needsSettings: Bool {
        switch outcome {
        case .skipped, .failed, .collectorDown: return true
        case .added, .preparing: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: Runner.headImage(.normal)).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 11).accessibilityHidden(true)
                Text(loc("TokenCat이 하는 일", "What TokenCat does")).font(TCFont.title).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18) }
                    .buttonStyle(HoverButtonStyle(circle: true))
                    .help(loc("안내 닫기", "Close welcome")).accessibilityLabel(loc("안내 닫기", "Close welcome"))
            }
            .frame(height: 18)
            row("lock.shield", loc("대화 본문은 저장하지 않습니다", "Doesn't store conversation text"),
                loc("모델·토큰 수·도구 종류·프로젝트 폴더 같은 메타데이터만 읽습니다",
                    "Reads only metadata such as models, token counts, tool types and project folders"))
            row("slider.horizontal.3", telemetry.title, telemetry.detail, tail: telemetry.tail, links: true)
            row("hand.raised", loc("모델 호출·계정 로그인을 하지 않습니다", "Doesn't call models or sign in to accounts"),
                loc("인터넷 요청은 GitHub 새 버전 확인·내려받기와 OpenAI·Anthropic 사용량 확인뿐입니다(설정에서 끄기)",
                    "Only goes online to check GitHub for new versions and to ask OpenAI and Anthropic for usage (turn off in Settings)"))
        }
        .padding(12)
        .buttonStyle(.automatic)
        .container(tint: true)
    }

    /// The links follow the detail on its line when they fit, otherwise they start the next line (after `tail`).
    private func row(_ symbol: String, _ title: String, _ detail: String, tail: String? = nil, links: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: symbol).font(TCFont.body).foregroundStyle(Color.accentColor).frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(TCFont.metaMedium).fixedSize(horizontal: false, vertical: true)
                if links {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            detailText(([detail] + [tail].compactMap { $0 }).joined(separator: " · ")).fixedSize()
                            linkButtons
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            detailText(detail).fixedSize(horizontal: false, vertical: true)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if let tail { detailText(tail).fixedSize() }
                                linkButtons
                            }
                        }
                    }
                } else {
                    detailText(detail).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detailText(_ text: String) -> some View { Text(text).font(TCFont.meta).toneSecondary() }

    @ViewBuilder private var linkButtons: some View {
        if added {
            link(loc("백업 보기", "Show backup"), help: loc("원본 백업 \(Self.backupPath) · Finder에서 보여 주기만 합니다",
                                                 "Original backup \(Self.backupPath) · only shows it in Finder")) {
                let url = URL(fileURLWithPath: (Self.backupPath as NSString).expandingTildeInPath, isDirectory: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        link(loc("설정 열기", "Open settings"), help: loc("설정의 실측 탭을 엽니다", "Opens the Telemetry tab in Settings"), emphasized: needsSettings, action: settings)
    }

    /// An underlined 11 pt medium text button; accent when it is the next step.
    private func link(_ title: String, help: String, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(TCFont.metaMedium).underline().foregroundStyle(emphasized ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.primary))
        }
        .buttonStyle(.plain).fixedSize()
        .help(help)
    }
}

// MARK: - Flow card

/// The 60 hero buckets for VoiceOver's audio graph and data table.
struct FlowChartDescriptor: AXChartDescriptorRepresentable {
    var values: [Int]
    func makeChartDescriptor() -> AXChartDescriptor {
        let span = Double(max(0, values.count - 1)) * FlowSeries.bucketSeconds
        let x = AXNumericDataAxisDescriptor(title: loc("시간", "Time"), range: -span...0, gridlinePositions: []) { value in
            value >= 0 ? loc("지금", "Now") : Format.ago(Format.span(Int(-value), .second, spoken: true))
        }
        let y = AXNumericDataAxisDescriptor(title: loc("출력 토큰", "Output tokens"), range: 0...Double(max(values.max() ?? 0, 1)), gridlinePositions: []) { value in
            loc("\(Int(value)) 토큰", plural(Int(value), "token"))
        }
        let points = values.enumerated().map { index, value in
            AXDataPoint(x: Double(index - (values.count - 1)) * FlowSeries.bucketSeconds, y: Double(value))
        }
        return AXChartDescriptor(title: loc("최근 5분 출력 토큰 기록", "Output tokens recorded in the last 5 min"),
                                 summary: loc("5초 동안 로그에 기록된 출력 토큰 수이며 속도가 아닙니다",
                                              "Output tokens recorded in the log per 5 s, not a speed"),
                                 xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [AXDataSeriesDescriptor(name: loc("5초 기록량", "Recorded per 5 s"), isContinuous: false, dataPoints: points)])
    }
}

struct FlowCard: View {
    var flow: FlowSeries
    var counts: SessionCounts
    var now: Date
    var loading: Bool
    var newestOutputAt: Date?
    var collapsed: Bool
    /// "지금 속도" (`SessionPresentation.speedHeadline`): measured by the client, never derived from these log records.
    var speed: SpeedHeadline? = nil
    @State private var showsHelp = false
    @Environment(\.tokenCatHighContrast) private var high
    static var help: String {
        loc("막대 하나는 5초 동안 로그에 기록된 출력 토큰 수입니다. Codex는 응답이 끝날 때, Claude Code는 메시지가 끝날 때 기록하므로 생성 중인 토큰은 아직 포함되지 않습니다. 속도로 환산하지 않습니다.",
            "Each bar is the number of output tokens recorded in the log over 5 seconds. Codex records them when a response ends and Claude Code when a message ends, so tokens still being generated aren't included yet. They're never converted into a speed.")
    }

    private var total: Int { flow.total }
    private var caption: FlowCaption { SessionPresentation.flowCaption(counts: counts, last: flow.last?.at, now: now) }
    private var lowerHeight: CGFloat? { Self.lowerHeight(loading: loading, total: total, speed: speed) }
    /// The slot under the number: the provider split on the left, "지금 속도" on the right. Always 18 pt (its 15 pt value),
    /// so the card and the popover do not move by 4 pt each time the speed comes and goes.
    static func lowerHeight(loading: Bool, total: Int, speed: SpeedHeadline?) -> CGFloat? {
        guard !loading, total > 0 || speed != nil else { return nil }
        return 18
    }

    var body: some View {
        Group {
            if collapsed { collapsedRow } else { card }
        }
        .padding(.horizontal, DashboardLayout.inset).padding(.vertical, DashboardLayout.insetVertical)
        .accessibilityElement(children: .contain)
    }

    private var collapsedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(loc("출력 토큰", "Output tokens")).font(TCFont.title).fixedSize().accessibilityAddTraits(.isHeader)
            Text(loc("최근 5분 기록 없음", "None in the last 5 min")).font(TCFont.meta).toneSecondary().lineLimit(1)
            Spacer(minLength: 8)
            // Without any output yet the row already says "기록 없음" once.
            if let newestOutputAt {
                Text(loc("마지막 출력 ", "Last output ") + SessionPresentation.helpAge(newestOutputAt, now: now))
                    .font(TCFont.metaMono).toneSecondary().lineLimit(1).fixedSize()
            }
        }
        .frame(height: 20)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow.frame(height: 16)
            VStack(alignment: .leading, spacing: 0) {
                numberRow.frame(height: 32).padding(.top, 6)
                if let lowerHeight { Color.clear.frame(height: lowerHeight).padding(.top, 2) }
                FlowChart(values: flow.hero, fresh: flow.fresh, loading: loading).frame(height: 61).padding(.top, 8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(loc("최근 5분 출력 토큰 기록", "Output tokens recorded in the last 5 min"))
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(Self.help)
            .accessibilityChartDescriptor(FlowChartDescriptor(values: flow.hero))
            // Drawn over the reserved slot, outside the record element: the speed is its own VoiceOver element,
            // since the record element says it is not a speed.
            .overlay(alignment: .top) {
                if let lowerHeight {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        providerRow.fixedSize().accessibilityHidden(true)
                        Spacer(minLength: 8)
                        if let speed { SpeedHeadlineView(headline: speed) }
                    }
                    .frame(height: lowerHeight).padding(.top, 40)
                }
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(loc("출력 토큰", "Output tokens")).font(TCFont.title).fixedSize().accessibilityAddTraits(.isHeader)
            Text(loc("최근 5분 · 로그 기록 기준", "Last 5 min · based on log records")).font(TCFont.meta).toneSecondary().lineLimit(1)
            Spacer(minLength: 4)
            Button { showsHelp.toggle() } label: { Image(systemName: "info.circle").font(TCFont.meta).frame(width: 20, height: 20) }
                .buttonStyle(HoverButtonStyle(circle: true))
                .popover(isPresented: $showsHelp, arrowEdge: .bottom) { FlowHelp() }
                .help(loc("출력 토큰 설명", "About output tokens")).accessibilityLabel(loc("출력 토큰 설명", "About output tokens"))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
    }

    private var numberRow: some View {
        let secondary = TCColor.textSecondary(contrast: high)
        return HStack(alignment: .lastTextBaseline, spacing: 0) {
            (Text(loading ? "0,000" : Format.tokens(total)).font(TCFont.hero).foregroundColor(total == 0 && !loading ? secondary : nil)
                + Text(" tok").font(TCFont.body).foregroundColor(secondary))
                .lineLimit(1).fixedSize()
                .redacted(reason: loading ? .placeholder : [])
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    if let glyph = caption.glyph, !loading { StateGlyphView(kind: glyph, side: 8, contrast: high) }
                    Text(loading ? SessionPresentation.lastRecordCaption : caption.text).font(TCFont.meta).lineLimit(1).truncationMode(.tail)
                        .foregroundColor(caption.emphasized && !loading ? nil : secondary)
                }
                .frame(maxWidth: 220, alignment: .trailing)
                .help(caption.help)
                lastValue
            }
        }
    }

    @ViewBuilder private var lastValue: some View {
        if loading {
            Text(loc("+0,000 tok · 방금", "+0,000 tok · just now")).font(TCFont.bodyMediumMono).redacted(reason: .placeholder)
        } else if let last = flow.last {
            HStack(spacing: 4) {
                if SessionPresentation.isFresh(last.at, now: now) { Circle().fill(TCColor.activity).frame(width: 6, height: 6) }
                Text("+\(Format.tokens(last.tokens)) tok · \(SessionPresentation.recordAge(last.at, now: now))")
                    .font(TCFont.bodyMediumMono).lineLimit(1).fixedSize()
            }
        } else {
            // The caption already says "기록 없음" when it matters; the value stays an unknown.
            Text("—").font(TCFont.bodyMediumMono).toneTertiary()
        }
    }

    /// Both clients: "Codex 1.2k · Claude Code 6.6k"; one client: its name only, never the hero number again.
    private var providerRow: some View {
        let parts = TokenSource.allCases.compactMap { source -> (TokenSource, Int)? in
            guard let value = flow.byProvider[source], value > 0 else { return nil }
            return (source, value)
        }
        let text = parts.count > 1 ? parts.map { "\($0.0.title) \(Format.compactTokens($0.1))" }.joined(separator: " · ")
            : (parts.first?.0.title ?? "")
        return Text(text).font(TCFont.metaMono).toneSecondary().lineLimit(1)
    }

    private var accessibilityValue: String {
        if loading { return loc("기록 확인 중", "Reading records") }
        var parts = [loc("\(total.formatted()) 토큰", plural(total, "token"))]
        if let last = flow.last {
            let age = SessionPresentation.recordAge(last.at, now: now, spoken: true)
            parts.append(loc("마지막 기록 \(last.tokens.formatted()) 토큰, \(age)", "Last record \(plural(last.tokens, "token")), \(age)"))
        }
        else { parts.append(loc("최근 5분 동안 출력 기록 없음", "No output recorded in the last 5 min")) }
        let caption = SessionPresentation.flowCaption(counts: counts, last: flow.last?.at, now: now, spoken: true)
        if caption.glyph != nil || caption.text != SessionPresentation.lastRecordCaption { parts.append(caption.text) }
        parts.append(loc("로그 기록 시점 기준이며 속도가 아닙니다", "Based on log record times, not a speed"))
        return parts.joined(separator: ". ")
    }
}

/// "지금 속도 · TokenCat  52.3 요청 tok/s": the value in `metric`, one step under the hero and above the last record.
/// The label drops first when the row is tight, then the project; help and VoiceOver always name the session.
private struct SpeedHeadlineView: View {
    var headline: SpeedHeadline
    @Environment(\.tokenCatHighContrast) private var high

    var body: some View {
        ViewThatFits(in: .horizontal) {
            labelled(headline.project.map { loc("지금 속도 · ", "Speed now · ") + $0 } ?? loc("지금 속도", "Speed now"))
            labelled(headline.project ?? loc("지금 속도", "Speed now"))
            value
        }
        .help(headline.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc("지금 속도", "Speed now"))
        .accessibilityValue(headline.spoken)
    }

    private func labelled(_ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(TCFont.meta).toneSecondary().lineLimit(1).fixedSize()
            value
        }
    }

    /// An unknown rate is a tertiary "—" with " tok/s", like the row's speed cell, so it never reads as a divider.
    private var value: some View {
        let unit = Text(" " + (headline.kind ?? "tok/s")).font(TCFont.micro).foregroundColor(TCColor.textSecondary(contrast: high))
        return (Text(headline.value).font(TCFont.metric).foregroundColor(headline.known ? nil : TCColor.textTertiary(contrast: high)) + unit)
            .lineLimit(1).fixedSize()
    }
}

/// ⓘ: the full explanation and the two-line legend, also reachable by keyboard (F-6).
private struct FlowHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FlowCard.help).font(TCFont.meta).fixedSize(horizontal: false, vertical: true)
            legend(TCColor.neutral, loc("막대 하나 = 5초 동안 기록된 출력", "One bar = output recorded over 5 s"))
            legend(TCColor.activity, loc("초록 = 최근 5초 안 기록", "Green = recorded in the last 5 s"))
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }
    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            // One 10 pt slot draws a 6 × 10 pt bar, shaped like the chart's.
            FlowBars(values: [1], scale: 1).fill(color).frame(width: 10, height: 10)
            Text(text).font(TCFont.meta)
        }
    }
}

/// Label band 10 + plot 36 + gap 3 + axis 12 (F-3). Loading draws only the baseline and the axis.
struct FlowChart: View {
    var values: [Int]
    var fresh: [Bool]
    var loading: Bool
    @Environment(\.tokenCatHighContrast) private var high

    var body: some View {
        let peak = loading ? 0 : (values.max() ?? 0)
        let scale = niceMax(Double(peak))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(peak > 0 ? Format.compactTokens(Int(scale)) : " ").font(TCFont.micro.monospacedDigit()).toneSecondary()
            }
            .frame(height: 10)
            ZStack(alignment: .top) {
                if peak > 0 {
                    Rectangle().fill(TCColor.primary(0.08)).frame(height: 0.5)
                    VStack(spacing: 0) {
                        ZStack {
                            FlowBars(values: values, scale: scale).fill(high ? TCColor.primary(0.6) : TCColor.neutral)
                            FlowBars(values: values, scale: scale, mask: fresh).fill(TCColor.activity)
                        }
                        Color.clear.frame(height: 1)
                    }
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(TCColor.primary(high ? 0.25 : 0.12)).frame(height: 1)
                }
            }
            .frame(height: 36)
            ticks.frame(height: 3)
            HStack(spacing: 0) {
                Text(Format.ago(Format.span(5, .minute)))
                Spacer(minLength: 0)
                Text(loc("지금", "now"))
            }
            .font(TCFont.micro).toneSecondary().frame(height: 12)
        }
        .accessibilityHidden(true)
    }

    /// Minute marks below the baseline at −4, −3, −2 and −1 min.
    private var ticks: some View {
        Canvas { context, size in
            var path = Path()
            for minute in 1...4 {
                let x = (size.width * (1 - CGFloat(minute) / 5) * 2).rounded() / 2
                path.addRect(CGRect(x: x - 0.5, y: 0, width: 1, height: 3))
            }
            context.fill(path, with: .color(TCColor.primary(high ? 0.35 : 0.18)))
        }
    }
}

// MARK: - Usage limits

/// The AI container's bottom rows (Codex, then Claude): the last recorded or live-read limit window, always with its record
/// age or "실시간"; no forecast.
struct UsageLimitRow: View {
    var limit: UsageLimitSummary
    var now: Date
    @Environment(\.tokenCatHighContrast) private var high

    var body: some View {
        let expired = limit.expired(now: now)
        let details = limit.details(now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(limit.title).font(TCFont.meta).toneSecondary().lineLimit(1).fixedSize()
                value(expired: expired).padding(.leading, 6).fixedSize()
                Spacer(minLength: 8)
                // The reset countdown is never truncated; the record age drops first.
                ViewThatFits(in: .horizontal) {
                    ForEach(details, id: \.self) { Text($0).font(TCFont.metaMono).toneSecondary().lineLimit(1).fixedSize() }
                }
            }
            .frame(height: 16)
            if !expired {
                Meter(fraction: limit.usedPercent / 100, color: Meter.color(limit.usedPercent)).frame(height: 4).padding(.top, 5)
            }
        }
        .padding(.horizontal, DashboardLayout.inset).padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(TCColor.hairline(contrast: high)).frame(height: 0.5).padding(.horizontal, DashboardLayout.inset)
        }
        .help(limit.help(now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.title)
        .accessibilityValue(limit.spoken(now: now))
    }

    private func value(expired: Bool) -> Text {
        let secondary = TCColor.textSecondary(contrast: high)
        if expired { return Text("—").font(TCFont.value).foregroundColor(TCColor.textTertiary(contrast: high)) }
        return Text(limit.percentText).font(TCFont.value).foregroundColor(limit.isOld(now: now) ? secondary : nil)
            + Text("%").font(TCFont.micro).foregroundColor(secondary)
            + Text(loc(" 사용", " used")).font(TCFont.meta).foregroundColor(secondary)
    }
}

// MARK: - Sessions

struct SessionsHeader: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        let list = model.sessions
        let expanded = model.sessionsExpanded
        HStack(spacing: 6) {
            Text(loc("세션", "Sessions")).font(TCFont.title).accessibilityAddTraits(.isHeader)
                .help(loc("↑↓ 이동 · Return 상세 · ⌘C ID 복사", "↑↓ move · Return details · ⌘C copy ID")
                      + (list.showsSpeedColumn ? "" : loc("\n속도 실측 없음 · 로그 시각으로 추정하지 않습니다",
                                                          "\nNo measured speed · not estimated from log times")))
            Spacer(minLength: 6)
            if list.hiddenGroups + list.hiddenChildren > 0 || expanded {
                Button { model.sessionsExpanded.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(expanded ? loc("접기", "Show less")
                             : (list.hiddenGroups > 0 ? loc("\(list.counts.groups)개 모두 보기", "Show all \(list.counts.groups)")
                                : loc("하위 \(list.hiddenChildren)개 더 보기", "Show \(plural(list.hiddenChildren, "more subagent"))")))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").imageScale(.small)
                    }
                    .font(TCFont.metaMedium).padding(.horizontal, 6).frame(height: 20)
                }
                .fixedSize()
                .padding(.trailing, -6)
                .help(loc("하위 에이전트 포함 \(list.counts.readings)개 기록", "\(plural(list.counts.readings, "record")) including subagents")
                      + (expanded || list.hiddenGroups == 0 ? "" : loc(" · 접힌 세션 \(list.hiddenGroups)개", " · \(plural(list.hiddenGroups, "collapsed session"))")))
                .accessibilityLabel(expanded ? loc("세션 목록 접기", "Collapse session list")
                                    : (list.hiddenGroups > 0 ? loc("세션 목록 모두 보기", "Show all sessions") : loc("하위 에이전트 더 보기", "Show more subagents")))
                .accessibilityValue(expanded ? "" : "\(list.hiddenGroups > 0 ? list.counts.groups : list.hiddenChildren)" + loc("개", ""))
            }
        }
        .frame(height: 18)
    }
}

/// What every row needs from the list: the clock, the shared column rules and the list's selection state.
struct RowContext {
    var now: Date
    var restart: Set<TokenSource>
    var showsSpeed: Bool
    var sharedProjects: Set<String>
    var selectedID: String?
    var detailID: String?
    var rotor: Namespace.ID
    var tap: (String) -> Void

    func detailHeight(_ item: SessionRowItem) -> CGFloat {
        detailID == item.id ? SessionPresentation.detailHeight(item.reading, state: item.state) : 0
    }
    /// The speed cell for a row's third line (`SessionPresentation.speedCell`).
    func speed(_ item: SessionRowItem) -> SpeedSlot? {
        SessionPresentation.speedCell(item.reading, state: item.state, now: now, showsColumn: showsSpeed, restart: restart)
    }
    func showsID(_ reading: TokenReading) -> Bool { reading.project.map(sharedProjects.contains) ?? false }
}

struct SessionList: View {
    @ObservedObject var model: DashboardModel
    var scrolls: Bool
    var presentation: DashboardPresentation
    /// Grow-only while the popover stays open so rows changing type do not resize it.
    @State private var viewportFloor: CGFloat = 0
    /// The group whose "+N 하위" row expanded the list; the header toggle scrolls to the top instead.
    @State private var focus: String?
    @State private var showOlder = false
    @State private var selectedID: String?
    @State private var selectedIndex = 0
    @State private var detailID: String?
    @State private var pointerInside = false
    @State private var menuTracking = false
    /// While the pointer is over the list or a row menu is open, blocks keep this order (S-8).
    @State private var frozenOrder: [String]?
    @FocusState private var keyboardFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tokenCatHighContrast) private var high
    @Namespace private var rotor

    init(model: DashboardModel, scrolls: Bool, presentation: DashboardPresentation = .popover, selection: String? = nil, detail: String? = nil) {
        _model = ObservedObject(wrappedValue: model)
        self.scrolls = scrolls
        self.presentation = presentation
        _selectedID = State(initialValue: selection)
        _detailID = State(initialValue: detail)
    }

    var body: some View {
        let list = frozenOrder.map { model.sessions.reordered($0) } ?? model.sessions
        Group {
            if model.tokensSampledAt == nil {
                SkeletonRows()
            } else if list.blocks.isEmpty {
                EmptySessions(foldersFound: model.logFoldersFound, recheck: model.recheckLogFolders)
            } else {
                rows(list)
            }
        }
        .container()
    }

    private func detailExtra(_ list: SessionListModel) -> CGFloat {
        guard let id = detailID, let item = list.item(id) else { return 0 }
        return SessionPresentation.detailHeight(item.reading, state: item.state)
    }

    private func target(_ list: SessionListModel) -> CGFloat {
        min(SessionListModel.maxViewport, list.viewport(showOlder: showOlder) + detailExtra(list))
    }

    private func rows(_ list: SessionListModel) -> some View {
        let goal = target(list)
        let height = min(SessionListModel.maxViewport, max(goal, viewportFloor))
        let overflows = presentation == .panel || list.height(showOlder: showOlder) + detailExtra(list) > height + 0.5
        let surface = Group {
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView { content(list, overflows: overflows) }
                        .onChange(of: model.sessionsExpanded) { _ in
                            viewportFloor = 0
                            // A focused group folded into "이전" opens that section so the scroll can reach it.
                            showOlder = focus.flatMap { id in model.sessions.blocks.first { $0.id == id }?.older } ?? false
                            if frozenOrder != nil { frozenOrder = model.sessions.blocks.map(\.id) }
                            let anchor = focus ?? "session-list-top"
                            focus = nil
                            // Wait for the expanded rows to lay out before scrolling to the focused group.
                            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
                        }
                        .onChange(of: selectedID) { id in
                            guard let id else { return }
                            DispatchQueue.main.async { proxy.scrollTo(id) }
                        }
                        .onChange(of: detailID) { id in
                            guard let id else { return }
                            DispatchQueue.main.async { proxy.scrollTo("detail:" + id) }
                        }
                }
            } else {
                // ImageRenderer cannot rasterize AppKit's scroll surface; export the same viewport.
                content(list, overflows: false).fixedSize(horizontal: false, vertical: true).frame(height: height, alignment: .top).clipped()
            }
        }
        // In the panel the list absorbs the window height and scrolls, down to one live row.
        .frame(minHeight: presentation == .panel ? min(height, SessionRowItem.liveDetailHeight) : height,
               maxHeight: presentation == .panel ? .infinity : height)
        // A short fade at the cut says the list continues; overlay scrollers are hidden at rest.
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                    .frame(height: overflows ? 14 : 0)
            }
        }
        return accessible(tracking(keyboard(surface, list), list, goal: goal), list)
    }

    private func keyboard<V: View>(_ view: V, _ list: SessionListModel) -> some View {
        view
            .background { if scrolls { keyboardShortcuts } }
            .focusable(scrolls)
            .focused($keyboardFocus)
            .modifier(NoFocusEffect())
            .onMoveCommand { move($0, in: list) }
            .onCopyCommand { copyItems(list) }
    }

    private func tracking<V: View>(_ view: V, _ list: SessionListModel, goal: CGFloat) -> some View {
        view
        .onHover { pointerInside = $0; updateFreeze() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in menuTracking = true; updateFreeze() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in menuTracking = false; updateFreeze() }
        .onChange(of: list.navigation(showOlder: showOlder)) { keepSelection($0) }
        .onAppear {
            viewportFloor = goal
            takeFocusRequest()
            autoFocus()
        }
        // A popover closed by Esc or another app never sends onHover(false); a stale freeze must not outlive it.
        .onDisappear { detailID = nil; selectedID = nil; unfreeze() }
        .onChange(of: goal) { viewportFloor = max(viewportFloor, $0) }
        .onChange(of: model.popoverShownAt) { _ in
            unfreeze()
            showOlder = false
            detailID = nil
            selectedID = nil
            viewportFloor = model.sessions.viewport(showOlder: false)
            autoFocus()
        }
        .onChange(of: model.focusRequest) { _ in takeFocusRequest() }
    }

    private func accessible<V: View>(_ view: V, _ list: SessionListModel) -> some View {
        view
        .help(loc("↑↓ 이동 · Return 상세 · ⌘C ID 복사", "↑↓ move · Return details · ⌘C copy ID"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("세션 목록", "Session list"))
        .accessibilityHint(loc("↑↓ 이동 · Return 상세 · ⌘C ID 복사", "↑↓ move · Return details · ⌘C copy ID"))
        .accessibilityRotor(Text(loc("입력 필요 세션", "Sessions needing input"))) { rotorEntries(list.blocks.filter { $0.state == .input }) }
        .accessibilityRotor(Text(loc("진행 중 세션", "Active sessions"))) { rotorEntries(list.blocks.filter { $0.state.isRunning }) }
    }

    private func rotorEntries(_ blocks: [SessionBlock]) -> some AccessibilityRotorContent {
        ForEach(blocks) { block in
            AccessibilityRotorEntry(Text(SessionPresentation.spokenLabel(block.lead.reading, state: block.state)), id: block.id, in: rotor)
        }
    }

    private func content(_ list: SessionListModel, overflows: Bool) -> some View {
        let context = RowContext(now: model.now, restart: model.telemetryRestartNeeded, showsSpeed: list.showsSpeedColumn,
                                 sharedProjects: list.sharedProjects(showOlder: showOlder), selectedID: selectedID, detailID: detailID, rotor: rotor,
                                 tap: { toggleDetail($0) })
        return VStack(spacing: 0) {
            Color.clear.frame(height: 0).id("session-list-top")
            ForEach(list.entries(showOlder: showOlder)) { entry in
                switch entry {
                case .divider:
                    Rectangle().fill(TCColor.hairline(contrast: high)).frame(height: 0.5)
                        .padding(.leading, DashboardLayout.textX).padding(.trailing, DashboardLayout.inset)
                        .frame(height: SessionListModel.dividerHeight)
                case .caption(let title, let rule, _):
                    DateCaption(title: title, rule: rule)
                case .older(let count):
                    OlderRow(count: count, selected: selectedID == SessionListModel.olderID) { showOlder = true }
                        .id(SessionListModel.olderID)
                case .block(let block):
                    SessionBlockView(block: block, context: context) {
                        focus = block.id
                        model.sessionsExpanded = true
                    }
                }
            }
            // Lets the last row scroll clear of the fade.
            if scrolls && overflows { Color.clear.frame(height: 10) }
        }
    }

    /// Return and Space while the list has keyboard focus; disabled otherwise so focused buttons keep their keys.
    private var keyboardShortcuts: some View {
        ZStack {
            Button(loc("상세", "Details")) { activate() }.keyboardShortcut(.return, modifiers: [])
            Button(loc("상세", "Details")) { activate() }.keyboardShortcut(.space, modifiers: [])
        }
        .disabled(!keyboardFocus || selectedID == nil)
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func toggleDetail(_ id: String) {
        detailID = detailID == id ? nil : id
        if selectedID != nil { selectedID = id }
        if scrolls { keyboardFocus = true }
    }

    /// macOS 13 cannot hide the ring on a focusable list, so there the list takes focus from a click only.
    private func autoFocus() {
        guard scrolls else { return }
        if #available(macOS 14.0, *) { DispatchQueue.main.async { keyboardFocus = true } }
    }

    private func unfreeze() {
        frozenOrder = nil
        pointerInside = false
        menuTracking = false
    }

    private func activate() {
        guard let id = selectedID else { return }
        if id == SessionListModel.olderID { showOlder = true }
        else if id.hasPrefix("more:") {
            focus = String(id.dropFirst(5))
            model.sessionsExpanded = true
        } else { toggleDetail(id) }
    }

    private func move(_ direction: MoveCommandDirection, in list: SessionListModel) {
        let rows = list.navigation(showOlder: showOlder)
        guard !rows.isEmpty else { return }
        guard let current = selectedID, let index = rows.firstIndex(of: current) else {
            select(list.startRow(showOlder: showOlder) ?? rows[0], in: rows)
            return
        }
        switch direction {
        case .up: select(rows[max(0, index - 1)], in: rows)
        case .down: select(rows[min(rows.count - 1, index + 1)], in: rows)
        default: break
        }
    }

    /// Keyboard focus stays on the list, so VoiceOver would say nothing: the selected row is read out here.
    private func select(_ id: String, in rows: [String]) {
        selectedID = id
        selectedIndex = rows.firstIndex(of: id) ?? 0
        guard let item = model.sessions.item(id) else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: SessionPresentation.spokenLabel(item.reading, state: item.state),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Keeps the selection by id through reorders; a vanished row hands it to the nearest position.
    private func keepSelection(_ rows: [String]) {
        if let id = detailID, !rows.contains(id) { detailID = nil }
        guard let id = selectedID else { return }
        if let index = rows.firstIndex(of: id) { selectedIndex = index; return }
        selectedID = rows.isEmpty ? nil : rows[min(selectedIndex, rows.count - 1)]
    }

    private func copyItems(_ list: SessionListModel) -> [NSItemProvider] {
        guard let id = selectedID, let reading = list.item(id)?.reading else { return [] }
        let text = reading.isSubagent ? (reading.agentID ?? reading.sessionID) : reading.sessionID
        return text.map { [NSItemProvider(object: $0 as NSString)] } ?? []
    }

    private func updateFreeze() {
        let freeze = scrolls && (pointerInside || menuTracking)
        if freeze, frozenOrder == nil {
            frozenOrder = model.sessions.blocks.map(\.id)
        } else if !freeze, frozenOrder != nil {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { frozenOrder = nil }
        }
    }

    /// A notification or quick-menu request: select that group and scroll to it, once.
    private func takeFocusRequest() {
        guard scrolls, model.focusRequest != nil else { return }
        DispatchQueue.main.async {
            guard let id = model.consumeFocusRequest() else { return }
            frozenOrder = nil
            if !model.sessions.blocks.contains(where: { $0.id == id }) {
                // The expand handler scrolls to `focus` and opens "이전" when the group sits there.
                focus = id
                model.sessionsExpanded = true
            }
            guard let block = model.sessions.blocks.first(where: { $0.id == id }) else { return }
            let older = showOlder || block.older
            showOlder = older
            select(id, in: model.sessions.navigation(showOlder: older))
            if #available(macOS 14.0, *) { keyboardFocus = true }
        }
    }
}

private struct DateCaption: View {
    var title: String
    var rule: Bool
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        Text(title).font(TCFont.caption).toneSecondary()
            .padding(.leading, DashboardLayout.glyphX).padding(.bottom, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .frame(height: SessionListModel.captionHeight)
            .overlay(alignment: .top) { if rule { Rectangle().fill(TCColor.hairline(contrast: high)).frame(height: 0.5) } }
            .accessibilityAddTraits(.isHeader)
    }
}

private struct OlderRow: View {
    var count: Int
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(loc("이전 기록 \(count)개 더 보기", "Show \(plural(count, "earlier record"))"))
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .font(TCFont.metaMedium).toneSecondary()
            .frame(maxWidth: .infinity).frame(height: SessionListModel.olderHeight)
            .background(selected ? TCColor.selection(keyWindow: true) : (hovering ? TCColor.hover(contrast: high) : .clear))
            .overlay { if selected { Rectangle().strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // ↑↓ and Return reach it inside the list, where a Tab stop would show no focus.
        .focusable(false)
        .onHover { hovering = $0 }
        .accessibilityLabel(loc("이전 기록 더 보기", "Show earlier records")).accessibilityValue("\(count)" + loc("개", ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Three 28 pt placeholder rows while the first sample is read (O-2); no spinner, no shimmer.
private struct SkeletonRows: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(TCColor.primary(0.05)).frame(width: 140, height: 10)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(TCColor.primary(0.05)).frame(width: 64, height: 10)
                }
                .padding(.leading, DashboardLayout.textX).padding(.trailing, DashboardLayout.inset)
                .frame(height: 28)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc("세션 목록", "Session list"))
        .accessibilityValue(loc("기록 확인 중", "Reading records"))
    }
}

/// No sessions yet, or no log folders (O-3). Folder existence comes from the model, never from the view body.
private struct EmptySessions: View {
    static var webNote: String { loc("Claude 웹·데스크톱 채팅은 수집하지 않습니다", "Claude web and desktop chats aren't collected") }
    var foldersFound: Bool
    var recheck: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Image(nsImage: Runner.image(pose: foldersFound ? .sleep : .sit, frame: 0)).resizable().interpolation(.none)
                if foldersFound, let z = Runner.fxMask(pose: .sleep, step: RunnerAnimator.largeZ) {
                    Image(nsImage: z).resizable().interpolation(.none).renderingMode(.template).foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
            }
            .frame(width: Runner.size.width * 2, height: Runner.size.height * 2)
            .accessibilityHidden(true)
            let names = TokenProvider.readTitles
            Text(foldersFound ? loc("아직 \(names.korean) 세션 기록이 없습니다", "No \(names.english) sessions yet")
                 : loc("\(names.korean) 기록 폴더를 찾지 못했습니다", "Couldn't find \(names.english) log folders"))
                .font(TCFont.bodyMedium).multilineTextAlignment(.center).padding(.top, 8)
            VStack(spacing: 2) {
                if foldersFound {
                    Text(loc("새 세션을 시작하면 여기에 표시됩니다", "New sessions appear here when you start them"))
                    Text(Self.webNote)
                } else {
                    Text(TokenProvider.readRootsText(home: FileManager.default.homeDirectoryForCurrentUser)).font(TCFont.meta.monospaced())
                }
            }
            .font(TCFont.meta).toneSecondary().padding(.top, 4)
            if !foldersFound {
                SmallBorderedButton(title: loc("다시 확인", "Check Again"), action: recheck).padding(.top, 8)
                Text(Self.webNote).font(TCFont.meta).toneSecondary().padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.vertical, DashboardLayout.insetVertical)
        .accessibilityElement(children: .combine)
    }
}

/// A lead row, its children, the inline details and the tree guide that joins them (S-5).
struct SessionBlockView: View {
    var block: SessionBlock
    var context: RowContext
    var expand: () -> Void
    @Environment(\.tokenCatHighContrast) private var high

    var body: some View {
        VStack(spacing: 0) {
            lead
            detail(block.lead)
            ForEach(block.children) { child in
                ChildSessionRow(item: child, parent: block.lead.reading, context: context)
                detail(child)
            }
            if block.moreCount > 0 {
                Button(action: expand) {
                    Text(block.moreText).font(TCFont.meta.monospacedDigit()).toneSecondary().lineLimit(1)
                        .padding(.leading, DashboardLayout.childTextX).padding(.trailing, DashboardLayout.inset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: SessionListModel.moreHeight)
                        .rowChrome(selected: context.selectedID == block.moreID)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .id(block.moreID)
                .help(loc("실행 중인 하위 에이전트는 모두 보여주고, 로그 대기 하위는 실행 중인 하위가 없을 때만 \(SessionListModel.collapsedChildren)개까지 보여줍니다",
                          "Shows every running subagent. Subagents waiting for log appear only when none are running, up to \(SessionListModel.collapsedChildren)"))
                .accessibilityAddTraits(context.selectedID == block.moreID ? .isSelected : [])
                .accessibilityLabel(loc("하위 에이전트 \(block.moreCount)개 더 보기", "Show \(plural(block.moreCount, "more subagent"))"))
                .accessibilityValue(block.moreSpoken)
            }
        }
        // Behind the rows, so a fresh-record dot in the glyph column draws over the line.
        .background(alignment: .topLeading) { guide }
        .accessibilityRotorEntry(id: block.id, in: context.rotor)
    }

    @ViewBuilder private var lead: some View {
        let item = block.lead
        switch item.kind {
        case .live:
            LiveSessionRow(item: item, childCount: block.childCount, context: context)
        case .measurement:
            MeasurementRow(reading: item.reading, now: context.now, selected: context.selectedID == item.id)
                .onTapGesture { context.tap(item.id) }
                .accessibilityAction { context.tap(item.id) }
        default:
            // Input and retry children are running, so every one of them is in `children`.
            let urgent = block.state == .input || block.state == .retrying
            IdleSessionRow(item: item, childCount: block.childCount, groupState: block.state,
                           liveChildren: urgent ? block.children.filter { $0.state == block.state }.count
                               : (block.state.isRunning ? block.runningChildren : block.waitingChildren),
                           context: context)
        }
    }

    @ViewBuilder private func detail(_ item: SessionRowItem) -> some View {
        if context.detailID == item.id {
            SessionDetail(item: item, indent: item.kind == .child ? DashboardLayout.childTextX : DashboardLayout.textX).id("detail:" + item.id)
        }
    }

    /// 1 pt primary 0.15 from below the lead glyph (x = 17) to the last child or "+N 하위" row, with a 6 pt tail to each.
    @ViewBuilder private var guide: some View {
        if !block.children.isEmpty || block.moreCount > 0 {
            let x = DashboardLayout.guideX
            let start: CGFloat = block.lead.kind == .live ? 23 : 19
            let tails = guideTails
            Path { path in
                path.move(to: CGPoint(x: x, y: start))
                path.addLine(to: CGPoint(x: x, y: tails.last ?? start))
                for y in tails {
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + 6, y: y))
                }
            }
            .stroke(TCColor.primary(high ? 0.3 : 0.15), lineWidth: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var guideTails: [CGFloat] {
        var y = block.lead.height + context.detailHeight(block.lead)
        var tails: [CGFloat] = []
        for child in block.children {
            tails.append(y + child.height / 2)
            y += child.height + context.detailHeight(child)
        }
        if block.moreCount > 0 { tails.append(y + SessionListModel.moreHeight / 2) }
        return tails
    }
}

/// State glyph plus tool category, input kind or state on a tinted capsule; its glyph sits on the glyph column (x = 12).
struct StateChip: View {
    var kind: StateGlyph.Kind
    var text: String
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        let color = StateGlyph.color(kind)
        HStack(spacing: 4) {
            StateGlyphView(kind: kind, side: 8, contrast: high).frame(width: 10, height: 10)
            Text(text).font(TCFont.metaMedium).lineLimit(1)
        }
        .padding(.leading, 4).padding(.trailing, 6).frame(height: 18)
        .background(color.opacity(high ? 0.28 : 0.16), in: Capsule())
        .overlay { if high { Capsule().strokeBorder(color, lineWidth: 1) } }
        .fixedSize()
    }
}

struct SpeedLabel: View {
    var slot: SpeedSlot
    /// Narrow third line: the rate kind moves to help.
    var short = false
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        Group {
            if slot.known {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let prefix = slot.prefix { Text(prefix + " ").font(TCFont.micro) }
                    Text(slot.value).font(TCFont.metaMedium.monospacedDigit())
                    Text(" " + (short ? "tok/s" : (slot.kind ?? "tok/s"))).font(TCFont.micro)
                }
                .toneSecondary()
            } else {
                // The unit keeps a lone "—" from reading as a divider.
                Text("—").font(TCFont.meta).foregroundColor(TCColor.textTertiary(contrast: high))
                    + Text(" tok/s").font(TCFont.micro).foregroundColor(TCColor.textSecondary(contrast: high))
            }
        }
        .lineLimit(1).fixedSize().help(slot.help)
    }
}

struct ContextLabel: View {
    var slot: ContextSlot
    var short = false
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        Group {
            if let compacted = slot.compacted {
                Text(compacted).font(TCFont.meta).toneSecondary()
                    .padding(.horizontal, 4).background(TCColor.primary(0.08), in: Capsule())
            } else {
                HStack(spacing: 4) {
                    if let fraction = slot.fraction {
                        Meter(fraction: fraction, color: slot.warning ? TCColor.warning : TCColor.neutral).frame(width: 32, height: 4)
                    }
                    Text(short ? slot.short : slot.text).font(TCFont.meta.monospacedDigit()).toneSecondary()
                }
            }
        }
        .lineLimit(1).fixedSize().help(slot.help)
    }
}

private enum RowText {
    /// One line of help; a client waiting for a restart adds why its speed is missing.
    static func help(_ reading: TokenReading, _ context: RowContext) -> String {
        loc("클릭: 상세 · 우클릭: 메뉴", "Click: details · Right-click: menu")
            + (context.restart.contains(reading.source)
               ? loc("\n\(reading.source.title)를 새로 실행하면 속도가 표시됩니다", "\nRestart \(reading.source.title) to show speed") : "")
    }

    /// The fold-in count stays in VoiceOver after "하위 N" left the second line.
    static func children(_ count: Int) -> String? { count > 0 ? loc("하위 에이전트 \(count)개 기록", plural(count, "subagent record")) : nil }

    static func output(_ reading: TokenReading) -> String {
        guard let output = reading.currentTurnOutputTokens else { return loc("이번 턴 누적 미확인", "Output this turn unknown") }
        return loc("이번 턴 출력 \(output.formatted()) 토큰", "\(plural(output, "output token")) this turn")
    }
}

struct LiveSessionRow: View {
    var item: SessionRowItem
    var childCount = 0
    var context: RowContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tokenCatHighContrast) private var high
    private var reading: TokenReading { item.reading }
    private var now: Date { context.now }

    private var trailing: String {
        switch item.state {
        case .waiting: return loc("활동 ", "Active ") + Format.age(SessionPresentation.liveAt(reading), now: now)
        case .input: return loc("입력 대기 ", "Waiting for input ") + Format.elapsed(reading.lastActivity, at: now)
        case .retrying: return reading.retry.map { SessionPresentation.retryText($0, now: now) } ?? item.state.title
        default: return loc("턴 ", "Turn ") + Format.elapsed(reading.currentTurnStartedAt, at: now)
        }
    }

    var body: some View {
        let speed = context.speed(item)
        let contextSlot = SessionPresentation.context(reading, now: now)
        let record = SessionPresentation.lastRecord(reading)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                StateChip(kind: StateGlyph.Kind(item.state) ?? .working, text: SessionPresentation.chipText(item.state, reading))
                    .padding(.leading, DashboardLayout.glyphX - 4)
                Text(reading.project ?? loc("프로젝트 미확인", "Unknown project")).font(TCFont.title).lineLimit(1).truncationMode(.tail).layoutPriority(2)
                    .padding(.leading, 8)
                if context.showsID(reading) {
                    Text(SessionPresentation.shortID(reading)).font(TCFont.meta).toneSecondary().lineLimit(1).fixedSize().padding(.leading, 6)
                }
                Spacer(minLength: 8)
                primaryNumber.frame(minWidth: 86, alignment: .trailing)
            }
            .frame(height: 18)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(SessionPresentation.clientLine(reading)).font(TCFont.meta).toneSecondary().lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(trailing).font(TCFont.metaMono).lineLimit(1).fixedSize()
                    .foregroundStyle(item.state == .input || item.state == .retrying ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                                     : AnyShapeStyle(TCColor.textSecondary(contrast: high)))
            }
            .frame(height: 14)
            .padding(.leading, DashboardLayout.textX)
            if item.showsDetail {
                ViewThatFits(in: .horizontal) {
                    line3(record, contextSlot, speed, shortContext: false, shortSpeed: false, age: true)
                    line3(record, contextSlot, speed, shortContext: false, shortSpeed: true, age: true)
                    line3(record, contextSlot, speed, shortContext: true, shortSpeed: true, age: true)
                    line3(record, contextSlot, speed, shortContext: true, shortSpeed: true, age: false)
                }
                .frame(height: 12)
                .padding(.leading, DashboardLayout.glyphX)
            }
        }
        .padding(.trailing, DashboardLayout.inset).padding(.vertical, 5)
        .frame(height: item.height, alignment: .top)
        .rowChrome(selected: context.selectedID == item.id)
        .id(item.id)
        .onTapGesture { context.tap(item.id) }
        .help(RowText.help(reading, context))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(context.selectedID == item.id ? .isSelected : [])
        .accessibilityLabel(SessionPresentation.spokenLabel(reading, state: item.state))
        .accessibilityValue(spokenValue(contextSlot, SessionPresentation.speed(reading, now: now)))
        .accessibilityAction { context.tap(item.id) }
        .rowActions(reading)
    }

    private func spokenValue(_ contextSlot: ContextSlot?, _ speed: SpeedSlot) -> String {
        var state: String?
        if item.state == .input { state = SessionPresentation.inputTitle(reading) }
        if item.state == .retrying { state = reading.retry.map { SessionPresentation.retryText($0, now: now, api: true, spoken: true) } }
        return [state, SessionPresentation.effortLabel(reading).map { loc("추론 \($0)", "Reasoning \($0)") },
                SessionPresentation.spokenDuration(reading.currentTurnStartedAt, now: now).map { loc("턴 경과 \($0)", "Turn elapsed \($0)") },
                RowText.output(reading), RowText.children(childCount), contextSlot?.spoken,
                speed.known || item.state.expectsSpeed ? speed.spoken : nil].compactMap { $0 }.joined(separator: ", ")
    }

    /// Starts at the glyph column: the last-record dot hangs there, its text sits on the text column.
    private func line3(_ record: TokenOutputEvent?, _ contextSlot: ContextSlot?, _ speed: SpeedSlot?, shortContext: Bool, shortSpeed: Bool,
                       age: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let record { LastRecordLabel(record: record, now: now, age: age) }
            Spacer(minLength: 8)
            if let contextSlot { ContextLabel(slot: contextSlot, short: shortContext) }
            if let speed { SpeedLabel(slot: speed, short: shortSpeed).padding(.leading, contextSlot == nil ? 0 : 10) }
        }
    }

    @ViewBuilder private var primaryNumber: some View {
        let secondary = TCColor.textSecondary(contrast: high)
        if let output = reading.currentTurnOutputTokens {
            let quiet = output == 0 || item.state == .waiting
            (Text(Format.tokens(output)).font(TCFont.metric).foregroundColor(quiet ? secondary : nil)
                + Text(" tok").font(TCFont.micro).foregroundColor(secondary))
                .lineLimit(1).fixedSize()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: output)
                .help(output == 0 ? loc("현재 턴에서 아직 기록된 출력이 없습니다", "No output recorded in this turn yet")
                      : loc("현재 턴에서 기록된 출력 토큰", "Output tokens recorded in this turn"))
        } else {
            Text("—").font(TCFont.metric).toneTertiary()
                .help(loc("현재 턴 시작 부분을 읽지 못해 이번 턴 누적량을 알 수 없습니다", "Couldn't read the start of this turn, so its total is unknown"))
        }
    }
}

/// "+1,356 tok · 방금" with a reserved 6 pt dot 4 pt before it (as on the flow card and child rows): green and primary
/// semibold for 5 s, then secondary.
private struct LastRecordLabel: View {
    var record: TokenOutputEvent
    var now: Date
    var age = true
    @Environment(\.tokenCatHighContrast) private var high
    var body: some View {
        let fresh = SessionPresentation.isFresh(record.at, now: now)
        let secondary = TCColor.textSecondary(contrast: high)
        // The dot sits in a 12 pt slot from the glyph column (x = 12) so the text stays on the text column (x = 28).
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Circle().fill(TCColor.activity).frame(width: 6, height: 6).frame(width: 12, alignment: .trailing).opacity(fresh ? 1 : 0)
            (Text("+\(Format.tokens(record.tokens)) tok").font(fresh ? TCFont.metaMonoSemibold : TCFont.metaMono).foregroundColor(fresh ? nil : secondary)
                + Text(age ? " · " + SessionPresentation.recordAge(record.at, now: now) : "").font(TCFont.metaMono).foregroundColor(secondary))
                .lineLimit(1).fixedSize()
        }
        .help(loc("이번 턴의 마지막 출력 기록 · 로그 기록 시점 기준", "Last output record this turn · based on log record times"))
    }
}

struct IdleSessionRow: View {
    var item: SessionRowItem
    var childCount = 0
    var groupState: SessionDisplayState
    var liveChildren: Int
    var context: RowContext
    @Environment(\.tokenCatHighContrast) private var high
    private var reading: TokenReading { item.reading }
    private var now: Date { context.now }
    private var age: String { Format.age(reading.lastActivity, now: now) }
    /// An idle lead whose subagents are live shows the group's state instead of its own age.
    private var followsGroup: Bool { !item.state.isLive && groupState.isLive && liveChildren > 0 }
    private var trailing: String { followsGroup ? SessionPresentation.childGroupText(groupState, count: liveChildren) : age }
    /// "중단", "종료 기록 없음" beside the client, so the age column keeps one width; it drops first when the row is tight
    /// (the ring glyph, help and VoiceOver still say it).
    private var stateWord: String? {
        guard !followsGroup else { return nil }
        switch item.state {
        case .interrupted: return loc("중단", "Interrupted")
        case .unfinished: return loc("종료 기록 없음", "No end record")
        default: return nil
        }
    }

    var body: some View {
        let state = followsGroup ? groupState : item.state
        HStack(alignment: .center, spacing: 0) {
            StateGlyphView(kind: StateGlyph.Kind(state) ?? .idle, side: 8, contrast: high).frame(width: 10)
                .padding(.leading, DashboardLayout.glyphX)
            ViewThatFits(in: .horizontal) {
                names(client: true, id: context.showsID(reading), word: true)
                names(client: true, id: context.showsID(reading), word: false)
                names(client: true, id: false, word: false)
                names(client: false, id: false, word: false)
            }
            .padding(.leading, 6)
            .layoutPriority(1)
            Spacer(minLength: 8)
            if !followsGroup, stateWord == nil, let last = reading.lastOutputTokens {
                (Text(loc("마지막 턴 ", "Last turn ")).font(TCFont.micro) + Text(Format.compactTokens(last)).font(TCFont.metaMono))
                    .toneSecondary().lineLimit(1).fixedSize().padding(.trailing, 10)
                    .help(SessionPresentation.lastTurnSummary(reading) ?? "")
            }
            // A fixed 64 pt age column, so "마지막 턴" lines up across rows; the group's state text may be wider.
            Text(trailing).font(TCFont.metaMono).toneSecondary().lineLimit(1)
                .frame(minWidth: 64, maxWidth: followsGroup ? .infinity : 64, alignment: .trailing).fixedSize()
                .help(state.title + loc(" · 마지막 활동 ", " · last activity ") + SessionPresentation.helpAge(reading.lastActivity, now: now))
        }
        .padding(.trailing, DashboardLayout.inset)
        .frame(height: item.height)
        .rowChrome(selected: context.selectedID == item.id)
        .id(item.id)
        .onTapGesture { context.tap(item.id) }
        .help(RowText.help(reading, context))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(context.selectedID == item.id ? .isSelected : [])
        .accessibilityLabel(SessionPresentation.spokenLabel(reading, state: state))
        .accessibilityValue([loc("마지막 활동 ", "Last activity ") + Format.age(reading.lastActivity, now: now, spoken: true), followsGroup ? trailing : nil, RowText.children(childCount), SessionPresentation.lastTurnSummary(reading),
                             SessionPresentation.speed(reading, now: now).spoken].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction { context.tap(item.id) }
        .rowActions(reading)
    }

    private func names(client: Bool, id: Bool, word: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(reading.project ?? loc("프로젝트 미확인", "Unknown project")).font(TCFont.body).lineLimit(1).truncationMode(.tail).layoutPriority(2)
            if client { Text(reading.source.title).font(TCFont.meta).toneSecondary().lineLimit(1).fixedSize() }
            if word, let stateWord { Text(stateWord).font(TCFont.micro).toneSecondary().lineLimit(1).fixedSize() }
            if id { Text(SessionPresentation.shortID(reading)).font(TCFont.meta).toneSecondary().lineLimit(1).fixedSize() }
        }
    }
}

struct ChildSessionRow: View {
    var item: SessionRowItem
    var parent: TokenReading
    var context: RowContext
    @Environment(\.tokenCatHighContrast) private var high
    private var reading: TokenReading { item.reading }
    private var now: Date { context.now }

    /// Tool category, input, retry and log wait only; a running child says nothing extra.
    private var stateWord: String? {
        switch item.state {
        case .tool: return SessionPresentation.toolTitle(reading.toolCategory)
        case .input: return SessionPresentation.inputTitle(reading)
        case .retrying: return reading.retry.map { SessionPresentation.retryText($0, now: now) } ?? item.state.title
        case .waiting: return item.state.title
        default: return nil
        }
    }

    var body: some View {
        let live = item.state.isLive
        let title = SessionPresentation.childTitle(reading)
        let project = SessionPresentation.childProjectSuffix(reading, parent: parent)
        HStack(alignment: .center, spacing: 0) {
            StateGlyphView(kind: StateGlyph.Kind(item.state) ?? .idle, side: 8, contrast: high).frame(width: 10)
                .padding(.leading, DashboardLayout.textX)
            // Each part shows whole or not at all (the project drops first, then the role); never a cut "a7b…".
            ViewThatFits(in: .horizontal) {
                nameLine(title.title, [title.detail, project])
                nameLine(title.title, [title.detail])
                Text(title.title).lineLimit(1).truncationMode(.middle)
            }
            .font(TCFont.meta).padding(.leading, 6).layoutPriority(1)
            if let stateWord { Text(stateWord).font(TCFont.micro).toneSecondary().lineLimit(1).fixedSize().padding(.leading, 6) }
            Spacer(minLength: 8)
            if live {
                recordAge.frame(minWidth: 44, alignment: .trailing)
                number.frame(minWidth: 56, alignment: .trailing).padding(.leading, 8)
            } else {
                Text(Format.age(reading.lastActivity, now: now)).font(TCFont.metaMono).toneSecondary()
                    .frame(minWidth: 64, alignment: .trailing).fixedSize()
            }
        }
        .padding(.trailing, DashboardLayout.inset)
        .frame(height: item.height)
        .rowChrome(selected: context.selectedID == item.id)
        .id(item.id)
        .onTapGesture { context.tap(item.id) }
        .help(RowText.help(reading, context))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(context.selectedID == item.id ? .isSelected : [])
        .accessibilityLabel(SessionPresentation.spokenLabel(reading, state: item.state))
        .accessibilityValue([SessionPresentation.spokenDuration(reading.currentTurnStartedAt, now: now).map { loc("턴 경과 \($0)", "Turn elapsed \($0)") },
                             live ? RowText.output(reading) : loc("마지막 활동 ", "Last activity ") + Format.age(reading.lastActivity, now: now, spoken: true),
                             SessionPresentation.context(reading, now: now)?.spoken, SessionPresentation.speed(reading, now: now).spoken,
                             SessionPresentation.roleLabel(reading.agentRole).map { loc("역할 \($0)", "Role \($0)") }, "ID \(SessionPresentation.agentLabel(reading))"]
                                .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction { context.tap(item.id) }
        .rowActions(reading)
    }

    @ViewBuilder private var recordAge: some View {
        if let record = SessionPresentation.lastRecord(reading) {
            let age = SessionPresentation.recordAge(record.at, now: now)
            HStack(spacing: 4) {
                if age == SessionPresentation.justNow { Circle().fill(TCColor.activity).frame(width: 6, height: 6) }
                Text(age).font(TCFont.metaMono).toneSecondary().lineLimit(1).fixedSize()
            }
        }
    }

    @ViewBuilder private var number: some View {
        let secondary = TCColor.textSecondary(contrast: high)
        if let output = reading.currentTurnOutputTokens {
            // A child waiting for a log is not producing; its total stays quiet.
            let quiet = item.state == .waiting || output == 0
            (Text(Format.tokens(output)).font(quiet ? TCFont.metaMono : TCFont.metaMonoSemibold).foregroundColor(quiet ? secondary : nil)
                + Text(" tok").font(TCFont.micro).foregroundColor(secondary))
                .lineLimit(1).fixedSize()
        } else {
            Text("—").font(TCFont.meta).toneTertiary()
        }
    }

    private func nameLine(_ name: String, _ parts: [String?]) -> some View {
        let secondary = TCColor.textSecondary(contrast: high)
        return parts.compactMap { $0 }.reduce(Text(name)) { $0 + Text(" · \($1)").foregroundColor(secondary) }
            .lineLimit(1).fixedSize()
    }
}

struct MeasurementRow: View {
    var reading: TokenReading
    var now: Date
    var selected = false
    var body: some View {
        let speed = SessionPresentation.speed(reading, now: now)
        let measuredAt = reading.speedMeasurement?.at ?? reading.lastActivity
        let age = Format.age(measuredAt, now: now)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: "speedometer").font(TCFont.meta).toneSecondary().frame(width: 10)
                .padding(.leading, DashboardLayout.glyphX)
            Text(reading.project ?? loc("모델 실측", "Model measurement")).font(TCFont.body).lineLimit(1).fixedSize().padding(.leading, 6)
            Text(reading.model ?? loc("모델 미확인", "Unknown model")).font(TCFont.meta).toneSecondary().lineLimit(1).truncationMode(.middle).padding(.leading, 6)
            Spacer(minLength: 8)
            SpeedLabel(slot: speed)
            Text(loc("측정 \(age)", "Measured \(age)")).font(TCFont.metaMono).toneSecondary().fixedSize().padding(.leading, 10)
        }
        .padding(.trailing, DashboardLayout.inset)
        .frame(height: 28)
        .rowChrome(selected: selected)
        .id(reading.id)
        .help(loc("클릭: 상세 · 우클릭: 메뉴", "Click: details · Right-click: menu"))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(reading.project ?? loc("모델 실측", "Model measurement")), \(reading.source.title) \(reading.model ?? loc("모델 미확인", "Unknown model"))")
        .accessibilityValue(speed.spoken + loc(", 측정 ", ", measured ") + Format.age(measuredAt, now: now, spoken: true))
        .rowActions(reading)
    }
}

/// The inline detail under a row (S-6): a two-column grid, 15 pt lines, 8 pt above and below, a rule on top.
struct SessionDetail: View {
    var item: SessionRowItem
    var indent: CGFloat
    @Environment(\.tokenCatHighContrast) private var high
    /// The copy buttons' own focus: inside the list `isFocused` reports the list, so `HoverButtonStyle` cannot ring them.
    @FocusState private var copyFocus: String?
    var body: some View {
        let items = SessionPresentation.detailItems(item.reading, state: item.state)
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(TCColor.hairline(contrast: high)).frame(height: 0.5)
                .padding(.leading, indent).padding(.trailing, DashboardLayout.inset)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { detail in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(detail.label).font(TCFont.meta).toneSecondary().lineLimit(1).frame(width: 76, alignment: .leading)
                        // A full UUID needs ~266 pt; it shrinks slightly (Latin only, never Korean) before it truncates.
                        Text(detail.value).font(TCFont.metaMono).lineLimit(1).minimumScaleFactor(detail.copy == nil ? 1 : 0.9)
                            .truncationMode(.middle).textSelection(.enabled)
                        if let copy = detail.copy {
                            Button { copyToPasteboard(copy) } label: { Image(systemName: "doc.on.doc").font(TCFont.meta).frame(width: 18, height: 15) }
                                .buttonStyle(HoverButtonStyle(ring: false))
                                .focused($copyFocus, equals: detail.id)
                                .overlay {
                                    if copyFocus == detail.id {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                                    }
                                }
                                .help(loc("복사", "Copy")).accessibilityLabel(loc("\(detail.label) 복사", "Copy \(detail.label)"))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 15)
                }
            }
            .padding(.vertical, 8).padding(.leading, indent).padding(.trailing, DashboardLayout.inset)
        }
        .frame(height: SessionPresentation.detailHeight(item.reading, state: item.state), alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("세션 상세", "Session details"))
    }
}

// MARK: - System

/// `kern.memorystatus_vm_pressure_level`: the memory meter colour follows pressure, not the used %.
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
        case .normal: return loc("정상", "Normal")
        case .warning: return loc("경고", "Warning")
        case .critical: return loc("위험", "Critical")
        case .unknown: return loc("미확인", "Unknown")
        }
    }
    var color: Color {
        switch self {
        case .warning: return TCColor.warning
        case .critical: return TCColor.critical
        default: return TCColor.neutral
        }
    }
}

/// The borderless bottom area (8): label 12, value 16, aux 11; the whole area opens Activity Monitor.
struct SystemArea: View {
    var system: SystemSnapshot
    var cpuHistory: [Double]
    var hasSample: Bool
    var open: () -> Void
    @State private var hovering = false
    @Environment(\.tokenCatHighContrast) private var high

    private func ratio(_ used: UInt64?, _ total: UInt64?) -> Double? { hasSample ? Format.ratio(used, total) : nil }

    var body: some View {
        let battery = system.batteryPresent
        let widths: [CGFloat] = battery ? [56, 72, 56, 56, 76] : [64, 80, 64, 120]
        VStack(spacing: 0) {
            Rectangle().fill(TCColor.hairline(contrast: high)).frame(height: 0.5).padding(.horizontal, -DashboardLayout.gutter)
            HStack(alignment: .top, spacing: 12) {
                cpu.frame(width: widths[0], alignment: .leading)
                memory.frame(width: widths[1], alignment: .leading)
                disk.frame(width: widths[2], alignment: .leading)
                if battery { batteryCell.frame(width: widths[3], alignment: .leading) }
                network.frame(width: widths[widths.count - 1], alignment: .leading)
            }
            .frame(height: 44, alignment: .top)
            .padding(.horizontal, DashboardLayout.inset).padding(.vertical, 6)
            .background(hovering ? TCColor.hover(contrast: high) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if hovering { Image(systemName: "arrow.up.forward").font(TCFont.micro).toneSecondary().padding(6) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onHover { hovering = $0 }
            .padding(.top, 4)
        }
        .help(loc("활성 상태 보기에서 자세히 보기", "Show details in Activity Monitor"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("시스템", "System"))
        .accessibilityAction(named: loc("활성 상태 보기", "Open Activity Monitor"), open)
    }

    /// Before the first sample a redacted "00%" (about 32 pt), so the skeleton has the value's width.
    private func percentText(_ value: Double?) -> Text {
        guard hasSample else { return Text("00").font(TCFont.value) + Text("%").font(TCFont.micro) }
        guard let value, value.isFinite else { return Text("—").font(TCFont.value).foregroundColor(TCColor.textTertiary(contrast: high)) }
        return Text(String(format: "%.0f", value)).font(TCFont.value) + Text("%").font(TCFont.micro).foregroundColor(TCColor.textSecondary(contrast: high))
    }

    /// Label 12, 2, value 16, 3, aux 11. Help is static so the tooltip does not reset every second; live values go to VoiceOver.
    private func cell<Value: View, Aux: View>(_ title: String, help: String, spoken: String, @ViewBuilder value: () -> Value,
                                              @ViewBuilder aux: () -> Aux) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(TCFont.micro).toneSecondary().lineLimit(1).frame(height: 12)
            value().lineLimit(1).frame(height: 16).padding(.top, 2).redacted(reason: hasSample ? [] : .placeholder)
            aux().frame(height: 11, alignment: .top).padding(.top, 3).redacted(reason: hasSample ? [] : .placeholder)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spoken)
    }

    private var cpu: some View {
        let value = hasSample ? system.cpuPercent : nil
        let peak = hasSample ? cpuHistory.suffix(30).max() : nil
        return cell("CPU", help: loc("CPU 전체 코어 사용률", "CPU usage across all cores")
                        + (peak.map { String(format: loc("\n최근 30초 최고 %.0f%%", "\nPeak %.0f%% in the last 30 s"), $0) } ?? ""),
                    spoken: Format.percent(value) + (peak.map { String(format: loc(", 최근 30초 최고 %.0f퍼센트", ", peak %.0f percent in the last 30 s"), $0) } ?? "")) {
            percentText(value)
        } aux: {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Meter(fraction: (value ?? 0) / 100, color: Meter.color(value)).frame(height: 4).padding(.top, 1)
                    if let peak {
                        Rectangle().fill(TCColor.primary(0.5)).frame(width: 1, height: 6)
                            .offset(x: (geometry.size.width * min(1, max(0, peak / 100)) - 0.5).rounded())
                    }
                }
            }
        }
    }

    private var memory: some View {
        let value = ratio(system.memoryUsedBytes, system.memoryTotalBytes)
        let pressure = MemoryPressure(hasSample ? system.memoryPressure : nil)
        return cell(loc("메모리", "Memory"), help: loc("메모리: 앱·유선·압축 사용량 / 실제 메모리\n막대 색은 메모리 압력 기준",
                                              "Memory: app, wired and compressed / physical memory\nBar color follows memory pressure"),
                    spoken: "\(Format.percent(value)), \(Format.capacity(system.memoryUsedBytes, system.memoryTotalBytes)), "
                        + loc("메모리 압력 \(pressure.title)", "memory pressure: \(pressure.title)")) {
            // The named pill when it fits the column (Korean), otherwise a warning mark; VoiceOver still reads the name.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    percentText(value).fixedSize()
                    if pressure == .warning || pressure == .critical {
                        Text(pressure.title).font(TCFont.micro).padding(.horizontal, 3)
                            .background(pressure.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .fixedSize()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    percentText(value).fixedSize()
                    Image(systemName: pressure == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill").font(TCFont.micro).foregroundStyle(pressure.color)
                }
            }
        } aux: {
            Meter(fraction: (value ?? 0) / 100, color: pressure.color).frame(height: 4)
        }
    }

    private var disk: some View {
        let value = ratio(system.diskUsedBytes, system.diskTotalBytes)
        return cell(loc("저장 공간", "Storage"), help: loc("저장 공간: 홈 폴더가 있는 볼륨의 사용량 / 전체 용량",
                                                "Storage: used / total capacity of the volume with your home folder"),
                    spoken: "\(Format.percent(value)), \(Format.capacity(system.diskUsedBytes, system.diskTotalBytes))") {
            percentText(value)
        } aux: {
            Meter(fraction: (value ?? 0) / 100, color: Meter.color(value)).frame(height: 4)
        }
    }

    private var batteryCell: some View {
        let value = hasSample ? system.batteryPercent : nil
        let charging = system.isCharging == true
        let color: Color = {
            guard let value, !charging else { return TCColor.neutral }
            return value <= 10 ? TCColor.critical : (value <= 20 ? TCColor.warning : TCColor.neutral)
        }()
        return cell(loc("배터리", "Battery"), help: loc("배터리 잔량", "Battery level") + " · \(Format.power(system))", spoken: "\(Format.percent(value)), \(Format.power(system))") {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                percentText(value).fixedSize()
                if charging { Image(systemName: "bolt.fill").font(TCFont.value).imageScale(.small).toneSecondary() }
            }
        } aux: {
            Meter(fraction: (value ?? 0) / 100, color: color).frame(height: 4)
        }
    }

    private var network: some View {
        let download = StatusBarContent.splitRate(StatusBarContent.networkRate(hasSample ? system.downloadBytesPerSecond : nil))
        let upload = StatusBarContent.networkRate(hasSample ? system.uploadBytesPerSecond : nil)
        let up = StatusBarContent.splitRate(upload)
        // The redacted skeleton before the first sample has a rate's width.
        let shownDown = hasSample ? download : (number: "0.0", unit: "kB/s")
        let shownUp = hasSample ? up : (number: "0.0", unit: "kB/s")
        return cell(loc("네트워크", "Network"),
                    help: loc("네트워크: Wi-Fi·Ethernet 합산, VPN·루프백 제외", "Network: Wi-Fi and Ethernet combined, excluding VPN and loopback")
                        + "\n" + (system.localIPs.isEmpty ? loc("IPv4 주소 미확인", "IPv4 address unknown") : "IPv4 " + system.localIPs.joined(separator: " · ")),
                    spoken: loc("다운로드 \(download.number)\(download.unit), 업로드 \(upload)", "Download \(download.number)\(download.unit), upload \(upload)")) {
            Text("↓ " + shownDown.number).font(TCFont.value)
                + Text(shownDown.unit.isEmpty ? "" : " " + shownDown.unit).font(TCFont.micro).foregroundColor(TCColor.textSecondary(contrast: high))
        } aux: {
            Text("↑ " + shownUp.number + (shownUp.unit.isEmpty ? "" : " " + shownUp.unit)).font(TCFont.micro.monospacedDigit()).toneSecondary().lineLimit(1)
        }
    }
}

// MARK: - Footer

/// One leading status item (9): collection delay, telemetry notice, or "실시간"; the latter two open telemetry settings.
/// The update item sits trailing and takes the rest of the row; the status item never shrinks for it.
struct DashboardFooter: View {
    var status: FooterStatus
    var notice: TelemetryNotice?
    var help: String
    var open: () -> Void
    var update: UpdateNotice? = nil
    var updateAction: (UpdateCommand) -> Void = { _ in }
    @Environment(\.tokenCatHighContrast) private var high

    var body: some View {
        HStack(spacing: 0) {
            leading.fixedSize()
            Spacer(minLength: 12)
            if let update { UpdateFooterItem(notice: update, action: updateAction).layoutPriority(1) }
        }
        .frame(height: 18)
    }

    @ViewBuilder private var leading: some View {
        Group {
            switch status.kind {
            case .loading:
                item(Circle().fill(TCColor.idle).frame(width: 6, height: 6), primary: false).help(loc("첫 수집을 준비하고 있습니다", "Preparing the first sample"))
            case .aiDelay, .systemDelay:
                item(Circle().fill(TCColor.warning).frame(width: 6, height: 6), primary: true).help(help)
            case .notice:
                let problem = notice?.isProblem ?? true
                Button(action: open) {
                    item(Image(systemName: problem ? "exclamationmark.triangle.fill" : "info.circle").font(TCFont.meta)
                        .foregroundStyle(problem ? AnyShapeStyle(TCColor.warning) : AnyShapeStyle(TCColor.textSecondary(contrast: high))),
                         primary: problem)
                        .padding(.horizontal, 5)
                }
                .padding(.leading, -5)
                .help(notice?.help ?? help)
                .accessibilityHint(loc("설정을 엽니다", "Opens Settings"))
            case .live:
                Button(action: open) { item(Circle().fill(TCColor.activity).frame(width: 6, height: 6), primary: false).padding(.horizontal, 5) }
                    .padding(.leading, -5)
                    .help(help)
                    .accessibilityHint(loc("설정을 엽니다", "Opens Settings"))
            }
        }
    }

    private func item<Mark: View>(_ mark: Mark, primary: Bool) -> some View {
        HStack(spacing: 5) {
            mark
            Text(status.text).font(TCFont.meta.monospacedDigit()).lineLimit(1)
                .foregroundStyle(primary ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(TCColor.textSecondary(contrast: high)))
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }
}

/// The footer's quiet update line: secondary text, accent text buttons, ✕ hides it for that version only.
/// The failure's short reason drops first when the row is narrow, then the text itself (to help; a failure keeps its ⚠).
struct UpdateFooterItem: View {
    var notice: UpdateNotice
    var action: (UpdateCommand) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(detail: true)
            row(detail: false)
            row(detail: false, text: false).help(notice.text)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("업데이트", "Update"))
    }

    private func row(detail: Bool, text: Bool = true) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if case .failed = notice.kind {
                    Image(systemName: "exclamationmark.triangle.fill").font(TCFont.meta).foregroundStyle(TCColor.warning)
                }
                if text {
                    Text(detail ? ([notice.text] + [notice.detail].compactMap { $0 }).joined(separator: " · ") : notice.text)
                        .font(TCFont.metaMono).toneSecondary().lineLimit(1)
                }
            }
            .fixedSize()
            .help(notice.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notice.text)
            .accessibilityValue(notice.detail ?? "")
            .accessibilityHint(notice.help)
            .padding(.trailing, 2)
            buttons
        }
        .frame(height: 18)
    }

    @ViewBuilder private var buttons: some View {
        switch notice.kind {
        case .available:
            textButton(loc("업데이트", "Update"), help: notice.help) { action(.install) }
            close(loc("이 버전 알림 숨기기", "Hide notice for this version"))
        case .failed(let retryable):
            if retryable { textButton(loc("다시 시도", "Try Again"), help: loc("릴리스 정보를 다시 확인하고 내려받습니다", "Checks the release again and downloads it")) { action(.install) } }
            Button { action(.openReleasePage) } label: {
                Image(systemName: "arrow.up.forward.square").font(TCFont.meta).frame(width: 18, height: 18)
            }
            .buttonStyle(HoverButtonStyle(circle: true))
            .help(loc("릴리스 페이지 열기", "Open release page")).accessibilityLabel(loc("릴리스 페이지 열기", "Open release page"))
            close(loc("이 버전 알림 숨기기", "Hide notice for this version"))
        case .updated:
            close(loc("알림 닫기", "Close notice"))
        case .downloading, .installing:
            EmptyView()
        }
    }

    private func textButton(_ title: String, help: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).font(TCFont.metaMedium).foregroundStyle(Color.accentColor).padding(.horizontal, 5).frame(height: 18)
        }
        .fixedSize()
        .help(help)
    }

    private func close(_ label: String) -> some View {
        Button { action(.dismiss) } label: {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(HoverButtonStyle(circle: true))
        .help(label).accessibilityLabel(label)
    }
}
