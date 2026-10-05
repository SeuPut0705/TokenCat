using static TokenCat.Lang;

namespace TokenCat;

/// LocalizationChecks.swift, Windows edition: the bundle's per-app pick becomes the Windows display language list. Its
/// SessionPresentation/OnboardingCard cases belong to WP3's SessionPresentationChecks (same descriptions). The Format cases
/// of SessionPresentationChecks.swift ("token format", "compact token format", "ages use the model clock") live here with Format.
public static class LocalizationChecks
{
    public static List<string> Run()
    {
        var c = new Check("Localization", "Localization: ");
        void check(bool valid, string description) => c.That(valid, description);
        const AppLanguage ko = AppLanguage.Ko, en = AppLanguage.En;

        // Resolution: flag → first Korean or English display language → English.
        check(Resolve(["TokenCat", "--language", "en"], ["ko-KR"]) == en
              && Resolve(["TokenCat", "--language", "ko"], ["en-US"]) == ko, "--language does not win");
        check(Resolve(["TokenCat"], ["ja-JP", "ko-KR", "en-US"]) == ko && Resolve(["TokenCat"], ["en-GB", "ko-KR"]) == en
              && Resolve(["TokenCat"], ["ja-JP"]) == en && Resolve(["TokenCat"], ["kok-IN"]) == en
              && Resolve(["TokenCat"], []) == en, "without bundle localizations the system list or English is not used");
        check(Resolve(["TokenCat", "--language", "fr"], ["ko"]) == ko && FlagValue(["--language", "fr"]) == "fr"
              && FlagValue(["--language"]) == "" && FlagValue(["--self-test"]) == null,
              "an unknown --language value is not reported or falls through wrongly");

        // Call-site API.
        check(Loc("세션", "Session") == "세션" && With(en, () => Loc("세션", "Session")) == "Session" && Current == ko,
              "loc does not follow the language or `with` does not restore it");
        check(Plural(1, "session") == "1 session" && Plural(2, "session") == "2 sessions" && Plural(0, "session") == "0 sessions"
              && Plural(3, "child", "children") == "3 children", "English plural");

        // Formatting helpers in both languages.
        var now = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        DateTimeOffset at(double offset) => now.AddSeconds(offset);
        check(Format.Age(at(-3), now) == "3초 전" && Format.Later(Format.Span(4, Format.TimeUnit.Second)) == "4초 후"
              && Format.Span(5, Format.TimeUnit.Minute, spoken: true) == "5분", "Korean formatting changed");
        With(en, () =>
        {
            check(Format.Age(at(-3), now) == "3s ago" && Format.Age(at(-200), now) == "3m ago"
                  && Format.Age(at(-7_200), now) == "2h ago" && Format.Age(at(-5 * 86_400), now) == "5d ago"
                  && Format.Age(null, now) == "never", "English ages");
            check(Format.Later(Format.Span(4, Format.TimeUnit.Second)) == "in 4s" && Format.Ago(Format.Span(1, Format.TimeUnit.Day)) == "1d ago"
                  && Format.Span(1, Format.TimeUnit.Hour, spoken: true) == "1 hour" && Format.Span(5, Format.TimeUnit.Minute, spoken: true) == "5 minutes",
                  "English relative and spoken spans");
            check(Format.Power(new SystemSnapshot { IsCharging = true }) == "Charging" && Format.Tokens(12_480) == "12,480"
                  && Format.Percent(null) == "—", "English power state, grouping or the unknown dash");
        });

        // From SessionPresentationChecks.swift "Formats and honest speed".
        check(Format.Tokens(786) == "786" && Format.Tokens(12_480) == "12,480" && Format.Tokens(123_400) == "123.4k"
              && Format.Tokens(1_234_567) == "1.23M" && Format.Tokens(999_960) == "1.00M", "token format");
        check(Format.CompactTokens(786) == "786" && Format.CompactTokens(8_100) == "8.1k" && Format.CompactTokens(1_000) == "1k"
              && Format.CompactTokens(1_200_000) == "1.2M", "compact token format");
        check(Format.Age(at(-3), now) == "3초 전" && Format.Age(at(-200), now) == "3분 전" && Format.Age(at(5), now) == "0초 전",
              "ages use the model clock");

        // Windows only: printf rounding (half-even on the binary value) and the GB/TB switch.
        check(Format.Percent(42.5) == "42%" && Format.Tps(12.25) == "12.2" && Format.Capacity(8_589_934_592, 17_179_869_184) == "8 / 16 GB"
              && Format.Capacity(1_649_267_441_664, 2_199_023_255_552) == "1.5 / 2 TB" && Format.Capacity(null, 1) == "—"
              && Format.Ratio(1, 4) == 25 && Format.Ratio(1, 0) == null, "percent, tps or capacity format");
        return c.Done();
    }
}
