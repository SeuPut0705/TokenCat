using System.Globalization;
using static TokenCat.Lang;

namespace TokenCat;

public enum AppLanguage { Ko, En }

/// Localization.swift: both texts sit at the call site, so there is no string table.
/// `using static TokenCat.Lang;` → `Loc("세션 상세", "Session details")`, `Plural(2, "session")`.
public static class Lang
{
    /// Resolved once at launch; changed afterwards only by checks (`With`).
    public static AppLanguage Current { get; set; } = Resolve(Environment.GetCommandLineArgs(), [CultureInfo.CurrentUICulture.Name]);

    /// `--language ko|en` → the first Korean or English language in `system` (the Windows display language) → English.
    public static AppLanguage Resolve(IReadOnlyList<string> arguments, IEnumerable<string> system) =>
        FlagValue(arguments) is { } flag && Parse(flag) is { } language
            ? language
            : system.Select(FromCode).FirstOrDefault(code => code is not null) ?? AppLanguage.En;

    /// The value after `--language`, "" when it is missing, null without the flag.
    public static string? FlagValue(IReadOnlyList<string> arguments)
    {
        for (var i = 0; i < arguments.Count; i++)
            if (arguments[i] == "--language") return i + 1 < arguments.Count ? arguments[i + 1] : "";
        return null;
    }

    /// The raw value only: "ko" / "en".
    public static AppLanguage? Parse(string raw) => raw switch { "ko" => AppLanguage.Ko, "en" => AppLanguage.En, _ => null };

    /// "ko", "ko-KR", "en_GB" → the language; "kok" or "ja" → null.
    public static AppLanguage? FromCode(string code) =>
        Parse(code.Split(['-', '_'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant() ?? "");

    extension(AppLanguage language)
    {
        public string Code => language == AppLanguage.En ? "en" : "ko";
    }

    /// Date and number styles in the app's language (mac: `AppLanguage.locale`).
    public static CultureInfo Culture => CultureInfo.GetCultureInfo(Current.Code);

    /// Runs `body` in `language`, then restores the previous one. Checks only.
    public static T With<T>(AppLanguage language, Func<T> body)
    {
        var saved = Current;
        Current = language;
        try { return body(); }
        finally { Current = saved; }
    }

    public static void With(AppLanguage language, Action body) => With(language, () => { body(); return 0; });

    public static string Loc(string korean, string english) => Current == AppLanguage.En ? english : korean;

    /// English count noun: "1 session", "2 sessions"; pass `plural` for irregular nouns.
    public static string Plural(int count, string singular, string? plural = null) =>
        $"{count} " + (count == 1 ? singular : plural ?? singular + "s");
}

/// App.swift's `Format` plus Localization.swift's span helpers. `partial`: WP3 adds `Elapsed` (needs SessionPresentation.Clock).
/// Every number here is invariant like Swift's `String(format:)`; only token grouping uses ko-KR, as on mac.
public static partial class Format
{
    static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
    static readonly CultureInfo Korean = CultureInfo.GetCultureInfo("ko-KR");

    public enum TimeUnit { Second, Minute, Hour, Day }

    /// "5분" / "5m". `spoken` keeps Korean and spells English out: "5 minutes".
    public static string Span(int value, TimeUnit unit, bool spoken = false)
    {
        if (spoken && Current == AppLanguage.En) return Plural(value, unit.ToString().ToLowerInvariant());
        return unit switch
        {
            TimeUnit.Second => Loc($"{value}초", $"{value}s"),
            TimeUnit.Minute => Loc($"{value}분", $"{value}m"),
            TimeUnit.Hour => Loc($"{value}시간", $"{value}h"),
            _ => Loc($"{value}일", $"{value}d"),
        };
    }

    /// "5분 전" / "5m ago".
    public static string Ago(string span) => Loc($"{span} 전", $"{span} ago");
    /// "5분 후" / "in 5m".
    public static string Later(string span) => Loc($"{span} 후", $"in {span}");

    public static string Percent(double? value) => value is { } v ? v.ToString("F0", Invariant) + "%" : "—";
    public static string Tps(double? value) => value is { } v ? v.ToString("F1", Invariant) : "—";

    public static double? Ratio(ulong? used, ulong? total) =>
        used is { } u && total is { } t && t > 0 ? (double)u / t * 100 : null;

    public static string Capacity(ulong? used, ulong? total)
    {
        if (used is not { } u || total is not { } t) return "—";
        var terabytes = t >= 1_099_511_627_776;
        var factor = terabytes ? 1_099_511_627_776.0 : 1_073_741_824.0;
        string Number(ulong value) => Trim((value / factor).ToString("F1", Invariant));
        return $"{Number(u)} / {Number(t)} {(terabytes ? "TB" : "GB")}";
    }

    /// Grouped below 100,000 so recent counts stay exact; abbreviated above.
    public static string Tokens(int value)
    {
        if (value < 100_000) return value.ToString("N0", Korean);
        if (value < 999_950) return (value / 1_000.0).ToString("F1", Invariant) + "k";
        return (value / 1_000_000.0).ToString("F2", Invariant) + "M";
    }

    public static string CompactTokens(int value)
    {
        if (value < 1_000) return value.ToString(Invariant);
        if (value < 999_950) return Trim((value / 1_000.0).ToString("F1", Invariant)) + "k";
        return Trim((value / 1_000_000.0).ToString("F1", Invariant)) + "M";
    }

    /// "3분 전" / "3m ago" ("3 minutes ago" `spoken`); null is "기록 없음" / "never".
    public static string Age(DateTimeOffset? date, DateTimeOffset now, bool spoken = false)
    {
        if (date is not { } at) return Loc("기록 없음", "never");
        var seconds = Math.Max(0L, (long)(now - at).TotalSeconds);
        if (seconds < 60) return Ago(Span((int)seconds, TimeUnit.Second, spoken));
        if (seconds < 3_600) return Ago(Span((int)(seconds / 60), TimeUnit.Minute, spoken));
        if (seconds < 86_400) return Ago(Span((int)(seconds / 3_600), TimeUnit.Hour, spoken));
        return Ago(Span((int)(seconds / 86_400), TimeUnit.Day, spoken));
    }

    public static string Power(SystemSnapshot snapshot)
    {
        if (snapshot.IsCharging == true) return Loc("충전 중", "Charging");
        if (snapshot.PowerSource == "AC Power") return Loc("전원 어댑터 연결", "On power adapter");
        if (snapshot.PowerSource == "Battery Power") return Loc("배터리 사용 중", "On battery");
        return Loc("전원 상태 미확인", "Power source unknown");
    }

    static string Trim(string text) => text.EndsWith(".0", StringComparison.Ordinal) ? text[..^2] : text;
}
