using System.Globalization;
using System.Net;
using System.Reflection;
using System.Text.Json;
using static TokenCat.Lang;

namespace TokenCat;

// Updater.swift for the TokenCat-Windows.zip asset (DESIGN §9). The install steps are UpdateInstaller's.

/// A dotted version from a tag or the exe's ProductVersion: "v0.9.1" and "0.9.1-beta" both read as 0.9.1; missing parts are 0.
public sealed class AppVersion : IComparable<AppVersion>, IEquatable<AppVersion>
{
    AppVersion(int[] parts) => Parts = parts;

    public IReadOnlyList<int> Parts { get; }

    public static AppVersion? Parse(string? text)
    {
        if (text is null) return null;
        var core = text.Trim(' ', '\t');
        if (core.StartsWith('v') || core.StartsWith('V')) core = core[1..];
        if (core.IndexOfAny(['-', '+']) is var end and >= 0) core = core[..end];
        var parts = new List<int>();
        foreach (var part in core.Split('.'))
        {
            if (!int.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out var value)) return null;
            parts.Add(value);
        }
        return new AppVersion([.. parts]);
    }

    public override string ToString() => string.Join('.', Parts);

    public int CompareTo(AppVersion? other)
    {
        if (other is null) return 1;
        for (var i = 0; i < Math.Max(Parts.Count, other.Parts.Count); i++)
        {
            var order = (i < Parts.Count ? Parts[i] : 0).CompareTo(i < other.Parts.Count ? other.Parts[i] : 0);
            if (order != 0) return order;
        }
        return 0;
    }

    public bool Equals(AppVersion? other) => other is not null && CompareTo(other) == 0;
    public override bool Equals(object? obj) => Equals(obj as AppVersion);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        var count = Parts.Count;
        while (count > 0 && Parts[count - 1] == 0) count--;
        for (var i = 0; i < count; i++) hash.Add(Parts[i]);
        return hash.ToHashCode();
    }

    public static bool operator ==(AppVersion? a, AppVersion? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(AppVersion? a, AppVersion? b) => !(a == b);
    public static bool operator <(AppVersion a, AppVersion b) => a.CompareTo(b) < 0;
    public static bool operator >(AppVersion a, AppVersion b) => a.CompareTo(b) > 0;
}

/// The release's TokenCat-Windows.zip. `Sha256` is lowercase hex from GitHub's "sha256:…" digest; null when it reports none.
public sealed record UpdateAsset(Uri Url, long Size, string? Sha256);

/// The latest GitHub release as TokenCat uses it; also the cached copy behind the ETag.
public sealed record UpdateRelease(string Version, string Tag, Uri Page, UpdateAsset? Asset = null)
{
    /// The mac app looks only for TokenCat.zip; both ride on the same release.
    public const string AssetName = "TokenCat-Windows.zip";

    /// Reads tag_name, html_url, draft, prerelease and the assets' name, URL, size and digest; nothing else.
    /// Returns null for a draft or prerelease (never offered); throws invalidResponse for anything unreadable.
    public static UpdateRelease? Parse(ReadOnlySpan<byte> data)
    {
        var invalid = new UpdateError(UpdateFailure.InvalidResponse);
        if (Json.Parse(data) is not { ValueKind: JsonValueKind.Object } root || root.Field("tag_name")?.Text is not { } tag
            || AppVersion.Parse(tag) is null || Link(root.Field("html_url")) is not { } page) throw invalid;
        // Decodable reads every field it declares: optional ones may be missing or null, never of another type.
        bool Flag(string key) => root.Field(key) is { ValueKind: not JsonValueKind.Null } value && (value.Bool ?? throw invalid);
        var withheld = Flag("draft") | Flag("prerelease");
        UpdateAsset? asset = null;
        if (root.Field("assets") is { ValueKind: not JsonValueKind.Null } assets)
        {
            if (assets.ValueKind != JsonValueKind.Array) throw invalid;
            foreach (var item in assets.EnumerateArray())
            {
                if (item.Field("name")?.Text is not { } name || Link(item.Field("browser_download_url")) is not { } url
                    || item.Field("size") is not { ValueKind: JsonValueKind.Number } size || !size.TryGetInt64(out var bytes)) throw invalid;
                var digest = item.Field("digest") is { ValueKind: not JsonValueKind.Null } value ? value.Text ?? throw invalid : null;
                if (asset is null && name == AssetName) asset = new UpdateAsset(url, bytes, Sha256FromDigest(digest));
            }
        }
        if (withheld) return null;
        return new UpdateRelease(tag[0] is 'v' or 'V' ? tag[1..] : tag, tag, page, asset);
    }

    static Uri? Link(JsonElement? value) => value?.Text is { } text && Uri.TryCreate(text, UriKind.Absolute, out var uri) ? uri : null;

    /// "sha256:<64 hex>" → lowercase hex; any other algorithm or length → null.
    public static string? Sha256FromDigest(string? digest)
    {
        if (digest is null || !digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) return null;
        var hex = digest[7..].ToLowerInvariant();
        return hex.Length == 64 && hex.All(char.IsAsciiHexDigit) ? hex : null;
    }

    /// The zip and its SHA-256, or why this release cannot be installed in place.
    public (UpdateAsset Asset, string Sha256) Installable() =>
        Asset is not { } asset ? throw new UpdateError(UpdateFailure.NoAsset)
        : asset.Sha256 is not { } sha256 ? throw new UpdateError(UpdateFailure.NoDigest)
        : (asset, sha256);
}

public enum UpdateFailureKind
{
    Network, Server, RateLimited, InvalidResponse,
    NotNewer, NoAsset, NoDigest, SizeMismatch, DigestMismatch, ExtractFailed, InvalidBundle,
    NotBundle, Translocated, NotWritable, ReplaceFailed, RelaunchFailed,
}

/// Why a check or an install did not finish. `Text` is the full sentence (Settings, help); `Short` follows "업데이트 실패 · ".
/// `Status` (server), `Until` (rateLimited) and `Reason` (invalidBundle) are the Swift cases' payloads.
public sealed record UpdateFailure(UpdateFailureKind Kind)
{
    public int Status { get; init; }
    public DateTimeOffset Until { get; init; }
    public string Reason { get; init; } = "";

    public static UpdateFailure Network { get; } = new(UpdateFailureKind.Network);
    public static UpdateFailure Server(int status) => new(UpdateFailureKind.Server) { Status = status };
    public static UpdateFailure RateLimited(DateTimeOffset until) => new(UpdateFailureKind.RateLimited) { Until = until };
    public static UpdateFailure InvalidResponse { get; } = new(UpdateFailureKind.InvalidResponse);
    public static UpdateFailure NotNewer { get; } = new(UpdateFailureKind.NotNewer);
    public static UpdateFailure NoAsset { get; } = new(UpdateFailureKind.NoAsset);
    public static UpdateFailure NoDigest { get; } = new(UpdateFailureKind.NoDigest);
    public static UpdateFailure SizeMismatch { get; } = new(UpdateFailureKind.SizeMismatch);
    public static UpdateFailure DigestMismatch { get; } = new(UpdateFailureKind.DigestMismatch);
    public static UpdateFailure ExtractFailed { get; } = new(UpdateFailureKind.ExtractFailed);
    public static UpdateFailure InvalidBundle(string reason) => new(UpdateFailureKind.InvalidBundle) { Reason = reason };
    public static UpdateFailure NotBundle { get; } = new(UpdateFailureKind.NotBundle);
    public static UpdateFailure Translocated { get; } = new(UpdateFailureKind.Translocated);
    public static UpdateFailure NotWritable { get; } = new(UpdateFailureKind.NotWritable);
    public static UpdateFailure ReplaceFailed { get; } = new(UpdateFailureKind.ReplaceFailed);
    public static UpdateFailure RelaunchFailed { get; } = new(UpdateFailureKind.RelaunchFailed);

    public string Text => Kind switch
    {
        UpdateFailureKind.Network => Loc("GitHub에 연결하지 못했습니다. 네트워크 연결을 확인하세요.", "Couldn't connect to GitHub. Check your network connection."),
        UpdateFailureKind.Server => Loc($"GitHub가 HTTP {Status} 오류로 응답했습니다. 잠시 뒤 다시 시도하세요.", $"GitHub responded with HTTP {Status}. Try again in a moment."),
        UpdateFailureKind.RateLimited => Loc($"GitHub 요청 한도에 걸렸습니다. {Clock(Until)} 이후에 다시 확인할 수 있습니다.",
                                             $"GitHub's rate limit was reached. You can check again after {Clock(Until)}."),
        UpdateFailureKind.InvalidResponse => Loc("GitHub 응답을 읽지 못했습니다.", "Couldn't read GitHub's response."),
        UpdateFailureKind.NotNewer => Loc("설치할 새 버전이 없습니다.", "There's no new version to install."),
        // A copy opened while this one runs only opens this one's flyout and exits, so the manual paths say to quit first.
        UpdateFailureKind.NoAsset => Loc($"릴리스에 {UpdateRelease.AssetName} 파일이 없습니다. 릴리스 페이지에서 직접 내려받은 뒤 TokenCat을 종료하고 새 앱을 여세요.",
                                         $"The release has no {UpdateRelease.AssetName} file. Download it from the release page, then quit TokenCat and open the new copy."),
        UpdateFailureKind.NoDigest => Loc("릴리스 파일의 SHA-256 값이 없어 설치하지 않았습니다. 릴리스 페이지에서 직접 내려받은 뒤 TokenCat을 종료하고 새 앱을 여세요.",
                                          "The release file has no SHA-256 value, so it wasn't installed. Download it from the release page, then quit TokenCat and open the new copy."),
        UpdateFailureKind.SizeMismatch or UpdateFailureKind.DigestMismatch => Loc("내려받은 파일이 릴리스 정보와 달라 설치하지 않았습니다. 기존 앱은 그대로입니다.",
                                                                                  "The downloaded file doesn't match the release, so it wasn't installed. The current app is unchanged."),
        UpdateFailureKind.ExtractFailed => Loc("내려받은 파일의 압축을 풀지 못했습니다. 기존 앱은 그대로입니다.", "Couldn't unzip the downloaded file. The current app is unchanged."),
        UpdateFailureKind.InvalidBundle => Loc($"새 앱을 확인하지 못해 설치하지 않았습니다: {Reason}.", $"Couldn't verify the new app, so it wasn't installed: {Reason}."),
        UpdateFailureKind.NotBundle => Loc("TokenCat.exe로 실행하지 않아 업데이트할 수 없습니다.", "TokenCat isn't running as TokenCat.exe, so it can't update."),
        UpdateFailureKind.Translocated => Loc(@"TokenCat이 압축 파일 안이나 임시 폴더에서 실행되고 있어 업데이트할 수 없습니다. TokenCat을 종료하고 %LOCALAPPDATA%\Programs\TokenCat 폴더에 압축을 푼 뒤 다시 여세요.",
                                              @"TokenCat is running from inside the zip or a temporary folder, so it can't update. Quit TokenCat, extract it to %LOCALAPPDATA%\Programs\TokenCat, then open it again."),
        UpdateFailureKind.NotWritable => Loc("TokenCat이 있는 폴더에 쓸 권한이 없어 업데이트할 수 없습니다. 릴리스 페이지에서 직접 내려받은 뒤 TokenCat을 종료하고 새 앱을 여세요.",
                                             "TokenCat can't write to its folder, so it can't update. Download it from the release page, then quit TokenCat and open the new copy."),
        UpdateFailureKind.ReplaceFailed => Loc("새 앱으로 바꾸지 못했습니다. 기존 앱은 그대로입니다.", "Couldn't replace the app with the new version. The current app is unchanged."),
        _ => Loc("새 버전을 설치했지만 다시 열지 못했습니다. TokenCat을 종료한 뒤 다시 여세요.", "The new version is installed but couldn't reopen. Quit TokenCat, then open it again."),
    };

    public string Short => Kind switch
    {
        UpdateFailureKind.Network => Loc("네트워크 오류", "Network error"),
        UpdateFailureKind.Server or UpdateFailureKind.InvalidResponse => Loc("GitHub 응답 오류", "GitHub response error"),
        UpdateFailureKind.RateLimited => Loc("요청 한도", "Rate limit"),
        UpdateFailureKind.NotNewer => Loc("새 버전 없음", "No new version"),
        UpdateFailureKind.NoAsset => Loc("설치 파일 없음", "No release file"),
        UpdateFailureKind.NoDigest => Loc("검증 정보 없음", "No checksum"),
        UpdateFailureKind.SizeMismatch or UpdateFailureKind.DigestMismatch => Loc("파일 검증 실패", "File check failed"),
        UpdateFailureKind.ExtractFailed => Loc("압축 해제 실패", "Unzip failed"),
        UpdateFailureKind.InvalidBundle => Loc("앱 검증 실패", "App check failed"),
        UpdateFailureKind.NotBundle => Loc("TokenCat.exe 아님", "Not TokenCat.exe"),
        UpdateFailureKind.Translocated => Loc("임시 위치에서 실행 중", "Running from a temporary location"),
        UpdateFailureKind.NotWritable => Loc("쓰기 권한 없음", "No write permission"),
        UpdateFailureKind.ReplaceFailed => Loc("교체 실패", "Replace failed"),
        _ => Loc("다시 열기 실패", "Reopen failed"),
    };

    /// Trying again can help; the rest offer only the release page.
    public bool Retryable => Kind is UpdateFailureKind.Network or UpdateFailureKind.Server or UpdateFailureKind.RateLimited
        or UpdateFailureKind.InvalidResponse or UpdateFailureKind.SizeMismatch or UpdateFailureKind.DigestMismatch
        or UpdateFailureKind.ExtractFailed or UpdateFailureKind.ReplaceFailed;

    /// "14:05" in the local time zone.
    public static string Clock(DateTimeOffset date) => date.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture);
}

/// Swift's `throws UpdateFailure`.
public sealed class UpdateError(UpdateFailure failure) : Exception(failure.Kind.ToString())
{
    public UpdateFailure Failure { get; } = failure;
}

/// One /releases/latest answer.
public abstract record UpdateResponse
{
    UpdateResponse() { }

    public sealed record Release(UpdateRelease Value, string? ETag) : UpdateResponse;
    public sealed record NotModified : UpdateResponse;
    /// 404, or a draft or prerelease: nothing published to compare with.
    public sealed record None : UpdateResponse;
    public sealed record RateLimited(DateTimeOffset Until) : UpdateResponse;
    public sealed record Failed(UpdateFailure Failure) : UpdateResponse;

    /// `header` looks a response header up case-insensitively. 403/429 pause on Retry-After (seconds) or on
    /// X-RateLimit-Remaining 0 until X-RateLimit-Reset; without either (or with a non-finite value) they back off like any
    /// other error. The reset is GitHub's clock, so it is measured from the response's own Date when there is one: a PC
    /// clock that is off does not stretch the pause.
    public static UpdateResponse Interpret(int status, Func<string, string?> header, ReadOnlySpan<byte> body, DateTimeOffset now)
    {
        switch (status)
        {
            case 200:
                try { return UpdateRelease.Parse(body) is { } release ? new Release(release, header("ETag")) : new None(); }
                catch (UpdateError) { return new Failed(UpdateFailure.InvalidResponse); }
            case 304: return new NotModified();
            case 404: return new None();
            case 403 or 429:
                if (Seconds(header("Retry-After")) is { } seconds && seconds >= 0) return new RateLimited(Plus(now, seconds));
                if (header("X-RateLimit-Remaining") == "0" && Seconds(header("X-RateLimit-Reset")) is { } reset)
                    return new RateLimited(header("Date") is { } date && HttpDate(date) is { } served
                        ? Plus(now, reset - served.ToUnixTimeMilliseconds() / 1000.0)
                        : Plus(DateTimeOffset.UnixEpoch, reset));
                return new Failed(UpdateFailure.Server(status));
            default: return new Failed(UpdateFailure.Server(status));
        }
    }

    /// An HTTP Date header ("Fri, 15 Jan 2027 08:00:00 GMT").
    public static DateTimeOffset? HttpDate(string text) =>
        DateTimeOffset.TryParseExact(text, "r", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date) ? date : null;

    static double? Seconds(string? text) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && double.IsFinite(value) ? value : null;

    // Swift's Date takes any finite offset; DateTimeOffset stops at year 9999. The throttle caps every pause at an hour anyway.
    static DateTimeOffset Plus(DateTimeOffset at, double seconds) => at.AddSeconds(Math.Clamp(seconds, -1e10, 1e10));
}

/// Unauthenticated GitHub allows 60 requests an hour per address, 304s included: a rate limit pauses every request until it
/// resets (at most an hour, which is the window GitHub counts in), and errors back off 1, 2, 4, 8 minutes before the regular 15.
public struct UpdateThrottle
{
    public const double Interval = 15 * 60, MaximumPause = 60 * 60;

    /// Errors in a row since the last answer.
    public int Failures { readonly get; private set; }
    /// Rate limited: no request at all before this.
    public DateTimeOffset? PausedUntil { readonly get; set; }

    public static double Backoff(int failures) => failures <= 0 ? Interval : Math.Min(Interval, 60 * Math.Pow(2, Math.Min(failures, 5) - 1));

    public readonly bool Allows(DateTimeOffset now) => PausedUntil is not { } paused || now >= paused;

    /// What is left of the current error backoff; 0 without errors.
    public readonly double BackoffRemaining(DateTimeOffset now, DateTimeOffset? lastAttempt) =>
        Failures > 0 && lastAttempt is { } last ? Math.Max(0, Backoff(Failures) - (now - last).TotalSeconds) : 0;

    /// Wake and dashboard-open checks also wait out the current backoff.
    public readonly bool AllowsAutomatic(DateTimeOffset now, DateTimeOffset? lastAttempt) => Allows(now) && BackoffRemaining(now, lastAttempt) == 0;

    /// Records `response` and returns the delay before the next automatic check (a minute to an hour after a rate limit).
    public double Record(UpdateResponse response, DateTimeOffset now)
    {
        switch (response)
        {
            case UpdateResponse.RateLimited(var until):
                var resume = until > now.AddSeconds(60) ? until : now.AddSeconds(60);
                if (resume > now.AddSeconds(MaximumPause)) resume = now.AddSeconds(MaximumPause);
                PausedUntil = resume;
                return (resume - now).TotalSeconds;
            case UpdateResponse.Failed:
                Failures++;
                return Backoff(Failures);
            default:
                Failures = 0;
                PausedUntil = null;
                return Interval;
        }
    }
}

/// GET /repos/SeuPut0705/TokenCat/releases/latest and nothing else: no cookies, credentials or identifiers.
public sealed class UpdateClient(string version) : IDisposable
{
    public static readonly Uri Latest = new("https://api.github.com/repos/SeuPut0705/TokenCat/releases/latest");
    public static readonly Uri Releases = new("https://github.com/SeuPut0705/TokenCat/releases/latest");

    readonly HttpClient session = Session(TimeSpan.FromSeconds(15));
    CancellationTokenSource? task;

    public string Version { get; } = version;

    /// No cookies, no stored or default credentials, no cache (HttpClient has none). The system proxy applies, as on mac.
    public static SocketsHttpHandler Handler() => new() { UseCookies = false, Credentials = null, PreAuthenticate = false };

    /// `timeout` covers the whole request (15 s for the check, 600 s for the download).
    public static HttpClient Session(TimeSpan timeout) => new(Handler()) { Timeout = timeout };

    public static string UserAgent(string version) => $"TokenCat/{version}";

    /// The check and the download both send these, and nothing else identifying.
    public static void Identify(HttpRequestMessage request, string version)
    {
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgent(version));
        request.Headers.TryAddWithoutValidation("Accept-Language", "en");
    }

    public HttpRequestMessage Request(string? etag)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, Latest);
        request.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
        request.Headers.TryAddWithoutValidation("X-GitHub-Api-Version", "2022-11-28");
        Identify(request, Version);
        if (etag is not null) request.Headers.TryAddWithoutValidation("If-None-Match", etag);
        return request;
    }

    /// One request at a time: a new fetch cancels the previous one, which then returns null. `Status` is 0 without an HTTP
    /// answer; `Header` reads the answer's headers case-insensitively.
    public async Task<(UpdateResponse Response, int Status, Func<string, string?> Header)?> Fetch(string? etag)
    {
        task?.Cancel();
        var cancel = task = new CancellationTokenSource();
        try
        {
            using var request = Request(etag);
            using var http = await session.SendAsync(request, cancel.Token).ConfigureAwait(false);
            var body = await http.Content.ReadAsByteArrayAsync(cancel.Token).ConfigureAwait(false);
            var headers = http.Headers.Concat(http.Content.Headers)
                .ToDictionary(pair => pair.Key, pair => string.Join(", ", pair.Value), StringComparer.OrdinalIgnoreCase);
            string? Header(string name) => headers.GetValueOrDefault(name);
            return (UpdateResponse.Interpret((int)http.StatusCode, Header, body, DateTimeOffset.UtcNow), (int)http.StatusCode, Header);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested) { return null; }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException or IOException)
        {
            return (new UpdateResponse.Failed(UpdateFailure.Network), 0, _ => null);
        }
    }

    public void Cancel()
    {
        task?.Cancel();
        task = null;
    }

    public void Dispose()
    {
        Cancel();
        session.Dispose();
    }
}

/// Swift's Result<UpdateRelease?, UpdateFailure>: a failure, or the latest release (null: nothing published).
public readonly record struct UpdateResult(UpdateRelease? Release, UpdateFailure? Failure)
{
    public UpdateRelease? Get() => Failure is { } failure ? throw new UpdateError(failure) : Release;
}

/// What the updater keeps between launches, under the Swift UserDefaults keys. Nothing here is ever sent.
public sealed class UpdateStore(SettingsStore defaults)
{
    public string? ETag { get => defaults.Get<string>("updateETag"); set => defaults.Set("updateETag", value); }
    /// The release behind `ETag`, so a 304 still knows the latest version.
    public UpdateRelease? Release { get => defaults.Get<UpdateRelease>("updateRelease"); set => defaults.Set("updateRelease", value); }
    public DateTimeOffset? CheckedAt { get => defaults.Get<DateTimeOffset?>("updateCheckedAt"); set => defaults.Set("updateCheckedAt", value); }
    public DateTimeOffset? PausedUntil { get => defaults.Get<DateTimeOffset?>("updatePausedUntil"); set => defaults.Set("updatePausedUntil", value); }
    /// The last version announced by `Updater.Discovered`; each version is announced once.
    public string? NotifiedVersion { get => defaults.Get<string>("updateNotifiedVersion"); set => defaults.Set("updateNotifiedVersion", value); }
    /// Written right before the relaunch; the next launch says "…로 업데이트했습니다" once if it runs that version.
    public string? InstalledVersion { get => defaults.Get<string>("updateInstalledVersion"); set => defaults.Set("updateInstalledVersion", value); }

    /// If-None-Match goes out only while the release it stands for is cached.
    public string? ETagToSend => Release is null ? null : ETag;

    /// Updates the cache for `response` and returns the latest published release it stands for (a 304 reuses the cached
    /// copy, null means nothing is published), or the failure for answers that say nothing about it.
    public UpdateResult Resolve(UpdateResponse response)
    {
        switch (response)
        {
            case UpdateResponse.Release(var latest, var tag):
                Release = latest;
                ETag = tag;
                return new(latest, null);
            case UpdateResponse.NotModified:
                if (Release is { } release) return new(release, null);
                ETag = null;
                return new(null, UpdateFailure.InvalidResponse);
            case UpdateResponse.RateLimited(var until):
                return new(null, UpdateFailure.RateLimited(until));
            case UpdateResponse.Failed(var failure):
                return new(null, failure);
            default:
                Release = null;
                ETag = null;
                return new(null, null);
        }
    }
}

/// What the dashboard asks of the updater; the app shell carries it out.
public enum UpdateCommand { Check, Install, OpenReleasePage, Dismiss }

public abstract record UpdateCheck
{
    UpdateCheck() { }

    public sealed record Idle : UpdateCheck;
    public sealed record Checking : UpdateCheck;
    public sealed record Done : UpdateCheck;
    public sealed record Failed(UpdateFailure Failure) : UpdateCheck;
}

public abstract record UpdateInstall
{
    UpdateInstall() { }

    public sealed record None : UpdateInstall;
    public sealed record Downloading(double Fraction) : UpdateInstall;
    public sealed record Installing : UpdateInstall;
    public sealed record Failed(UpdateFailure Failure) : UpdateInstall;
}

/// Published by the updater to the dashboard and the menu.
public sealed record UpdateState
{
    /// This copy cannot update itself at all (not TokenCat.exe); no request is ever made.
    public string? Disabled { get; init; }
    public UpdateCheck Check { get; init; } = new UpdateCheck.Idle();
    public UpdateInstall Install { get; init; } = new UpdateInstall.None();
    public DateTimeOffset? CheckedAt { get; init; }
    /// The latest release, only while it is newer than this build.
    public UpdateRelease? Available { get; init; }
    /// The version this launch updated to; shown once, until the dashboard closes or ✕.
    public string? UpdatedTo { get; init; }

    public bool Installing => Install is UpdateInstall.Downloading or UpdateInstall.Installing;
    public UpdateFailure? InstallFailure => (Install as UpdateInstall.Failed)?.Failure;
    /// A failure that trying again cannot fix (a copy in a temporary folder, a folder without write access, a release without
    /// its file or digest, …): the install is not offered again until a newer release arrives.
    public bool BlockedByFailure => InstallFailure is { Retryable: false };
    public bool CanInstall => Disabled is null && Available is not null && !Installing && !BlockedByFailure;
    public bool CanCheck => Disabled is null && Check is not UpdateCheck.Checking && !Installing;

    /// The quick menu item: the install while it can run, the release page after a failure that blocks it.
    public UpdateCommand? QuickMenuCommand =>
        Disabled is null && Available is not null && !Installing ? BlockedByFailure ? UpdateCommand.OpenReleasePage : UpdateCommand.Install : null;

    public string? QuickMenuTitle => Available?.Version is { } version && QuickMenuCommand is { } command
        ? command == UpdateCommand.Install ? Loc($"업데이트 {version} 설치…", $"Install Update {version}…")
            : Loc($"업데이트 {version} 릴리스 페이지…", $"Update {version} Release Page…")
        : null;

    /// A check's newer release. One other than the failed install's clears that failure, so it can be installed.
    public UpdateState Receive(UpdateRelease? release) =>
        (InstallFailure is not null && release is not null && release.Version != Available?.Version ? this with { Install = new UpdateInstall.None() } : this)
        with { Available = release };

    public static string Progress(double fraction)
    {
        var percent = (int)Math.Floor(Math.Min(1, Math.Max(0, fraction)) * 100);
        return Loc($"업데이트 내려받는 중 {percent}%", $"Downloading update {percent}%");
    }

    /// "0.9.1로 업데이트했습니다"; "으로" after 0, 3 and 6 (영, 삼, 육), which end in a consonant other than ㄹ.
    public static string Updated(string version) =>
        Loc(version + (version.LastOrDefault(char.IsAsciiDigit) is '0' or '3' or '6' ? "으로" : "로") + " 업데이트했습니다", $"Updated to {version}");

    /// The footer's trailing item, most important first: progress, failure, a new version (unless closed with ✕ for that
    /// version), then the one-time note after an update.
    public UpdateNotice? Notice(string? dismissed)
    {
        var version = Available?.Version ?? "";
        switch (Install)
        {
            case UpdateInstall.Downloading(var fraction):
                return new(UpdateNoticeKind.Downloading, Progress(fraction),
                    Loc($"TokenCat {version} 내려받는 중 · 설치가 끝나면 다시 엽니다", $"Downloading TokenCat {version} · reopens when installed"), version);
            case UpdateInstall.Installing:
                return new(UpdateNoticeKind.Installing, Loc("설치 중…", "Installing…"),
                    Loc("내려받은 앱을 확인하고 바꾸는 중 · 끝나면 TokenCat을 다시 엽니다", "Verifying and replacing the app · TokenCat reopens when done"), version);
            case UpdateInstall.Failed(var failure):
                return new(UpdateNoticeKind.Failed, Loc("업데이트 실패", "Update failed"), failure.Text, version)
                {
                    Detail = failure.Short, Retryable = failure.Retryable,
                };
        }
        if (Available is { } available && available.Version != dismissed)
            return new(UpdateNoticeKind.Available, Loc($"새 버전 {available.Version}", $"New version {available.Version}"),
                Loc("내려받아 설치한 뒤 TokenCat을 다시 엽니다", "Downloads and installs it, then reopens TokenCat"), available.Version);
        if (UpdatedTo is { } updated)
            return new(UpdateNoticeKind.Updated, Updated(updated), Loc($"TokenCat {updated} 실행 중", $"Running TokenCat {updated}"), updated);
        return null;
    }

    /// The Settings status line: a title ("최신 버전입니다 · 3분 전 확인", "새 버전 0.9.1") and an optional second line.
    /// An install failure gives its short reason here; Settings shows the full sentence under the row.
    public (string Title, string? Detail, bool Problem) Status(DateTimeOffset now)
    {
        if (Disabled is { } disabled) return (disabled, null, false);
        switch (Install)
        {
            case UpdateInstall.Downloading(var fraction): return (Progress(fraction), null, false);
            case UpdateInstall.Installing: return (Loc("설치 중…", "Installing…"), null, false);
            case UpdateInstall.Failed(var failure): return (Loc("업데이트 실패", "Update failed"), failure.Short, true);
        }
        if (Available is { } available)
            return (Loc($"새 버전 {available.Version}", $"New version {available.Version}"), CheckedAt is { } at ? Checked(at, now) : null, false);
        switch (Check)
        {
            case UpdateCheck.Checking: return (Loc("확인 중…", "Checking…"), null, false);
            case UpdateCheck.Failed(var failure): return (Loc("확인하지 못했습니다", "Couldn't check"), failure.Text, true);
        }
        if (CheckedAt is not { } checkedAt) return (Loc("아직 확인하지 않았습니다", "Not checked yet"), null, false);
        return (Loc("최신 버전입니다 · ", "Up to date · ") + Checked(checkedAt, now), null, false);
    }

    /// Minute-granular so the line does not tick: "방금 확인", "3분 전 확인".
    public static string Checked(DateTimeOffset date, DateTimeOffset now) =>
        (now - date).TotalSeconds < 60 ? Loc("방금 확인", "Checked just now") : Loc(Format.Age(date, now) + " 확인", "Checked " + Format.Age(date, now));
}

public enum UpdateNoticeKind { Available, Downloading, Installing, Failed, Updated }

/// The dashboard footer's trailing update item. `Retryable` is meaningful for `Failed` only.
public sealed record UpdateNotice(UpdateNoticeKind Kind, string Text, string Help, string Version)
{
    /// The failure's short reason, dropped first when the footer is narrow.
    public string? Detail { get; init; }
    public bool Retryable { get; init; }
}

/// Checks GitHub for a newer release and installs it only when asked. One thread (the UI's): timers and requests come back
/// through the SynchronizationContext it was created on. Automatic checks: 5 s after launch, every 15 min, 15 s after wake,
/// and when the dashboard opens 5 min after the last one.
public sealed class Updater
{
    public const double LaunchDelay = 5, WakeDelay = 15, OpenAfter = 5 * 60;

    readonly string exePath, version;
    readonly AppVersion? current;
    readonly UpdateClient client;
    readonly UpdateStore store;
    readonly SynchronizationContext? context = SynchronizationContext.Current;
    UpdateState state = new();
    UpdateThrottle throttle;
    bool automatic, running, fetching;
    Timer? timer;
    DateTimeOffset? lastAttempt;
    /// Identifies the request in flight; answers for an older one are dropped.
    int request;
    CancellationTokenSource? installation;
    /// A quit that arrived during "설치 중…"; answered once that step ends.
    Action? quitReply;

    /// Defaults: the running exe, this build's version and the shared settings file.
    public Updater(string? exePath = null, string? version = null, SettingsStore? defaults = null)
    {
        this.exePath = exePath ?? Environment.ProcessPath ?? "";
        this.version = version ?? CurrentVersion;
        current = AppVersion.Parse(this.version);
        client = new UpdateClient(this.version);
        store = new UpdateStore(defaults ?? SettingsStore.Shared);
    }

    /// This build's version (build.sh's CFBundleShortVersionString via Directory.Build.props).
    public static string CurrentVersion =>
        typeof(Updater).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "";

    public event Action<UpdateState>? StateChanged;
    /// A newer release seen for the first time; once per version, for the optional notification.
    public event Action<UpdateRelease>? Discovered;
    /// Runs after the new version was started: the shell stops the collector, removes the tray icon and exits.
    public Action Shutdown { get; set; } = () => Environment.Exit(0);

    public UpdateState State
    {
        get => state;
        private set
        {
            if (value == state) return;
            state = value;
            StateChanged?.Invoke(value);
        }
    }

    public void Start(bool automatic)
    {
        if (running) return;
        running = true;
        if (!UpdateInstaller.IsExe(exePath))
            State = State with { Disabled = Loc("TokenCat.exe로 실행할 때만 업데이트를 확인합니다", "Checks for updates only when running as TokenCat.exe") };
        else if (current is null)
            State = State with { Disabled = Loc("버전 정보를 읽지 못해 업데이트를 확인하지 않습니다", "Can't read the version, so updates aren't checked") };
        if (State.Disabled is null)
        {
            // What a relaunched copy could not remove last time (DESIGN §2.9).
            UpdateInstaller.Cleanup(exePath);
            // A stored pause longer than any the throttle sets (written under a wrong clock) is dropped.
            if (store.PausedUntil is { } paused && (paused - DateTimeOffset.UtcNow).TotalSeconds > UpdateThrottle.MaximumPause) store.PausedUntil = null;
            throttle.PausedUntil = store.PausedUntil;
            var next = State with { CheckedAt = store.CheckedAt, Available = Newer(store.Release) };
            if (store.InstalledVersion is { } installed)
            {
                store.InstalledVersion = null;
                if (AppVersion.Parse(installed) == current) next = next with { UpdatedTo = installed };
            }
            State = next;
        }
        this.automatic = false;
        SetAutomatic(automatic);
    }

    /// Timers, the request and any download stop; nothing is published afterwards.
    public void Stop()
    {
        running = false;
        timer?.Dispose();
        timer = null;
        CancelFetch();
        installation?.Cancel();
        installation = null;
    }

    /// "새 버전 자동 확인". Turning it on checks within 5 s unless a check ran in the last 15 min.
    public void SetAutomatic(bool on)
    {
        if (on == automatic) return;
        automatic = on;
        timer?.Dispose();
        timer = null;
        if (!on) return;
        var due = ((lastAttempt ?? DateTimeOffset.MinValue).AddSeconds(UpdateThrottle.Interval) - DateTimeOffset.UtcNow).TotalSeconds;
        Schedule(Math.Max(LaunchDelay, due));
    }

    /// "지금 확인": skips the backoff wait, never a rate-limit pause.
    public void CheckNow() => Check();

    public void DashboardOpened()
    {
        var now = DateTimeOffset.UtcNow;
        if (!running || !automatic || fetching || (now - (lastAttempt ?? DateTimeOffset.MinValue)).TotalSeconds < OpenAfter
            || !throttle.AllowsAutomatic(now, lastAttempt)) return;
        Check();
    }

    /// About 15 s after waking, or when the current error backoff ends if that is later.
    public void SystemDidWake()
    {
        if (!running || !automatic) return;
        Schedule(Math.Max(WakeDelay, throttle.BackoffRemaining(DateTimeOffset.UtcNow, lastAttempt)));
    }

    public void ClearFailure()
    {
        if (State.Install is UpdateInstall.Failed) State = State with { Install = new UpdateInstall.None() };
    }

    public void ClearUpdatedNote() => State = State with { UpdatedTo = null };

    void Post(Action action)
    {
        if (context is null) action();
        else context.Post(_ => action(), null);
    }

    void Schedule(double delay)
    {
        timer?.Dispose();
        timer = null;
        if (!running || !automatic || State.Disabled is not null) return;
        var paused = throttle.PausedUntil is { } until ? (until - DateTimeOffset.UtcNow).TotalSeconds : 0;
        var wait = Math.Max(Math.Max(1, delay), paused);
        Timer? next = null;
        next = new Timer(_ => Post(() =>
        {
            if (timer != next) return; // replaced or stopped meanwhile
            timer = null;
            Check();
        }), null, TimeSpan.FromSeconds(wait), Timeout.InfiniteTimeSpan);
        timer = next;
    }

    async void Check()
    {
        if (!running || State.Disabled is not null || fetching) return;
        // A download is under way: the regular check comes back later instead of competing with it.
        if (State.Installing)
        {
            Schedule(UpdateThrottle.Interval);
            return;
        }
        State = State with { Check = new UpdateCheck.Checking() };
        if (await Fetch() is not { } result) return;
        if (result.Failure is { } failure) State = State with { Check = new UpdateCheck.Failed(failure) };
        else Apply(result.Release);
    }

    /// Records a successful answer. Internal for the checks.
    internal void Apply(UpdateRelease? latest)
    {
        var next = State with { Check = new UpdateCheck.Done(), CheckedAt = store.CheckedAt };
        next = next.Receive(Newer(latest));
        State = next;
        if (next.Available is { } release && store.NotifiedVersion != release.Version)
        {
            store.NotifiedVersion = release.Version;
            Discovered?.Invoke(release);
        }
    }

    /// A newer release with a Windows asset; one without it is "no update for Windows" (quiet), not a failure (DESIGN §9).
    UpdateRelease? Newer(UpdateRelease? release) =>
        release is { Asset: not null } && current is not null && AppVersion.Parse(release.Version) is { } latest && latest > current ? release : null;

    async Task<UpdateResult?> Fetch()
    {
        var now = DateTimeOffset.UtcNow;
        if (!throttle.Allows(now) && throttle.PausedUntil is { } until) return new UpdateResult(null, UpdateFailure.RateLimited(until));
        CancelFetch();
        var token = ++request;
        fetching = true;
        lastAttempt = now;
        var answer = await client.Fetch(store.ETagToSend);
        if (answer is not { } value || !running || request != token) return null;
        fetching = false;
        var delay = throttle.Record(value.Response, DateTimeOffset.UtcNow);
        store.PausedUntil = throttle.PausedUntil;
        var result = store.Resolve(value.Response);
        if (result.Failure is null) store.CheckedAt = DateTimeOffset.UtcNow;
        Schedule(delay);
        return result;
    }

    void CancelFetch()
    {
        if (!fetching) return;
        client.Cancel();
        fetching = false;
        request++;
        if (State.Check is UpdateCheck.Checking)
            State = State with { Check = State.CheckedAt is null ? new UpdateCheck.Idle() : new UpdateCheck.Done() };
    }

    /// Always user-initiated. Guards first, then a fresh look at the latest release, then download → verify → replace →
    /// relaunch. Every failure leaves the running app as it was.
    public async void Install()
    {
        if (!running || State.Disabled is not null || State.Installing) return;
        if (UpdateInstaller.Blocker(exePath) is { } blocker)
        {
            State = State with { Install = new UpdateInstall.Failed(blocker) };
            return;
        }
        State = State with { Install = new UpdateInstall.Downloading(0) };
        if (await Fetch() is not { } result || State.Install is not UpdateInstall.Downloading) return;

        using var cancel = new CancellationTokenSource();
        var staging = UpdateInstaller.StagingFolder(exePath);
        UpdateRelease? release = null;
        UpdateFailure? failure = null;
        try
        {
            // While GitHub's API is rate-limited, the release already read is enough: the download host is not limited, and
            // size and digest are still checked. The check state keeps showing the limit.
            UpdateRelease? latest;
            if (result.Failure is { Kind: UpdateFailureKind.RateLimited } && State.Available is { } cached) latest = cached;
            else
            {
                latest = result.Get();
                Apply(latest);
            }
            release = Newer(latest) ?? throw new UpdateError(UpdateFailure.NotNewer);
            var (asset, sha256) = release.Installable();
            installation = cancel;
            var progress = new Progress<double>(fraction =>
            {
                if (installation == cancel && State.Install is UpdateInstall.Downloading)
                    State = State with { Install = new UpdateInstall.Downloading(fraction) };
            });
            var archive = await UpdateInstaller.Download(asset, staging, version, progress, cancel.Token);
            if (cancel.IsCancellationRequested) return;
            State = State with { Install = new UpdateInstall.Installing() };
            var releaseVersion = release.Version;
            await Task.Run(() => UpdateInstaller.Install(archive, staging, exePath, asset.Size, sha256, releaseVersion, cancel.Token));
        }
        catch (UpdateError error) { failure = error.Failure; }
        catch (OperationCanceledException) { return; }
        finally
        {
            if (installation == cancel) installation = null;
            UpdateInstaller.RemoveFolder(staging);
        }
        if (cancel.IsCancellationRequested || !running) return;
        Finished(failure, release);
    }

    void Finished(UpdateFailure? failure, UpdateRelease? release)
    {
        var quitting = quitReply;
        quitReply = null;
        if (failure is not null || release is null) State = State with { Install = new UpdateInstall.Failed(failure ?? UpdateFailure.ReplaceFailed) };
        else
        {
            // Kept even if the relaunch fails: the next start of this exe runs the new version.
            store.InstalledVersion = release.Version;
            // Asked to quit meanwhile: it quits without reopening, and the next launch runs the new version.
            if (quitting is null)
            {
                try { UpdateInstaller.Relaunch(exePath).Dispose(); }
                catch (UpdateError)
                {
                    State = State with { Install = new UpdateInstall.Failed(UpdateFailure.RelaunchFailed) };
                    return;
                }
                Shutdown();
            }
        }
        quitting?.Invoke();
    }

    /// A quit during "설치 중…" (checking and swapping the downloaded exe, a few seconds) waits for that step, so the exe is
    /// never left mid-swap; `reply` runs once it ends, or after 60 s. False when nothing needs waiting for.
    public bool DeferQuit(Action reply)
    {
        if (installation is null || State.Install is not UpdateInstall.Installing) return false;
        quitReply = reply;
        Timer? deadline = null;
        deadline = new Timer(_ => Post(() =>
        {
            deadline?.Dispose();
            if (quitReply is not { } pending) return;
            quitReply = null;
            pending();
        }), null, TimeSpan.FromSeconds(60), Timeout.InfiniteTimeSpan);
        return true;
    }

    /// `--update-check`: one unconditional GET, printed. Never reads or writes the app's update state, never installs.
    public static int CommandLineCheck() => CommandLineCheck(Environment.ProcessPath ?? "", CurrentVersion);

    static int CommandLineCheck(string exePath, string version)
    {
        Console.WriteLine(Loc($"현재 버전: {version}", $"Current version: {version}") + (UpdateInstaller.IsExe(exePath) ? ""
            : Loc(" (TokenCat.exe 아님 · 앱에서는 업데이트를 확인하지 않음)", " (not TokenCat.exe · the app wouldn't check for updates)")));
        Console.WriteLine(Loc($"요청: GET {UpdateClient.Latest.AbsoluteUri}", $"Request: GET {UpdateClient.Latest.AbsoluteUri}"));
        using var client = new UpdateClient(version);
        var fetch = client.Fetch(null);
        if (!fetch.Wait(TimeSpan.FromSeconds(20)) || fetch.Result is not { } answer)
        {
            Console.WriteLine(Loc("결과: 응답 없음 (시간 초과)", "Result: no response (timed out)"));
            return 1;
        }
        var (response, status, header) = answer;
        if (status > 0)
        {
            var remaining = header("X-RateLimit-Remaining") ?? "?";
            var limit = header("X-RateLimit-Limit") ?? "?";
            var reset = "";
            if (double.TryParse(header("X-RateLimit-Reset"), NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) && double.IsFinite(seconds))
            {
                var at = UpdateFailure.Clock(DateTimeOffset.UnixEpoch.AddSeconds(Math.Clamp(seconds, 0, 1e10)));
                reset = Loc($" · {at} 초기화", $" · resets at {at}");
            }
            Console.WriteLine(Loc($"HTTP {status} · GitHub 요청 한도 {remaining}/{limit} 남음{reset}", $"HTTP {status} · GitHub rate limit {remaining}/{limit} left{reset}"));
        }
        switch (response)
        {
            case UpdateResponse.Release(var release, _):
                Console.WriteLine(Loc($"최신 릴리스: {release.Tag} · {release.Page.AbsoluteUri}", $"Latest release: {release.Tag} · {release.Page.AbsoluteUri}"));
                Console.WriteLine(release.Asset is { } asset
                    ? Loc("자산: ", "Asset: ") + $"{UpdateRelease.AssetName} · {asset.Size} bytes · "
                      + (asset.Sha256 is { } sha256 ? $"sha256:{sha256}" : Loc("SHA-256 digest 없음", "no SHA-256 digest"))
                    : Loc($"자산: {UpdateRelease.AssetName} 없음", $"Asset: no {UpdateRelease.AssetName}"));
                switch ((AppVersion.Parse(version), AppVersion.Parse(release.Version)))
                {
                    case ({ } current, { } latest) when latest > current:
                        string installable;
                        try
                        {
                            release.Installable();
                            installable = Loc("설치 조건 충족", "installable");
                        }
                        catch (UpdateError error) { installable = error.Failure.Text; }
                        Console.WriteLine(Loc($"결과: 업데이트 있음 ({version} → {release.Version}) · {installable}",
                                              $"Result: update available ({version} → {release.Version}) · {installable}"));
                        break;
                    case ({ } current, { } latest):
                        Console.WriteLine(latest == current ? Loc("결과: 최신 버전입니다", "Result: up to date")
                            : Loc($"결과: 실행 중인 버전이 릴리스보다 새롭습니다 ({version} > {release.Version})",
                                  $"Result: the running version is newer than the release ({version} > {release.Version})"));
                        break;
                    default:
                        Console.WriteLine(Loc("결과: 현재 버전을 읽지 못해 비교하지 않았습니다", "Result: couldn't read the current version, so nothing was compared"));
                        break;
                }
                return 0;
            case UpdateResponse.None:
                Console.WriteLine(Loc("최신 릴리스: 없음 (GitHub에 공개된 릴리스가 없습니다)", "Latest release: none (nothing published on GitHub)"));
                Console.WriteLine(Loc("결과: 최신 버전입니다 (비교할 릴리스 없음)", "Result: up to date (no release to compare)"));
                return 0;
            case UpdateResponse.NotModified:
                Console.WriteLine(Loc("결과: 예상하지 못한 304 응답", "Result: unexpected 304 response"));
                return 1;
            case UpdateResponse.RateLimited(var until):
                Console.WriteLine(Loc($"결과: 확인 실패 · GitHub 요청 한도 · {UpdateFailure.Clock(until)} 이후 다시 시도",
                                      $"Result: check failed · GitHub rate limit · try again after {UpdateFailure.Clock(until)}"));
                return 1;
            case UpdateResponse.Failed(var failure):
                Console.WriteLine(Loc($"결과: 확인 실패 · {failure.Text}", $"Result: check failed · {failure.Text}"));
                return 1;
            default:
                return 1;
        }
    }
}
