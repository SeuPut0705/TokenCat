using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using static TokenCat.Lang;

namespace TokenCat;

/// The install steps (DESIGN §9), each usable on its own; `SelfTest` runs them on a copy of the running exe. NTFS lets a running
/// image be renamed but not overwritten or deleted: TokenCat.exe → TokenCat.exe.old, the new exe moves in, it is started with
/// `--after-update <pid>`, and that copy removes TokenCat.exe.old and TokenCat.update\ once this process has exited.
public static class UpdateInstaller
{
    public const string ExeName = "TokenCat.exe";

    /// Paths are split on both separators: checks on macOS use Windows paths, where Path.GetFileName would not split on '\'.
    public static bool IsExe(string path) => string.Equals(FileName(path), ExeName, StringComparison.OrdinalIgnoreCase);

    static string FileName(string path) => path[(path.LastIndexOfAny(['\\', '/']) + 1)..];
    static string Folder(string path) => path[..Math.Max(0, path.LastIndexOfAny(['\\', '/']))];

    /// The download and extraction folder: next to the exe, so the final moves are renames on one volume.
    public static string StagingFolder(string exe) => Path.Combine(Folder(exe), "TokenCat.update");

    /// Why this copy cannot replace itself in place; checked before anything is downloaded. Explorer runs an exe opened inside
    /// a zip from %TEMP%, mac's App Translocation counterpart.
    public static UpdateFailure? Blocker(string exe, Func<string, bool>? isWritable = null)
    {
        if (!IsExe(exe)) return UpdateFailure.NotBundle;
        if (InTemporaryFolder(exe)) return UpdateFailure.Translocated;
        return (isWritable ?? CanWrite)(Folder(exe)) ? null : UpdateFailure.NotWritable;
    }

    /// Under %TEMP% as given, or under its usual long form %LOCALAPPDATA%\Temp: a user name over 8 characters gets an 8.3
    /// TEMP (C:\Users\LONGNA~1\…) while the exe path may be spelled long. ponytail: compares strings; GetLongPathName via
    /// the App if another spelling ever shows up on a PC.
    public static bool InTemporaryFolder(string path)
    {
        static string Normalized(string text) => text.Replace('\\', '/');
        string[] temporary = [Path.GetTempPath(), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Temp")];
        return temporary.Any(temp => Normalized(path).StartsWith(Normalized(temp).TrimEnd('/') + "/", StringComparison.OrdinalIgnoreCase));
    }

    /// Windows has no reliable access() for folders: create and drop a file (Program Files without admin fails here).
    static bool CanWrite(string folder)
    {
        try
        {
            using (File.Create(Path.Combine(folder, $".tokencat-{Guid.NewGuid():N}.tmp"), 1, FileOptions.DeleteOnClose)) { }
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
    }

    /// Streams the asset into `staging`, reporting whole percents. Anything but a complete 200 answer is a network failure;
    /// a cancel throws OperationCanceledException.
    public static async Task<string> Download(UpdateAsset asset, string staging, string version, IProgress<double> progress, CancellationToken cancel)
    {
        try { Directory.CreateDirectory(staging); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new UpdateError(UpdateFailure.NotWritable); }
        var target = Path.Combine(staging, UpdateRelease.AssetName);
        try
        {
            using var session = UpdateClient.Session(TimeSpan.FromSeconds(600));
            using var request = new HttpRequestMessage(HttpMethod.Get, asset.Url);
            UpdateClient.Identify(request, version);
            using var response = await session.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel).ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.OK) throw new UpdateError(UpdateFailure.Network);
            var total = asset.Size > 0 ? asset.Size : response.Content.Headers.ContentLength ?? 0;
            await using var source = await response.Content.ReadAsStreamAsync(cancel).ConfigureAwait(false);
            await using var file = File.Create(target);
            var buffer = new byte[1 << 16];
            long written = 0;
            var shown = -1;
            int read;
            while ((read = await source.ReadAsync(buffer, cancel).ConfigureAwait(false)) > 0)
            {
                await file.WriteAsync(buffer.AsMemory(0, read), cancel).ConfigureAwait(false);
                written += read;
                if (total <= 0) continue;
                var percent = (int)Math.Min(100, written * 100 / total);
                if (percent == shown) continue;
                shown = percent;
                progress.Report(percent / 100.0);
            }
        }
        catch (Exception error) when (error is HttpRequestException or IOException
                                      || error is OperationCanceledException && !cancel.IsCancellationRequested)
        {
            throw new UpdateError(UpdateFailure.Network);
        }
        return target;
    }

    /// Verify → extract → validate → replace; only UpdateErrors leave it. A cancel before the swap fails it, after it the swap stands.
    public static void Install(string archive, string staging, string exe, long size, string sha256, string version, CancellationToken cancel)
    {
        try
        {
            Verify(archive, size, sha256);
            var fresh = Extract(archive, Path.Combine(staging, "extracted"));
            Validate(fresh, version);
            if (cancel.IsCancellationRequested) throw new UpdateError(UpdateFailure.ReplaceFailed);
            Replace(exe, fresh);
        }
        catch (Exception error) when (error is not UpdateError) { throw new UpdateError(UpdateFailure.ReplaceFailed); }
    }

    /// Size first, then SHA-256.
    public static void Verify(string file, long size, string sha256)
    {
        long actual;
        try { actual = new FileInfo(file).Length; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { actual = -1; }
        if (actual != size) throw new UpdateError(UpdateFailure.SizeMismatch);
        string? digest;
        try { digest = Digest(file); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { digest = null; }
        if (digest != sha256) throw new UpdateError(UpdateFailure.DigestMismatch);
    }

    /// Lowercase hex SHA-256.
    public static string Digest(string file)
    {
        using var stream = File.OpenRead(file);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    /// Exactly TokenCat.exe, optionally with LICENSE, as flat entries; nothing else is written, so no entry can leave `folder`.
    public static string Extract(string archive, string folder)
    {
        try
        {
            using var zip = ZipFile.OpenRead(archive);
            var names = zip.Entries.Select(entry => entry.FullName).Order(StringComparer.Ordinal).ToArray();
            if (names is not ([ExeName] or ["LICENSE", ExeName]))
                throw new UpdateError(UpdateFailure.InvalidBundle(Loc("압축 파일에 TokenCat.exe와 LICENSE만 있어야 합니다",
                                                                      "the archive must hold only TokenCat.exe and LICENSE")));
            Directory.CreateDirectory(folder);
            foreach (var entry in zip.Entries) entry.ExtractToFile(Path.Combine(folder, entry.FullName), overwrite: true);
        }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            throw new UpdateError(UpdateFailure.ExtractFailed);
        }
        return Path.Combine(folder, ExeName);
    }

    /// The release's version in the exe's ProductVersion (mac: CFBundleShortVersionString). Only a Windows-built exe carries it
    /// (DESIGN §1 #11), so this also proves it is a PE with our version resource. x64 only: no machine check (open question 4).
    public static void Validate(string exe, string version)
    {
        FileVersionInfo info;
        try { info = FileVersionInfo.GetVersionInfo(exe); }
        catch (FileNotFoundException) { throw new UpdateError(UpdateFailure.InvalidBundle(Loc("앱 정보를 읽지 못했습니다", "couldn't read the app's information"))); }
        if (AppVersion.Parse(info.ProductVersion) is not { } shipped || shipped != AppVersion.Parse(version))
            throw new UpdateError(UpdateFailure.InvalidBundle(Loc("앱 버전이 릴리스와 다릅니다", "the app version doesn't match the release")));
    }

    /// TokenCat.exe → TokenCat.exe.old (allowed while it runs), then the new exe into its place. Each move is retried
    /// (Defender scans a fresh exe and holds it briefly); if the second fails, the old exe moves back.
    public static void Replace(string exe, string fresh)
    {
        var old = exe + ".old";
        try { Retry(() => File.Move(exe, old, overwrite: true)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new UpdateError(UpdateFailure.ReplaceFailed); }
        try { Retry(() => File.Move(fresh, exe)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            try { File.Move(old, exe); }
            catch (Exception back) when (back is IOException or UnauthorizedAccessException) { }
            throw new UpdateError(UpdateFailure.ReplaceFailed);
        }
    }

    /// Starts `exe --after-update <pid>` from its folder. No handle is passed on (.NET opens sockets and files non-inheritable),
    /// so the new copy never holds the collector's port; it waits for `pid` itself.
    public static Process Relaunch(string exe, int? pid = null)
    {
        try
        {
            var start = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Folder(exe) };
            start.ArgumentList.Add("--after-update");
            start.ArgumentList.Add((pid ?? Environment.ProcessId).ToString(CultureInfo.InvariantCulture));
            return Process.Start(start) ?? throw new UpdateError(UpdateFailure.RelaunchFailed);
        }
        catch (Exception error) when (error is Win32Exception or IOException or InvalidOperationException)
        {
            throw new UpdateError(UpdateFailure.RelaunchFailed);
        }
    }

    /// `--after-update <pid>`: waits for the old process (≤ 60 s; 0 waits for nothing), then removes TokenCat.exe.old and
    /// TokenCat.update\. The App takes the single-instance mutex after this returns.
    public static void FinishAfterUpdate(int pid)
    {
        if (pid > 0)
        {
            try
            {
                using var old = Process.GetProcessById(pid);
                old.WaitForExit(TimeSpan.FromSeconds(60));
            }
            catch (Exception error) when (error is ArgumentException or InvalidOperationException) { } // already gone
        }
        Cleanup(Environment.ProcessPath ?? "");
    }

    /// Best effort: what stays is retried at the next launch (Updater.Start).
    public static void Cleanup(string exe)
    {
        var old = exe + ".old";
        try { if (File.Exists(old)) Retry(() => File.Delete(old)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        RemoveFolder(StagingFolder(exe));
    }

    public static void RemoveFolder(string folder)
    {
        try { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    static void Retry(Action action)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (Exception error) when (attempt < 3 && error is IOException or UnauthorizedAccessException) { Thread.Sleep(200); }
        }
    }

    /// `--update-selftest <zip>`: the real release zip against a copy of the running exe in a temp folder: verify, extract
    /// (its entry rules), validate (its version), then the production order on NTFS: the copy runs (the old app), is renamed
    /// to TokenCat.exe.old while running, the new exe moves in and starts with `--after-update <old pid>`, the old one exits,
    /// and the new one removes TokenCat.exe.old and the update folder (with a marker file in it). Both are then stopped.
    /// Returns the exit code.
    public static int SelfTest(string zip)
    {
        var c = new Check("Update self-test", "Updater: ");
        void check(bool valid, string description) => c.That(valid, description);
        static UpdateFailure? Fails(Action body)
        {
            try
            {
                body();
                return null;
            }
            catch (UpdateError error) { return error.Failure; }
        }

        var running = Environment.ProcessPath ?? "";
        var root = Directory.CreateTempSubdirectory("TokenCat-update-selftest-").FullName;
        Process? old = null, copy = null;
        try
        {
            var installed = Path.Combine(root, "app", ExeName);
            var staging = StagingFolder(installed);
            Directory.CreateDirectory(staging);
            File.Copy(running, installed);
            var archive = Path.Combine(staging, UpdateRelease.AssetName);
            File.Copy(zip, archive);
            var size = new FileInfo(archive).Length;
            var sha256 = Digest(archive);
            check(size > 0 && Fails(() => Verify(archive, size, sha256)) is null
                  && Fails(() => Verify(archive, size + 1, sha256)) == UpdateFailure.SizeMismatch
                  && Fails(() => Verify(archive, size, new string('0', 64))) == UpdateFailure.DigestMismatch,
                  "the release zip verifies by size and SHA-256");
            var fresh = "";
            check(Fails(() => fresh = Extract(archive, Path.Combine(staging, "extracted"))) is null && File.Exists(fresh)
                  && Fails(() => Validate(fresh, Updater.CurrentVersion)) is null
                  && Fails(() => Validate(fresh, "99.0.0")) == UpdateFailure.InvalidBundle(Loc("앱 버전이 릴리스와 다릅니다", "the app version doesn't match the release")),
                  "extract yields TokenCat.exe with this version");
            check(Blocker(installed) == UpdateFailure.Translocated, "a copy in the temporary folder is refused before any download");
            if (!File.Exists(fresh)) return Suites.Report(c.Done());

            string runningDigest = Digest(installed), freshDigest = Digest(fresh);
            // The "old app": a running image of the copy (it waits on this process, so it stays up until it is stopped below).
            old = Relaunch(installed);
            check(Fails(() => Replace(installed, fresh)) is null && Digest(installed) == freshDigest && Digest(installed + ".old") == runningDigest
                  && !File.Exists(fresh), "replace renames the running copy to TokenCat.exe.old and moves the new one in");
            File.WriteAllBytes(Path.Combine(staging, "marker"), []);
            var started = Fails(() => copy = Relaunch(installed, old.Id)) is null;
            // The old app quits after relaunching; the new copy then deletes its image.
            old.Kill();
            old.WaitForExit(5_000);
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (started && DateTime.UtcNow < deadline && (File.Exists(installed + ".old") || Directory.Exists(staging))) Thread.Sleep(200);
            check(started && !File.Exists(installed + ".old") && !Directory.Exists(staging),
                  "the relaunched copy (--after-update) removes TokenCat.exe.old and the update folder once the old one has exited");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            check(false, $"the self-test could not prepare its copy: {error.Message}");
        }
        finally
        {
            foreach (var process in new[] { old, copy })
            {
                if (process is null) continue;
                try
                {
                    if (!process.HasExited) process.Kill();
                    process.WaitForExit(5_000);
                }
                catch (Exception error) when (error is InvalidOperationException or Win32Exception) { }
                process.Dispose();
            }
            try { Retry(() => Directory.Delete(root, recursive: true)); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return Suites.Report(c.Done());
    }
}
