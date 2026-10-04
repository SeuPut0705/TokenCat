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
    static let privacy = "로컬 로그와 로컬 실측의 메타데이터만 읽습니다. 프롬프트·응답 본문은 저장하거나 표시하지 않으며, 모델을 호출하거나 계정에 로그인하지 않습니다."
    static let copyright = "Copyright © 2026 TokenCat contributors · MIT License"
    static func license() -> String {
        Bundle.main.url(forResource: "LICENSE", withExtension: nil).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "앱 번들에서 LICENSE 파일을 찾지 못했습니다."
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

/// A Settings section another surface can open directly (the popover's 실측 notice).
enum SettingsFocus: String { case telemetry }

/// Live system state shown in Settings: read back on open, never changed without a user action.
final class SettingsState: ObservableObject {
    /// Consumed (set back to nil) once Settings has scrolled to it.
    @Published var focus: SettingsFocus?
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var loginError: String?
    @Published private(set) var notificationStatus: UNAuthorizationStatus?
    @Published private(set) var notificationError: String?
    @Published private(set) var reduceMotion = false
    private let notifier: Notifier

    init(notifier: Notifier) {
        self.notifier = notifier
        refresh()
    }

    func refresh() {
        loginStatus = LoginItem.status
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        notifier.authorizationStatus { [weak self] in self?.notificationStatus = $0 }
    }

    func setLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            loginError = nil
        } catch {
            loginError = "로그인 항목을 바꾸지 못했습니다: \(error.localizedDescription)"
        }
        loginStatus = LoginItem.status
    }

    /// Asks macOS only when a notification toggle is switched on and permission was never decided.
    func notificationToggleEnabled() {
        notifier.authorizationStatus { [weak self] status in
            guard let self else { return }
            self.notificationStatus = status
            guard status == .notDetermined else { return }
            self.notifier.requestAuthorization { status, error in
                self.notificationStatus = status
                self.notificationError = error.map { "알림 권한 요청 실패: \($0)" }
            }
        }
    }
}

struct SettingsView: View {
    static let width: CGFloat = 420
    @ObservedObject var preferences: Preferences
    let model: DashboardModel
    @ObservedObject var state: SettingsState
    var showAbout: () -> Void = {}
    @State private var showsLicense = false

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onAppear { state.refresh(); reveal(proxy) }
                .onChange(of: state.focus) { _ in reveal(proxy) }
        }
        .frame(width: Self.width)
        .sheet(isPresented: $showsLicense) { LicenseView() }
    }

    /// After the current layout pass, so the target section exists; no animation, so Reduce Motion needs no case.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let focus = state.focus else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(focus, anchor: .top)
            state.focus = nil
        }
    }

    private var form: some View {
        Form {
            Section {
                MenuBarPreview(model: model, preferences: preferences)
                Picker("표시 방식", selection: $preferences.statusBarLayout) {
                    ForEach(StatusBarLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help(preferences.statusBarLayout.summary)
                MetricRows(preferences: preferences)
            } header: {
                Text("메뉴 막대")
            } footer: {
                footer(preferences.statusBarLayout == .minimal
                     ? "최소 표시는 고양이와 AI 상태·세션 수만 보여 줍니다. 항목 목록은 두 줄·한 줄 표시에 적용됩니다."
                     : "끌어서 순서를 바꿉니다. 고양이를 숨기면 마지막 항목은 숨길 수 없습니다.")
            }

            Section {
                Toggle("메뉴 막대에 고양이 표시", isOn: Binding(get: { preferences.showRunner }, set: { preferences.setShowRunner($0) }))
                    .disabled(preferences.showRunner && !preferences.canHideRunner)
                    .help(preferences.canHideRunner ? "" : "표시할 항목이 없어 고양이를 숨길 수 없습니다")
                Picker("움직임 기준", selection: $preferences.animationSource) {
                    ForEach(RunnerMotion.allCases) { Text($0.title).tag($0) }
                }
                caption(preferences.animationSource.caption)
                if state.reduceMotion { caption("macOS의 '동작 줄이기'가 켜져 있어 고양이는 자세만 바뀝니다.") }
            } header: {
                Text("고양이")
            }

            Section {
                Toggle("로그인 시 TokenCat 열기", isOn: Binding(get: { LoginItem.isOn(state.loginStatus) }, set: { state.setLogin($0) }))
                    .help("켜면 macOS 로그인 항목에 등록하고, 끄면 해제합니다. 켜기 전에는 등록하지 않습니다.")
                caption(LoginItem.describe(state.loginStatus))
                if state.loginStatus == .requiresApproval {
                    Button("로그인 항목 설정 열기") { LoginItem.openSystemSettings() }
                }
                if !LoginItem.isInApplications {
                    caption("앱을 /Applications로 옮긴 뒤 켜는 것을 권장합니다. 다른 위치의 앱을 다시 빌드하거나 옮기면 등록이 풀릴 수 있습니다.")
                }
                if let error = state.loginError { caption(error, color: .red) }
            } header: {
                Text("일반")
            }

            Section {
                Toggle("턴 완료", isOn: notificationBinding(\.notifyTurnComplete))
                    .help("최상위 세션의 턴이 끝나거나 중단되면 알립니다")
                Toggle("입력 필요", isOn: notificationBinding(\.notifyInput))
                    .help("Claude Code의 질문·계획 승인이나 Codex Plan 모드 질문을 기다리면 알립니다. 권한 확인 창은 로그에 남지 않아 알 수 없습니다")
                caption(Notifier.describe(state.notificationStatus),
                        color: state.notificationStatus == .denied && (preferences.notifyTurnComplete || preferences.notifyInput) ? .orange : .secondary)
                if state.notificationStatus == .denied {
                    Button("알림 설정 열기") {
                        let id = Bundle.main.bundleIdentifier ?? "dev.seuput.TokenCat"
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                if let error = state.notificationError { caption(error, color: .red) }
            } header: {
                Text("알림")
            } footer: {
                footer("기본값은 꺼짐입니다. 팝오버나 패널이 보이는 동안에는 보내지 않습니다. 본문에는 프로젝트·모델·토큰 수·소요 시간만 넣고 질문이나 응답 내용은 넣지 않습니다.")
            }

            Section {
                TelemetryRows(model: model)
            } header: {
                Text("실측")
            } footer: {
                footer("실측은 클라이언트가 보낸 출력 토큰·요청 시간 같은 수치만 받습니다. 연결 설정은 앱이 시작할 때 확인하며, 이미 실행 중인 클라이언트는 새로 실행해야 적용됩니다.")
            }
            .id(SettingsFocus.telemetry)

            Section {
                LabeledContent("버전") { Text(AppInfo.title).monospacedDigit().textSelection(.enabled) }
                caption(AppInfo.privacy)
                HStack {
                    Button("MIT 라이선스 보기") { showsLicense = true }
                    Button("TokenCat 정보") { showAbout() }
                }
            } header: {
                Text("정보")
            }

            Section {
                HStack {
                    Button("기본값으로 되돌리기") { preferences.reset() }
                    Spacer()
                }
            } footer: {
                footer("메뉴 막대·고양이·알림 선택만 기본값으로 되돌립니다. 로그인 항목과 macOS 알림 권한은 바꾸지 않습니다.")
            }
        }
        .formStyle(.grouped)
    }

    /// Grouped forms align footers trailing at body size on macOS; keep them as leading captions.
    private func footer(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func notificationBinding(_ key: ReferenceWritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { preferences[keyPath: key] }, set: { on in
            preferences[keyPath: key] = on
            if on { state.notificationToggleEnabled() }
        })
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
                        Text(id.title)
                        if missingBattery {
                            Text("이 Mac에는 배터리가 없습니다").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(missingBattery || locked)
                .accessibilityAction(named: "위로 이동") { preferences.move(id, by: -1) }
                .accessibilityAction(named: "아래로 이동") { preferences.move(id, by: 1) }
                Spacer(minLength: 0)
            }
            .help(locked ? "고양이를 숨긴 상태에서는 최소 한 항목을 표시해야 합니다" : "끌어서 순서를 바꿉니다")
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
                Button("위로 이동") { preferences.move(id, by: -1) }.disabled(preferences.order.first == id)
                Button("아래로 이동") { preferences.move(id, by: 1) }.disabled(preferences.order.last == id)
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

/// Still light and dark renders of the real status item content, from the same native renderer.
private struct MenuBarPreview: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        let preview = MenuBarStrip.preview(model: model, preferences: preferences)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(preview.images.indices, id: \.self) { index in
                let image = preview.images[index]
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, alignment: .leading)
            }
            Text("메뉴 막대 폭 약 \(Int(preview.width.rounded()))pt · 노치 Mac에서는 자리가 부족하면 가려질 수 있습니다")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("메뉴 막대 미리보기")
        .accessibilityValue("폭 약 \(Int(preview.width.rounded()))포인트")
    }
}

private struct TelemetryRows: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        LabeledContent("수집기") {
            Text(model.telemetryStatus).multilineTextAlignment(.trailing)
        }
        if let note = model.telemetrySetupNote {
            Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(TokenSource.allCases, id: \.self) { source in
            LabeledContent(source.title) {
                Text(model.telemetryClientStatus(source))
                    .foregroundStyle(model.telemetryRestartNeeded.contains(source) ? Color.orange : .secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
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
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380, height: 360)
    }
}
