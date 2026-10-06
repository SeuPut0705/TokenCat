import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// In-process row reordering only; external drags (e.g. plain text) never match.
    static let tokenCatMetricRow = UTType(exportedAs: "dev.seuput.TokenCat.metric-row", conformingTo: .data)
}
import UserNotifications

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }
    static var title: String { "TokenCat \(version) (\(build))" }
    /// The binary the disconnect command names; settings fixtures pin the installed path so snapshots hold no local path.
    static var executablePath = Bundle.main.executablePath ?? "/Applications/TokenCat.app/Contents/MacOS/TokenCat"
    static var privacy: String {
        loc("로컬 로그와 로컬 실측의 메타데이터만 읽습니다. 프롬프트·응답 본문은 저장하거나 표시하지 않으며, 모델을 호출하거나 계정에 로그인하지 않습니다. 인터넷 요청은 GitHub에 최신 버전을 묻는 업데이트 확인, 업데이트를 누를 때의 내려받기, 실시간 한도 확인이 켜져 있을 때 Codex·Claude Code에 저장된 로그인으로 OpenAI·Anthropic에 사용량을 묻는 요청뿐입니다. 토큰은 저장하지 않습니다.",
            "TokenCat reads only metadata from local logs and local telemetry. It never stores or shows prompts or responses, never calls a model and never signs in to an account. It goes online only to check GitHub for updates, to download one when you click Update and, with Live usage limits on, to ask OpenAI and Anthropic for usage with Codex and Claude Code's saved sign-in. Tokens are never stored.")
    }
    static let copyright = "Copyright © 2026 TokenCat contributors · MIT License"
    static func license() -> String {
        Bundle.main.url(forResource: "LICENSE", withExtension: nil).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? loc("앱 번들에서 LICENSE 파일을 찾지 못했습니다.", "Couldn't find the LICENSE file in the app bundle.")
    }
    static var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: privacy, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                       .foregroundColor: NSColor.secondaryLabelColor,
                                                                       .paragraphStyle: paragraph])
        return [.credits: credits, NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright]
    }
}

/// A Settings pane another surface can open directly (the popover's 실측 notice).
enum SettingsFocus: String { case telemetry }

/// The toolbar tabs of the Settings window (T-1), in toolbar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    /// `character` keeps the raw value "cat" for the remembered tab and `--pane cat`.
    case general, menubar, character = "cat", telemetry, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return loc("일반", "General")
        case .menubar: return loc("메뉴 막대", "Menu Bar")
        case .character: return loc("캐릭터", "Character")
        case .telemetry: return loc("실측", "Telemetry")
        case .about: return loc("정보", "About")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .menubar: return "menubar.rectangle"
        case .character: return "cat"
        case .telemetry: return "dot.radiowaves.left.and.right"
        case .about: return "info.circle"
        }
    }
    /// "cat" is missing from older SF Symbols; the paw print stands in.
    var image: NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            ?? (self == .character ? NSImage(systemSymbolName: "pawprint", accessibilityDescription: title) : nil)
    }
}

/// What Settings asks of the app shell; views never reach windows themselves.
struct SettingsActions {
    /// Clears `onboardingSeen` and opens the dashboard.
    var reshowOnboarding: () -> Void
    static let none = SettingsActions(reshowOnboarding: {})
}

/// Live system state shown in Settings: read back on open, never changed without a user action.
final class SettingsState: ObservableObject {
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var loginError: String?
    @Published private(set) var notificationStatus: UNAuthorizationStatus?
    @Published private(set) var soundSetting: UNNotificationSetting?
    @Published private(set) var notificationError: String?
    @Published private(set) var reduceMotion = false
    /// The cat's planned pose for the menu bar preview (T-5); the shell keeps it current while Settings is open.
    @Published var runnerPose: RunnerPose = .sit
    private let notifier: Notifier

    init(notifier: Notifier) {
        self.notifier = notifier
        refresh()
    }

    /// Fixed states for `--snapshot-settings --fixtures`: the login item and notification permission are never read or asked.
    init(notifier: Notifier, login: SMAppService.Status, notifications: UNAuthorizationStatus?, sound: UNNotificationSetting?) {
        self.notifier = notifier
        loginStatus = login
        notificationStatus = notifications
        soundSetting = sound
    }

    func refresh() {
        loginStatus = LoginItem.status
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        notifier.settings { [weak self] status, sound in
            self?.notificationStatus = status
            self?.soundSetting = sound
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            loginError = nil
        } catch {
            loginError = loc("로그인 항목을 바꾸지 못했습니다: \(error.localizedDescription)", "Couldn't change the login item: \(error.localizedDescription)")
        }
        loginStatus = LoginItem.status
    }

    /// Asks macOS only when a toggle is switched on: alerts when never decided; with `sound` (the sound toggle) alerts and
    /// sound. The caption then shows what macOS reports, not what was asked.
    func notificationToggleEnabled(sound: Bool = false) {
        notifier.settings { [weak self] status, setting in
            guard let self else { return }
            self.notificationStatus = status
            self.soundSetting = setting
            guard status == .notDetermined || sound else { return }
            self.notifier.requestAuthorization(sound: sound) { status, error in
                self.notificationStatus = status
                self.notificationError = error.map { loc("알림 권한 요청 실패: \($0)", "Notification permission request failed: \($0)") }
                self.notifier.settings { self.notificationStatus = $0; self.soundSetting = $1 }
            }
        }
    }
}

/// The Settings window content: toolbar tabs, one hosting controller per pane, the window height following the pane (T-1).
/// The window title follows the selected tab; the last tab is remembered.
final class SettingsTabsController: NSTabViewController {
    static let width: CGFloat = 480
    /// The tallest pane must fit without scrolling.
    static let maximumHeight: CGFloat = 600
    static let paneKey = "settingsPane"
    private let defaults: UserDefaults

    init(preferences: Preferences, model: DashboardModel, state: SettingsState, actions: SettingsActions, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.paneKey).flatMap(SettingsPane.init(rawValue:))
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let controller = NSHostingController(rootView: SettingsPaneView(pane: pane, preferences: preferences, model: model,
                                                                            state: state, actions: actions))
            controller.sizingOptions = [.preferredContentSize]
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.image = pane.image
            item.identifier = pane.rawValue
            addTabViewItem(item)
        }
        if let saved { select(saved) }
    }

    required init?(coder: NSCoder) { nil }

    var pane: SettingsPane { SettingsPane.allCases.indices.contains(selectedTabViewItemIndex) ? SettingsPane.allCases[selectedTabViewItemIndex] : .general }

    func select(_ pane: SettingsPane) {
        if let index = SettingsPane.allCases.firstIndex(of: pane) { selectedTabViewItemIndex = index }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        transitionOptions = reduceMotion ? [] : [.crossfade, .allowUserInteraction]
        super.tabView(tabView, didSelect: tabViewItem)
        defaults.set(pane.rawValue, forKey: Self.paneKey)
        view.window?.title = pane.title
        fitWindow(animated: !reduceMotion)
    }

    /// The selected pane's height, top edge fixed; animated unless Reduce Motion.
    func fitWindow(animated: Bool) {
        guard let window = view.window, let child = tabView.selectedTabViewItem?.viewController else { return }
        let delta = child.view.fittingSize.height - window.contentLayoutRect.height
        guard abs(delta) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y -= delta
        frame.size.height += delta
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    /// A fixed-width, titled window with toolbar-style tabs; not resizable (the height follows the pane).
    static func configure(_ window: NSWindow, with tabs: SettingsTabsController) {
        window.styleMask = [.titled, .closable]
        window.contentViewController = tabs
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.title = tabs.pane.title
    }
}

/// One pane. Each observes only what it shows, so hidden panes do not re-render on every model publish.
struct SettingsPaneView: View {
    let pane: SettingsPane
    let preferences: Preferences
    let model: DashboardModel
    let state: SettingsState
    let actions: SettingsActions

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane(preferences: preferences, state: state)
            case .menubar: MenuBarPane(preferences: preferences, model: model, state: state)
            case .character: CharacterPane(preferences: preferences, state: state)
            case .telemetry: TelemetryPane(model: model, preferences: preferences)
            case .about: AboutPane(model: model, preferences: preferences, state: state, actions: actions)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: SettingsTabsController.width)
    }
}

/// Title with an 11 pt secondary subtitle under it, inside the control's own label (T-2); explicit, so macOS 13 lays it out too.
/// `warning` puts a 12 pt warning triangle before the title.
private struct SettingsLabel: View {
    var title: String
    var subtitle: String?
    var subtitleColor: Color = .secondary
    var warning = false
    /// A disabled control's label is not dimmed by Form on its own.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(TCColor.warning)
                        .accessibilityHidden(true)
                }
                Text(title).foregroundStyle(isEnabled ? HierarchicalShapeStyle.primary : .secondary)
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(subtitleColor).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Grouped forms align footers trailing at body size on macOS; keep them as leading captions.
private func settingsFooter(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
}

private func settingsCaption(_ text: String, color: Color = .secondary) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
}

/// System Settings › Notifications, at TokenCat.
private func openNotificationSettings() {
    let id = Bundle.main.bundleIdentifier ?? "dev.seuput.TokenCat"
    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
        NSWorkspace.shared.open(url)
    }
}

private struct GeneralPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var state: SettingsState
    @State private var confirmsReset = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { LoginItem.isOn(state.loginStatus) }, set: { state.setLogin($0) })) {
                    SettingsLabel(title: loc("로그인 시 TokenCat 열기", "Open TokenCat at login"), subtitle: LoginItem.describe(state.loginStatus))
                }
                .help(loc("켜면 macOS 로그인 항목에 등록하고, 끄면 해제합니다. 켜기 전에는 등록하지 않습니다.",
                           "When on, TokenCat is added to Login Items in macOS; when off, it's removed. Nothing is registered until you turn this on."))
                if let error = state.loginError { settingsCaption(error, color: .red) }
                if state.loginStatus == .requiresApproval {
                    Button(loc("로그인 항목 설정 열기", "Open Login Items Settings")) { LoginItem.openSystemSettings() }
                }
            } header: {
                Text(loc("시작", "Startup"))
            } footer: {
                if !LoginItem.isInApplications {
                    settingsFooter(loc("앱을 /Applications로 옮긴 뒤 켜는 것을 권장합니다. 다른 위치의 앱을 다시 빌드하거나 옮기면 등록이 풀릴 수 있습니다.",
                                       "Move the app to /Applications before turning this on. A copy elsewhere can lose its registration when it's rebuilt or moved."))
                }
            }

            Section {
                Toggle(isOn: notificationBinding(\.notifyTurnComplete)) {
                    SettingsLabel(title: loc("턴 완료", "Turn complete"),
                                  subtitle: loc("최상위 세션의 턴이 끝나거나 중단되면 알립니다", "Notifies when a top-level session's turn ends or is interrupted"))
                }
                Toggle(isOn: notificationBinding(\.notifyInput)) {
                    SettingsLabel(title: loc("입력 필요", "Input needed"),
                                  subtitle: loc("질문·계획 승인을 기다리면 알립니다. 권한 확인 요청은 로그에 남지 않아 알 수 없습니다",
                                                "Notifies when a question or plan approval is waiting. Permission prompts aren't logged, so TokenCat can't see them"))
                }
                Toggle(isOn: Binding(get: { preferences.notifyInputSound }, set: { on in
                    preferences.notifyInputSound = on
                    if on { state.notificationToggleEnabled(sound: true) }
                })) {
                    SettingsLabel(title: loc("입력 필요 알림에 소리", "Sound for input-needed alerts"),
                                  subtitle: Notifier.describeSound(state.notificationStatus, state.soundSetting, on: preferences.notifyInputSound))
                }
                .disabled(!preferences.notifyInput)
                // The way to System Settings sits in this row when macOS blocks alerts or the sound.
                LabeledContent(loc("권한", "Permission")) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(Notifier.describe(state.notificationStatus)).font(.system(size: 11)).multilineTextAlignment(.trailing)
                            .foregroundStyle(state.notificationStatus == .denied
                                             && (preferences.notifyTurnComplete || preferences.notifyInput || preferences.notifyUpdate)
                                             ? TCColor.warning : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if state.notificationStatus == .denied
                            || (preferences.notifyInput && preferences.notifyInputSound && Notifier.soundBlocked(state.notificationStatus, state.soundSetting)) {
                            Button(loc("알림 설정 열기", "Open Notification Settings"), action: openNotificationSettings).controlSize(.small)
                        }
                    }
                }
                if let error = state.notificationError { settingsCaption(error, color: .red) }
            } header: {
                Text(loc("알림", "Notifications"))
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    settingsFooter(loc("기본값은 꺼짐입니다. 상세 화면이 보이는 동안에는 보내지 않습니다. 프로젝트·모델·토큰 수·소요 시간만 넣고 질문이나 응답 내용은 넣지 않습니다.",
                                       "Off by default, and never sent while the dashboard is visible. They include only the project, model, token count and duration, never questions or responses."))
                    HStack {
                        Spacer()
                        Button(loc("기본값으로 되돌리기…", "Restore Defaults…")) { confirmsReset = true }
                    }
                }
            }
        }
        .alert(loc("메뉴 막대·캐릭터·알림 설정을 기본값으로 되돌릴까요?", "Restore the menu bar, character and notification settings to their defaults?"), isPresented: $confirmsReset) {
            Button(loc("되돌리기", "Restore"), role: .destructive) { preferences.reset(undoManager: undoManager) }
            Button(loc("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc("항목 순서와 표시, 표시 방식, 캐릭터, 알림 선택이 바뀝니다. 로그인 항목, 새 버전 자동 확인과 macOS 알림 권한은 그대로입니다.",
                      "This resets item order and visibility, the layout, and the character and notification choices. The login item, automatic update checks and macOS notification permission stay as they are."))
        }
    }

    private func notificationBinding(_ key: ReferenceWritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { preferences[keyPath: key] }, set: { on in
            preferences[keyPath: key] = on
            if on { state.notificationToggleEnabled() }
        })
    }
}

/// "업데이트" on the 정보 tab: automatic checks, the status line with its buttons and the opt-in notice.
/// Only this section follows the model's clock.
private struct UpdateSection: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var state: SettingsState

    var body: some View {
        let update = model.update
        let status = update.status(now: model.now)
        let failure = update.installFailure
        Section {
            Toggle(loc("새 버전 자동 확인", "Check for updates automatically"), isOn: $preferences.autoCheckUpdates)
                .disabled(update.disabled != nil)
                .help(loc("실행 직후, 15분마다, 잠자기에서 깨어난 뒤 GitHub 최신 릴리스를 확인합니다",
                           "Checks GitHub for the latest release at launch, every 15 minutes and after waking from sleep"))
            // One row: the full failure sentence spans the width under the status and its buttons; it replaces the short
            // reason, and only the title carries the warning mark.
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent {
                    HStack(spacing: 6) { updateButtons(update, failure: failure) }
                        .fixedSize()
                } label: {
                    SettingsLabel(title: status.title, subtitle: failure == nil ? status.detail : nil, warning: status.problem)
                }
                if let failure { settingsCaption(failure.text) }
            }
            // Turned on while macOS denies notifications: said here too, with the way to System Settings in the same row.
            let denied = preferences.notifyUpdate && state.notificationStatus == .denied
            LabeledContent {
                HStack(spacing: 8) {
                    if denied { Button(loc("알림 설정 열기", "Open Notification Settings"), action: openNotificationSettings).controlSize(.small) }
                    Toggle(loc("새 버전 알림", "Notify about new versions"), isOn: Binding(get: { preferences.notifyUpdate }, set: { on in
                        preferences.notifyUpdate = on
                        if on { state.notificationToggleEnabled() }
                    }))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(update.disabled != nil)
                }
            } label: {
                SettingsLabel(title: loc("새 버전 알림", "Notify about new versions"),
                              subtitle: denied ? loc("macOS 알림 권한이 꺼져 있어 보내지 않습니다", "Not sent because macOS notification permission is off")
                                  : loc("새 버전을 찾으면 소리 없이 한 번 알립니다", "Notifies once, without sound, when a new version is found"),
                              subtitleColor: denied ? TCColor.warning : .secondary)
            }
            if preferences.notifyUpdate, let error = state.notificationError { settingsCaption(error, color: .red) }
        } header: {
            Text(loc("업데이트", "Updates"))
        }
    }

    /// At most two: after a retryable failure "다시 시도" and the release page (no second way to check); after one that
    /// blocks the install, what the person can do (the Applications folder for a translocated copy, else the release page)
    /// and "지금 확인", since a newer release can be installed again.
    @ViewBuilder private func updateButtons(_ update: UpdateState, failure: UpdateFailure?) -> some View {
        if let failure {
            if failure.retryable {
                if update.canInstall {
                    Button(loc("다시 시도", "Try Again")) { model.requestUpdate(.install) }
                        .help(loc("릴리스 정보를 다시 확인하고 내려받습니다", "Checks the release again and downloads it"))
                }
                Button(loc("릴리스 페이지 열기", "Open Release Page")) { model.requestUpdate(.openReleasePage) }
            } else {
                if failure == .translocated {
                    Button(loc("응용 프로그램 폴더 열기", "Open Applications Folder")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true)) }
                        .help(loc("Finder에서 TokenCat을 이 폴더로 옮긴 뒤 다시 여세요", "Move TokenCat to this folder in Finder, then open it again"))
                } else {
                    Button(loc("릴리스 페이지 열기", "Open Release Page")) { model.requestUpdate(.openReleasePage) }
                }
                Button(loc("지금 확인", "Check Now")) { model.requestUpdate(.check) }.disabled(!update.canCheck)
            }
        } else {
            if update.canInstall {
                Button(loc("업데이트", "Update")) { model.requestUpdate(.install) }
                    .help(loc("내려받아 설치한 뒤 TokenCat을 다시 엽니다", "Downloads and installs the update, then reopens TokenCat"))
            }
            Button(loc("지금 확인", "Check Now")) { model.requestUpdate(.check) }.disabled(!update.canCheck)
        }
    }
}

private struct MenuBarPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var model: DashboardModel
    @ObservedObject var state: SettingsState
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Form {
            Section {
                MenuBarPreview(model: model, preferences: preferences, pose: state.runnerPose)
                Picker(loc("프리셋", "Preset"), selection: Binding(get: { preferences.preset },
                                                                set: { $0.map { preferences.apply($0, undoManager: undoManager) } })) {
                    ForEach(DisplayPreset.allCases) { Text($0.title).tag(DisplayPreset?.some($0)) }
                    if preferences.preset == nil { Text(loc("사용자 지정", "Custom")).tag(DisplayPreset?.none) }
                }
                .help(loc("표시 방식과 항목을 한 번에 바꿉니다", "Sets the layout and items in one step"))
                Picker(loc("표시 방식", "Layout"), selection: $preferences.statusBarLayout) {
                    ForEach(StatusBarLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help(preferences.statusBarLayout.summary)
            }
            Section {
                MetricRows(preferences: preferences)
            } header: {
                Text(loc("항목", "Items"))
            } footer: {
                settingsFooter(preferences.statusBarLayout == .minimal
                               ? loc("최소 표시는 캐릭터와 AI 상태·세션 수만 보여 줍니다. 항목 목록은 두 줄·한 줄 표시에 적용됩니다.",
                                     "Minimal shows only the character, AI status and session count. The item list applies to the Two Lines and One Line layouts.")
                               : loc("끌어서 순서를 바꿉니다. 캐릭터를 숨기면 마지막 항목은 숨길 수 없습니다.",
                                     "Drag to reorder. With the character hidden, the last item can't be hidden."))
            }
        }
    }
}

private struct CharacterPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            Section {
                Picker(loc("캐릭터", "Character"), selection: $preferences.character) {
                    ForEach(RunnerCharacter.allCases) { character in
                        Label { Text(character.title) } icon: {
                            Image(nsImage: Runner.image(pose: .walk, frame: 0, character: character)).interpolation(.none)
                        }
                        .tag(character)
                    }
                }
                Toggle(loc("메뉴 막대에 캐릭터 표시", "Show character in menu bar"), isOn: Binding(get: { preferences.showRunner }, set: { preferences.setShowRunner($0) }))
                    .disabled(preferences.showRunner && !preferences.canHideRunner)
                    .help(preferences.canHideRunner ? "" : loc("표시할 항목이 없어 캐릭터를 숨길 수 없습니다", "The character can't be hidden because no other item is shown"))
                Picker(selection: $preferences.animationSource) {
                    ForEach(RunnerMotion.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel(title: loc("움직임 기준", "Motion source"), subtitle: preferences.animationSource.subtitle)
                }
                .help(preferences.animationSource.caption)
                let entries = RunnerLegend.entries(preferences.animationSource)
                if !entries.isEmpty { RunnerLegend(entries: entries, character: preferences.character, reduceMotion: state.reduceMotion) }
                if state.reduceMotion { settingsCaption(loc("macOS의 '동작 줄이기'가 켜져 있어 캐릭터는 자세만 바뀝니다.", "Reduce Motion is on in macOS, so the character only changes poses.")) }
            }
        }
    }
}

/// One tile per pose the chosen motion uses: frame 0 drawn 1:1 without smoothing, a caption under it (T-4).
/// Hovering plays the pose once (not under Reduce Motion). Each tile is one VoiceOver element.
struct RunnerLegend: View {
    struct Entry: Equatable {
        var pose: RunnerPose
        var name: String
        var caption: String
    }
    var entries: [Entry]
    var character: RunnerCharacter
    var reduceMotion: Bool

    static func entries(_ motion: RunnerMotion) -> [Entry] {
        switch motion {
        case .activity:
            return [Entry(pose: .walk, name: loc("걷기", "Walk"), caption: loc("진행·도구 실행", "Working · tool")),
                    Entry(pose: .run, name: loc("달리기", "Run"), caption: loc("출력 기록 직후", "Just recorded")),
                    Entry(pose: .alert, name: loc("정면 보기", "Facing you"), caption: loc("입력 필요", "Input needed")),
                    Entry(pose: .sit, name: loc("앉기", "Sit"), caption: loc("대기·쉬는 중", "Waiting · idle")),
                    Entry(pose: .sleep, name: loc("잠", "Sleep"), caption: loc("10분간 활동 없음", "Idle 10 min"))]
        case .cpu:
            return [Entry(pose: .sit, name: loc("앉기", "Sit"), caption: loc("4% 미만", "Under 4%")),
                    Entry(pose: .walk, name: loc("걷기", "Walk"), caption: loc("20%까지", "Up to 20%")),
                    Entry(pose: .run, name: loc("달리기", "Run"), caption: loc("20% 넘음", "Over 20%"))]
        case .measured:
            return [Entry(pose: .sit, name: loc("앉기", "Sit"), caption: loc("실측 없음", "Not measured")),
                    Entry(pose: .walk, name: loc("걷기", "Walk"), caption: loc("40 tok/s 미만", "Under 40 tok/s")),
                    Entry(pose: .run, name: loc("달리기", "Run"), caption: loc("40 이상", "40 or more"))]
        case .still:
            return []
        }
    }

    var body: some View {
        // Never wraps: the captions step down to 10 pt when the row does not fit.
        ViewThatFits(in: .horizontal) {
            row(captionSize: 11)
            row(captionSize: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(captionSize: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Equal columns, wide enough for the longest caption ("10분간 활동 없음": 75.6 pt at 11, 68.9 at 10).
            ForEach(entries, id: \.pose) {
                LegendTile(entry: $0, character: character, reduceMotion: reduceMotion, captionSize: captionSize).frame(width: captionSize == 11 ? 76 : 70)
            }
        }
        .fixedSize()
    }
}

private struct LegendTile: View {
    var entry: RunnerLegend.Entry
    var character: RunnerCharacter
    var reduceMotion: Bool
    var captionSize: CGFloat
    @State private var frame = 0
    @State private var fx: Int?
    @State private var playing = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Image(nsImage: Runner.image(pose: entry.pose, frame: frame, character: character)).interpolation(.none)
                if let step = fx ?? RunnerAnimator.stillFX(entry.pose), !playing || fx != nil,
                   let mask = Runner.fxMask(pose: entry.pose, step: step) {
                    Image(nsImage: mask).renderingMode(.template).interpolation(.none).foregroundColor(.secondary)
                }
            }
            .frame(width: Runner.size.width, height: Runner.size.height)
            .frame(width: 64, height: 36)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
            Text(entry.caption).font(.system(size: captionSize)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .contentShape(Rectangle())
        .onHover { if $0 { play() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name), \(entry.caption)")
    }

    /// One pass through the pose's frames with its own timing, then back to frame 0.
    private func play() {
        guard !reduceMotion, !playing else { return }
        let timing = Runner.timing(entry.pose)
        let count = timing.durations.count
        guard count > 1 else { return }
        var steps: [(frame: Int, fx: Int?, seconds: TimeInterval)] = []
        if entry.pose == .sleep {
            steps = [(1, RunnerAnimator.smallZ, timing.durations[1]), (0, RunnerAnimator.largeZ, timing.durations[0])]
        } else {
            steps = (1..<count).map { ($0, nil, timing.durations[$0]) }
            if count > 2 { steps.append((0, nil, timing.durations[0])) }
        }
        playing = true
        Task { @MainActor in
            for step in steps {
                frame = step.frame
                fx = step.fx
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, step.seconds) * 1_000_000_000))
            }
            frame = 0
            fx = nil
            playing = false
        }
    }
}

/// Collector and client rows (T-3): a 12 pt state symbol, 13 pt secondary text, an optional 11 pt second line.
enum TelemetryStatusRow: Equatable {
    case receiving, waiting, starting, problem, info, received

    var symbol: String {
        switch self {
        case .receiving, .received: return "checkmark.circle.fill"
        case .waiting: return "circle.dashed"
        case .starting: return "circle.dotted"
        case .problem: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }
    var color: Color {
        switch self {
        case .receiving, .received: return TCColor.activity
        case .problem: return TCColor.warning
        default: return .secondary
        }
    }

    static func collector(_ state: TelemetryCollectorState) -> (row: TelemetryStatusRow, text: String) {
        let address = "127.0.0.1:\(LocalTelemetryCollector.port)"
        switch state {
        case .receiving: return (.receiving, loc("수신 중 · \(address)", "Receiving · \(address)"))
        case .waiting: return (.waiting, loc("수신 대기 · \(address)", "Waiting · \(address)"))
        case .starting: return (.starting, loc("준비 중", "Preparing"))
        case .busyTokenCat: return (.problem, loc("꺼짐 · 다른 TokenCat이 수집 중", "Off · another TokenCat is collecting"))
        case .busyOtherApp: return (.problem, loc("꺼짐 · 다른 앱이 \(LocalTelemetryCollector.port) 포트 사용 중", "Off · another app is using port \(LocalTelemetryCollector.port)"))
        case .failed: return (.problem, loc("꺼짐 · 수집기를 시작하지 못함", "Off · couldn't start the collector"))
        case .stopped: return (.problem, loc("꺼짐", "Off"))
        }
    }

    /// Checked top to bottom: restart needed, a day without a reading, a reading, an undecodable batch, nothing.
    static func client(restartNeeded: Bool, expired: Bool, lastReceived: Date?, batch: Date?, now: Date)
        -> (row: TelemetryStatusRow, text: String, detail: String?) {
        if restartNeeded { return (.info, loc("새로 실행하면 실측이 표시됩니다", "Restart to show telemetry"), nil) }
        if expired { return (.problem, loc("이 버전에서 실측을 받지 못했습니다", "No telemetry from this version"), nil) }
        if let at = lastReceived { return (.received, loc("최근 수신 ", "Last received ") + SessionPresentation.helpAge(at, now: now), nil) }
        if batch != nil {
            return (.waiting, loc("기록 수신 중 · 속도 형식 없음", "Receiving records · no speed data"),
                    loc("받은 실측에서 요청별 생성 시간을 찾지 못해 속도를 표시하지 않습니다", "Received telemetry has no per-request generation time, so no speed is shown"))
        }
        return (.waiting, loc("이번 실행에서 받은 실측 없음", "No telemetry since launch"), nil)
    }

    /// The usage-limit bridge, checked top to bottom: an empty status line, skipped, a reading, the bridge waiting for a
    /// relaunch, nothing connected. `bridged` is nil until a connection succeeds this run. A recreated original command
    /// adds the second line. `desktop`: the newest reading is the Claude desktop app's own record, not a bridge receipt;
    /// `live`: a live read (실시간 한도 확인).
    static func claudeLimits(notes: [TelemetrySetupNote], bridged: Bool?, received: Date?, desktop: Bool = false, live: Bool = false, now: Date)
        -> (row: TelemetryStatusRow, text: String, detail: String?) {
        if notes.contains(.originalUnknown) { return (.problem, loc("상태 표시줄이 비어 보일 수 있음", "Status line may look empty"),
                                                                 loc("settings.json의 statusLine을 직접 고쳐 주세요", "Fix statusLine in settings.json by hand")) }
        if notes.contains(.statusLineSkipped) { return (.info, loc("연결 안 함 · statusLine 형식이 달라 건너뜀", "Not connected · unsupported statusLine format"), nil) }
        let detail = notes.contains(.originalRecreated) ? loc("원래 상태 표시줄 명령을 백업 기록에서 다시 만들었습니다", "Recreated the original status line command from backup") : nil
        if let at = received, live { return (.received, loc("실시간 확인 ", "Checked live ") + SessionPresentation.helpAge(at, now: now), detail) }
        if let at = received, desktop { return (.received, loc("Claude 데스크톱 앱 기록 · \(Format.age(at, now: now))", "Claude desktop app · recorded \(Format.age(at, now: now))"), detail) }
        if let at = received { return (.received, loc("최근 수신 ", "Last received ") + SessionPresentation.helpAge(at, now: now), detail) }
        if bridged == true { return (.waiting, loc("아직 받지 못함 · Claude Code를 새로 실행하면 표시", "Nothing yet · restart Claude Code to show"), detail) }
        return (.info, bridged == nil ? loc("연결 확인 전", "Not checked yet") : loc("연결 안 함", "Not connected"), nil)
    }
}

private struct TelemetryPane: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var preferences: Preferences
    /// Read once on appear; the buttons only reveal files in Finder and never open or edit them.
    @State private var files: [(title: String, url: URL)] = []

    var body: some View {
        Form {
            Section {
                collector
                if let note = model.telemetrySetupNote { settingsCaption(note, color: TCColor.warning) }
                ForEach(TokenSource.allCases, id: \.self) { source in
                    let status = TelemetryStatusRow.client(restartNeeded: model.telemetryRestartNeeded.contains(source),
                                                           expired: model.telemetryRestartExpired.contains(source),
                                                           lastReceived: model.telemetryLastReceived[source],
                                                           batch: model.telemetryBatches[source], now: model.now)
                    LabeledContent(source.title) { statusLine(status.row, status.text, detail: status.detail) }
                }
                // Whether the status line bridge delivers; the newer of the two windows' receipts (no reset time: the desktop app).
                let newest = [model.claudeLimits.fiveHour, model.claudeLimits.sevenDay].compactMap { $0 }.max { $0.receivedAt < $1.receivedAt }
                let live = newest?.live == true
                let limits = TelemetryStatusRow.claudeLimits(notes: model.telemetryConnectNotes, bridged: model.claudeBridged, received: newest?.receivedAt,
                                                             desktop: newest?.resetsAt == nil && !live, live: live, now: model.now)
                LabeledContent(loc("Claude 한도", "Claude limits")) { statusLine(limits.row, limits.text, detail: limits.detail) }
            } footer: {
                // Non-breaking hyphens (U+2011) keep the flag on one line; the footer is not selectable, so it is retyped.
                settingsFooter(loc("실측은 출력 토큰·요청 시간 같은 수치만, Claude 한도는 상태 표시줄 JSON과 Claude 데스크톱 앱 사용량 기록의 사용률만 받습니다. 이미 실행 중인 클라이언트는 새로 실행해야 적용됩니다. 해제하려면 터미널에서 \(AppInfo.executablePath) \u{2011}\u{2011}disconnect\u{2011}telemetry를 실행합니다.",
                                   "Telemetry receives only numbers such as output tokens and request times. Claude limits use only the usage percentage from the status line JSON and the Claude desktop app's usage history. Restart running clients to apply. To disconnect, run \(AppInfo.executablePath) \u{2011}\u{2011}disconnect\u{2011}telemetry in Terminal."))
            }
            Section {
                Toggle(isOn: $preferences.liveUsageLimits) {
                    SettingsLabel(title: loc("실시간 한도 확인", "Live usage limits"),
                                  subtitle: loc("Codex·Claude Code에 저장된 로그인으로 OpenAI·Anthropic 사용량을 사용 중에는 1분, 평소에는 10분마다 확인합니다. 토큰은 저장하지 않습니다.",
                                                "Checks usage with OpenAI and Anthropic using Codex and Claude Code's saved sign-in, every minute while in use and every 10 minutes otherwise. Tokens are never stored."))
                }
                .help(loc("세션이 실행 중이거나 TokenCat 창이 열려 있으면 1분마다, 그 밖에는 10분마다 확인하고, 화면이나 Mac이 잠자는 동안은 멈춥니다. 만료된 Claude 토큰은 보내지 않고 갱신하지도 않습니다.",
                          "Checks every minute while a session runs or a TokenCat window is open, otherwise every 10 minutes, and pauses while the screens or the Mac sleep. An expired Claude token is never sent or refreshed."))
            }
            if !files.isEmpty {
                Section {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { fileButtons }
                        VStack(alignment: .leading, spacing: 6) { fileButtons }
                    }
                } footer: {
                    settingsFooter(loc("Finder에서 위치만 보여 주며 파일을 열거나 바꾸지 않습니다.", "Only shows where the files are in Finder; never opens or changes them."))
                }
            }
        }
        .onAppear { files = Self.existingFiles() }
    }

    private var collector: some View {
        let status = TelemetryStatusRow.collector(model.telemetryState)
        return LabeledContent(loc("수집기", "Collector")) {
            VStack(alignment: .trailing, spacing: 4) {
                statusLine(status.row, status.text, detail: nil)
                if let next = model.telemetryNextRetryAt {
                    HStack(spacing: 6) {
                        Text(loc("다음 자동 재시도 ", "Automatic retry in ") + SessionPresentation.clock(max(0, Int(ceil(next.timeIntervalSince(model.now))))))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        Button(loc("지금 다시 시도", "Retry Now")) { model.retryTelemetryNow() }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(model.telemetryState == .starting)
                    }
                }
                if model.telemetryState == .busyTokenCat, let other = Self.otherTokenCat() {
                    Button(loc("Finder에서 보기", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([other]) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help(other.path)
                }
            }
        }
    }

    private func statusLine(_ row: TelemetryStatusRow, _ text: String, detail: String?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: row.symbol).font(.system(size: 12)).foregroundStyle(row.color).accessibilityHidden(true)
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var fileButtons: some View {
        ForEach(files, id: \.url) { file in
            Button(file.title) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }.controlSize(.small)
        }
    }

    static func existingFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(title: String, url: URL)] {
        [(loc("백업 폴더 보기", "Show Backup Folder"), home.appendingPathComponent("Library/Application Support/TokenCat/telemetry-backups", isDirectory: true)),
         (loc("Codex 설정 파일 보기", "Show Codex Config"), home.appendingPathComponent(".codex/config.toml")),
         (loc("Claude Code 설정 파일 보기", "Show Claude Code Config"), home.appendingPathComponent(".claude/settings.json"))]
            .filter { FileManager.default.fileExists(atPath: $0.1.path) }
    }

    /// The bundle of another running TokenCat, so the person can find the copy holding the port.
    static func otherTokenCat() -> URL? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?.bundleURL
    }
}

private struct AboutPane: View {
    let model: DashboardModel
    let preferences: Preferences
    let state: SettingsState
    let actions: SettingsActions
    @State private var showsLicense = false

    var body: some View {
        Form {
            Section {
                // "TokenCat 정보" (the standard About panel) stays in the ⋯ and quick menus.
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    Text("TokenCat").font(.system(size: 15, weight: .semibold))
                    Text(loc("버전 \(AppInfo.version) (\(AppInfo.build))", "Version \(AppInfo.version) (\(AppInfo.build))")).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(AppInfo.privacy).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                HStack {
                    Button(loc("MIT 라이선스 보기", "Show MIT License")) { showsLicense = true }
                    Button(loc("처음 안내 다시 보기", "Show Welcome Again"), action: actions.reshowOnboarding)
                        .help(loc("처음 실행 안내(TokenCat이 하는 일)를 상세 화면에 다시 보입니다",
                                  "Shows the first-launch welcome (What TokenCat does) on the dashboard again"))
                    Spacer()
                }
            }
            UpdateSection(model: model, preferences: preferences, state: state)
        }
        .sheet(isPresented: $showsLicense) { LicenseView() }
    }
}

extension MetricID {
    /// The label the bar draws, shown after the title in the item list (T-5); nil when it equals the title, or for a client
    /// speed item, whose row shows its glyph instead.
    var barLabel: String? {
        switch self {
        case .cpu, .codexSpeed, .claudeSpeed: return nil
        case .memory: return "RAM"
        case .disk: return "DISK"
        case .battery: return "BAT"
        case .network: return "NET"
        case .ai: return "AI"
        case .averageSpeed: return "AVG"
        }
    }
}

/// Reorderable item list: drag, context menu, or the VoiceOver actions "위로 이동"/"아래로 이동".
/// A grouped Form is not a List, so `.onMove` never receives drags; rows are their own drag sources and drop targets.
private struct MetricRows: View {
    @ObservedObject var preferences: Preferences
    @State private var dragging: MetricID?

    var body: some View {
        ForEach(preferences.order) { id in
            let missingBattery = id == .battery && !preferences.hasBattery
            let locked = !missingBattery && preferences.visible.contains(id) && !preferences.canHide(id)
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
                Toggle(isOn: Binding(get: { !missingBattery && preferences.visible.contains(id) }, set: { preferences.setVisible(id, $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        if let source = id.speedSource {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(id.title)
                                (Text(" · ").font(.system(size: 11)).foregroundColor(.secondary) + Text(Image(nsImage: SpeedGlyph.image(source, side: 9))))
                                    .accessibilityHidden(true)
                            }
                        } else {
                            id.barLabel.map { Text(id.title) + Text(" · \($0)").font(.system(size: 11)).foregroundColor(.secondary) } ?? Text(id.title)
                        }
                        if missingBattery {
                            Text(loc("이 Mac에는 배터리가 없습니다", "This Mac has no battery")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(missingBattery || locked)
                .accessibilityAction(named: loc("위로 이동", "Move up")) { preferences.move(id, by: -1) }
                .accessibilityAction(named: loc("아래로 이동", "Move down")) { preferences.move(id, by: 1) }
                Spacer(minLength: 0)
            }
            .help(locked ? loc("캐릭터를 숨긴 상태에서는 최소 한 항목을 표시해야 합니다", "With the character hidden, at least one item must stay visible")
                  : loc("끌어서 순서를 바꿉니다", "Drag to reorder"))
            .contentShape(Rectangle())
            // The row itself moves while dragging; no dimming, since a drag cancelled outside never reports back.
            .onDrag {
                dragging = id
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.tokenCatMetricRow.identifier, visibility: .ownProcess) { done in
                    done(Data(id.rawValue.utf8), nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [.tokenCatMetricRow], delegate: MetricDropDelegate(target: id, preferences: preferences, dragging: $dragging))
            .contextMenu {
                Button(loc("위로 이동", "Move Up")) { preferences.move(id, by: -1) }.disabled(preferences.order.first == id)
                Button(loc("아래로 이동", "Move Down")) { preferences.move(id, by: 1) }.disabled(preferences.order.last == id)
            }
        }
    }
}

/// Moves the dragged row live as it passes over another row; refuses drops unless a drag started in this list.
private struct MetricDropDelegate: DropDelegate {
    let target: MetricID
    let preferences: Preferences
    @Binding var dragging: MetricID?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil && info.hasItemsConforming(to: [.tokenCatMetricRow]) }
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { preferences.move(dragging, onto: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Light and dark strips of the real status item at their native size and without smoothing; the cat shows its planned
/// pose (frame 0). A strip wider than the row is cut with a short fade, never scaled. Rebuilt through a memo (T-5).
private struct MenuBarPreview: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var preferences: Preferences
    var pose: RunnerPose
    @State private var cache = MenuBarPreviewCache()

    var body: some View {
        let preview = cache.preview(model: model, preferences: preferences, pose: pose)
        let width = Int(preview.width.rounded())
        let notch = NSScreen.screens.contains { $0.auxiliaryTopLeftArea != nil }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(preview.images.indices, id: \.self) { index in
                let image = preview.images[index]
                GeometryReader { proxy in
                    let overflow = image.size.width > proxy.size.width + 0.5
                    Image(nsImage: image).interpolation(.none).frame(width: image.size.width, height: image.size.height)
                        .frame(width: proxy.size.width, alignment: .leading)
                        .clipped()
                        .mask {
                            HStack(spacing: 0) {
                                Color.black
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: overflow ? 28 : 0)
                            }
                        }
                }
                .frame(height: image.size.height)
            }
            Text(notch ? loc("메뉴 막대 폭 약 \(width)pt · 노치 Mac에서는 자리가 부족하면 가려질 수 있습니다",
                              "About \(width) pt of menu bar · may hide behind the notch if space is short")
                 : loc("메뉴 막대 폭 약 \(width)pt", "About \(width) pt of menu bar"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc("메뉴 막대 미리보기", "Menu bar preview"))
        .accessibilityValue(loc("폭 약 \(width)포인트", "About \(width) points wide"))
    }
}

private struct LicenseView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MIT License").font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(AppInfo.license()).font(.system(size: 11)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(loc("닫기", "Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380, height: 360)
    }
}
