using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;

namespace TokenCat;

/// UpdaterChecks.swift: versions, release parsing, request and cache rules, presentation, install guards, and the install steps
/// on temp files (rename semantics stand in on macOS; `--update-selftest <zip>` runs them on the real exe on Windows). No network.
/// Descriptions are verbatim except where the platform differs (asset name, .exe instead of .app).
public static class UpdaterChecks
{
    public static List<string> Run()
    {
        var c = new Check("Updater", "Updater: ");
        void check(bool valid, string description) => c.That(valid, description);
        static UpdateFailure? failure(Action body)
        {
            try
            {
                body();
                return null;
            }
            catch (UpdateError error) { return error.Failure; }
        }
        var at = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var folder = Directory.CreateTempSubdirectory("TokenCat-updater-checks-").FullName;
        try
        {
            var defaults = new SettingsStore(Path.Combine(folder, "settings.json"));

            // Versions: numeric parts, "v" prefix, suffix ignored, missing parts are 0.
            static AppVersion version(string text) => AppVersion.Parse(text)!;
            check(version("v0.9.1") > version("0.9.0") && version("0.10.0") > version("0.9.9") && version("1.0.0") > version("0.99"),
                  "numeric version order");
            check(AppVersion.Parse("0.9.1-beta.2") == AppVersion.Parse("0.9.1") && AppVersion.Parse("1.0") == AppVersion.Parse("1.0.0")
                  && !(version("1.0") < version("1.0.0")) && AppVersion.Parse("V2.0")?.ToString() == "2.0", "suffix and missing parts");
            check(new[] { "", "v", "abc", "1..2", "1.x", "-1" }.All(text => AppVersion.Parse(text) is null), "unreadable versions are rejected");

            // Release JSON: only the fields TokenCat uses; drafts and prereleases are never offered.
            var digest = string.Concat(Enumerable.Repeat("AB", 32));
            JsonObject zipAsset(string name = UpdateRelease.AssetName) => new()
            {
                ["name"] = name, ["size"] = 5_242_880, ["digest"] = "sha256:" + digest,
                ["browser_download_url"] = $"https://github.com/SeuPut0705/TokenCat/releases/download/v0.9.1/{name}",
            };
            byte[] json(string tag = "v0.9.1", bool draft = false, bool prerelease = false, JsonArray? assets = null)
            {
                var root = new JsonObject
                {
                    ["tag_name"] = tag, ["html_url"] = $"https://github.com/SeuPut0705/TokenCat/releases/tag/{tag}",
                    ["draft"] = draft, ["prerelease"] = prerelease, ["name"] = $"TokenCat {tag}", ["id"] = 1,
                };
                if (assets is not null) root["assets"] = assets;
                return Encoding.UTF8.GetBytes(root.ToJsonString());
            }
            // Null for a withheld release and for an error alike.
            static UpdateRelease? parse(byte[] data)
            {
                try { return UpdateRelease.Parse(data); }
                catch (UpdateError) { return null; }
            }
            static bool withheld(byte[] data)
            {
                try { return UpdateRelease.Parse(data) is null; }
                catch (UpdateError) { return false; }
            }
            var release = parse(json(assets: [new JsonObject { ["name"] = "TokenCat-Windows.zip.sha256", ["size"] = 1, ["browser_download_url"] = "https://example.invalid/a" },
                                              zipAsset("TokenCat.zip"), zipAsset()]));
            check(release is { Version: "0.9.1", Tag: "v0.9.1", Asset: { Size: 5_242_880 } asset }
                  && release.Page.AbsoluteUri == "https://github.com/SeuPut0705/TokenCat/releases/tag/v0.9.1"
                  && asset.Sha256 == digest.ToLowerInvariant() && asset.Url.Segments[^1] == "TokenCat-Windows.zip",
                  "a release with TokenCat-Windows.zip and its digest");
            var bare = parse(json());
            var noDigest = zipAsset();
            noDigest.Remove("digest");
            var undigested = parse(json(assets: [noDigest]));
            var other = zipAsset();
            other["digest"] = "sha512:" + digest;
            check(bare is { Asset: null } && failure(() => bare.Installable()) == UpdateFailure.NoAsset
                  && parse(json(assets: [zipAsset("TokenCat.zip"), zipAsset("TokenCat-Windows-0.9.1.zip")]))?.Asset is null,
                  "a release without TokenCat-Windows.zip parses but cannot be installed");
            check(undigested?.Asset is { Sha256: null } && failure(() => undigested.Installable()) == UpdateFailure.NoDigest
                  && parse(json(assets: [other]))?.Asset?.Sha256 is null, "an asset without a SHA-256 digest cannot be installed");
            check(withheld(json(draft: true, assets: [zipAsset()])) && withheld(json(prerelease: true, assets: [zipAsset()])) && !withheld(json(assets: [zipAsset()])),
                  "drafts and prereleases are not offered");
            check(failure(() => UpdateRelease.Parse("{}"u8)) == UpdateFailure.InvalidResponse
                  && failure(() => UpdateRelease.Parse(json(tag: "latest"))) == UpdateFailure.InvalidResponse
                  && failure(() => UpdateRelease.Parse("<html>"u8)) == UpdateFailure.InvalidResponse
                  && failure(() => UpdateRelease.Parse(json(assets: [new JsonObject { ["name"] = "TokenCat-Windows.zip" }]))) == UpdateFailure.InvalidResponse
                  && failure(() => UpdateRelease.Parse(json(assets: [zipAsset()]).Concat("x"u8.ToArray()).ToArray())) == UpdateFailure.InvalidResponse,
                  "unreadable answers are errors");

            // Digests: "sha256:<64 hex>" only; the file check catches a wrong size or a wrong hash.
            check(UpdateRelease.Sha256FromDigest("sha256:" + digest) == digest.ToLowerInvariant() && UpdateRelease.Sha256FromDigest(null) is null
                  && UpdateRelease.Sha256FromDigest("sha256:abc") is null && UpdateRelease.Sha256FromDigest("sha256:" + new string('g', 64)) is null
                  && UpdateRelease.Sha256FromDigest(digest) is null, "digest parsing");
            var sample = Path.Combine(folder, "digest-sample");
            File.WriteAllText(sample, "abc");
            const string abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
            check(UpdateInstaller.Digest(sample) == abc && failure(() => UpdateInstaller.Verify(sample, 3, abc)) is null
                  && failure(() => UpdateInstaller.Verify(sample, 4, abc)) == UpdateFailure.SizeMismatch
                  && failure(() => UpdateInstaller.Verify(sample, 3, new string('0', 64))) == UpdateFailure.DigestMismatch
                  && failure(() => UpdateInstaller.Verify(Path.Combine(folder, "missing"), 3, abc)) == UpdateFailure.SizeMismatch,
                  "SHA-256 of sample bytes, size and hash mismatches");

            // HTTP answers: ETag, 304, 404 and the rate-limit headers.
            UpdateResponse answer(int status, Dictionary<string, string>? headers = null, byte[]? body = null)
            {
                var lowered = (headers ?? []).ToDictionary(pair => pair.Key.ToLowerInvariant(), pair => pair.Value);
                return UpdateResponse.Interpret(status, name => lowered.GetValueOrDefault(name.ToLowerInvariant()), body ?? [], at);
            }
            UpdateResponse limited(double seconds) => new UpdateResponse.RateLimited(at.AddSeconds(seconds));
            UpdateResponse server(int status) => new UpdateResponse.Failed(UpdateFailure.Server(status));
            var latest = release ?? new UpdateRelease("0.9.1", "v0.9.1", UpdateClient.Releases);
            check(answer(200, new() { ["etag"] = "W/\"abc\"" }, json(assets: [zipAsset()])) == new UpdateResponse.Release(latest, "W/\"abc\"")
                  && answer(200, [], json(draft: true)) == new UpdateResponse.None()
                  && answer(200, [], "nope"u8.ToArray()) == new UpdateResponse.Failed(UpdateFailure.InvalidResponse)
                  && answer(304) == new UpdateResponse.NotModified() && answer(404) == new UpdateResponse.None(), "200, 304 and 404 answers");
            check(answer(403, new() { ["X-RateLimit-Remaining"] = "0", ["X-RateLimit-Reset"] = "1800000600" }) == limited(600)
                  && answer(429, new() { ["Retry-After"] = "120" }) == limited(120)
                  && answer(403, new() { ["Retry-After"] = "30", ["X-RateLimit-Remaining"] = "0", ["X-RateLimit-Reset"] = "1800000600" }) == limited(30)
                  && answer(403) == server(403) && answer(403, new() { ["X-RateLimit-Remaining"] = "12" }) == server(403) && answer(500) == server(500),
                  "403/429 pause on Retry-After or an exhausted limit; other errors back off");
            // GitHub's clock 6 h behind this PC: the reset is 10 minutes after the response's Date, not 6 h 10 min from now.
            check(UpdateResponse.HttpDate("Fri, 15 Jan 2027 02:00:00 GMT") == at.AddSeconds(-21_600)
                  && answer(403, new() { ["X-RateLimit-Remaining"] = "0", ["X-RateLimit-Reset"] = "1799979000", ["Date"] = "Fri, 15 Jan 2027 02:00:00 GMT" }) == limited(600)
                  && answer(429, new() { ["Retry-After"] = "inf" }) == server(429) && answer(429, new() { ["Retry-After"] = "nan" }) == server(429)
                  && answer(403, new() { ["X-RateLimit-Remaining"] = "0", ["X-RateLimit-Reset"] = "inf" }) == server(403)
                  && answer(403, new() { ["X-RateLimit-Remaining"] = "0", ["X-RateLimit-Reset"] = "1e300" }) is UpdateResponse.RateLimited,
                  "the reset is measured on GitHub's clock; non-finite values do not pause");

            // Schedule: backoff 1, 2, 4, 8 then 15 min; a rate limit pauses everything until it resets (at least a minute).
            check(Enumerable.Range(0, 7).Select(UpdateThrottle.Backoff).SequenceEqual([900.0, 60, 120, 240, 480, 900, 900]), "backoff schedule");
            var throttle = new UpdateThrottle();
            var delays = new List<double>();
            for (var i = 0; i < 3; i++) delays.Add(throttle.Record(new UpdateResponse.Failed(UpdateFailure.Network), at));
            var waits = !throttle.AllowsAutomatic(at.AddSeconds(239), at) && throttle.AllowsAutomatic(at.AddSeconds(240), at);
            // A wake 60 s into the 4-minute backoff waits the remaining 3 minutes, not 15 s.
            var wakeWait = throttle.BackoffRemaining(at.AddSeconds(60), at);
            var regular = throttle.Record(new UpdateResponse.NotModified(), at);
            check(delays.SequenceEqual([60.0, 120, 240]) && waits && wakeWait == 180 && regular == 900 && throttle.Failures == 0
                  && throttle.AllowsAutomatic(at, at) && throttle.BackoffRemaining(at, at) == 0,
                  "errors back off and automatic triggers, wake included, wait it out; an answer resets it");
            var paused = throttle.Record(limited(600), at);
            check(paused == 600 && !throttle.Allows(at.AddSeconds(599)) && throttle.Allows(at.AddSeconds(600)) && !throttle.AllowsAutomatic(at.AddSeconds(300), at),
                  "a rate limit pauses until its reset");
            check(throttle.Record(limited(-30), at) == 60 && throttle.PausedUntil == at.AddSeconds(60), "a reset already past still pauses a minute");
            check(throttle.Record(limited(86_400 * 30), at) == 3_600 && throttle.PausedUntil == at.AddSeconds(3_600),
                  "a reset far away (a wrong clock) pauses at most an hour");

            // Requests: fixed headers (a fixed language), If-None-Match only with a cached release; a 304 reuses it. The download
            // sends the same identity.
            using var client = new UpdateClient("0.9.0");
            using var plain = client.Request(null);
            using var conditional = client.Request("W/\"abc\"");
            using var download = new HttpRequestMessage(HttpMethod.Get, UpdateClient.Releases);
            UpdateClient.Identify(download, "0.9.0");
            static string? value(HttpRequestMessage request, string name) => request.Headers.TryGetValues(name, out var values) ? string.Join(",", values) : null;
            static string[] names(HttpRequestMessage request) => request.Headers.Select(header => header.Key.ToLowerInvariant()).Order().ToArray();
            check(plain.RequestUri == UpdateClient.Latest && plain.Method == HttpMethod.Get && value(plain, "If-None-Match") is null
                  && value(plain, "Accept") == "application/vnd.github+json" && value(plain, "X-GitHub-Api-Version") == "2022-11-28"
                  && value(plain, "User-Agent") == "TokenCat/0.9.0" && value(plain, "Accept-Language") == "en" && plain.Content is null
                  && names(plain).SequenceEqual(["accept", "accept-language", "user-agent", "x-github-api-version"])
                  && names(download).SequenceEqual(["accept-language", "user-agent"]) && value(download, "User-Agent") == "TokenCat/0.9.0"
                  && value(conditional, "If-None-Match") == "W/\"abc\"", "request headers");
            using var handler = UpdateClient.Handler();
            using var session = UpdateClient.Session(TimeSpan.FromSeconds(15));
            check(!handler.UseCookies && handler.Credentials is null && handler.DefaultProxyCredentials is null && !handler.PreAuthenticate
                  && session.Timeout == TimeSpan.FromSeconds(15), "ephemeral session without cache, cookies or credentials, 15 s timeout");
            var store = new UpdateStore(defaults);
            var noCache = store.ETagToSend is null;
            var first = store.Resolve(new UpdateResponse.Release(latest, "W/\"abc\""));
            var sendsETag = store.ETagToSend == "W/\"abc\"";
            var reused = store.Resolve(new UpdateResponse.NotModified());
            var stillLimited = store.Resolve(new UpdateResponse.RateLimited(at));
            check(noCache && first == new UpdateResult(latest, null) && sendsETag && reused == new UpdateResult(latest, null)
                  && stillLimited == new UpdateResult(null, UpdateFailure.RateLimited(at)) && store.Release == latest,
                  "a 304 reuses the cached release; a rate limit keeps the cache");
            var gone = store.Resolve(new UpdateResponse.None());
            var orphan = store.Resolve(new UpdateResponse.NotModified());
            check(gone == new UpdateResult(null, null) && store.Release is null && store.ETag is null && store.ETagToSend is null
                  && orphan == new UpdateResult(null, UpdateFailure.InvalidResponse), "404 clears the cache; a 304 without a cached release is an error");

            // Presentation and ✕ per version.
            var newer = new UpdateRelease("0.9.2", "v0.9.2", UpdateClient.Releases, latest.Asset);
            var state = new UpdateState { Check = new UpdateCheck.Done(), CheckedAt = at.AddSeconds(-180), Available = latest };
            check(state.Notice(null) == new UpdateNotice(UpdateNoticeKind.Available, "새 버전 0.9.1", "내려받아 설치한 뒤 TokenCat을 다시 엽니다", "0.9.1")
                  && state.Notice("0.9.1") is null, "the new-version notice hides for the dismissed version");
            state = state with { Available = newer };
            check(state.Notice("0.9.1")?.Text == "새 버전 0.9.2", "a newer version shows again after a dismissal");
            state = state with { Available = latest, Install = new UpdateInstall.Downloading(0.456) };
            check(state.Notice("0.9.1")?.Text == "업데이트 내려받는 중 45%" && state.Status(at).Title == "업데이트 내려받는 중 45%"
                  && state.QuickMenuTitle is null && !state.CanCheck && !state.CanInstall, "download progress");
            state = state with { Install = new UpdateInstall.Installing() };
            check(state.Notice(null)?.Text == "설치 중…" && state.Notice(null)?.Kind == UpdateNoticeKind.Installing, "installing");
            var failed = (state with { Install = new UpdateInstall.Failed(UpdateFailure.Network) }).Notice(null);
            state = state with { Install = new UpdateInstall.Failed(UpdateFailure.Translocated) };
            var blocked = state.Notice(null);
            // A failure that trying again cannot fix is not offered the install again; the quick menu opens the release page.
            var blockedInstall = new[] { UpdateFailure.Translocated, UpdateFailure.NotWritable, UpdateFailure.NoDigest, UpdateFailure.RelaunchFailed }.Any(reason =>
            {
                var copy = state with { Install = new UpdateInstall.Failed(reason) };
                return copy.CanInstall || copy.QuickMenuTitle != "업데이트 0.9.1 릴리스 페이지…" || copy.QuickMenuCommand != UpdateCommand.OpenReleasePage;
            });
            state = state with { Install = new UpdateInstall.Failed(UpdateFailure.Network) };
            check(failed is { Text: "업데이트 실패", Detail: "네트워크 오류", Kind: UpdateNoticeKind.Failed, Retryable: true }
                  && blocked is { Kind: UpdateNoticeKind.Failed, Retryable: false, Detail: "임시 위치에서 실행 중" }
                  && new UpdateState { Install = new UpdateInstall.Failed(UpdateFailure.Translocated) }.Status(at) == ("업데이트 실패", "임시 위치에서 실행 중", true)
                  && !blockedInstall && state.CanInstall && state.QuickMenuTitle == "업데이트 0.9.1 설치…" && state.QuickMenuCommand == UpdateCommand.Install,
                  "failures: short reason, retry only when it can help; a blocked install offers the release page instead");
            // A newer release than the failed one can be installed again; the same release keeps the failure.
            var blockedState = (state with { Install = new UpdateInstall.Failed(UpdateFailure.NotWritable) }).Receive(latest);
            var sameKept = !blockedState.CanInstall && blockedState.InstallFailure == UpdateFailure.NotWritable;
            blockedState = blockedState.Receive(newer);
            var downloading = (state with { Install = new UpdateInstall.Downloading(0.1) }).Receive(newer);
            check(sameKept && blockedState.CanInstall && blockedState.InstallFailure is null && blockedState.QuickMenuTitle == "업데이트 0.9.2 설치…"
                  && downloading.Install == new UpdateInstall.Downloading(0.1), "a newer release clears a blocking failure; a download in progress is untouched");
            state = state with { Install = new UpdateInstall.None() };
            check(state.Status(at) == ("새 버전 0.9.1", "3분 전 확인", false) && state.QuickMenuTitle == "업데이트 0.9.1 설치…",
                  "Settings line and quick menu item with a new version");
            state = state with { Available = null };
            check(state.Status(at) == ("최신 버전입니다 · 3분 전 확인", null, false)
                  && new UpdateState { CheckedAt = at.AddSeconds(-20) }.Status(at).Title == "최신 버전입니다 · 방금 확인"
                  && new UpdateState().Status(at).Title == "아직 확인하지 않았습니다"
                  && new UpdateState { Check = new UpdateCheck.Checking() }.Status(at).Title == "확인 중…" && !new UpdateState { Check = new UpdateCheck.Checking() }.CanCheck
                  && new UpdateState { Check = new UpdateCheck.Failed(UpdateFailure.Network) }.Status(at) == ("확인하지 못했습니다", UpdateFailure.Network.Text, true)
                  && new UpdateState { Disabled = "TokenCat.exe로 실행할 때만 업데이트를 확인합니다" }.Status(at).Title == "TokenCat.exe로 실행할 때만 업데이트를 확인합니다"
                  && state.QuickMenuTitle is null, "Settings status lines");
            check(new UpdateState { UpdatedTo = "0.9.1" }.Notice(null)?.Text == "0.9.1로 업데이트했습니다"
                  && UpdateState.Updated("0.9.10") == "0.9.10으로 업데이트했습니다" && UpdateState.Updated("1.3") == "1.3으로 업데이트했습니다"
                  && UpdateState.Updated("0.9.7") == "0.9.7로 업데이트했습니다", "the one-time note after an update");
            var fivePast = new DateTimeOffset(DateTime.SpecifyKind(at.LocalDateTime.Date.AddHours(14).AddMinutes(5), DateTimeKind.Local));
            check(UpdateFailure.RateLimited(fivePast).Text.Contains("14:05")
                  && new[] { UpdateFailure.Network, UpdateFailure.NoAsset, UpdateFailure.NoDigest, UpdateFailure.DigestMismatch, UpdateFailure.NotWritable,
                             UpdateFailure.Translocated, UpdateFailure.InvalidBundle("x") }.All(reason => reason.Text.Length > 0 && reason.Short.Length > 0)
                  && UpdateFailure.NoAsset.Text.Contains("TokenCat-Windows.zip"),
                  "failure texts");
            Lang.With(AppLanguage.En, () =>
            {
                var english = new UpdateState { Check = new UpdateCheck.Done(), CheckedAt = at.AddSeconds(-180), Available = latest };
                var available = english.Status(at) == ("New version 0.9.1", "Checked 3m ago", false)
                                && english.Notice(null)?.Text == "New version 0.9.1" && english.QuickMenuTitle == "Install Update 0.9.1…";
                english = english with { Install = new UpdateInstall.Downloading(0.456) };
                var progress = english.Notice(null)?.Text == "Downloading update 45%";
                english = english with { Install = new UpdateInstall.Failed(UpdateFailure.Translocated) };
                var englishBlocked = english.Notice(null) is { Text: "Update failed", Detail: "Running from a temporary location" }
                                     && english.QuickMenuTitle == "Update 0.9.1 Release Page…";
                check(available && progress && englishBlocked
                      && new UpdateState { CheckedAt = at.AddSeconds(-20) }.Status(at).Title == "Up to date · Checked just now"
                      && new UpdateState { UpdatedTo = "0.9.10" }.Notice(null)?.Text == "Updated to 0.9.10"
                      && UpdateFailure.InvalidBundle("x").Text == "Couldn't verify the new app, so it wasn't installed: x.",
                      "English status lines, notices and quick menu items");
            });

            // Install guards, before any download.
            const string installed = @"C:\Users\me\AppData\Local\Programs\TokenCat\TokenCat.exe";
            check(UpdateInstaller.Blocker(installed, _ => true) is null
                  && UpdateInstaller.Blocker(Path.Combine(Path.GetTempPath(), "Temp1_TokenCat-Windows.zip", "TokenCat.exe"), _ => true) == UpdateFailure.Translocated
                  && UpdateInstaller.Blocker(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Temp",
                      "Temp1_TokenCat-Windows.zip", "TokenCat.exe"), _ => true) == UpdateFailure.Translocated
                  && UpdateInstaller.Blocker(@"C:\work\windows\TokenCat.Checks\bin\Release\net10.0\TokenCat.Checks.exe", _ => true) == UpdateFailure.NotBundle
                  && UpdateInstaller.Blocker(installed, path => path != @"C:\Users\me\AppData\Local\Programs\TokenCat") == UpdateFailure.NotWritable
                  && UpdateInstaller.Blocker("C:/Users/me/AppData/Local/Programs/TokenCat/tokencat.EXE", _ => true) is null
                  && UpdateInstaller.Blocker(Path.Combine(folder, "TokenCat.exe")) == UpdateFailure.Translocated,
                  "install guards: a temporary folder, not TokenCat.exe, not writable");

            // The controller without the network: disabled copies make no request; discovery and the update note happen once.
            var raw = new Updater(@"C:\work\bin\TokenCat.Checks.exe", "0.9.0", defaults);
            raw.Start(automatic: true);
            raw.CheckNow();
            raw.Install();
            check(raw.State.Disabled is not null && raw.State.Check is UpdateCheck.Idle && raw.State.Install is UpdateInstall.None,
                  "a raw binary never checks or installs");
            raw.Stop();
            store.InstalledVersion = "0.9.0";
            store.Release = newer;
            var app = new Updater(installed, "0.9.0", defaults);
            var discovered = new List<string>();
            app.Discovered += found => discovered.Add(found.Version);
            app.Start(automatic: false);
            var restored = app.State.UpdatedTo == "0.9.0" && store.InstalledVersion is null && app.State.Available == newer;
            app.Apply(latest);
            app.Apply(latest);
            var once = discovered.SequenceEqual(["0.9.1"]) && app.State.Available == latest;
            app.Apply(new UpdateRelease("0.8.0", "v0.8.0", UpdateClient.Releases, latest.Asset));
            var older = app.State.Available is null;
            app.Apply(null);
            check(restored && once && older && app.State.Available is null && app.State.Check is UpdateCheck.Done,
                  "cache at launch, one discovery per version, older ignored");
            app.Apply(new UpdateRelease("0.9.5", "v0.9.5", UpdateClient.Releases));
            check(app.State.Available is null && discovered.Count == 1, "a newer release without TokenCat-Windows.zip is not offered (DESIGN §9)");
            app.Stop();
            store.InstalledVersion = "0.8.0";
            store.PausedUntil = DateTimeOffset.UtcNow.AddDays(30);
            var stale = new Updater(installed, "0.9.0", defaults);
            stale.Start(automatic: false);
            check(stale.State.UpdatedTo is null && store.InstalledVersion is null, "a note for another version is dropped");
            check(store.PausedUntil is null, "a stored pause longer than an hour (a wrong clock) is dropped at launch");
            stale.Stop();

            // The install steps on temp files: a zip laid out like the release, extract's entry rules, the version check,
            // rename-replace, and the cleanup the relaunched copy runs.
            var exe = Path.Combine(folder, "app", UpdateInstaller.ExeName);
            Directory.CreateDirectory(Path.GetDirectoryName(exe)!);
            File.WriteAllText(exe, "old");
            var staging = UpdateInstaller.StagingFolder(exe);
            Directory.CreateDirectory(staging);
            string zip(string name, params string[] entries)
            {
                var path = Path.Combine(staging, name);
                using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
                foreach (var entry in entries)
                {
                    using var writer = new StreamWriter(archive.CreateEntry(entry).Open());
                    writer.Write(entry == UpdateInstaller.ExeName ? "new" : "text");
                }
                return path;
            }
            var good = zip("good.zip", UpdateInstaller.ExeName, "LICENSE");
            var size = new FileInfo(good).Length;
            var sha256 = UpdateInstaller.Digest(good);
            check(size > 0 && failure(() => UpdateInstaller.Verify(good, size, sha256)) is null
                  && failure(() => UpdateInstaller.Verify(good, size + 1, sha256)) == UpdateFailure.SizeMismatch
                  && failure(() => UpdateInstaller.Verify(good, size, new string('0', 64))) == UpdateFailure.DigestMismatch,
                  "the release zip verifies by size and SHA-256");
            var fresh = "";
            var refused = UpdateFailure.InvalidBundle("압축 파일에 TokenCat.exe와 LICENSE만 있어야 합니다");
            string extracted(string name) => Path.Combine(staging, name);
            check(failure(() => fresh = UpdateInstaller.Extract(good, extracted("extracted"))) is null && File.ReadAllText(fresh) == "new"
                  && File.Exists(Path.Combine(extracted("extracted"), "LICENSE"))
                  && failure(() => UpdateInstaller.Extract(zip("only.zip", UpdateInstaller.ExeName), extracted("only"))) is null
                  && failure(() => UpdateInstaller.Extract(zip("two.zip", UpdateInstaller.ExeName, "Other.exe"), extracted("two"))) == refused
                  && failure(() => UpdateInstaller.Extract(zip("slip.zip", "../TokenCat.exe"), extracted("slip"))) == refused
                  && failure(() => UpdateInstaller.Extract(zip("nested.zip", "TokenCat/TokenCat.exe"), extracted("nested"))) == refused
                  && failure(() => UpdateInstaller.Extract(zip("double.zip", UpdateInstaller.ExeName, UpdateInstaller.ExeName), extracted("double"))) == refused
                  && failure(() => UpdateInstaller.Extract(sample, extracted("bad"))) == UpdateFailure.ExtractFailed
                  && !Directory.Exists(extracted("two")) && !File.Exists(Path.Combine(staging, UpdateInstaller.ExeName)),
                  "an archive with more than TokenCat.exe (and LICENSE) is refused before anything is written");
            var mismatch = UpdateFailure.InvalidBundle("앱 버전이 릴리스와 다릅니다");
            var assembly = typeof(UpdateInstaller).Assembly.Location;
            if (assembly.Length == 0) c.Skip(); // single-file App: no assembly on disk; --update-selftest validates the real exe
            else
                check(failure(() => UpdateInstaller.Validate(assembly, Updater.CurrentVersion)) is null && failure(() => UpdateInstaller.Validate(assembly, "99.0.0")) == mismatch
                      && failure(() => UpdateInstaller.Validate(fresh, Updater.CurrentVersion)) == mismatch
                      && failure(() => UpdateInstaller.Validate(Path.Combine(folder, "missing.exe"), "0.9.0")) == UpdateFailure.InvalidBundle("앱 정보를 읽지 못했습니다"),
                      "validate reads the version the build wrote into the file");
            var swapped = failure(() => UpdateInstaller.Replace(exe, fresh)) is null && File.ReadAllText(exe) == "new" && File.ReadAllText(exe + ".old") == "old"
                          && !File.Exists(fresh);
            File.WriteAllText(fresh, "newer");
            var again = failure(() => UpdateInstaller.Replace(exe, fresh)) is null && File.ReadAllText(exe) == "newer" && File.ReadAllText(exe + ".old") == "new";
            var putBack = failure(() => UpdateInstaller.Replace(exe, Path.Combine(folder, "nothing.exe"))) == UpdateFailure.ReplaceFailed
                          && File.ReadAllText(exe) == "newer";
            var missing = failure(() => UpdateInstaller.Replace(Path.Combine(folder, "gone", UpdateInstaller.ExeName), exe)) == UpdateFailure.ReplaceFailed
                          && File.Exists(exe);
            check(swapped && again && putBack && missing,
                  "replace renames the running copy to TokenCat.exe.old and moves the new one in; a failed move puts the old one back");
            check(failure(() => UpdateInstaller.Relaunch(Path.Combine(folder, "missing", UpdateInstaller.ExeName))) == UpdateFailure.RelaunchFailed,
                  "a relaunch that cannot start reports relaunchFailed");
            File.WriteAllText(Path.Combine(staging, "marker"), "");
            UpdateInstaller.Cleanup(exe);
            check(!File.Exists(exe + ".old") && !Directory.Exists(staging) && File.Exists(exe),
                  "after an update the relaunched copy removes TokenCat.exe.old and TokenCat.update, nothing else");
        }
        finally { Directory.Delete(folder, true); }
        return c.Done();
    }
}
