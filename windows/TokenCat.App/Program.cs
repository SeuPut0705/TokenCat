using System.Globalization;
using System.Windows;
using TokenCat;
using static TokenCat.Lang;
using Forms = System.Windows.Forms;

// Entry.swift for Windows: CLI flags first (they never take the single-instance mutex), then the tray app (DESIGN §2.9, §7.7).
static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // Swift's interpolation and String(format:) ignore the user's locale; culture-specific text names its culture.
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        if (Command(args) is { } exit) return exit;

        // `--after-update <pid>`: the new copy waits for the old one, then removes TokenCat.exe.old (§9).
        if (Value(args, "--after-update") is { } pid && int.TryParse(pid, out var old)) UpdateInstaller.FinishAfterUpdate(old);

        // One per user session. A second launch lets the first take the foreground (only the launched process may grant
        // it), signals it to open the dashboard and exits.
        using var mutex = new Mutex(true, @"Local\dev.seuput.TokenCat", out var first);
        if (!first)
        {
            try { first = mutex.WaitOne(0); }
            catch (AbandonedMutexException) { first = true; } // a crashed holder: the mutex is ours now
        }
        using var openRequest = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\dev.seuput.TokenCat.open");
        if (!first)
        {
            Native.AllowSetForegroundWindow(Native.ASFW_ANY);
            openRequest.Set();
            return 0;
        }

        Forms.Application.SetColorMode(Forms.SystemColorMode.System);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        // The Updater (a Shell field) posts its timers back through the context it is created on; Run() hasn't installed one yet.
        SynchronizationContext.SetSynchronizationContext(new System.Windows.Threading.DispatcherSynchronizationContext(app.Dispatcher));
        var shell = new Shell(app);
        var registration = ThreadPool.RegisterWaitForSingleObject(openRequest,
            (_, _) => app.Dispatcher.BeginInvoke(shell.OpenAtCorner), null, -1, false);
        app.Startup += (_, _) => shell.Start();
        try { return app.Run(); }
        finally { registration.Unregister(null); }
    }

    static string? Value(string[] args, string flag)
    {
        var index = Array.IndexOf(args, flag);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    /// The CLI (Entry.swift's flags plus Windows' own). Null runs the app.
    static int? Command(string[] args)
    {
        string[] flags = ["--self-test", "--telemetry-lifecycle-checks", "--connect-telemetry", "--disconnect-telemetry", "--telemetry-readings",
            "--update-check", "--update-selftest", "--diagnose", "--snapshot"];
        var language = FlagValue(args);
        if (!args.Any(flags.Contains) && (language is null || Parse(language) is not null)) return null;
        Native.UseParentConsole();
        // `--language ko|en` picks the display language for any command, including the app itself.
        if (language is not null && Parse(language) is null)
        {
            Console.WriteLine($"Unknown --language '{language}': ko or en");
            return 1;
        }
        if (args.Contains("--self-test"))
        {
            // Existing suites assert Korean text; the localization suite switches to English where it checks it.
            Current = AppLanguage.Ko;
            List<string> failures = [.. AppChecks.Run(), .. Suites.RunAll()];
            return Suites.Report(failures);
        }
        // Opens real loopback listeners on two free test ports (never the app's port), so it stays out of --self-test.
        if (args.Contains("--telemetry-lifecycle-checks"))
            return Suites.Report(TelemetryLifecycleChecks.Run(int.TryParse(Value(args, "--telemetry-lifecycle-checks"), out var port) ? port : null));
        if (args.Contains("--connect-telemetry") || args.Contains("--disconnect-telemetry")) return ConnectTelemetry(args.Contains("--connect-telemetry"));
        if (args.Contains("--telemetry-readings"))
        {
            if (!TelemetryCollector.IsOwnCollectorRunning(TimeSpan.FromSeconds(1))) return 1;
            Console.WriteLine(System.Text.Encoding.UTF8.GetString(Json.Serialize(TelemetryCollector.FetchSnapshot(TimeSpan.FromSeconds(1)))).TrimEnd());
            return 0;
        }
        // Read-only: one GET of the latest release, printed; nothing is stored, downloaded or installed.
        if (args.Contains("--update-check")) return Updater.CommandLineCheck();
        if (args.Contains("--update-selftest"))
        {
            if (Value(args, "--update-selftest") is not { } zip) { Console.WriteLine("--update-selftest <zip>"); return 1; }
            return UpdateInstaller.SelfTest(zip);
        }
        if (args.Contains("--diagnose"))
        {
            var sampler = new WindowsSystemSampler();
            sampler.Sample();
            Thread.Sleep(1000);
            var system = sampler.Sample();
            var tokens = TokenSpeed.Apply(new TokenTracker(AppPaths.Home).Sample(), TelemetryCollector.FetchSnapshot(TimeSpan.FromSeconds(1)));
            Console.WriteLine(System.Text.Encoding.UTF8.GetString(Json.Serialize(new { system, tokens })).TrimEnd());
            return 0;
        }
        if (args.Contains("--snapshot"))
        {
            if (Value(args, "--snapshot") is not { } directory) { Console.WriteLine("--snapshot <dir>"); return 1; }
            return Snapshot.Write(directory);
        }
        return null;
    }

    /// The app's automatic connection follows the last command, a refused disconnect included: the intent is the same.
    static int ConnectTelemetry(bool connect)
    {
        SettingsStore.Shared.Set(TelemetrySetup.OptOutKey, !connect);
        // A failed write is silent in the store; an unsaved opt-out would let the next launch reconnect.
        if (SettingsStore.Shared.Get<bool?>(TelemetrySetup.OptOutKey) != !connect)
        {
            Console.WriteLine(Loc("TokenCat 설정 파일을 저장하지 못해 아무것도 바꾸지 않았습니다.", "Couldn't save TokenCat's settings file, so nothing was changed."));
            return 1;
        }
        if (connect &&!TelemetryCollector.IsOwnCollectorRunning(TimeSpan.FromSeconds(1)))
        {
            Console.WriteLine(Loc("실행 중인 TokenCat 로컬 수집기가 없습니다. 앱을 먼저 실행하세요.", "No TokenCat collector is running. Open the app first."));
            return 1;
        }
        try
        {
            var setup = new TelemetrySetup(AppPaths.Home, AppPaths.Support);
            var result = connect ? setup.Connect() : setup.Disconnect();
            Console.WriteLine(result.Message);
            var count = result.ChangedFiles.Count;
            var names = string.Join(", ", result.RestartRequired.Select(source => source.Title));
            Console.WriteLine(Loc($"변경 파일 {count}개 · 다음 실행부터 적용: {names}", $"{Plural(count, "file")} changed · applies from the next launch: {names}"));
            return 0;
        }
        catch (Exception error)
        {
            Console.WriteLine(Loc($"실측 연결: {error.Message}", $"Telemetry: {error.Message}"));
            return 1;
        }
    }
}
