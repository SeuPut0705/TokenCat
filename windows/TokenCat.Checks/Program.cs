using System.Globalization;
using TokenCat;

// Swift's interpolation and String(format:) ignore the user's locale; culture-specific text names its culture
// (Lang.Culture, ko-KR). The App's Main does the same.
CultureInfo.DefaultThreadCurrentCulture = CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

// dotnet run --project windows/TokenCat.Checks -c Release [-- --diagnose-tokens [home] | -- --telemetry-lifecycle-checks [port]]
if (args is ["--diagnose-tokens", .. var home]) return TokenDiagnostics.Run(home is [var path, ..] ? path : AppPaths.Home);
if (args is ["--telemetry-lifecycle-checks", .. var port])
    return Suites.Report(TelemetryLifecycleChecks.Run(port is [var text, ..] && int.TryParse(text, out var value) ? value : null));
return Suites.Report(Suites.RunAll());
