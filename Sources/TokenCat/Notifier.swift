import Foundation
import UserNotifications

/// Metadata of one top-level group for notifications. Never carries prompt, question or tool input text.
struct AttentionSignal: Equatable {
    var id: String
    var source: TokenSource
    var project: String?
    var model: String?
    var live: Bool
    var input: Bool
    /// `.complete` or `.interrupted` once the group stopped being live.
    var ended: TokenActivityState?
    var outputTokens: Int?
    var durationSeconds: Double?
    /// The lead's newest record: with `id`, the key that keeps a turn end from replaying the cat's `content`.
    var endedAt: Date? = nil

    static func make(_ groups: [SessionGroup]) -> [AttentionSignal] {
        groups.compactMap { group in
            guard group.state != .measurement else { return nil }
            let lead = group.lead.reading
            let input = group.members.contains { $0.reading.activityState == .input }
            // A subagent waiting for a log (stale) neither holds back the lead's completion nor,
            // when it later times out, produces a late one.
            let live = group.members.contains { $0.state.isRunning } || input
            let ended = !live && !lead.active && (lead.activityState == .complete || lead.activityState == .interrupted)
                ? lead.activityState : nil
            return AttentionSignal(id: group.id, source: lead.source, project: lead.project, model: lead.model, live: live,
                                   input: input, ended: ended, outputTokens: lead.lastOutputTokens,
                                   durationSeconds: lead.lastTurnDurationSeconds, endedAt: lead.lastActivity)
        }
    }
}

enum AttentionEvent: Equatable {
    case finished(AttentionSignal)
    case input(AttentionSignal)

    var signal: AttentionSignal {
        switch self { case .finished(let signal), .input(let signal): return signal }
    }
    /// The state first (P-5): "입력 필요 · TokenCat", "턴 완료 · TokenCat", "턴 중단 · 프로젝트 미확인".
    var title: String {
        let what: String
        switch self {
        case .input: what = "입력 필요"
        case .finished(let signal): what = signal.ended == .interrupted ? "턴 중단" : "턴 완료"
        }
        return what + " · " + (signal.project.flatMap { $0.isEmpty ? nil : $0 } ?? "프로젝트 미확인")
    }
    /// "Claude Code · claude-opus-5-5".
    var subtitle: String { [signal.source.title, signal.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
    /// Completion "12,480 tok · 4분 12초" (never divided), input "답변하면 계속됩니다", interruption nothing.
    var body: String {
        switch self {
        case .input: return "답변하면 계속됩니다"
        case .finished(let signal):
            guard signal.ended == .complete else { return "" }
            return [signal.outputTokens.flatMap { $0 > 0 ? "\(Format.tokens($0)) tok" : nil }, signal.durationSeconds.flatMap(Self.duration)]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
    /// One delivered notification per group and kind: a newer one replaces it, and leaving input removes it.
    var identifier: String {
        switch self {
        case .input(let signal): return Self.inputIdentifier(signal.id)
        case .finished(let signal): return "done-" + signal.id
        }
    }
    static func inputIdentifier(_ group: String) -> String { "input-" + group }

    /// Raw duration reported by the client; never combined with token counts.
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let total = Int(seconds.rounded())
        if total >= 3_600 { return "\(total / 3_600)시간 \(total / 60 % 60)분" }
        return total >= 60 ? "\(total / 60)분 \(total % 60)초" : "\(total)초"
    }
}

/// Top-level transitions only: live → complete/interrupted, and → waiting for input.
/// The first update only records the baseline so launching never replays old states.
struct AttentionTracker {
    private var previous: [String: AttentionSignal] = [:]
    private var primed = false

    mutating func update(_ signals: [AttentionSignal]) -> [AttentionEvent] {
        defer {
            previous = Dictionary(signals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            primed = true
        }
        guard primed else { return [] }
        return signals.compactMap { signal in
            let before = previous[signal.id]
            if signal.input && before?.input != true { return .input(signal) }
            guard signal.ended != nil, let before, before.live else { return nil }
            // Output and duration describe the last completion; they belong to this turn only
            // when a completed turn just recorded new values.
            var finished = signal
            if signal.ended != .complete
                || (before.outputTokens == signal.outputTokens && before.durationSeconds == signal.durationSeconds) {
                finished.outputTokens = nil
                finished.durationSeconds = nil
            }
            return .finished(finished)
        }
    }
}

/// Opt-in local notifications. Permission is requested only when a toggle is turned on; sound only with its own toggle.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// A click: the group (`SessionGroup.id`) to select, nil when the notification carries none.
    var onOpen: ((String?) -> Void)?
    private var center: UNUserNotificationCenter { .current() }

    func activate() { center.delegate = self }

    func authorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        settings { status, _ in completion(status) }
    }

    /// Permission and the sound setting as macOS reports them now.
    func settings(_ completion: @escaping (UNAuthorizationStatus, UNNotificationSetting) -> Void) {
        center.getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus, settings.soundSetting) }
        }
    }

    /// `sound` adds `.sound` (the "입력 필요 알림에 소리" toggle); otherwise alerts only.
    func requestAuthorization(sound: Bool = false, _ completion: @escaping (UNAuthorizationStatus, String?) -> Void) {
        center.requestAuthorization(options: sound ? [.alert, .sound] : [.alert]) { [weak self] _, error in
            self?.authorizationStatus { completion($0, error?.localizedDescription) }
        }
    }

    /// Reuses the event's identifier, so a newer notification for the same group replaces the delivered one.
    func post(_ event: AttentionEvent, sound: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.subtitle = event.subtitle
        content.body = event.body
        content.threadIdentifier = event.signal.id
        content.userInfo = ["group": event.signal.id]
        if sound, case .input = event { content.sound = .default }
        center.add(UNNotificationRequest(identifier: event.identifier, content: content, trigger: nil)) { error in
            if let error { NSLog("TokenCat 알림 요청 실패: %@", error.localizedDescription) }
        }
    }

    static let updateIdentifier = "update"

    /// "새 버전 알림": no sound, one identifier for every version, so a newer version replaces the delivered one; a click
    /// opens the dashboard, where the notice offers the install.
    func postUpdate(_ release: UpdateRelease) {
        let content = UNMutableNotificationContent()
        content.title = "새 버전 \(release.version)"
        content.body = "TokenCat 상세 화면이나 설정에서 업데이트할 수 있습니다"
        content.threadIdentifier = Self.updateIdentifier
        center.add(UNNotificationRequest(identifier: Self.updateIdentifier, content: content, trigger: nil)) { error in
            if let error { NSLog("TokenCat 알림 요청 실패: %@", error.localizedDescription) }
        }
    }

    /// The "새 버전" notification no longer applies (nothing newer, installing, or just updated): it goes away.
    func removeUpdate() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.updateIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.updateIdentifier])
    }

    /// The group no longer waits for input: its "입력 필요" notification goes away.
    func removeInput(_ group: String) {
        let identifier = AttentionEvent.inputIdentifier(group)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// At launch: "입력 필요" notifications an earlier run delivered for groups no longer waiting go away.
    /// True when the sound toggle is on but macOS will not play it: the settings button is shown (P-5).
    static func soundBlocked(_ status: UNAuthorizationStatus?, _ sound: UNNotificationSetting?) -> Bool {
        status != nil && status != .notDetermined && (status == .denied || sound == .disabled || sound == .notSupported)
    }

    func removeStaleInput(keeping: Set<String>) {
        center.getDeliveredNotifications { [weak self] delivered in
            let stale = delivered.map(\.request.identifier).filter { $0.hasPrefix(AttentionEvent.inputIdentifier("")) && !keeping.contains($0) }
            if !stale.isEmpty { self?.center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let group = response.notification.request.content.userInfo["group"] as? String
        DispatchQueue.main.async { self.onOpen?(group) }
        completionHandler()
    }

    static func describe(_ status: UNAuthorizationStatus?) -> String {
        switch status {
        case .authorized, .provisional: return "알림 권한 허용됨"
        case .denied: return "시스템 설정에서 TokenCat 알림이 꺼져 있어 보낼 수 없습니다"
        case .notDetermined: return "켜면 macOS가 알림 권한을 한 번 묻습니다"
        case nil: return "알림 권한 확인 중"
        default: return "알림 권한 상태를 확인할 수 없습니다"
        }
    }

    /// The sound toggle's caption, from the setting macOS reports (P-5). An earlier alert-only grant is not asked again,
    /// so the sound can stay `.disabled` / `.notSupported` until the user changes it in System Settings.
    static func describeSound(_ status: UNAuthorizationStatus?, _ sound: UNNotificationSetting?, on: Bool) -> String {
        guard on else { return "꺼짐 · 입력 필요 알림을 소리 없이 보냅니다" }
        switch (status, sound) {
        case (.denied?, _): return "알림이 꺼져 있어 소리도 나지 않습니다"
        case (_, .enabled?): return "켜짐 · 입력 필요 알림에 기본 소리를 냅니다"
        case (.notDetermined?, _): return "알림 권한을 허용하면 소리가 납니다"
        case (_, .disabled?): return "시스템 설정에서 TokenCat 알림 소리가 꺼져 있습니다"
        case (_, .notSupported?): return "macOS가 TokenCat 알림 소리를 허용하지 않았습니다 · 시스템 설정 › 알림에서 확인하세요"
        default: return "알림 소리 설정을 확인하는 중"
        }
    }
}
