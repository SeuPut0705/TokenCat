import AppKit
import CryptoKit
import Foundation

// MARK: - Versions and releases

/// A dotted version from a tag or Info.plist: "v0.9.1" and "0.9.1-beta" both read as 0.9.1; missing parts count as 0.
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var core = Substring(text.trimmingCharacters(in: .whitespaces))
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        core = core.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    private static func padded(_ a: AppVersion, _ b: AppVersion) -> ([Int], [Int]) {
        let count = max(a.parts.count, b.parts.count)
        return (a.parts + Array(repeating: 0, count: count - a.parts.count), b.parts + Array(repeating: 0, count: count - b.parts.count))
    }
    static func == (a: AppVersion, b: AppVersion) -> Bool {
        let (x, y) = padded(a, b)
        return x == y
    }
    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let (x, y) = padded(a, b)
        return x.lexicographicallyPrecedes(y)
    }
}

/// The latest GitHub release as TokenCat uses it; also the cached copy behind the ETag.
struct UpdateRelease: Codable, Equatable {
    static let assetName = "TokenCat.zip"
    static let bundleIdentifier = "dev.seuput.TokenCat"
    /// The tag without its "v": "0.9.1".
    var version: String
    var tag: String
    var page: URL
    /// The release's "TokenCat.zip", when it has one.
    var asset: Asset?

    struct Asset: Codable, Equatable {
        var url: URL
        var size: Int
        /// Lowercase hex from GitHub's "sha256:…" asset digest; nil when it reports none.
        var sha256: String?
    }

    /// Reads tag_name, html_url, draft, prerelease and the assets' name, URL, size and digest; nothing else.
    /// Returns nil for a draft or prerelease (never offered); throws `.invalidResponse` for anything unreadable.
    static func parse(_ data: Data) throws -> UpdateRelease? {
        struct Payload: Decodable {
            var tag_name: String
            var html_url: URL
            var draft: Bool?
            var prerelease: Bool?
            var assets: [AssetPayload]?
        }
        struct AssetPayload: Decodable {
            var name: String
            var browser_download_url: URL
            var size: Int
            var digest: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), AppVersion(payload.tag_name) != nil
        else { throw UpdateFailure.invalidResponse }
        if payload.draft == true || payload.prerelease == true { return nil }
        let version = payload.tag_name.first == "v" || payload.tag_name.first == "V" ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let asset = payload.assets?.first { $0.name == assetName }
            .map { Asset(url: $0.browser_download_url, size: $0.size, sha256: sha256(fromDigest: $0.digest)) }
        return UpdateRelease(version: version, tag: payload.tag_name, page: payload.html_url, asset: asset)
    }

    /// "sha256:<64 hex>" → lowercase hex; any other algorithm or length → nil.
    static func sha256(fromDigest digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst(7).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// The zip and its SHA-256, or why this release cannot be installed in place.
    func installable() throws -> (asset: Asset, sha256: String) {
        guard let asset else { throw UpdateFailure.noAsset }
        guard let sha256 = asset.sha256 else { throw UpdateFailure.noDigest }
        return (asset, sha256)
    }
}

/// Why a check or an install did not finish. `text` is the full sentence (Settings, help); `short` follows "업데이트 실패 · ".
enum UpdateFailure: Error, Equatable {
    case network, server(Int), rateLimited(until: Date), invalidResponse
    case notNewer, noAsset, noDigest, sizeMismatch, digestMismatch, extractFailed, invalidBundle(String)
    case notBundle, translocated, notWritable, replaceFailed, relaunchFailed

    var text: String {
        switch self {
        case .network: return "GitHub에 연결하지 못했습니다. 네트워크 연결을 확인하세요."
        case .server(let status): return "GitHub가 HTTP \(status)로 응답했습니다. 잠시 뒤 다시 시도하세요."
        case .rateLimited(let until): return "GitHub 요청 한도에 걸렸습니다. \(Self.clock(until)) 이후에 다시 확인할 수 있습니다."
        case .invalidResponse: return "GitHub 응답을 읽지 못했습니다."
        case .notNewer: return "설치할 새 버전이 없습니다."
        case .noAsset: return "릴리스에 \(UpdateRelease.assetName) 파일이 없습니다. 릴리스 페이지에서 직접 내려받으세요."
        case .noDigest: return "릴리스 파일의 SHA-256 값이 없어 설치하지 않았습니다. 릴리스 페이지에서 직접 내려받으세요."
        case .sizeMismatch, .digestMismatch: return "내려받은 파일이 릴리스 정보와 달라 설치하지 않았습니다. 기존 앱은 그대로입니다."
        case .extractFailed: return "내려받은 파일의 압축을 풀지 못했습니다. 기존 앱은 그대로입니다."
        case .invalidBundle(let reason): return "새 앱을 확인하지 못해 설치하지 않았습니다: \(reason)."
        case .notBundle: return "앱 번들(.app)로 실행하지 않아 업데이트할 수 없습니다."
        case .translocated: return "macOS가 TokenCat을 임시 위치에서 실행하고 있어 업데이트할 수 없습니다. Finder에서 TokenCat을 응용 프로그램 폴더로 옮긴 뒤 다시 여세요."
        case .notWritable: return "TokenCat이 있는 폴더에 쓸 권한이 없어 업데이트할 수 없습니다. 릴리스 페이지에서 직접 내려받으세요."
        case .replaceFailed: return "새 앱으로 바꾸지 못했습니다. 기존 앱은 그대로입니다."
        case .relaunchFailed: return "새 버전을 설치했지만 다시 열지 못했습니다. TokenCat을 종료한 뒤 다시 여세요."
        }
    }

    var short: String {
        switch self {
        case .network: return "네트워크 오류"
        case .server, .invalidResponse: return "GitHub 응답 오류"
        case .rateLimited: return "요청 한도"
        case .notNewer: return "새 버전 없음"
        case .noAsset: return "설치 파일 없음"
        case .noDigest: return "검증 정보 없음"
        case .sizeMismatch, .digestMismatch: return "파일 검증 실패"
        case .extractFailed: return "압축 해제 실패"
        case .invalidBundle: return "앱 검증 실패"
        case .notBundle: return "앱 번들 아님"
        case .translocated: return "임시 위치에서 실행 중"
        case .notWritable: return "쓰기 권한 없음"
        case .replaceFailed: return "교체 실패"
        case .relaunchFailed: return "다시 열기 실패"
        }
    }

    /// Trying again can help; the rest offer only the release page.
    var retryable: Bool {
        switch self {
        case .network, .server, .rateLimited, .invalidResponse, .sizeMismatch, .digestMismatch, .extractFailed, .replaceFailed: return true
        default: return false
        }
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Requests

/// One /releases/latest answer.
enum UpdateResponse: Equatable {
    case release(UpdateRelease, etag: String?)
    case notModified
    /// 404, or a draft or prerelease: nothing published to compare with.
    case none
    case rateLimited(until: Date)
    case failed(UpdateFailure)

    /// `header` looks a response header up case-insensitively. 403/429 pause on Retry-After (seconds) or on
    /// X-RateLimit-Remaining 0 until X-RateLimit-Reset; without either (or with a non-finite value) they back off like
    /// any other error. The reset is GitHub's clock, so it is measured from the response's own Date when there is one:
    /// a Mac clock that is off does not stretch the pause.
    static func interpret(status: Int, header: (String) -> String?, body: Data, now: Date) -> UpdateResponse {
        switch status {
        case 200:
            do {
                guard let release = try UpdateRelease.parse(body) else { return .none }
                return .release(release, etag: header("ETag"))
            } catch { return .failed(.invalidResponse) }
        case 304: return .notModified
        case 404: return .none
        case 403, 429:
            if let seconds = header("Retry-After").flatMap({ TimeInterval($0) }), seconds.isFinite, seconds >= 0 {
                return .rateLimited(until: now.addingTimeInterval(seconds))
            }
            if header("X-RateLimit-Remaining") == "0", let reset = header("X-RateLimit-Reset").flatMap({ TimeInterval($0) }), reset.isFinite {
                if let served = header("Date").flatMap(httpDate) {
                    return .rateLimited(until: now.addingTimeInterval(reset - served.timeIntervalSince1970))
                }
                return .rateLimited(until: Date(timeIntervalSince1970: reset))
            }
            return .failed(.server(status))
        default: return .failed(.server(status))
        }
    }

    /// An HTTP Date header ("Fri, 15 Jan 2027 08:00:00 GMT").
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

/// Unauthenticated GitHub allows 60 requests an hour per address, 304s included: a rate limit pauses every request until
/// it resets (at most an hour, which is the window GitHub counts in), and errors back off 1, 2, 4, 8 minutes before the
/// regular 15.
struct UpdateThrottle: Equatable {
    static let interval: TimeInterval = 15 * 60
    static let maximumPause: TimeInterval = 60 * 60
    /// Errors in a row since the last answer.
    private(set) var failures = 0
    /// Rate limited: no request at all before this.
    var pausedUntil: Date?

    static func backoff(_ failures: Int) -> TimeInterval {
        guard failures > 0 else { return interval }
        return min(interval, 60 * pow(2, Double(min(failures, 5) - 1)))
    }

    func allows(at now: Date) -> Bool { pausedUntil.map { now >= $0 } ?? true }

    /// What is left of the current error backoff; 0 without errors.
    func backoffRemaining(at now: Date, lastAttempt: Date?) -> TimeInterval {
        guard failures > 0, let lastAttempt else { return 0 }
        return max(0, Self.backoff(failures) - now.timeIntervalSince(lastAttempt))
    }

    /// Wake and dashboard-open checks also wait out the current backoff.
    func allowsAutomatic(at now: Date, lastAttempt: Date?) -> Bool {
        allows(at: now) && backoffRemaining(at: now, lastAttempt: lastAttempt) == 0
    }

    /// Records `response` and returns the delay before the next automatic check (a minute to an hour after a rate limit).
    mutating func record(_ response: UpdateResponse, now: Date) -> TimeInterval {
        switch response {
        case .release, .notModified, .none:
            failures = 0
            pausedUntil = nil
            return Self.interval
        case .rateLimited(let until):
            let resume = min(max(until, now.addingTimeInterval(60)), now.addingTimeInterval(Self.maximumPause))
            pausedUntil = resume
            return resume.timeIntervalSince(now)
        case .failed:
            failures += 1
            return Self.backoff(failures)
        }
    }
}

/// GET /repos/SeuPut0705/TokenCat/releases/latest and nothing else: no cookies, cache, credentials or identifiers.
final class UpdateClient {
    static let latest = URL(string: "https://api.github.com/repos/SeuPut0705/TokenCat/releases/latest")!
    static let releases = URL(string: "https://github.com/SeuPut0705/TokenCat/releases/latest")!
    let version: String
    private let session = URLSession(configuration: UpdateClient.configuration())
    private var task: URLSessionDataTask?

    init(version: String) { self.version = version }
    deinit { session.invalidateAndCancel() }

    /// Ephemeral, 15 s timeout, no cookies, cache or stored credentials.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    static func userAgent(_ version: String) -> String { "TokenCat/\(version)" }

    /// The check and the download both send these. Without an explicit Accept-Language, macOS adds the person's
    /// preferred languages to every request; it still adds `Accept-Encoding: gzip, deflate` on its own.
    static func identify(_ request: inout URLRequest, version: String) {
        request.setValue(userAgent(version), forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
    }

    func request(etag: String?) -> URLRequest {
        var request = URLRequest(url: Self.latest)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        Self.identify(&request, version: version)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    /// One request at a time: a new fetch cancels the previous one. `done` runs on URLSession's queue, never for a
    /// cancelled request.
    func fetch(etag: String?, done: @escaping (UpdateResponse, HTTPURLResponse?) -> Void) {
        task?.cancel()
        let task = session.dataTask(with: request(etag: etag)) { data, response, error in
            if (error as? URLError)?.code == .cancelled { return }
            guard let http = response as? HTTPURLResponse else { done(.failed(.network), nil); return }
            done(.interpret(status: http.statusCode, header: { http.value(forHTTPHeaderField: $0) }, body: data ?? Data(), now: Date()), http)
        }
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// What the updater keeps between launches. Nothing here is ever sent.
struct UpdateStore {
    let defaults: UserDefaults

    var etag: String? {
        get { defaults.string(forKey: "updateETag") }
        nonmutating set { defaults.set(newValue, forKey: "updateETag") }
    }
    /// The release behind `etag`, so a 304 still knows the latest version.
    var release: UpdateRelease? {
        get { defaults.data(forKey: "updateRelease").flatMap { try? JSONDecoder().decode(UpdateRelease.self, from: $0) } }
        nonmutating set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "updateRelease") }
    }
    var checkedAt: Date? {
        get { defaults.object(forKey: "updateCheckedAt") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "updateCheckedAt") }
    }
    var pausedUntil: Date? {
        get { defaults.object(forKey: "updatePausedUntil") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "updatePausedUntil") }
    }
    /// The last version announced by `Updater.onDiscovered`; each version is announced once.
    var notifiedVersion: String? {
        get { defaults.string(forKey: "updateNotifiedVersion") }
        nonmutating set { defaults.set(newValue, forKey: "updateNotifiedVersion") }
    }
    /// Written right before the relaunch; the next launch says "…로 업데이트했습니다" once if it runs that version.
    var installedVersion: String? {
        get { defaults.string(forKey: "updateInstalledVersion") }
        nonmutating set { defaults.set(newValue, forKey: "updateInstalledVersion") }
    }

    /// If-None-Match goes out only while the release it stands for is cached.
    var etagToSend: String? { release == nil ? nil : etag }

    /// Updates the cache for `response` and returns the latest published release it stands for (a 304 reuses the
    /// cached copy, nil means nothing is published), or the failure for answers that say nothing about it.
    func resolve(_ response: UpdateResponse) -> Result<UpdateRelease?, UpdateFailure> {
        switch response {
        case .release(let latest, let tag):
            release = latest
            etag = tag
            return .success(latest)
        case .notModified:
            if let release { return .success(release) }
            etag = nil
            return .failure(.invalidResponse)
        case .none:
            release = nil
            etag = nil
            return .success(nil)
        case .rateLimited(let until): return .failure(.rateLimited(until: until))
        case .failed(let failure): return .failure(failure)
        }
    }
}

// MARK: - State and presentation

/// What the dashboard asks of the updater; the app shell carries it out.
enum UpdateCommand: Equatable { case check, install, openReleasePage, dismiss }

/// Published by `DashboardModel.update`.
struct UpdateState: Equatable {
    enum Check: Equatable { case idle, checking, done, failed(UpdateFailure) }
    enum Install: Equatable { case none, downloading(Double), installing, failed(UpdateFailure) }
    /// This copy cannot update itself at all (not an .app bundle); no request is ever made.
    var disabled: String?
    var check = Check.idle
    var install = Install.none
    var checkedAt: Date?
    /// The latest release, only while it is newer than this build.
    var available: UpdateRelease?
    /// The version this launch updated to; shown once, until the dashboard closes or ✕.
    var updatedTo: String?

    var installing: Bool {
        switch install {
        case .downloading, .installing: return true
        case .none, .failed: return false
        }
    }
    var installFailure: UpdateFailure? {
        if case .failed(let failure) = install { return failure }
        return nil
    }
    /// A failure that trying again cannot fix (the translocated copy, a folder without write access, a release without its
    /// file or digest, …): the install is not offered again until a newer release arrives.
    var blockedByFailure: Bool { installFailure.map { !$0.retryable } ?? false }
    var canInstall: Bool { disabled == nil && available != nil && !installing && !blockedByFailure }
    var canCheck: Bool { disabled == nil && check != .checking && !installing }
    /// The quick menu item: the install while it can run, the release page after a failure that blocks it.
    var quickMenuCommand: UpdateCommand? {
        guard disabled == nil, available != nil, !installing else { return nil }
        return blockedByFailure ? .openReleasePage : .install
    }
    var quickMenuTitle: String? {
        guard let version = available?.version, let command = quickMenuCommand else { return nil }
        return command == .install ? "업데이트 \(version) 설치…" : "업데이트 \(version) 릴리스 페이지…"
    }

    /// A check's newer release. One other than the failed install's clears that failure, so it can be installed.
    mutating func receive(available release: UpdateRelease?) {
        if installFailure != nil, let release, release.version != available?.version { install = .none }
        available = release
    }

    static func progress(_ fraction: Double) -> String { "업데이트 내려받는 중 \(Int((min(1, max(0, fraction)) * 100).rounded(.down)))%" }
    /// "0.9.1로 업데이트했습니다"; "으로" after 0, 3 and 6 (영, 삼, 육), which end in a consonant other than ㄹ.
    static func updated(_ version: String) -> String {
        let last = version.last(where: \.isNumber)
        return version + (last.map { "036".contains($0) } == true ? "으로" : "로") + " 업데이트했습니다"
    }

    /// The footer's trailing item, most important first: progress, failure, a new version (unless closed with ✕ for that
    /// version), then the one-time note after an update.
    func notice(dismissed: String?) -> UpdateNotice? {
        let version = available?.version ?? ""
        switch install {
        case .downloading(let fraction):
            return UpdateNotice(kind: .downloading, text: Self.progress(fraction), help: "TokenCat \(version) 내려받는 중 · 설치가 끝나면 다시 엽니다", version: version)
        case .installing:
            return UpdateNotice(kind: .installing, text: "설치 중…", help: "내려받은 앱을 확인하고 바꾸는 중 · 끝나면 TokenCat을 다시 엽니다", version: version)
        case .failed(let failure):
            return UpdateNotice(kind: .failed(retryable: failure.retryable), text: "업데이트 실패", detail: failure.short, help: failure.text, version: version)
        case .none:
            break
        }
        if let available, available.version != dismissed {
            return UpdateNotice(kind: .available, text: "새 버전 \(available.version)", help: "내려받아 설치한 뒤 TokenCat을 다시 엽니다", version: available.version)
        }
        if let updatedTo { return UpdateNotice(kind: .updated, text: Self.updated(updatedTo), help: "TokenCat \(updatedTo) 실행 중", version: updatedTo) }
        return nil
    }

    /// The Settings status line: a title ("최신 버전입니다 · 3분 전 확인", "새 버전 0.9.1") and an optional second line.
    /// An install failure gives its short reason here; Settings shows the full sentence under the row.
    func status(now: Date) -> (title: String, detail: String?, problem: Bool) {
        if let disabled { return (disabled, nil, false) }
        switch install {
        case .downloading(let fraction): return (Self.progress(fraction), nil, false)
        case .installing: return ("설치 중…", nil, false)
        case .failed(let failure): return ("업데이트 실패", failure.short, true)
        case .none: break
        }
        if let available { return ("새 버전 \(available.version)", checkedAt.map { Self.checked($0, now: now) }, false) }
        switch check {
        case .checking: return ("확인 중…", nil, false)
        case .failed(let failure): return ("확인하지 못했습니다", failure.text, true)
        case .idle, .done: break
        }
        guard let checkedAt else { return ("아직 확인하지 않았습니다", nil, false) }
        return ("최신 버전입니다 · " + Self.checked(checkedAt, now: now), nil, false)
    }

    /// Minute-granular so the line does not tick: "방금 확인", "3분 전 확인".
    static func checked(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "방금 확인" : Format.age(date, now: now) + " 확인"
    }
}

/// The dashboard footer's trailing update item.
struct UpdateNotice: Equatable {
    enum Kind: Equatable { case available, downloading, installing, failed(retryable: Bool), updated }
    var kind: Kind
    var text: String
    /// The failure's short reason, dropped first when the footer is narrow.
    var detail: String? = nil
    var help: String
    var version: String
}

// MARK: - Updater

/// Checks GitHub for a newer release and installs it only when asked. Main thread only; the app shell starts and stops it.
/// Automatic checks: 5 s after launch, every 15 min, 15 s after wake, and when the dashboard opens 5 min after the last one.
final class Updater {
    static let launchDelay: TimeInterval = 5
    static let wakeDelay: TimeInterval = 15
    static let openAfter: TimeInterval = 5 * 60

    var onChange: ((UpdateState) -> Void)?
    /// A newer release seen for the first time; once per version, for the optional notification.
    var onDiscovered: ((UpdateRelease) -> Void)?
    private(set) var state = UpdateState() { didSet { if state != oldValue { onChange?(state) } } }
    private let bundleURL: URL
    private let version: String
    private let current: AppVersion?
    private let client: UpdateClient
    private let store: UpdateStore
    private var throttle = UpdateThrottle()
    private var automatic = false
    private var running = false
    private var timer: Timer?
    private var lastAttempt: Date?
    /// Identifies the request in flight; answers for an older one are dropped.
    private var request = 0
    private var fetching = false
    private var installation: UpdateInstallation?
    /// A quit that arrived during "설치 중…"; answered once that step ends.
    private var quitReply: (() -> Void)?

    init(bundleURL: URL = Bundle.main.bundleURL, version: String = AppInfo.version, defaults: UserDefaults = .standard) {
        self.bundleURL = bundleURL
        self.version = version
        current = AppVersion(version)
        client = UpdateClient(version: version)
        store = UpdateStore(defaults: defaults)
    }

    func start(automatic: Bool) {
        guard !running else { return }
        running = true
        if bundleURL.pathExtension != "app" { state.disabled = "앱 번들(.app)로 실행할 때만 업데이트를 확인합니다" }
        else if current == nil { state.disabled = "버전 정보를 읽지 못해 업데이트를 확인하지 않습니다" }
        if state.disabled == nil {
            // A stored pause longer than any the throttle sets (written under a wrong clock) is dropped.
            if let paused = store.pausedUntil, paused.timeIntervalSinceNow > UpdateThrottle.maximumPause { store.pausedUntil = nil }
            throttle.pausedUntil = store.pausedUntil
            var next = state
            next.checkedAt = store.checkedAt
            next.available = newer(store.release)
            if let installed = store.installedVersion {
                store.installedVersion = nil
                if AppVersion(installed) == current { next.updatedTo = installed }
            }
            state = next
        }
        self.automatic = false
        setAutomatic(automatic)
    }

    /// Timers, the request and any download stop; nothing is published afterwards.
    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        cancelFetch()
        installation?.cancel()
        installation = nil
    }

    /// "새 버전 자동 확인". Turning it on checks within 5 s unless a check ran in the last 15 min.
    func setAutomatic(_ on: Bool) {
        guard on != automatic else { return }
        automatic = on
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let due = (lastAttempt ?? .distantPast).addingTimeInterval(UpdateThrottle.interval).timeIntervalSinceNow
        schedule(after: max(Self.launchDelay, due))
    }

    /// "지금 확인": skips the backoff wait, never a rate-limit pause.
    func checkNow() { check() }

    func dashboardOpened() {
        guard running, automatic, !fetching, Date().timeIntervalSince(lastAttempt ?? .distantPast) >= Self.openAfter,
              throttle.allowsAutomatic(at: Date(), lastAttempt: lastAttempt) else { return }
        check()
    }

    /// About 15 s after waking, or when the current error backoff ends if that is later.
    func systemDidWake() {
        guard running, automatic else { return }
        schedule(after: max(Self.wakeDelay, throttle.backoffRemaining(at: Date(), lastAttempt: lastAttempt)))
    }

    func clearFailure() {
        if case .failed = state.install { state.install = .none }
    }

    func clearUpdatedNote() { state.updatedTo = nil }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        timer = nil
        guard running, automatic, state.disabled == nil else { return }
        let wait = max(1, delay, throttle.pausedUntil?.timeIntervalSinceNow ?? 0)
        let next = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.check()
        }
        next.tolerance = min(60, wait * 0.1)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func check() {
        guard running, state.disabled == nil, !fetching else { return }
        // A download is under way: the regular check comes back later instead of competing with it.
        guard !state.installing else { schedule(after: UpdateThrottle.interval); return }
        state.check = .checking
        fetch { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let latest): self.apply(latest: latest)
            case .failure(let failure): self.state.check = .failed(failure)
            }
        }
    }

    /// Records a successful answer. Internal for the self-test.
    func apply(latest: UpdateRelease?) {
        var next = state
        next.check = .done
        next.checkedAt = store.checkedAt
        next.receive(available: newer(latest))
        state = next
        if let release = next.available, store.notifiedVersion != release.version {
            store.notifiedVersion = release.version
            onDiscovered?(release)
        }
    }

    private func newer(_ release: UpdateRelease?) -> UpdateRelease? {
        guard let release, let current, let latest = AppVersion(release.version), latest > current else { return nil }
        return release
    }

    private func fetch(_ done: @escaping (Result<UpdateRelease?, UpdateFailure>) -> Void) {
        let now = Date()
        if !throttle.allows(at: now), let until = throttle.pausedUntil { done(.failure(.rateLimited(until: until))); return }
        cancelFetch()
        request &+= 1
        let token = request
        fetching = true
        lastAttempt = now
        client.fetch(etag: store.etagToSend) { [weak self] response, _ in
            DispatchQueue.main.async {
                guard let self, self.running, self.request == token else { return }
                self.fetching = false
                let delay = self.throttle.record(response, now: Date())
                self.store.pausedUntil = self.throttle.pausedUntil
                let result = self.store.resolve(response)
                if case .success = result { self.store.checkedAt = Date() }
                done(result)
                self.schedule(after: delay)
            }
        }
    }

    private func cancelFetch() {
        guard fetching else { return }
        client.cancel()
        fetching = false
        request &+= 1
        if state.check == .checking { state.check = state.checkedAt == nil ? .idle : .done }
    }

    // MARK: Install

    /// Always user-initiated. Guards first, then a fresh look at the latest release, then download → verify → replace →
    /// relaunch. Every failure leaves the running app as it was.
    func install() {
        guard running, state.disabled == nil, !state.installing else { return }
        if let blocker = UpdateInstaller.blocker(for: bundleURL) { state.install = .failed(blocker); return }
        state.install = .downloading(0)
        fetch { [weak self] result in
            guard let self, case .downloading = self.state.install else { return }
            do {
                let latest = try result.get()
                self.apply(latest: latest)
                guard let release = self.newer(latest) else { throw UpdateFailure.notNewer }
                let (asset, sha256) = try release.installable()
                let installation = try UpdateInstallation(release: release, asset: asset, sha256: sha256, bundleURL: self.bundleURL,
                                                          version: self.version)
                installation.onProgress = { [weak self] in self?.state.install = .downloading($0) }
                installation.onInstalling = { [weak self] in self?.state.install = .installing }
                installation.onFinish = { [weak self] in self?.finished($0, release: release) }
                self.installation = installation
                installation.start()
            } catch {
                self.state.install = .failed(error as? UpdateFailure ?? .invalidResponse)
            }
        }
    }

    private func finished(_ result: Result<URL, UpdateFailure>, release: UpdateRelease) {
        installation = nil
        let quitting = quitReply
        quitReply = nil
        switch result {
        case .failure(let failure):
            state.install = .failed(failure)
        case .success(let app):
            // Kept even if the relaunch fails: the next start of this bundle runs the new version.
            store.installedVersion = release.version
            // Asked to quit meanwhile: it quits without reopening, and the next launch runs the new version.
            if quitting == nil {
                do { try UpdateInstaller.relaunch(app) } catch {
                    state.install = .failed(.relaunchFailed)
                    return
                }
                NSApp.terminate(nil)
            }
        }
        quitting?()
    }

    /// A quit during "설치 중…" (checking and swapping the downloaded app, a few seconds) waits for that step, so the
    /// bundle is never left mid-swap and the staging folder is removed; `reply` runs once it ends, or after 60 s.
    /// False when nothing needs waiting for.
    func deferQuit(_ reply: @escaping () -> Void) -> Bool {
        guard installation != nil, state.install == .installing else { return false }
        quitReply = reply
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, let reply = self.quitReply else { return }
            self.quitReply = nil
            reply()
        }
        return true
    }

    // MARK: Command line

    /// `--update-check`: one unconditional GET, printed. Never reads or writes the app's update state, never installs.
    static func commandLineCheck(bundleURL: URL = Bundle.main.bundleURL, version: String = AppInfo.version) -> Int32 {
        print("현재 버전: \(version)" + (bundleURL.pathExtension == "app" ? "" : " (앱 번들 아님 · 앱에서는 업데이트를 확인하지 않음)"))
        print("요청: GET \(UpdateClient.latest.absoluteString)")
        final class Box { var value: (UpdateResponse, HTTPURLResponse?)? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let client = UpdateClient(version: version)
        client.fetch(etag: nil) { response, http in
            box.value = (response, http)
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success, let (response, http) = box.value else {
            print("결과: 응답 없음 (시간 초과)")
            return 1
        }
        if let http {
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining") ?? "?"
            let limit = http.value(forHTTPHeaderField: "X-RateLimit-Limit") ?? "?"
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { TimeInterval($0) }
                .map { " · \(UpdateFailure.clock(Date(timeIntervalSince1970: $0))) 초기화" } ?? ""
            print("HTTP \(http.statusCode) · GitHub 요청 한도 \(remaining)/\(limit) 남음\(reset)")
        }
        switch response {
        case .release(let release, _):
            print("최신 릴리스: \(release.tag) · \(release.page.absoluteString)")
            if let asset = release.asset {
                print("자산: \(UpdateRelease.assetName) · \(asset.size) bytes · " + (asset.sha256.map { "sha256:\($0)" } ?? "SHA-256 digest 없음"))
            } else {
                print("자산: \(UpdateRelease.assetName) 없음")
            }
            switch (AppVersion(version), AppVersion(release.version)) {
            case let (current?, latest?) where latest > current:
                let installable: String
                do { _ = try release.installable(); installable = "설치 조건 충족" } catch { installable = (error as? UpdateFailure)?.text ?? "설치 불가" }
                print("결과: 업데이트 있음 (\(version) → \(release.version)) · \(installable)")
            case let (current?, latest?):
                print(latest == current ? "결과: 최신 버전입니다" : "결과: 실행 중인 버전이 릴리스보다 새롭습니다 (\(version) > \(release.version))")
            default:
                print("결과: 현재 버전을 읽지 못해 비교하지 않았습니다")
            }
            return 0
        case .none:
            print("최신 릴리스: 없음 (GitHub에 공개된 릴리스가 없습니다)")
            print("결과: 최신 버전입니다 (비교할 릴리스 없음)")
            return 0
        case .notModified:
            print("결과: 예상하지 못한 304 응답")
            return 1
        case .rateLimited(let until):
            print("결과: 확인 실패 · GitHub 요청 한도 · \(UpdateFailure.clock(until)) 이후 다시 시도")
            return 1
        case .failed(let failure):
            print("결과: 확인 실패 · \(failure.text)")
            return 1
        }
    }
}

// MARK: - Install

/// One download-and-replace attempt. Its staging folder sits on the app's volume. It is removed when the attempt ends,
/// when it is cancelled during the download, and after a quit that waited for the install step (`Updater.deferQuit`);
/// a staging folder that still outlives the process is in the system's temporary items, which macOS clears.
final class UpdateInstallation: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onInstalling: (() -> Void)?
    var onFinish: ((Result<URL, UpdateFailure>) -> Void)?
    private let release: UpdateRelease
    private let asset: UpdateRelease.Asset
    private let sha256: String
    private let bundleURL: URL
    private let version: String
    private let staging: URL
    private var session: URLSession?
    /// Delegate queue only.
    private var archive: URL?
    private var lastPercent = -1
    private let lock = NSLock()
    private var cancelledFlag = false
    /// The install step was handed to `queue`; from then on only that queue touches the staging folder.
    private var installStarted = false
    private static let queue = DispatchQueue(label: "dev.seuput.TokenCat.update", qos: .utility)

    init(release: UpdateRelease, asset: UpdateRelease.Asset, sha256: String, bundleURL: URL, version: String) throws {
        self.release = release
        self.asset = asset
        self.sha256 = sha256
        self.bundleURL = bundleURL
        self.version = version
        do {
            staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true)
        } catch { throw UpdateFailure.notWritable }
        super.init()
    }

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    func start() {
        let configuration = UpdateClient.configuration()
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: asset.url)
        UpdateClient.identify(&request, version: version)
        session.downloadTask(with: request).resume()
    }

    /// Quitting: the session ends and no callback runs. During the download the staging folder goes right away (the app
    /// may exit next); once the install step runs, that queue removes it, never racing the swap.
    func cancel() {
        lock.lock()
        cancelledFlag = true
        let installing = installStarted
        lock.unlock()
        onProgress = nil
        onInstalling = nil
        onFinish = nil
        session?.invalidateAndCancel()
        session = nil
        if installing { Self.queue.async { [staging] in try? FileManager.default.removeItem(at: staging) } }
        else { try? FileManager.default.removeItem(at: staging) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = asset.size > 0 ? Int64(asset.size) : totalBytesExpectedToWrite
        guard total > 0 else { return }
        let percent = Int(min(100, totalBytesWritten * 100 / total))
        guard percent != lastPercent else { return }
        lastPercent = percent
        DispatchQueue.main.async { [weak self] in self?.onProgress?(Double(percent) / 100) }
    }

    /// The file is deleted once this returns, so it moves into the staging folder now.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let target = staging.appendingPathComponent(UpdateRelease.assetName)
        if (try? FileManager.default.moveItem(at: location, to: target)) != nil { archive = target }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if (error as? URLError)?.code == .cancelled || cancelled { return }
        guard error == nil, let archive else {
            Self.queue.async { self.complete(.failure(.network)) }
            return
        }
        lock.lock()
        let start = !cancelledFlag
        installStarted = start
        lock.unlock()
        guard start else { return }
        DispatchQueue.main.async { [weak self] in self?.onInstalling?() }
        Self.queue.async { self.install(archive) }
    }

    private func install(_ archive: URL) {
        do {
            try UpdateInstaller.verify(archive, size: asset.size, sha256: sha256)
            let app = try UpdateInstaller.extract(archive, into: staging.appendingPathComponent("extracted", isDirectory: true))
            try UpdateInstaller.validate(app, version: release.version)
            guard !cancelled else { complete(.failure(.replaceFailed)); return }
            complete(.success(try UpdateInstaller.replace(bundleURL, with: app, version: release.version)))
        } catch {
            complete(.failure(error as? UpdateFailure ?? .replaceFailed))
        }
    }

    /// Update queue: the staging folder goes first, whatever happened.
    private func complete(_ result: Result<URL, UpdateFailure>) {
        try? FileManager.default.removeItem(at: staging)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.onFinish?(result)
        }
    }
}

/// The install steps, each usable on its own (the self-test runs them on a copy of this bundle).
enum UpdateInstaller {
    #if arch(arm64)
    static let runningArchitecture = NSBundleExecutableArchitectureARM64
    #else
    static let runningArchitecture = NSBundleExecutableArchitectureX86_64
    #endif

    /// Why this copy cannot replace itself in place; checked before anything is downloaded.
    static func blocker(for bundleURL: URL, isWritable: (String) -> Bool = FileManager.default.isWritableFile(atPath:)) -> UpdateFailure? {
        guard bundleURL.pathExtension == "app" else { return .notBundle }
        if bundleURL.path.contains("/AppTranslocation/") { return .translocated }
        guard isWritable(bundleURL.path), isWritable(bundleURL.deletingLastPathComponent().path) else { return .notWritable }
        return nil
    }

    /// Size first, then SHA-256.
    static func verify(_ file: URL, size: Int, sha256: String) throws {
        let actual = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
        guard actual?.intValue == size else { throw UpdateFailure.sizeMismatch }
        guard (try? digest(of: file)) == sha256 else { throw UpdateFailure.digestMismatch }
    }

    /// Lowercase hex SHA-256, read 1 MB at a time.
    static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `ditto -x -k` into `folder`; exactly one TokenCat.app may come out (hidden files and __MACOSX aside).
    static func extract(_ archive: URL, into folder: URL) throws -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path]) == 0 else { throw UpdateFailure.extractFailed }
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        guard items == ["TokenCat.app"] else { throw UpdateFailure.invalidBundle("압축 파일에 TokenCat.app 하나만 있어야 합니다") }
        return folder.appendingPathComponent("TokenCat.app", isDirectory: true)
    }

    /// The release's identity and version, an executable for this Mac's CPU and macOS, and a signature that verifies.
    static func validate(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary else { throw UpdateFailure.invalidBundle("앱 정보를 읽지 못했습니다") }
        guard info["CFBundleIdentifier"] as? String == UpdateRelease.bundleIdentifier else { throw UpdateFailure.invalidBundle("번들 ID가 다릅니다") }
        guard let shipped = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), shipped == AppVersion(version)
        else { throw UpdateFailure.invalidBundle("앱 버전이 릴리스와 다릅니다") }
        guard bundle.executableArchitectures?.contains(where: { $0.intValue == runningArchitecture }) == true
        else { throw UpdateFailure.invalidBundle("이 Mac의 CPU용 실행 파일이 없습니다") }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            guard let parts = AppVersion(minimum)?.parts, ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
                majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0))
            else { throw UpdateFailure.invalidBundle("macOS \(minimum) 이상이 필요합니다") }
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0
        else { throw UpdateFailure.invalidBundle("코드 서명을 확인하지 못했습니다") }
    }

    /// Swaps the new bundle into place in one step; the running process keeps its already-open files. The swap can finish
    /// and only the removal of the old copy fail (something inside it cannot be deleted): the new bundle `version` is
    /// then in place, so that counts as installed and the old copy is left to the staging folder's cleanup.
    static func replace(_ bundleURL: URL, with app: URL, version: String) throws -> URL {
        do { return try FileManager.default.replaceItemAt(bundleURL, withItemAt: app) ?? bundleURL } catch {
            let leftBehind = (error as NSError).userInfo["NSFileBackupItemLeftBehindLocationKey"] as? URL
            let installed = (NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String)
                .flatMap(AppVersion.init)
            guard let leftBehind, let installed, installed == AppVersion(version) else { throw UpdateFailure.replaceFailed }
            try? FileManager.default.removeItem(at: leftBehind)
            return bundleURL
        }
    }

    /// A detached shell waits for `pid` to exit, then opens the new bundle. It runs in its own session with no inherited
    /// descriptors, so the app's exit does not end it and it never holds the collector's port. After 60 s it gives up
    /// without opening anything.
    static func relaunch(_ app: URL, pid: pid_t = getpid()) throws {
        let script = "i=0; while kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); [ $i -ge 600 ] && exit 1; sleep 0.1; done; sleep 0.5; exec /usr/bin/open -n \"$2\""
        try spawnDetached("/bin/sh", ["-c", script, "sh", String(pid), app.path])
    }

    private static func spawnDetached(_ tool: String, _ arguments: [String]) throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        posix_spawn_file_actions_addopen(&files, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&files, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&files, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let argv = ([tool] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, tool, &files, &attributes, argv, environ) == 0 else { throw UpdateFailure.relaunchFailed }
    }

    /// Runs a system tool silently and returns its exit status (-1 when it could not start).
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
