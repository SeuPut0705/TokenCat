using System.Globalization;
using System.Text.Json.Serialization;
using static TokenCat.Lang;

namespace TokenCat;

public static class TokenSpeed
{
    /// Session and agent identities must match. Model names or timing never establish identity.
    public static List<TokenReading> Apply(IReadOnlyList<TokenReading> readings, IReadOnlyList<TelemetryReading> measurements)
    {
        var result = readings.ToList();
        var latest = new Dictionary<string, TelemetryReading>(StringComparer.Ordinal);
        // Claude also sends unlogged side requests on the session's model right after a turn (a few tokens each); a request
        // missing from a log that has its session and agent is one of them. Dropped before the newest-per-identity pick below,
        // which would otherwise let it replace the real response.
        var logged = readings.Where(r => r.Source == TokenSource.Claude && r.RequestIDs.Count > 0)
            .Select(r => $"{r.SessionID}|{r.AgentID}").ToHashSet(StringComparer.Ordinal);
        var known = readings.SelectMany(r => r.RequestIDs).ToHashSet(StringComparer.Ordinal);
        foreach (var received in measurements)
        {
            var measurement = (received.ServerTokenIntervalSampleCount ?? 1) > 1
                ? received with { SessionID = null, AgentID = null, RequestID = null } : received;
            if (measurement.Provider == TokenSource.Claude && measurement.RequestID is { } request && !known.Contains(request)
                && logged.Contains($"{measurement.SessionID}|{measurement.AgentID}")) continue;
            var key = string.Join('\u001f', measurement.Provider.Id, measurement.SessionID ?? "", measurement.AgentID ?? "", measurement.Model ?? "");
            if (latest.TryGetValue(key, out var prior))
            {
                var priorHasRate = new TokenSpeedMeasurement(prior).TokensPerSecond is not null;
                var newHasRate = new TokenSpeedMeasurement(measurement).TokensPerSecond is not null;
                if (priorHasRate && !newHasRate) continue;
                if (priorHasRate == newHasRate && prior.At >= measurement.At) continue;
            }
            latest[key] = measurement;
        }
        foreach (var measurement in latest.Values.OrderBy(m => m.At))
        {
            var speed = new TokenSpeedMeasurement(measurement);
            // Logs only: a telemetry row appended earlier in this loop must not capture a later measurement.
            var sessionMatches = Enumerable.Range(0, readings.Count).Where(index => measurement.SessionID is { } session
                && result[index].Source == measurement.Provider && result[index].SessionID == session).ToList();
            List<int> matches;
            if ((measurement.ServerTokenIntervalSampleCount ?? 1) > 1) matches = [];
            else if (measurement.AgentID is { } agent) matches = [.. sessionMatches.Where(index => result[index].AgentID == agent)];
            else if (measurement.Provider is TokenSource.Claude or TokenSource.Gemini or TokenSource.Qwen)
            {
                // Claude Code tags every subagent request with agent_id; an untagged request
                // belongs to the session's single main-thread log. Gemini CLI and Qwen Code subagent logs carry their
                // parent's session ID, and only main-conversation requests are decoded for them.
                var main = sessionMatches.Where(index => result[index].AgentID is null && !result[index].IsSubagent).ToList();
                matches = main.Count == 1 ? main : [];
            }
            // Elsewhere a session identifier names one log: a Codex subagent runs in its own thread, so its log is the only match
            // even though it carries an agent path that Codex telemetry does not repeat.
            else matches = sessionMatches.Count == 1 ? sessionMatches : [];
            if (matches is [var match])
            {
                // A side request on another model (e.g. title generation) must not hide the
                // current model's rate; a different model is shown only when nothing else matches.
                bool Current(TokenSpeedMeasurement value) => value.Model is not null && value.Model == result[match].Model;
                if (result[match].SpeedMeasurement is { } existing
                    && (Current(existing) != Current(speed) ? Current(existing) : existing.At > speed.At)) continue;
                result[match] = result[match] with { SpeedMeasurement = speed };
            }
            else
            {
                // An agent of a logged session whose own log isn't tracked: no nameless row for it.
                if (measurement.AgentID is not null && sessionMatches.Count > 0) continue;
                var key = string.Join(':', measurement.Provider.Id, measurement.SessionID ?? "model", measurement.AgentID ?? "", measurement.Model ?? "");
                result.Add(new TokenReading(measurement.Provider, $"telemetry:{key}")
                {
                    SessionID = measurement.SessionID,
                    AgentID = measurement.AgentID,
                    Project = measurement.SessionID is null ? Loc("모델 실측", "Model measurement") : Loc("요청 실측", "Request measurement"),
                    Model = measurement.Model,
                    LastActivity = measurement.At,
                    ActivityState = TokenActivityState.Complete,
                    SpeedMeasurement = speed,
                });
            }
        }
        return result;
    }
}

public sealed partial record TokenSpeedMeasurement
{
    [JsonIgnore]
    public TokenRateKind? Kind =>
        ServerTokenIntervalMs is { } interval && double.IsFinite(interval) && interval > 0
            ? (ServerTokenIntervalSampleCount ?? 1) > 1 ? TokenRateKind.ServerAggregate : TokenRateKind.ServerGeneration
        : OutputTokens is >= 0 && RequestDurationMs is { } duration && double.IsFinite(duration) && duration > 0 ? TokenRateKind.RequestProcessing
        : null;

    [JsonIgnore]
    public double? TokensPerSecond
    {
        get
        {
            var rate = Kind switch
            {
                TokenRateKind.ServerGeneration or TokenRateKind.ServerAggregate => 1_000 / ServerTokenIntervalMs,
                TokenRateKind.RequestProcessing => OutputTokens * 1_000.0 / RequestDurationMs,
                _ => null,
            };
            return rate is { } value && double.IsFinite(value) && value >= 0 ? value : null;
        }
    }

    [JsonIgnore]
    public string Details
    {
        get
        {
            var invariant = CultureInfo.InvariantCulture;
            // printf's %.0f: ties to even (2.5 → "2"), where .NET's "F0" rounds them away from zero.
            static string Whole(double value) => Math.Round(value, MidpointRounding.ToEven).ToString("F0", CultureInfo.InvariantCulture);
            var lines = new List<string>();
            if (Kind is TokenRateKind.ServerGeneration or TokenRateKind.ServerAggregate && ServerTokenIntervalMs is { } interval)
            {
                var ms = interval.ToString("F3", invariant);
                lines.Add(Loc($"서버 실측 토큰 간 시간 {ms} ms", $"Measured server time between tokens {ms} ms"));
                if (Kind == TokenRateKind.ServerAggregate && ServerTokenIntervalSampleCount is { } count)
                    lines.Add(Loc($"모델 지표 평균 · 실측 {count.ToString(invariant)}회", $"Model metric average · {Plural(count, "measurement")}"));
                if (MetricWindowStartedAt is { } start)
                {
                    // Foundation's `.numeric` date + `.standard` time in the app language, local time.
                    var time = start.ToLocalTime().ToString(Current == AppLanguage.En ? "M/d/yyyy, h:mm:ss tt" : "yyyy. M. d. tt h:mm:ss", Culture);
                    lines.Add(Loc($"실측 구간 시작 {time}", $"Measurement window started {time}"));
                }
                if (ServerTokenIntervalMetric is { } metric) lines.Add(metric);
            }
            else if (Kind == TokenRateKind.RequestProcessing && OutputTokens is { } output && RequestDurationMs is { } duration)
            {
                var tokens = output.ToString(invariant);
                lines.Add(Loc($"요청 실측: {tokens} 출력 토큰 / {Whole(duration)} ms", $"Request measurement: {tokens} output tokens / {Whole(duration)} ms"));
                lines.Add(RequestDurationIncludesRetries ? Loc("재시도를 포함한 요청 처리율", "Request processing rate, retries included")
                    : Loc("성공 요청 처리율 · 첫 응답 대기·추론 포함", "Successful request processing rate · first-response wait and reasoning included"));
            }
            else lines.Add(Loc("속도 미측정", "Speed not measured"));
            if (TtftMs is { } ttft && double.IsFinite(ttft) && ttft >= 0) lines.Add(Loc($"첫 토큰 {Whole(ttft)} ms", $"First token {Whole(ttft)} ms"));
            if (ServerInferenceMs is { } inference && double.IsFinite(inference) && inference > 0)
                lines.Add(Loc($"서버 inference {Whole(inference)} ms", $"Server inference {Whole(inference)} ms"));
            if (Model is { } model) lines.Add(Loc($"측정 모델 {model}", $"Measured model {model}"));
            if (RequestID is { } requestID) lines.Add(Loc($"요청 {requestID}", $"Request {requestID}"));
            return string.Join("\n", lines);
        }
    }
}
