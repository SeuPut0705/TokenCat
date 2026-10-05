namespace TokenCat;

/// TokenSpeedChecks.swift, descriptions verbatim.
public static class TokenSpeedChecks
{
    public static List<string> Run()
    {
        var c = new Check("Token speed", "Token speed ");
        void check(string name, bool condition) => c.That(condition, name);
        var at = DateTimeOffset.Parse("2026-10-04T10:00:00Z", System.Globalization.CultureInfo.InvariantCulture);
        var reading = new TelemetryReading { Provider = TokenSource.Codex, At = at, Model = "same-model" };

        var server = reading with { SessionID = "a", ServerTokenIntervalMs = 40, ServerTokenIntervalSampleCount = 1, OutputTokens = 200, RequestDurationMs = 1_000 };
        var serverSpeed = new TokenSpeedMeasurement(server);
        check("server interval gives generation rate, not request rate", serverSpeed.Kind == TokenRateKind.ServerGeneration && serverSpeed.TokensPerSecond == 25);
        var request = reading with { Provider = TokenSource.Claude, SessionID = "a", OutputTokens = 120, RequestDurationMs = 2_400 };
        var requestSpeed = new TokenSpeedMeasurement(request);
        check("exact request fields give distinct processing rate", requestSpeed.Kind == TokenRateKind.RequestProcessing && requestSpeed.TokensPerSecond == 50);
        var timingOnly = reading with { OutputTokens = 1_000, ServerInferenceMs = 10, TtftMs = 1 };
        check("inference or TTFT cannot substitute a matched duration", new TokenSpeedMeasurement(timingOnly).TokensPerSecond == null);
        var invalid = server with { ServerTokenIntervalMs = double.PositiveInfinity, OutputTokens = null, RequestDurationMs = null };
        check("nonfinite fields produce no speed", new TokenSpeedMeasurement(invalid).TokensPerSecond == null);
        var zeroDuration = reading with { OutputTokens = 120, RequestDurationMs = 0, ServerTokenIntervalMs = 0 };
        check("zero time never produces invented speed", new TokenSpeedMeasurement(zeroDuration).TokensPerSecond == null);

        var a = new TokenReading(TokenSource.Codex, "a") { SessionID = "a", Model = "same-model", LastOutputTokens = 999 };
        var b = new TokenReading(TokenSource.Codex, "b") { SessionID = "b", Model = "same-model", LastOutputTokens = 999 };
        var matched = TokenSpeed.Apply([a, b], [server]);
        check("identical models do not mix sessions", matched.Count == 2 && matched[0].SpeedMeasurement?.TokensPerSecond == 25 && matched[1].SpeedMeasurement == null);
        check("log output counts never become measured speed", TokenSpeed.Apply([a], []).FirstOrDefault()?.SpeedMeasurement == null);
        var wrongProvider = TokenSpeed.Apply([a], [request]);
        check("providers cannot cross a shared session identifier", wrongProvider.Count == 2 && wrongProvider[0].SpeedMeasurement == null);
        var child = new TokenReading(TokenSource.Codex, "child") { SessionID = "a", AgentID = "worker", Model = "same-model", IsSubagent = true };
        var ambiguous = TokenSpeed.Apply([a, child], [server]);
        check("missing agent cannot select a parent among shared sessions", ambiguous.Count == 3 && ambiguous[0].SpeedMeasurement == null && ambiguous[1].SpeedMeasurement == null);
        var claudeMain = new TokenReading(TokenSource.Claude, "claude-main") { SessionID = "c", Model = "main-model" };
        var claudeChild = new TokenReading(TokenSource.Claude, "claude-child") { SessionID = "c", AgentID = "helper", Model = "main-model", IsSubagent = true };
        var mainRequest = reading with { Provider = TokenSource.Claude, SessionID = "c", Model = "main-model", OutputTokens = 300, RequestDurationMs = 3_000 };
        var sideRequest = reading with { Provider = TokenSource.Claude, SessionID = "c", Model = "side-model", At = at.AddSeconds(5), OutputTokens = 10, RequestDurationMs = 500 };
        var claudeShared = TokenSpeed.Apply([claudeMain, claudeChild], [mainRequest, sideRequest]);
        check("untagged Claude request attaches to the main log, not its subagent or a new row",
              claudeShared.Count == 2 && claudeShared[0].SpeedMeasurement?.TokensPerSecond == 100 && claudeShared[1].SpeedMeasurement == null);
        check("a newer side request on another model does not hide the current model's rate", claudeShared[0].SpeedMeasurement?.Model == "main-model");
        var sideOnly = TokenSpeed.Apply([claudeMain], [sideRequest]);
        check("a different-model rate is kept when it is the only match", sideOnly.Count == 1 && sideOnly[0].SpeedMeasurement?.Model == "side-model");
        var loggedMain = claudeMain with { RequestIDs = ["req-main"] };
        var loggedRequest = mainRequest with { RequestID = "req-main" };
        var unloggedSide = reading with
        {
            Provider = TokenSource.Claude, SessionID = "c", Model = "main-model", At = at.AddSeconds(5), RequestID = "req-side",
            OutputTokens = 8, RequestDurationMs = 2_773,
        };
        var filtered = TokenSpeed.Apply([loggedMain], [loggedRequest, unloggedSide]);
        check("a same-model side request missing from the log does not replace the logged response",
              filtered.Count == 1 && filtered[0].SpeedMeasurement?.RequestID == "req-main");
        var logless = TokenSpeed.Apply([], [sideRequest, mainRequest]);
        check("a session without a log keeps one telemetry row per model", logless.Count == 2
              && logless.Select(r => r.SpeedMeasurement?.Model).OfType<string>().ToHashSet().SetEquals(["main-model", "side-model"]));
        var agent = server with { AgentID = "worker" };
        var identified = TokenSpeed.Apply([a, child], [agent]);
        check("known agent attaches only to exact identity", identified.Count == 2 && identified[0].SpeedMeasurement == null && identified[1].SpeedMeasurement?.TokensPerSecond == 25);
        var modelOnly = reading with { ServerTokenIntervalMs = 40 };
        var detached = TokenSpeed.Apply([a, b], [modelOnly]);
        check("model-only observations stay independently identified", detached.Count == 3 && detached[^1].Project == "모델 실측" && detached[0].SpeedMeasurement == null && detached[1].SpeedMeasurement == null);
        var aggregate = server with { ServerTokenIntervalSampleCount = 4 };
        var aggregates = TokenSpeed.Apply([a], [aggregate]);
        check("aggregate metrics never attach to a session", aggregates.Count == 2 && aggregates[0].SpeedMeasurement == null && aggregates[1].SessionID == null && aggregates[1].SpeedMeasurement?.Kind == TokenRateKind.ServerAggregate);
        var newerIncomplete = server with { At = server.At.AddSeconds(1), ServerTokenIntervalMs = null, OutputTokens = null, RequestDurationMs = null };
        var retained = TokenSpeed.Apply([a], [server, newerIncomplete]);
        check("incomplete timing record does not erase latest measured rate", retained[0].SpeedMeasurement?.TokensPerSecond == 25 && retained[0].SpeedMeasurement?.At == server.At);
        Lang.With(AppLanguage.En, () =>
            check("English kinds, details with a plural count, or project labels",
                  TokenRateKind.ServerGeneration.Title == "generation tok/s"
                  && new TokenSpeedMeasurement(aggregate).Details.StartsWith("Measured server time between tokens 40.000 ms\nModel metric average · 4 measurements\n", StringComparison.Ordinal)
                  && requestSpeed.Details.StartsWith("Request measurement: 120 output tokens / 2400 ms\nSuccessful request processing rate", StringComparison.Ordinal)
                  && TokenSpeed.Apply([], [modelOnly]).FirstOrDefault()?.Project == "Model measurement"));
        return c.Done();
    }
}
