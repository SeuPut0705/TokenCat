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
                                   durationSeconds: lead.lastTurnDurationSeconds)
        }
    }
}

enum AttentionEvent: Equatable {
    case finished(AttentionSignal)
    case input(AttentionSignal)

    var signal: AttentionSignal {
        switch self { case .finished(let signal), .input(let signal): return signal }
    }
    var title: String { signal.source.title }
    /// e.g. "TokenCat · claude-opus-5-5 턴 완료 · 12,480 tok · 4분 12초".
    var body: String {
        let signal = self.signal
        let what: String
        switch self {
        case .input: what = "입력 필요"
        case .finished(let signal): what = signal.ended == .interrupted ? "턴 중단" : "턴 완료"
        }
        let headline = [signal.model, what].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        var parts: [String?] = [signal.project, headline]
        if case .finished = self, signal.ended == .complete {
            parts.append(signal.outputTokens.flatMap { $0 > 0 ? "\(Format.tokens($0)) tok" : nil })
            parts.append(signal.durationSeconds.flatMap(Self.duration))
        }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

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

/// Opt-in local notifications. Permission is requested only when a toggle is turned on.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?
    private var center: UNUserNotificationCenter { .current() }

    func activate() { center.delegate = self }

    func authorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    func requestAuthorization(_ completion: @escaping (UNAuthorizationStatus, String?) -> Void) {
        center.requestAuthorization(options: [.alert]) { [weak self] _, error in
            self?.authorizationStatus { completion($0, error?.localizedDescription) }
        }
    }

    func post(_ event: AttentionEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.threadIdentifier = event.signal.id
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { NSLog("TokenCat 알림 요청 실패: %@", error.localizedDescription) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.onOpen?() }
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
}
