import Foundation

func runLocalizationChecks() -> [String] {
    var failures: [String] = []
    var checks = 0
    func check(_ valid: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !valid() { failures.append("Localization: " + description) }
    }
    func resolve(_ arguments: [String], _ bundle: [String]?, _ system: [String]) -> AppLanguage {
        AppLanguage.resolve(arguments: arguments, bundle: bundle, system: system)
    }
    // Resolution: flag → bundle's ko/en pick → first Korean or English system language → English.
    check(resolve(["TokenCat", "--language", "en"], ["ko"], ["ko-KR"]) == .en
          && resolve(["TokenCat", "--language", "ko"], ["en"], ["en-US"]) == .ko, "--language does not win")
    check(resolve(["TokenCat"], ["ko"], ["en-US"]) == .ko && resolve(["TokenCat"], ["en"], ["ko-KR"]) == .en,
          "the bundle's pick (per-app language) does not win over the system list")
    check(resolve(["TokenCat"], nil, ["ja-JP", "ko-KR", "en-US"]) == .ko && resolve(["TokenCat"], nil, ["en-GB", "ko-KR"]) == .en
          && resolve(["TokenCat"], nil, ["ja-JP"]) == .en && resolve(["TokenCat"], nil, ["kok-IN"]) == .en
          && resolve(["TokenCat"], nil, []) == .en, "without bundle localizations the system list or English is not used")
    check(resolve(["TokenCat", "--language", "fr"], ["ko"], []) == .ko && AppLanguage.flagValue(["--language", "fr"]) == "fr"
          && AppLanguage.flagValue(["--language"]) == "" && AppLanguage.flagValue(["--self-test"]) == nil,
          "an unknown --language value is not reported or falls through wrongly")
    check(Set(Bundle.main.localizations).isSuperset(of: ["ko", "en"]),
          "the app bundle does not declare ko and en localizations (\(Bundle.main.localizations))")

    // Call-site API.
    check(loc("세션", "Session") == "세션" && AppLanguage.with(.en) { loc("세션", "Session") } == "Session"
          && AppLanguage.current == .ko, "loc does not follow the language or `with` does not restore it")
    check(plural(1, "session") == "1 session" && plural(2, "session") == "2 sessions" && plural(0, "session") == "0 sessions"
          && plural(3, "child", "children") == "3 children", "English plural")

    // Formatting helpers in both languages.
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }
    check(Format.age(at(-3), now: now) == "3초 전" && SessionPresentation.countdown(to: at(7_980), now: now) == "2시간 13분"
          && SessionPresentation.helpAge(at(-45), now: now) == "1분 이내" && SessionPresentation.recordAge(at(-3), now: now) == "방금"
          && Format.later(Format.span(4, .second)) == "4초 후" && SessionPresentation.spokenDuration(at(-3_900), now: now) == "1시간 5분"
          && SessionPresentation.retryText(TokenRetryState(attempt: 2, maxAttempts: 10, retryAt: at(4), networkDown: false, at: now),
                                           now: now, api: true) == "API 재시도 2/10 · 4초 후", "Korean formatting changed")
    AppLanguage.with(.en) {
        check(Format.age(at(-3), now: now) == "3s ago" && Format.age(at(-200), now: now) == "3m ago"
              && Format.age(at(-7_200), now: now) == "2h ago" && Format.age(at(-5 * 86_400), now: now) == "5d ago"
              && Format.age(nil, now: now) == "never", "English ages")
        check(SessionPresentation.countdown(to: at(7_980), now: now) == "2h 13m"
              && SessionPresentation.countdown(to: at(473_460), now: now) == "5d 11h"
              && SessionPresentation.countdown(to: at(7_200), now: now) == "2h" && SessionPresentation.countdown(to: at(2_520), now: now) == "42m"
              && SessionPresentation.countdown(to: at(30), now: now) == "<1m", "English countdowns")
        check(SessionPresentation.helpAge(at(-45), now: now) == "<1m ago" && SessionPresentation.helpAge(at(-200), now: now) == "3m ago"
              && SessionPresentation.recordAge(at(-3), now: now) == "just now" && SessionPresentation.recordAge(at(-47), now: now) == "40s ago",
              "English help and record ages")
        check(Format.later(Format.span(4, .second)) == "in 4s" && Format.ago(Format.span(1, .day)) == "1d ago"
              && SessionPresentation.spokenDuration(at(-3_900), now: now) == "1 hour 5 minutes"
              && SessionPresentation.spokenDuration(at(-1), now: now) == "1 second", "English relative and spoken spans")
        let retry = TokenRetryState(attempt: 2, maxAttempts: 10, retryAt: at(4), networkDown: false, at: now)
        check(SessionPresentation.retryText(retry, now: now) == "Retry 2/10 · in 4s"
              && SessionPresentation.retryText(retry, now: now, api: true) == "API retry 2/10 · in 4s", "English retry text")
        check(OnboardingCard.outcome(notice: nil, note: OnboardingCard.notePrefix + "reason", failure: .conflict, state: .waiting)
              == .skipped("reason"), "the English connect note prefix is not stripped")
        var battery = SystemSnapshot()
        battery.isCharging = true
        check(Format.power(battery) == "Charging" && Format.tokens(12_480) == "12,480" && Format.percent(nil) == "—",
              "English power state, grouping or the unknown dash")
    }
    // Launch resolution of this process without --self-test's Korean override, so `-AppleLanguages '(en)'` can be checked.
    let launch = AppLanguage.resolve()
    print("Localization checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP"
          + " · launch language \(launch.rawValue) (bundle \(Bundle.main.preferredLocalizations), system \(Locale.preferredLanguages))")
    return failures
}
