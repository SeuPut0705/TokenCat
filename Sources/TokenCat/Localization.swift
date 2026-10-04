import Foundation

/// The display language, fixed for the process at launch. Korean and English texts sit side by side at each call site
/// (`loc`), so there is no shared string table.
enum AppLanguage: String, CaseIterable {
    case ko, en

    /// Resolved once at launch; changed afterwards only by checks (`with`). Read from any thread.
    static var current = resolve()

    /// `--language ko|en` (self-test, snapshots, docs) → the bundle's pick between its ko/en localizations, which follows
    /// System Settings › 일반 › 언어 및 지역 › 응용 프로그램 and AppleLanguages → the first Korean or English system
    /// language (an unbundled binary) → English.
    static func resolve(arguments: [String] = CommandLine.arguments,
                        bundle: [String]? = Set(Bundle.main.localizations).isSuperset(of: ["ko", "en"]) ? Bundle.main.preferredLocalizations : nil,
                        system: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let flag = flagValue(arguments).flatMap(AppLanguage.init(rawValue:)) { return flag }
        return (bundle ?? system).lazy.compactMap(AppLanguage.init(code:)).first ?? .en
    }

    /// The value after `--language`, "" when it is missing, nil without the flag.
    static func flagValue(_ arguments: [String]) -> String? {
        arguments.firstIndex(of: "--language").map { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : "" }
    }

    /// "ko", "ko-KR", "en_GB" → the language; "kok" or "ja" → nil.
    init?(code: String) {
        self.init(rawValue: code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? "")
    }

    /// For date and number styles: the app's language with this Mac's region.
    var locale: Locale { Locale(identifier: rawValue + (Locale.current.region.map { "_" + $0.identifier } ?? "")) }

    /// Runs `body` in `language`, then restores the previous one. Checks only.
    static func with<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
        let saved = current
        current = language
        defer { current = saved }
        return try body()
    }
}

/// The text for the current language: `loc("세션 상세", "Session details")`. A plain `String`, so `Text(loc(…))`, AppKit
/// titles, accessibility labels and notifications show it verbatim.
func loc(_ korean: String, _ english: String) -> String { AppLanguage.current == .en ? english : korean }

/// English count noun: "1 session", "2 sessions"; pass `plural` for irregular nouns.
func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count) " + (count == 1 ? singular : plural ?? singular + "s")
}

extension Format {
    enum TimeUnit { case second, minute, hour, day }

    /// "5분" / "5m". Two spans join with a space in both languages: "2시간 13분" / "2h 13m". `spoken` (VoiceOver) keeps
    /// Korean and spells English out: "5 minutes".
    static func span(_ value: Int, _ unit: TimeUnit, spoken: Bool = false) -> String {
        // The case names are the English nouns.
        if spoken, AppLanguage.current == .en { return plural(value, String(describing: unit)) }
        switch unit {
        case .second: return loc("\(value)초", "\(value)s")
        case .minute: return loc("\(value)분", "\(value)m")
        case .hour: return loc("\(value)시간", "\(value)h")
        case .day: return loc("\(value)일", "\(value)d")
        }
    }

    /// "5분 전" / "5m ago".
    static func ago(_ span: String) -> String { loc("\(span) 전", "\(span) ago") }
    /// "5분 후" / "in 5m".
    static func later(_ span: String) -> String { loc("\(span) 후", "in \(span)") }
}
