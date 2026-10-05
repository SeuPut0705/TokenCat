using System.Text;
using System.Text.Json;

namespace TokenCat;

/// TelemetryChecks.swift `runTelemetryChecks`: decoder, stores, HTTP parser and status line limits, without opening a port.
public static class TelemetryChecks
{
    public static List<string> Run()
    {
        var c = new Check("Telemetry");
        void check(bool valid, string description) => c.That(valid, description);
        static string J(object value) => JsonSerializer.Serialize(value);
        static string Attrs(Dictionary<string, object> values) => "[" + string.Join(",", values.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair =>
            $$$"""{"key":{{{J(pair.Key)}}},"value":{"{{{(pair.Value is string ? "stringValue" : "doubleValue")}}}":{{{J(pair.Value)}}}}}""")) + "]";
        static Dictionary<string, object> Service(string service) => new() { ["service.name"] = service };
        static byte[] Bytes(string text) => Encoding.UTF8.GetBytes(text);
        static byte[] Logs(Dictionary<string, object> values, string time = "1750000000000000000", string service = "claude-code") => Bytes(
            $$"""{"resourceLogs":[{"resource":{"attributes":{{Attrs(Service(service))}}},"scopeLogs":[{"logRecords":[{"timeUnixNano":{{J(time)}},"body":{"stringValue":"claude_code.api_request"},"attributes":{{Attrs(values)}}}]}]}]}""");
        static byte[] Trace(Dictionary<string, object> values, string service = "claude-code") => Bytes(
            $$"""{"resourceSpans":[{"resource":{"attributes":{{Attrs(Service(service))}}},"scopeSpans":[{"spans":[{"name":"claude_code.llm_request","endTimeUnixNano":"1750000001000000000","attributes":{{Attrs(values)}}}]}]}]}""");
        static byte[] Metric(string name, bool histogram = true, object? count = null, object? value = null, Dictionary<string, object>? values = null,
            string time = "1750000002000000000", string unit = "ms", string service = "codex_cli_rs")
        {
            var tail = histogram ? $"\"count\":{J(count ?? "1")},\"sum\":{J(value ?? 20)}" : $"\"asDouble\":{J(value ?? 20)}";
            var point = $$"""{"timeUnixNano":{{J(time)}},"startTimeUnixNano":"1749999990000000000","attributes":{{Attrs(values ?? [])}},{{tail}}}""";
            return Bytes($$$"""{"resourceMetrics":[{"resource":{"attributes":{{{Attrs(Service(service))}}}},"scopeMetrics":[{"metrics":[{"name":{{{J(name)}}},"unit":{{{J(unit)}}},"{{{(histogram ? "histogram" : "gauge")}}}":{"dataPoints":[{{{point}}}]}}]}]}]}""");
        }
        static string Json(object value) => JsonSerializer.Serialize(value, TokenCat.Json.Options);
        static bool Counts(IReadOnlyDictionary<string, int> counts, int logs, int metrics, int traces) =>
            counts.Count == 3 && counts["logs"] == logs && counts["metrics"] == metrics && counts["traces"] == traces;

        var collector = new TelemetryCollector();
        var request = new Dictionary<string, object> { ["session.id"] = "session-a", ["request_id"] = "request-a", ["model"] = "claude-test",
            ["output_tokens"] = 100, ["duration_ms"] = 2000 };
        check(collector.Ingest(Logs(request), "/v1/logs") && collector.Snapshot().Count == 1, "Claude OTLP request was not accepted");
        check(collector.Snapshot().FirstOrDefault()?.OutputTokens == 100 && collector.Snapshot().FirstOrDefault()?.RequestDurationMs == 2000,
              "Request usage and duration lost their shared observation");
        var failedRequest = new TelemetryCollector();
        var failedAttributes = Attrs(new() { ["output_tokens"] = 100, ["duration_ms"] = 2000 })[..^1];
        var failedPayload = Bytes($$$"""{"resourceLogs":[{"resource":{"attributes":{{{Attrs(Service("claude-code"))}}}},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"claude_code.api_request"},"attributes":{{{failedAttributes}}},{"key":"success","value":{"boolValue":false}}]}]}]}]}""");
        check(failedRequest.Ingest(failedPayload, "/v1/logs") && failedRequest.Snapshot().Count == 0,
              "An explicitly failed API request produced a successful request rate");
        var desktopRequest = new Dictionary<string, object> { ["session.id"] = "desktop-session", ["request_id"] = "desktop-request",
            ["model"] = "claude-opus-5-5", ["output_tokens"] = 200, ["duration_ms"] = 4532, ["ttft_ms"] = 2534 };
        var desktop = new TelemetryCollector();
        desktop.Ingest(Logs(desktopRequest, service: "claude-code-desktop"), "/v1/logs");
        check(desktop.Snapshot().FirstOrDefault() is { Provider: TokenSource.Claude, OutputTokens: 200, RequestDurationMs: 4532, SessionID: "desktop-session" },
              "The observed Claude desktop service did not decode API request usage and duration");
        var desktopTrace = new TelemetryCollector();
        desktopTrace.Ingest(Trace(desktopRequest, service: "claude-code-desktop"), "/v1/traces");
        check(desktopTrace.Snapshot().FirstOrDefault() is { Provider: TokenSource.Claude, TtftMs: 2534, RequestDurationIncludesRetries: true },
              "The observed Claude desktop service did not decode request trace timing");
        desktop.Ingest(Trace(desktopRequest, service: "claude-code-desktop"), "/v1/traces");
        check(desktop.Snapshot() is [{ OutputTokens: 200, TtftMs: 2534, RequestDurationIncludesRetries: false }],
              "Claude desktop log and trace did not preserve successful-attempt duration and TTFT");
        check(desktop.Diagnostics().Entries.Where(entry => entry.ResourceServiceName == "claude-code-desktop" && entry.Recognized)
                  .Select(entry => entry.Signal).ToHashSet().SetEquals(["logs", "traces"]),
              "Claude desktop log/trace metadata remained unrecognized in diagnostics");
        var unrecognizedClaude = new TelemetryCollector();
        foreach (var service in new[] { "claude-code-desktop-external", "claude-code-desktop ", "arbitrary-claude-service", "codex_cli_rs" })
        {
            unrecognizedClaude.Ingest(Logs(desktopRequest, service: service), "/v1/logs");
            unrecognizedClaude.Ingest(Trace(desktopRequest, service: service), "/v1/traces");
        }
        check(unrecognizedClaude.Snapshot().Count == 0 && unrecognizedClaude.Diagnostics().Entries.All(entry => !entry.Recognized),
              "Claude log/trace names bypassed exact service or provider matching");
        check(collector.Ingest(Logs(request), "/v1/logs") && collector.Snapshot() is [{ OutputTokens: 100 }],
              "Repeated OTLP delivery doubled request usage");
        request["duration_ms"] = 6000;
        request["ttft_ms"] = 400;
        request["agent_id"] = "agent-a";
        check(collector.Ingest(Trace(request), "/v1/traces") && collector.Snapshot().Count == 1, "Trace did not correlate with its request");
        check(collector.Snapshot().FirstOrDefault() is { RequestDurationMs: 2000, TtftMs: 400, AgentID: "agent-a", RequestDurationIncludesRetries: false },
              "Trace retries replaced the successful request duration or lost TTFT");
        var reverse = new TelemetryCollector();
        reverse.Ingest(Trace(request), "/v1/traces");
        request["duration_ms"] = 2000;
        reverse.Ingest(Logs(request), "/v1/logs");
        check(reverse.Snapshot().FirstOrDefault() is { RequestDurationMs: 2000, TtftMs: 400 }, "Log/trace arrival order changed request measurement priority");
        var traceOnly = new TelemetryCollector();
        traceOnly.Ingest(Trace(request), "/v1/traces");
        check(traceOnly.Snapshot().FirstOrDefault()?.RequestDurationIncludesRetries == true, "A trace-only duration concealed its retry-inclusive boundary");
        request["session.id"] = "session-b";
        collector.Ingest(Logs(request), "/v1/logs");
        check(collector.Snapshot().Select(reading => reading.SessionID).OfType<string>().ToHashSet().SetEquals(["session-a", "session-b"]),
              "A reused request ID leaked across sessions");
        request["session.id"] = "session-a";
        request["agent_id"] = "agent-other";
        request["output_tokens"] = 9999;
        collector.Ingest(Logs(request), "/v1/logs");
        check(collector.Snapshot().FirstOrDefault(reading => reading.SessionID == "session-a")?.OutputTokens == 100,
              "Conflicting agents polluted a correlated request");
        request["request_id"] = "request-zero";
        request["duration_ms"] = 0;
        var beforeInvalid = collector.Snapshot().Count;
        collector.Ingest(Logs(request), "/v1/logs");
        check(collector.Snapshot().Count == beforeInvalid, "A zero request duration produced a rate input");
        request["duration_ms"] = 2000;
        request["output_tokens"] = true;
        collector.Ingest(Logs(request), "/v1/logs");
        check(collector.Snapshot().Count == beforeInvalid, "Boolean usage was accepted as a numeric token count");
        request["output_tokens"] = 1.5;
        collector.Ingest(Logs(request), "/v1/logs");
        check(collector.Snapshot().Count == beforeInvalid, "Fractional output tokens were accepted");

        var codex = new TelemetryCollector();
        const string serviceTBT = "codex.responses_api_engine_service_tbt.duration_ms";
        foreach (var service in new[] { "codex_cli_rs", "codex_exec", "codex-app-server", "codex_desktop", "codex-tui",
                     "codex_vscode", "codex_mcp_server", "codex_sdk_ts", "codex-app-server-sdk", "Codex Desktop" })
        {
            var surface = new TelemetryCollector();
            surface.Ingest(Metric(serviceTBT, service: service), "/v1/metrics");
            check(surface.Snapshot().FirstOrDefault() is { Provider: TokenSource.Codex, ServerTokenIntervalMs: 20 }, $"Verified Codex service {service} was rejected");
        }
        var unknownService = new TelemetryCollector();
        foreach (var service in new[] { "arbitrary-codex-service", "arbitrary codex service", "Codex Desktop arbitrary", string.Concat(Enumerable.Repeat("codex", 100)), "claude-code" })
            unknownService.Ingest(Metric(serviceTBT, service: service), "/v1/metrics");
        check(unknownService.Snapshot().Count == 0, "Unknown or cross-provider service was classified by a metric name alone");
        check(unknownService.Diagnostics().Entries.Any(entry => entry.ResourceServiceName == "arbitrary codex service" && entry.MetricName == serviceTBT && !entry.Recognized),
              "Diagnostics lost the rejected resource service/name pair");

        var diagnostics = new TelemetryCollector();
        diagnostics.Ingest(Metric(serviceTBT, service: "Codex Desktop"), "/v1/metrics");
        diagnostics.Ingest(Metric(serviceTBT, unit: "s"), "/v1/metrics");
        diagnostics.Ingest(Metric("unknown.metric", service: "Codex Desktop"), "/v1/metrics");
        diagnostics.Ingest(Logs(new() { ["output_tokens"] = 1, ["duration_ms"] = 10, ["prompt"] = "PRIVATE_PROMPT",
            ["headers"] = "PRIVATE_HEADER", ["user.email"] = "PRIVATE_EMAIL" }), "/v1/logs");
        diagnostics.Ingest(Trace(new() { ["output_tokens"] = 1, ["duration_ms"] = 10 }), "/v1/traces");
        diagnostics.Ingest("not-json"u8, "/v1/logs");
        var diagnosticSnapshot = diagnostics.Diagnostics();
        check(Counts(diagnosticSnapshot.ReceivedBatches, 2, 3, 1) && Counts(diagnosticSnapshot.DecodedReadings, 1, 1, 1),
              "Signal diagnostic counts confused rejected batches or decoded readings");
        check(diagnosticSnapshot.Entries.Any(entry => entry is { ResourceServiceName: "Codex Desktop", MetricName: serviceTBT, Unit: "ms", Recognized: true })
              && diagnosticSnapshot.Entries.Any(entry => entry is { Unit: "s", Recognized: false })
              && diagnosticSnapshot.Entries.Any(entry => entry is { MetricName: "unknown.metric", Recognized: false }),
              "Diagnostics did not separate known metadata from unsupported units/names");
        var diagnosticJSON = Json(diagnosticSnapshot);
        check(!diagnosticJSON.Contains("PRIVATE") && !diagnosticJSON.Contains("output_tokens") && !diagnosticJSON.Contains("\"duration_ms\":"),
              "Diagnostic output retained event bodies or other attributes");
        const int bound = TelemetryCollector.MaximumDiagnostics;
        for (var index = 0; index < bound + 8; index++) diagnostics.Ingest(Metric($"unknown.metric.{index}"), "/v1/metrics");
        check(diagnostics.Diagnostics().Entries.Count == bound && diagnostics.Diagnostics().Entries[^1].MetricName == $"unknown.metric.{bound + 7}",
              "Diagnostic metadata did not evict entries at its memory bound");
        diagnostics.Ingest(Metric(new string('x', 1000)), "/v1/metrics");
        check(diagnostics.Diagnostics().Entries[^1].MetricName == "__invalid_metadata__", "Oversized diagnostic metadata was retained");
        const string iapiTBT = "codex.responses_api_engine_iapi_tbt.duration_ms";
        foreach (var reverseOrder in new[] { false, true })
        {
            var prioritized = new TelemetryCollector();
            var service = Metric(serviceTBT, count: "3", value: 48, values: new() { ["model"] = "priority-model" });
            var iapi = Metric(iapiTBT, count: "3", value: 33, values: new() { ["model"] = "priority-model" });
            foreach (var payload in reverseOrder ? new[] { iapi, service } : [service, iapi]) prioritized.Ingest(payload, "/v1/metrics");
            check(prioritized.Snapshot() is [{ ServerTokenIntervalMs: 16, ServerTokenIntervalMetric: serviceTBT, ServerTokenIntervalSampleCount: 3 }],
                  "Service TBT priority depended on export order at the same measurement timestamp");
        }
        check(codex.Ingest(Metric(serviceTBT), "/v1/metrics") && codex.Snapshot().FirstOrDefault() is { ServerTokenIntervalMs: 20, ServerTokenIntervalMetric: serviceTBT },
              "Singleton server TBT histogram was not decoded");
        check(codex.Snapshot().FirstOrDefault() is { SessionID: null, AgentID: null }, "An unattributed server measurement was assigned to a session");
        codex.Ingest(Metric(serviceTBT, count: "2", value: 100, values: new() { ["session.id"] = "must-not-attribute", ["agent_id"] = "agent",
            ["request_id"] = "request", ["model"] = "gpt-model" }, time: "1750000003000000000"), "/v1/metrics");
        check(codex.Snapshot().Any(reading => reading is { ServerTokenIntervalSampleCount: 2, ServerTokenIntervalMs: 50, Model: "gpt-model", SessionID: null,
                  AgentID: null, RequestID: null } && reading.MetricWindowStartedAt == DateTimeOffset.FromUnixTimeSeconds(1_749_999_990)),
              "Aggregated server timing lost its measurement count/window or leaked into a session");
        codex.Ingest(Metric(iapiTBT, histogram: false, value: 30, values: new() { ["conversation.id"] = "codex-session", ["model"] = "gpt-test" }), "/v1/metrics");
        check(codex.Snapshot().Any(reading => reading is { SessionID: "codex-session", ServerTokenIntervalMs: 30 }), "An explicit gauge measurement lost its verified metadata");
        codex.Ingest(Metric("codex.responses_api_inference_time.duration_ms", value: 3000), "/v1/metrics");
        check(codex.Snapshot().Any(reading => reading.ServerInferenceMs == 3000), "Server inference time was confused with inter-token time");
        var metricCount = codex.Snapshot().Count;
        codex.Ingest(Metric(serviceTBT, value: -10), "/v1/metrics");
        codex.Ingest(Metric(serviceTBT, count: "0", value: 10), "/v1/metrics");
        codex.Ingest(Metric(serviceTBT, time: "1750000004000000000", unit: "s"), "/v1/metrics");
        codex.Ingest(Metric("codex.request.duration_ms", time: "1750000004000000000"), "/v1/metrics");
        check(codex.Snapshot().Count == metricCount, "Unknown units, negative timing, or unrelated metrics were accepted");

        var privacy = new TelemetryCollector();
        privacy.Ingest(Logs(new() { ["session.id"] = "safe-session", ["request_id"] = "safe-request", ["model"] = "bad model text",
            ["output_tokens"] = 10, ["duration_ms"] = 100, ["prompt"] = "PRIVATE_PROMPT", ["body"] = "PRIVATE_BODY",
            ["user.email"] = "PRIVATE_EMAIL", ["tool_input"] = "PRIVATE_TOOL", ["headers"] = "PRIVATE_HEADER" }), "/v1/logs");
        var reflected = string.Join("\n", privacy.Snapshot());
        check(privacy.Snapshot().FirstOrDefault() is { Model: null } && !reflected.Contains("PRIVATE") && !reflected.Contains("bad model text"),
              "Content-bearing attributes survived the metadata whitelist");
        check(!privacy.Ingest("not-json"u8, "/v1/logs") && !privacy.Ingest(Bytes("""{"resourceLogs":"wrong"}"""), "/v1/logs")
              && !privacy.Ingest(Bytes("""{"resourceSpans":[]}"""), "/v1/logs"),
              "Malformed JSON/schema was accepted");

        // Unrecognized services keep span/event names and attribute keys only, never values.
        var unknownApp = new TelemetryCollector();
        static byte[] Spans(string[] names, Dictionary<string, object> values, string service = "codex-app-server") => Bytes(
            $$"""{"resourceSpans":[{"resource":{"attributes":{{Attrs(Service(service))}}},"scopeSpans":[{"spans":[{{string.Join(",", names.Select(name => $$"""{"name":{{J(name)}},"attributes":{{Attrs(values)}}}"""))}}]}]}]}""");
        unknownApp.Ingest(Spans(["handle_request", "handle_request"], new() { ["thread.id"] = "PRIVATE_THREAD", ["prompt"] = "PRIVATE_PROMPT" }), "/v1/traces");
        unknownApp.Ingest(Spans(["handle_request"], new() { ["turn.id"] = "PRIVATE_TURN", ["bad key\n"] = "x" }), "/v1/traces");
        unknownApp.Ingest(Spans(["PRIVATE PROMPT as a span name"], []), "/v1/traces");
        unknownApp.Ingest(Logs(new() { ["event.name"] = "codex.sse_event", ["output_token_count"] = 7, ["conversation.id"] = "PRIVATE_CONV" },
            service: "codex-app-server"), "/v1/logs");
        var appEntries = unknownApp.Diagnostics().Entries;
        var appJSON = Json(unknownApp.Diagnostics());
        check(appEntries.Count == 3 && unknownApp.Snapshot().Count == 0
              && appEntries.Any(entry => entry.Name == "__invalid_metadata__" && entry.AttributeKeys is [])
              && appEntries.Any(entry => entry is { Signal: "traces", Name: "handle_request", Recognized: false }
                  && entry.AttributeKeys?.SequenceEqual(["prompt", "thread.id", "turn.id"]) == true)
              && appEntries.Any(entry => entry is { Signal: "logs", Name: "codex.sse_event" }
                  && entry.AttributeKeys?.SequenceEqual(["conversation.id", "event.name", "output_token_count"]) == true)
              && !appJSON.Contains("PRIVATE") && !appJSON.Contains("\"7\""),
              "Unrecognized service diagnostics lost span/event names or keys, or kept attribute values");
        var manyKeys = new TelemetryCollector();
        manyKeys.Ingest(Spans(["wide"], Enumerable.Range(0, 100).ToDictionary(index => $"key.{index}", _ => (object)"v")), "/v1/traces");
        check(manyKeys.Diagnostics().Entries.FirstOrDefault()?.AttributeKeys?.Count == TelemetryCollector.MaximumDiagnosticKeys,
              "Diagnostic attribute keys were not bounded");

        // The newest reading per session/agent/model survives a burst that fills the recent window.
        static string Nanos(int index) => (1_750_000_000_000_000_000 + (long)index * 1_000_000).ToString();
        var burst = new TelemetryCollector();
        burst.Ingest(Logs(new() { ["session.id"] = "quiet-main", ["request_id"] = "main-request", ["model"] = "main-model",
            ["output_tokens"] = 40, ["duration_ms"] = 1_000 }, time: "1749999000000000000"), "/v1/logs");
        for (var index = 0; index < 300; index++)
            burst.Ingest(Logs(new() { ["session.id"] = "busy", ["agent_id"] = $"agent-{index % 20}", ["request_id"] = $"busy-{index}",
                ["model"] = "worker-model", ["output_tokens"] = 1, ["duration_ms"] = 10 }, time: Nanos(index)), "/v1/logs");
        var burstReadings = burst.Snapshot();
        check(burstReadings.Any(reading => reading is { SessionID: "quiet-main", OutputTokens: 40 })
              && burstReadings.Count == 257 && burstReadings[0].RequestID == "busy-299",
              "A quiet session's last measurement was evicted by a burst of other requests");
        var identities = new TelemetryCollector();
        for (var index = 0; index < 500; index++)
        {
            // 200 sessions, then one busy identity fills the recent window.
            var session = index < 200 ? $"s-{index}" : "busy";
            identities.Ingest(Logs(new() { ["session.id"] = session, ["request_id"] = $"r-{index}", ["output_tokens"] = 1, ["duration_ms"] = 10 },
                time: Nanos(index)), "/v1/logs");
        }
        var identityReadings = identities.Snapshot();
        check(identityReadings.Count == TelemetryCollector.MaximumReadings + TelemetryCollector.MaximumLatest - 1
              && identityReadings.Any(reading => reading.SessionID == "s-73") && !identityReadings.Any(reading => reading.SessionID == "s-72"),
              "The per-identity store was not bounded with least-recently-updated eviction");

        var agentBurst = new TelemetryCollector();
        agentBurst.Ingest(Logs(new() { ["session.id"] = "main-session", ["request_id"] = "main-only", ["model"] = "main-model",
            ["output_tokens"] = 40, ["duration_ms"] = 1_000 }, time: "1749999000000000000"), "/v1/logs");
        for (var index = 0; index < 400; index++)
            agentBurst.Ingest(Logs(new() { ["session.id"] = "main-session", ["agent_id"] = $"worker-{index}", ["request_id"] = $"worker-{index}",
                ["model"] = "worker-model", ["output_tokens"] = 1, ["duration_ms"] = 10 }, time: Nanos(index)), "/v1/logs");
        check(agentBurst.Snapshot().Any(reading => reading.RequestID == "main-only"),
              "More than 128 subagent identities evicted the quiet main session's last measurement");

        var undecoded = new TelemetryCollector();
        undecoded.Ingest("""{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"codex-app-server"}}]},"scopeSpans":[{"spans":[{"name":"session_task.turn"}]}]}]}"""u8, "/v1/traces");
        check(undecoded.Snapshot().Count == 0 && undecoded.LastBatchAt.ContainsKey(TokenSource.Codex) && !undecoded.LastBatchAt.ContainsKey(TokenSource.Claude),
              "A client batch without decodable readings was not recorded as received from that client");

        var bounded = new TelemetryCollector();
        for (var index = 0; index < 270; index++)
            bounded.Ingest(Logs(new() { ["session.id"] = "bounded-session", ["request_id"] = $"request-{index}", ["output_tokens"] = 1, ["duration_ms"] = 10 },
                time: Nanos(index)), "/v1/logs");
        check(bounded.Snapshot().Count == 256 && bounded.Snapshot()[0].RequestID == "request-269" && !bounded.Snapshot().Any(reading => reading.RequestID == "request-0"),
              "The in-memory request store did not evict its oldest records");

        static int? Code(HttpDecision decision) => decision is HttpDecision.Response response ? response.Code : null;
        static HttpDecision Parse(string text) => TelemetryHttp.Parse(Encoding.UTF8.GetBytes(text));
        var valid = Bytes("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
        if (TelemetryHttp.Parse(valid) is HttpDecision.Request { Path: var validPath, Body: var validBody })
            check(validPath == "/v1/logs" && validBody.SequenceEqual("{}"u8.ToArray()), "HTTP parser altered the JSON payload");
        else check(false, "Valid HTTP JSON export was rejected");
        check(TelemetryHttp.Parse(valid.AsSpan(0, valid.Length - 1)) is HttpDecision.Waiting, "Fragmented HTTP body did not wait for completion");
        var health = TokenCat.Json.Parse(TelemetryCollector.HealthBody(TelemetryCollector.DefaultPort));
        if (Parse("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n") is HttpDecision.Request { Path: var healthPath, Body: var healthBody })
            check(healthPath == "/health" && healthBody.Length == 0 && health?.Field("owner")?.Text == "TokenCat" && health?.Field("schema")?.Number == 1,
                  "Health response did not identify this collector");
        else check(false, "Health endpoint was unavailable");
        check(Code(Parse("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2097153\r\n\r\n")) == 413,
              "Oversized content length was not rejected before body allocation");
        check(Code(Parse("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}")) == 400,
              "Duplicate content lengths permitted request smuggling");
        check(Code(Parse("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n")) == 400,
              "Unsupported transfer encoding was accepted");
        check(Code(Parse("POST /v1/logs HTTP/1.1\r\nContent-Type: application/x-protobuf\r\nContent-Length: 2\r\n\r\n{}")) == 400,
              "Protobuf payload was incorrectly treated as JSON");
        check(Code(TelemetryHttp.Parse([.. valid, .. "another-request"u8])) == 400, "Pipelined bytes were allowed to contaminate a single-request connection");
        check(Code(TelemetryHttp.Parse(Enumerable.Repeat((byte)65, 16_385).ToArray())) == 431, "Unterminated HTTP headers escaped the header limit");
        check(Code(Parse("POST /other HTTP/1.1\r\n\r\n")) == 404, "Collector accepted an unconfigured endpoint");
        check(Code(Parse("GET /v1/readings HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n")) == 403
              && Code(Parse("POST /v1/logs HTTP/1.1\r\nOrigin: null\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")) == 403,
              "A browser Origin could read or write the local measurement store");
        if (Parse("GET /v1/readings HTTP/1.1\r\n\r\n") is HttpDecision.Request { Path: var readingsPath, Body: var readingsBody })
            check(readingsPath == "/v1/readings" && readingsBody.Length == 0, "Metadata readings endpoint changed");
        else check(false, "Metadata readings endpoint was rejected");
        if (Parse("GET /v1/diagnostics HTTP/1.1\r\n\r\n") is HttpDecision.Request { Path: var diagnosticsPath, Body: var diagnosticsBody })
            check(diagnosticsPath == "/v1/diagnostics" && diagnosticsBody.Length == 0, "Diagnostic metadata endpoint changed");
        else check(false, "Diagnostic metadata endpoint was rejected");
        check(Code(Parse("GET /v1/diagnostics HTTP/1.1\r\nOrigin: null\r\n\r\n")) == 403
              && Code(Parse("POST /v1/diagnostics HTTP/1.1\r\nContent-Length: 0\r\n\r\n")) == 405,
              "Diagnostic endpoint permitted a browser Origin or a write method");
        var encoded = Encoding.UTF8.GetString(TelemetryHttp.Encode(200, "{}"u8.ToArray()));
        check(encoded.Contains("Content-Length: 2\r\n") && encoded.Contains("Connection: close\r\n") && !encoded.Contains("Access-Control-Allow-Origin"),
              "Response framing or CORS contract changed");
        // Beyond the Swift cases: a 64-bit Content-Length is too large (413), not malformed; an empty content-type piece is skipped.
        check(Code(Parse("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 3000000000\r\n\r\n")) == 413
              && Parse("POST /v1/logs HTTP/1.1\r\nContent-Type: ;application/json\r\nContent-Length: 2\r\n\r\n{}") is HttpDecision.Request,
              "Content-Length or Content-Type parsing differs from Swift's Int and split rules");
        check(collector.LastReceivedAt != null && collector.State == TelemetryCollectorState.Receiving && collector.Status == "실측 수신 중",
              "A successful export did not update connection freshness");
        check(new TelemetryCollector().State == TelemetryCollectorState.Waiting
              && TelemetryCollectorState.BusyTokenCat.Status != TelemetryCollectorState.BusyOtherApp.Status,
              "Collector states did not separate another TokenCat from another app");
        Lang.With(AppLanguage.En, () => check(collector.Status == "Receiving telemetry"
            && TelemetryCollectorState.BusyOtherApp.Status == $"Telemetry off · another app is using port {TelemetryCollector.DefaultPort}",
            "English collector states changed"));

        // Claude Code status line JSON from the bridge: only rate_limits survive; nothing else is kept or counted as an export.
        var status = new TelemetryCollector();
        var statusBody = Bytes("""
            {"session_id":"status-session","cwd":"/Users/example/private-project","transcript_path":"/Users/example/t.jsonl",
             "model":{"id":"claude-opus-5-5","display_name":"Opus"},"cost":{"total_cost_usd":1.25},
             "rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1790007980},"seven_day":{"used_percentage":31.5,"resets_at":1790300000},
                            "spend_limit":{"used_percentage":99,"resets_at":1790300000}}}
            """);
        var before = DateTimeOffset.UtcNow;
        check(status.Ingest(statusBody, TelemetryHttp.ClaudeStatusPath) && status.ClaudeLimits.FiveHour?.UsedPercent == 42
              && status.ClaudeLimits.SevenDay?.UsedPercent == 31.5 && status.ClaudeLimits.FiveHour?.ResetsAt == DateTimeOffset.FromUnixTimeSeconds(1_790_007_980)
              && status.ClaudeLimits.FiveHour?.ReceivedAt >= before,
              "Claude status line limits were not decoded");
        var kept = Json(status.ClaudeLimits);
        check(!new[] { "private-project", "status-session", "claude-opus", "cost", "transcript", "spend" }.Any(kept.Contains)
              && status.Snapshot().Count == 0 && status.LastBatchAt.Count == 0 && status.LastReceivedAt == null && status.State == TelemetryCollectorState.Waiting
              && status.Diagnostics().Entries.Count == 0, "The status line copy kept more than the limits or posed as an OTLP export");
        var invalidWindows = Bytes("""{"rate_limits":{"five_hour":{"used_percentage":142,"resets_at":1790007980},"seven_day":{"used_percentage":true,"resets_at":1790300000000}}}""");
        check(status.Ingest(Bytes("""{"cwd":"/tmp"}"""), TelemetryHttp.ClaudeStatusPath) && status.Ingest(invalidWindows, TelemetryHttp.ClaudeStatusPath)
              && status.ClaudeLimits.FiveHour?.UsedPercent == 42 && status.ClaudeLimits.SevenDay?.UsedPercent == 31.5,
              "A status line without valid limits replaced the kept windows");
        check(!status.Ingest("not json"u8, TelemetryHttp.ClaudeStatusPath) && !status.Ingest("[1]"u8, TelemetryHttp.ClaudeStatusPath)
              && !status.Ingest(Enumerable.Repeat((byte)32, TelemetryHttp.MaximumStatusBodyBytes + 1).ToArray(), TelemetryHttp.ClaudeStatusPath),
              "Garbage or oversized status line bodies were accepted");
        if (Parse("POST /v1/claude/status HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}") is HttpDecision.Request { Path: var statusPath, Body: var statusRouteBody })
            check(statusPath == TelemetryHttp.ClaudeStatusPath && statusRouteBody.SequenceEqual("{}"u8.ToArray()), "Status line route altered its body");
        else check(false, "Status line route was rejected");
        check(Code(Parse("POST /v1/claude/status HTTP/1.1\r\nOrigin: null\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")) == 403
              && Code(Parse("POST /v1/claude/status HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 65537\r\n\r\n")) == 413
              && Code(Parse("POST /v1/claude/status HTTP/1.1\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}")) == 400
              && Code(Parse("GET /v1/claude/status HTTP/1.1\r\n\r\n")) == 405,
              "Status line route accepted a browser Origin, an oversized body, a non-JSON type or a read");
        // Windows: Windows PowerShell 5.1 and Notepad write a UTF-8 BOM; the bridge forwards raw stdin bytes.
        check(new TelemetryCollector().Ingest([0xEF, 0xBB, 0xBF, .. statusBody], TelemetryHttp.ClaudeStatusPath),
              "A status line body with a UTF-8 BOM was rejected");

        // ClaudeUsage (Telemetry.swift statics; the merge/desktop presentation cases are SessionPresentationChecks').
        var at = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        ClaudeUsageLimits? History(int version, double t) =>
            ClaudeUsage.DecodeDesktopHistory(Bytes($$$"""{"version":{{{version}}},"samples":[{"t":1789000000000,"org":"x","u":{"fh":90,"sd":90}},{"t":{{{t}}},"org":"x","u":{"fh":17,"sd":5}}]}"""));
        var recordedAt = at.AddSeconds(-720);
        check(History(1, recordedAt.ToUnixTimeMilliseconds()) == null
              && History(2, recordedAt.ToUnixTimeMilliseconds()) == new ClaudeUsageLimits(new(17, null, recordedAt), new(5, null, recordedAt))
              && ClaudeUsage.DecodeDesktopHistory([0xEF, 0xBB, 0xBF, .. Bytes("""{"version":2,"samples":[{"t":1790000000000,"u":{"fh":101,"sd":true}}]}""")])
                  == ClaudeUsageLimits.Empty
              && ClaudeUsage.DecodeDesktopHistory("""{"version":2,"samples":[]}"""u8) == null,
              "Claude desktop usage history: last sample only, no reset time, BOM tolerated, other shapes rejected");
        var folder = Directory.CreateTempSubdirectory("tokencat-desktop-history-");
        try
        {
            var missing = Path.Combine(folder.FullName, "missing", "plan-usage-history.json");
            var file = Path.Combine(folder.FullName, "plan-usage-history.json");
            var reader = new ClaudeUsage.DesktopReader([missing, file]);
            var empty = reader.Read();
            ClaudeUsageLimits first;
            // Read while the writer (Electron) still holds the file open.
            using (var writer = new FileStream(file, FileMode.Create, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete))
            {
                writer.Write(Bytes($$$"""{"version":2,"samples":[{"t":{{{recordedAt.ToUnixTimeMilliseconds()}}},"u":{"fh":17}}]}"""));
                writer.Flush();
                first = reader.Read();
            }
            File.WriteAllBytes(file, [.. Enumerable.Repeat((byte)32, TelemetryHttp.MaximumBodyBytes + 1)]);
            check(empty.IsEmpty && first.FiveHour?.UsedPercent == 17 && first.SevenDay is null && reader.Read().IsEmpty,
                  "The Claude desktop history reader did not take the first existing candidate, read it while open for writing, or skip an oversized file");
        }
        finally { folder.Delete(true); }

        // Never started: RetryNow has no retry to run and opens nothing (no port is touched).
        var unstarted = new TelemetryCollector(port: 1);
        unstarted.RetryNow();
        Thread.Sleep(50);
        check(!unstarted.IsRunning && unstarted.State == TelemetryCollectorState.Waiting && unstarted.NextRetryAt == null,
              "retryNow started a collector that was never started");
        return c.Done();
    }
}
