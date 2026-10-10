import Foundation

func runTelemetryChecks() -> [String] {
    var failures: [String] = []
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }
    func attribute(_ name: String, _ value: Any) -> [String: Any] {
        ["key": name, "value": value is String ? ["stringValue": value] : ["doubleValue": value]]
    }
    func attrs(_ values: [String: Any]) -> [[String: Any]] {
        values.sorted { $0.key < $1.key }.map { attribute($0.key, $0.value) }
    }
    func json(_ value: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data() }
    func logs(_ values: [String: Any], time: String = "1750000000000000000", service: String = "claude-code") -> Data {
        json(["resourceLogs": [["resource": ["attributes": attrs(["service.name": service])],
            "scopeLogs": [["logRecords": [["timeUnixNano": time, "body": ["stringValue": "claude_code.api_request"],
                "attributes": attrs(values)]]]]]]])
    }
    func trace(_ values: [String: Any], service: String = "claude-code") -> Data {
        json(["resourceSpans": [["resource": ["attributes": attrs(["service.name": service])],
            "scopeSpans": [["spans": [["name": "claude_code.llm_request", "endTimeUnixNano": "1750000001000000000",
                "attributes": attrs(values)]]]]]]])
    }
    func metric(_ name: String, histogram: Bool = true, count: Any = "1", value: Any = 20,
                values: [String: Any] = [:], time: String = "1750000002000000000", unit: String = "ms",
                service: String = "codex_cli_rs") -> Data {
        var point: [String: Any] = ["timeUnixNano": time, "startTimeUnixNano": "1749999990000000000", "attributes": attrs(values)]
        if histogram { point["count"] = count; point["sum"] = value }
        else { point["asDouble"] = value }
        return json(["resourceMetrics": [["resource": ["attributes": attrs(["service.name": service])],
            "scopeMetrics": [["metrics": [["name": name, "unit": unit,
                histogram ? "histogram" : "gauge": ["dataPoints": [point]]]]]]]]])
    }
    let collector = LocalTelemetryCollector()
    var request: [String: Any] = ["session.id": "session-a", "request_id": "request-a", "model": "claude-test",
                                 "output_tokens": 100, "duration_ms": 2000]
    check(collector.ingest(logs(request), path: "/v1/logs") && collector.snapshot().count == 1,
          "Claude OTLP request was not accepted")
    check(collector.snapshot().first?.outputTokens == 100 && collector.snapshot().first?.requestDurationMs == 2000,
          "Request usage and duration lost their shared observation")
    let failedRequest = LocalTelemetryCollector()
    let failedPayload = json(["resourceLogs": [["resource": ["attributes": attrs(["service.name": "claude-code"])],
        "scopeLogs": [["logRecords": [["body": ["stringValue": "claude_code.api_request"], "attributes":
            attrs(["output_tokens": 100, "duration_ms": 2000]) + [["key": "success", "value": ["boolValue": false]]]]]]]]]])
    check(failedRequest.ingest(failedPayload, path: "/v1/logs") && failedRequest.snapshot().isEmpty,
          "An explicitly failed API request produced a successful request rate")
    let desktopRequest: [String: Any] = ["session.id": "desktop-session", "request_id": "desktop-request",
        "model": "claude-opus-5-5", "output_tokens": 200, "duration_ms": 4532, "ttft_ms": 2534]
    let desktop = LocalTelemetryCollector()
    _ = desktop.ingest(logs(desktopRequest, service: "claude-code-desktop"), path: "/v1/logs")
    check(desktop.snapshot().first?.provider == .claude && desktop.snapshot().first?.outputTokens == 200
          && desktop.snapshot().first?.requestDurationMs == 4532
          && desktop.snapshot().first?.sessionID == "desktop-session",
          "The observed Claude desktop service did not decode API request usage and duration")
    let desktopTrace = LocalTelemetryCollector()
    _ = desktopTrace.ingest(trace(desktopRequest, service: "claude-code-desktop"), path: "/v1/traces")
    check(desktopTrace.snapshot().first?.provider == .claude && desktopTrace.snapshot().first?.ttftMs == 2534
          && desktopTrace.snapshot().first?.requestDurationIncludesRetries == true,
          "The observed Claude desktop service did not decode request trace timing")
    _ = desktop.ingest(trace(desktopRequest, service: "claude-code-desktop"), path: "/v1/traces")
    check(desktop.snapshot().count == 1 && desktop.snapshot().first?.outputTokens == 200
          && desktop.snapshot().first?.ttftMs == 2534
          && desktop.snapshot().first?.requestDurationIncludesRetries == false,
          "Claude desktop log and trace did not preserve successful-attempt duration and TTFT")
    check(Set(desktop.diagnostics().entries.filter { $0.resourceServiceName == "claude-code-desktop"
          && $0.recognized }.map(\.signal)) == ["logs", "traces"],
          "Claude desktop log/trace metadata remained unrecognized in diagnostics")
    let unrecognizedClaude = LocalTelemetryCollector()
    for service in ["claude-code-desktop-external", "claude-code-desktop ", "arbitrary-claude-service", "codex_cli_rs"] {
        _ = unrecognizedClaude.ingest(logs(desktopRequest, service: service), path: "/v1/logs")
        _ = unrecognizedClaude.ingest(trace(desktopRequest, service: service), path: "/v1/traces")
    }
    check(unrecognizedClaude.snapshot().isEmpty
          && unrecognizedClaude.diagnostics().entries.allSatisfy { !$0.recognized },
          "Claude log/trace names bypassed exact service or provider matching")
    check(collector.ingest(logs(request), path: "/v1/logs") && collector.snapshot().count == 1
          && collector.snapshot().first?.outputTokens == 100,
          "Repeated OTLP delivery doubled request usage")
    request["duration_ms"] = 6000
    request["ttft_ms"] = 400
    request["agent_id"] = "agent-a"
    check(collector.ingest(trace(request), path: "/v1/traces") && collector.snapshot().count == 1,
          "Trace did not correlate with its request")
    check(collector.snapshot().first?.requestDurationMs == 2000 && collector.snapshot().first?.ttftMs == 400
          && collector.snapshot().first?.agentID == "agent-a" && collector.snapshot().first?.requestDurationIncludesRetries == false,
          "Trace retries replaced the successful request duration or lost TTFT")
    let reverse = LocalTelemetryCollector()
    _ = reverse.ingest(trace(request), path: "/v1/traces")
    request["duration_ms"] = 2000
    _ = reverse.ingest(logs(request), path: "/v1/logs")
    check(reverse.snapshot().first?.requestDurationMs == 2000 && reverse.snapshot().first?.ttftMs == 400,
          "Log/trace arrival order changed request measurement priority")
    let traceOnly = LocalTelemetryCollector()
    _ = traceOnly.ingest(trace(request), path: "/v1/traces")
    check(traceOnly.snapshot().first?.requestDurationIncludesRetries == true,
          "A trace-only duration concealed its retry-inclusive boundary")
    request["session.id"] = "session-b"
    _ = collector.ingest(logs(request), path: "/v1/logs")
    check(Set(collector.snapshot().compactMap(\.sessionID)) == ["session-a", "session-b"],
          "A reused request ID leaked across sessions")
    request["session.id"] = "session-a"
    request["agent_id"] = "agent-other"
    request["output_tokens"] = 9999
    _ = collector.ingest(logs(request), path: "/v1/logs")
    check(collector.snapshot().first(where: { $0.sessionID == "session-a" })?.outputTokens == 100,
          "Conflicting agents polluted a correlated request")
    request["request_id"] = "request-zero"
    request["duration_ms"] = 0
    let beforeInvalid = collector.snapshot().count
    _ = collector.ingest(logs(request), path: "/v1/logs")
    check(collector.snapshot().count == beforeInvalid, "A zero request duration produced a rate input")
    request["duration_ms"] = 2000
    request["output_tokens"] = true
    _ = collector.ingest(logs(request), path: "/v1/logs")
    check(collector.snapshot().count == beforeInvalid, "Boolean usage was accepted as a numeric token count")
    request["output_tokens"] = 1.5
    _ = collector.ingest(logs(request), path: "/v1/logs")
    check(collector.snapshot().count == beforeInvalid, "Fractional output tokens were accepted")

    let codex = LocalTelemetryCollector()
    let serviceTBT = "codex.responses_api_engine_service_tbt.duration_ms"
    for service in ["codex_cli_rs", "codex_exec", "codex-app-server", "codex_desktop", "codex-tui",
                    "codex_vscode", "codex_mcp_server", "codex_sdk_ts", "codex-app-server-sdk", "Codex Desktop"] {
        let surface = LocalTelemetryCollector()
        _ = surface.ingest(metric(serviceTBT, service: service), path: "/v1/metrics")
        check(surface.snapshot().first?.provider == .codex && surface.snapshot().first?.serverTokenIntervalMs == 20,
              "Verified Codex service \(service) was rejected")
    }
    let unknownService = LocalTelemetryCollector()
    _ = unknownService.ingest(metric(serviceTBT, service: "arbitrary-codex-service"), path: "/v1/metrics")
    _ = unknownService.ingest(metric(serviceTBT, service: "arbitrary codex service"), path: "/v1/metrics")
    _ = unknownService.ingest(metric(serviceTBT, service: "Codex Desktop arbitrary"), path: "/v1/metrics")
    _ = unknownService.ingest(metric(serviceTBT, service: String(repeating: "codex", count: 100)), path: "/v1/metrics")
    _ = unknownService.ingest(metric(serviceTBT, service: "claude-code"), path: "/v1/metrics")
    check(unknownService.snapshot().isEmpty, "Unknown or cross-provider service was classified by a metric name alone")
    check(unknownService.diagnostics().entries.contains(where: {
        $0.resourceServiceName == "arbitrary codex service" && $0.metricName == serviceTBT && !$0.recognized
    }), "Diagnostics lost the rejected resource service/name pair")

    let diagnostics = LocalTelemetryCollector()
    _ = diagnostics.ingest(metric(serviceTBT, service: "Codex Desktop"), path: "/v1/metrics")
    _ = diagnostics.ingest(metric(serviceTBT, unit: "s"), path: "/v1/metrics")
    _ = diagnostics.ingest(metric("unknown.metric", service: "Codex Desktop"), path: "/v1/metrics")
    _ = diagnostics.ingest(logs(["output_tokens": 1, "duration_ms": 10, "prompt": "PRIVATE_PROMPT",
        "headers": "PRIVATE_HEADER", "user.email": "PRIVATE_EMAIL"]), path: "/v1/logs")
    _ = diagnostics.ingest(trace(["output_tokens": 1, "duration_ms": 10]), path: "/v1/traces")
    _ = diagnostics.ingest(Data("not-json".utf8), path: "/v1/logs")
    let diagnosticSnapshot = diagnostics.diagnostics()
    check(diagnosticSnapshot.receivedBatches == ["logs": 2, "metrics": 3, "traces": 1]
          && diagnosticSnapshot.decodedReadings == ["logs": 1, "metrics": 1, "traces": 1],
          "Signal diagnostic counts confused rejected batches or decoded readings")
    check(diagnosticSnapshot.entries.contains(where: { $0.resourceServiceName == "Codex Desktop"
          && $0.metricName == serviceTBT && $0.unit == "ms" && $0.recognized })
          && diagnosticSnapshot.entries.contains(where: { $0.unit == "s" && !$0.recognized })
          && diagnosticSnapshot.entries.contains(where: { $0.metricName == "unknown.metric" && !$0.recognized }),
          "Diagnostics did not separate known metadata from unsupported units/names")
    let diagnosticJSON = String(data: (try? JSONEncoder().encode(diagnosticSnapshot)) ?? Data(), encoding: .utf8) ?? ""
    check(!diagnosticJSON.contains("PRIVATE") && !diagnosticJSON.contains("output_tokens")
          && !diagnosticJSON.contains("\"duration_ms\":"), "Diagnostic output retained event bodies or other attributes")
    let bound = LocalTelemetryCollector.maximumDiagnostics
    for index in 0..<(bound + 8) {
        _ = diagnostics.ingest(metric("unknown.metric.\(index)"), path: "/v1/metrics")
    }
    check(diagnostics.diagnostics().entries.count == bound
          && diagnostics.diagnostics().entries.last?.metricName == "unknown.metric.\(bound + 7)",
          "Diagnostic metadata did not evict entries at its memory bound")
    _ = diagnostics.ingest(metric(String(repeating: "x", count: 1000)), path: "/v1/metrics")
    check(diagnostics.diagnostics().entries.last?.metricName == "__invalid_metadata__",
          "Oversized diagnostic metadata was retained")
    let iapiTBT = "codex.responses_api_engine_iapi_tbt.duration_ms"
    for reverseOrder in [false, true] {
        let prioritized = LocalTelemetryCollector()
        let service = metric(serviceTBT, count: "3", value: 48, values: ["model": "priority-model"])
        let iapi = metric(iapiTBT, count: "3", value: 33, values: ["model": "priority-model"])
        for payload in reverseOrder ? [iapi, service] : [service, iapi] {
            _ = prioritized.ingest(payload, path: "/v1/metrics")
        }
        check(prioritized.snapshot().count == 1 && prioritized.snapshot().first?.serverTokenIntervalMs == 16
              && prioritized.snapshot().first?.serverTokenIntervalMetric == serviceTBT
              && prioritized.snapshot().first?.serverTokenIntervalSampleCount == 3,
              "Service TBT priority depended on export order at the same measurement timestamp")
    }
    check(codex.ingest(metric(serviceTBT), path: "/v1/metrics")
          && codex.snapshot().first?.serverTokenIntervalMs == 20
          && codex.snapshot().first?.serverTokenIntervalMetric == serviceTBT,
          "Singleton server TBT histogram was not decoded")
    check(codex.snapshot().first?.sessionID == nil && codex.snapshot().first?.agentID == nil,
          "An unattributed server measurement was assigned to a session")
    _ = codex.ingest(metric(serviceTBT, count: "2", value: 100,
                           values: ["session.id": "must-not-attribute", "agent_id": "agent", "request_id": "request", "model": "gpt-model"],
                           time: "1750000003000000000"), path: "/v1/metrics")
    check(codex.snapshot().contains(where: { $0.serverTokenIntervalSampleCount == 2 && $0.serverTokenIntervalMs == 50
          && $0.model == "gpt-model" && $0.sessionID == nil && $0.agentID == nil && $0.requestID == nil
          && $0.metricWindowStartedAt == Date(timeIntervalSince1970: 1_749_999_990) }),
          "Aggregated server timing lost its measurement count/window or leaked into a session")
    _ = codex.ingest(metric("codex.responses_api_engine_iapi_tbt.duration_ms", histogram: false, value: 30,
                           values: ["conversation.id": "codex-session", "model": "gpt-test"]), path: "/v1/metrics")
    check(codex.snapshot().contains(where: { $0.sessionID == "codex-session" && $0.serverTokenIntervalMs == 30 }),
          "An explicit gauge measurement lost its verified metadata")
    _ = codex.ingest(metric("codex.responses_api_inference_time.duration_ms", value: 3000), path: "/v1/metrics")
    check(codex.snapshot().contains(where: { $0.serverInferenceMs == 3000 }),
          "Server inference time was confused with inter-token time")
    let metricCount = codex.snapshot().count
    _ = codex.ingest(metric(serviceTBT, value: -10), path: "/v1/metrics")
    _ = codex.ingest(metric(serviceTBT, count: "0", value: 10), path: "/v1/metrics")
    _ = codex.ingest(metric(serviceTBT, time: "1750000004000000000", unit: "s"), path: "/v1/metrics")
    _ = codex.ingest(metric("codex.request.duration_ms", time: "1750000004000000000"), path: "/v1/metrics")
    check(codex.snapshot().count == metricCount, "Unknown units, negative timing, or unrelated metrics were accepted")

    let privacy = LocalTelemetryCollector()
    _ = privacy.ingest(logs(["session.id": "safe-session", "request_id": "safe-request", "model": "bad model text",
        "output_tokens": 10, "duration_ms": 100, "prompt": "PRIVATE_PROMPT", "body": "PRIVATE_BODY",
        "user.email": "PRIVATE_EMAIL", "tool_input": "PRIVATE_TOOL", "headers": "PRIVATE_HEADER"]), path: "/v1/logs")
    let reflected = String(reflecting: privacy.snapshot())
    check(privacy.snapshot().first?.model == nil && !reflected.contains("PRIVATE") && !reflected.contains("bad model text"),
          "Content-bearing attributes survived the metadata whitelist")
    check(!privacy.ingest(Data("not-json".utf8), path: "/v1/logs")
          && !privacy.ingest(json(["resourceLogs": "wrong"]), path: "/v1/logs")
          && !privacy.ingest(json(["resourceSpans": []]), path: "/v1/logs"),
          "Malformed JSON/schema was accepted")

    // Unrecognized services keep span/event names and attribute keys only, never values.
    let unknownApp = LocalTelemetryCollector()
    func spans(_ names: [String], _ values: [String: Any], service: String = "codex-app-server") -> Data {
        json(["resourceSpans": [["resource": ["attributes": attrs(["service.name": service])],
            "scopeSpans": [["spans": names.map { ["name": $0, "attributes": attrs(values)] }]]]]])
    }
    _ = unknownApp.ingest(spans(["handle_request", "handle_request"], ["thread.id": "PRIVATE_THREAD", "prompt": "PRIVATE_PROMPT"]),
                          path: "/v1/traces")
    _ = unknownApp.ingest(spans(["handle_request"], ["turn.id": "PRIVATE_TURN", "bad key\n": "x"]), path: "/v1/traces")
    _ = unknownApp.ingest(spans(["PRIVATE PROMPT as a span name"], [:]), path: "/v1/traces")
    _ = unknownApp.ingest(logs(["event.name": "codex.sse_event", "output_token_count": 7, "conversation.id": "PRIVATE_CONV"],
                               service: "codex-app-server"), path: "/v1/logs")
    let appEntries = unknownApp.diagnostics().entries
    let appJSON = String(decoding: (try? JSONEncoder().encode(unknownApp.diagnostics())) ?? Data(), as: UTF8.self)
    check(appEntries.count == 3 && unknownApp.snapshot().isEmpty
          && appEntries.contains(where: { $0.name == "__invalid_metadata__" && $0.attributeKeys == [] })
          && appEntries.contains(where: { $0.signal == "traces" && $0.name == "handle_request" && !$0.recognized
              && $0.attributeKeys == ["prompt", "thread.id", "turn.id"] })
          && appEntries.contains(where: { $0.signal == "logs" && $0.name == "codex.sse_event"
              && $0.attributeKeys == ["conversation.id", "event.name", "output_token_count"] })
          && !appJSON.contains("PRIVATE") && !appJSON.contains("\"7\""),
          "Unrecognized service diagnostics lost span/event names or keys, or kept attribute values")
    let manyKeys = LocalTelemetryCollector()
    _ = manyKeys.ingest(spans(["wide"], Dictionary(uniqueKeysWithValues: (0..<100).map { ("key.\($0)", "v") })), path: "/v1/traces")
    check(manyKeys.diagnostics().entries.first?.attributeKeys?.count == LocalTelemetryCollector.maximumDiagnosticKeys,
          "Diagnostic attribute keys were not bounded")

    // The newest reading per session/agent/model survives a burst that fills the recent window.
    let burst = LocalTelemetryCollector()
    _ = burst.ingest(logs(["session.id": "quiet-main", "request_id": "main-request", "model": "main-model",
        "output_tokens": 40, "duration_ms": 1_000], time: "1749999000000000000"), path: "/v1/logs")
    for index in 0..<300 {
        _ = burst.ingest(logs(["session.id": "busy", "agent_id": "agent-\(index % 20)", "request_id": "busy-\(index)",
            "model": "worker-model", "output_tokens": 1, "duration_ms": 10],
            time: String(1_750_000_000_000_000_000 + Int64(index) * 1_000_000)), path: "/v1/logs")
    }
    let burstReadings = burst.snapshot()
    check(burstReadings.contains(where: { $0.sessionID == "quiet-main" && $0.outputTokens == 40 })
          && burstReadings.count == 257 && burstReadings.first?.requestID == "busy-299",
          "A quiet session's last measurement was evicted by a burst of other requests")
    let identities = LocalTelemetryCollector()
    for index in 0..<500 {
        // 200 sessions, then one busy identity fills the recent window.
        let session = index < 200 ? "s-\(index)" : "busy"
        _ = identities.ingest(logs(["session.id": session, "request_id": "r-\(index)", "output_tokens": 1, "duration_ms": 10],
            time: String(1_750_000_000_000_000_000 + Int64(index) * 1_000_000)), path: "/v1/logs")
    }
    let identityReadings = identities.snapshot()
    check(identityReadings.count == LocalTelemetryCollector.maximumReadings + LocalTelemetryCollector.maximumLatest - 1
          && identityReadings.contains(where: { $0.sessionID == "s-73" })
          && !identityReadings.contains(where: { $0.sessionID == "s-72" }),
          "The per-identity store was not bounded with least-recently-updated eviction")

    let agentBurst = LocalTelemetryCollector()
    _ = agentBurst.ingest(logs(["session.id": "main-session", "request_id": "main-only", "model": "main-model",
        "output_tokens": 40, "duration_ms": 1_000], time: "1749999000000000000"), path: "/v1/logs")
    for index in 0..<400 {
        _ = agentBurst.ingest(logs(["session.id": "main-session", "agent_id": "worker-\(index)", "request_id": "worker-\(index)",
            "model": "worker-model", "output_tokens": 1, "duration_ms": 10],
            time: String(1_750_000_000_000_000_000 + Int64(index) * 1_000_000)), path: "/v1/logs")
    }
    check(agentBurst.snapshot().contains(where: { $0.requestID == "main-only" }),
          "More than 128 subagent identities evicted the quiet main session's last measurement")

    let undecoded = LocalTelemetryCollector()
    _ = undecoded.ingest(Data(#"{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"codex-app-server"}}]},"scopeSpans":[{"spans":[{"name":"session_task.turn"}]}]}]}"#.utf8), path: "/v1/traces")
    check(undecoded.snapshot().isEmpty && undecoded.lastBatchAt[.codex] != nil && undecoded.lastBatchAt[.claude] == nil,
          "A client batch without decodable readings was not recorded as received from that client")

    // Gemini CLI `api_response` as its OTLP/HTTP JSON exporter sends it (resource and log both carry session.id). Utility and
    // subagent requests share the main session ID, so only role "main" (or no role, older versions) decodes.
    func geminiLog(role: String?, output: Int, thoughts: Int, input: Int, total: Int, duration: Int, time: String) -> String {
        let roleAttribute = role.map { #",{"key":"role","value":{"stringValue":"\#($0)"}}"# } ?? ""
        return #"{"timeUnixNano":"\#(time)","body":{"stringValue":"API response from gemini-2.5-pro. Status: 200. Duration: \#(duration)ms."},"attributes":[{"key":"session.id","value":{"stringValue":"gemini-session"}},{"key":"installation.id","value":{"stringValue":"install-1"}},{"key":"user.email","value":{"stringValue":"person@example.com"}},{"key":"interactive","value":{"boolValue":true}},{"key":"event.name","value":{"stringValue":"gemini_cli.api_response"}},{"key":"event.timestamp","value":{"stringValue":"2026-10-07T01:02:03.456Z"}},{"key":"model","value":{"stringValue":"gemini-2.5-pro"}},{"key":"duration_ms","value":{"intValue":\#(duration)}},{"key":"input_token_count","value":{"intValue":\#(input)}},{"key":"output_token_count","value":{"intValue":\#(output)}},{"key":"cached_content_token_count","value":{"intValue":0}},{"key":"thoughts_token_count","value":{"intValue":\#(thoughts)}},{"key":"tool_token_count","value":{"intValue":0}},{"key":"total_token_count","value":{"intValue":\#(total)}},{"key":"prompt_id","value":{"stringValue":"private-prompt-id"}},{"key":"auth_type","value":{"stringValue":"oauth-personal"}},{"key":"status_code","value":{"intValue":200}},{"key":"finish_reasons","value":{"arrayValue":{"values":[{"stringValue":"STOP"}]}}}\#(roleAttribute)]}"#
    }
    let geminiBatch = #"{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"gemini-cli"}},{"key":"service.version","value":{"stringValue":"v24.0.0"}},{"key":"session.id","value":{"stringValue":"gemini-session"}}]},"scopeLogs":[{"scope":{"name":"gemini-cli"},"logRecords":["#
        + [geminiLog(role: "main", output: 120, thoughts: 30, input: 1_000, total: 1_150, duration: 2_000, time: "1791000000000000000"),
           geminiLog(role: "utility_router", output: 5, thoughts: 0, input: 300, total: 305, duration: 400, time: "1791000001000000000"),
           geminiLog(role: "subagent", output: 500, thoughts: 0, input: 900, total: 1_400, duration: 1_000, time: "1791000002000000000")].joined(separator: ",")
        + "]}]}]}"
    let gemini = LocalTelemetryCollector()
    let geminiReading = gemini.ingest(Data(geminiBatch.utf8), path: "/v1/logs") ? gemini.snapshot() : []
    check(geminiReading.count == 1 && geminiReading.first?.provider == .gemini && geminiReading.first?.sessionID == "gemini-session"
          && geminiReading.first?.model == "gemini-2.5-pro" && geminiReading.first?.outputTokens == 150
          && geminiReading.first?.requestDurationMs == 2_000 && geminiReading.first?.agentID == nil
          && gemini.lastBatchAt[.gemini] != nil && gemini.diagnostics().entries.allSatisfy(\.recognized),
          "A Gemini CLI api_response did not decode to one main-session reading with thoughts counted")
    let geminiKept = String(decoding: (try? JSONEncoder().encode(geminiReading)) ?? Data(), as: UTF8.self)
    check(!["person@example.com", "install-1", "private-prompt-id", "oauth-personal"].contains(where: geminiKept.contains),
          "A Gemini CLI reading kept an identity or prompt attribute")
    let geminiOld = LocalTelemetryCollector()
    _ = geminiOld.ingest(Data((#"{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"gemini-cli"}}]},"scopeLogs":[{"logRecords":["#
        + geminiLog(role: nil, output: 90, thoughts: 0, input: 100, total: 190, duration: 1_500, time: "1791000003000000000") + "]}]}]}").utf8), path: "/v1/logs")
    check(geminiOld.snapshot().first?.outputTokens == 90 && geminiOld.snapshot().first?.sessionID == "gemini-session",
          "A Gemini CLI api_response without a role (older versions) was not decoded")

    // Qwen Code: session.id only on the log, response_id names the request, ttft_ms is measured; subagent requests carry subagent_name.
    func qwenLog(subagent: String?, response: String, output: Int, duration: Int) -> String {
        let subagentAttribute = subagent.map { #",{"key":"subagent_name","value":{"stringValue":"\#($0)"}}"# } ?? ""
        return #"{"timeUnixNano":"1791000005000000000","body":{"stringValue":"API response from qwen3-coder-plus. Status: 200. Duration: \#(duration)ms."},"attributes":[{"key":"session.id","value":{"stringValue":"qwen-session"}},{"key":"event.name","value":{"stringValue":"qwen-code.api_response"}},{"key":"event.timestamp","value":{"stringValue":"2026-10-07T01:02:05.000Z"}},{"key":"response_id","value":{"stringValue":"\#(response)"}},{"key":"model","value":{"stringValue":"qwen3-coder-plus"}},{"key":"status_code","value":{"intValue":200}},{"key":"duration_ms","value":{"intValue":\#(duration)}},{"key":"input_token_count","value":{"intValue":2000}},{"key":"output_token_count","value":{"intValue":\#(output)}},{"key":"cached_content_token_count","value":{"intValue":0}},{"key":"thoughts_token_count","value":{"intValue":0}},{"key":"total_token_count","value":{"intValue":\#(2_000 + output)}},{"key":"prompt_id","value":{"stringValue":"qwen-prompt"}},{"key":"auth_type","value":{"stringValue":"qwen-oauth"}},{"key":"ttft_ms","value":{"intValue":300}}\#(subagentAttribute)]}"#
    }
    let qwenBatch = #"{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"qwen-code"}},{"key":"service.version","value":{"stringValue":"0.20.0"}}]},"scopeLogs":[{"scope":{"name":"qwen-code"},"logRecords":["#
        + [qwenLog(subagent: nil, response: "chatcmpl-main-1", output: 80, duration: 1_600),
           qwenLog(subagent: "Code Reviewer", response: "chatcmpl-sub-1", output: 400, duration: 800)].joined(separator: ",") + "]}]}]}"
    let qwen = LocalTelemetryCollector()
    let qwenReading = qwen.ingest(Data(qwenBatch.utf8), path: "/v1/logs") ? qwen.snapshot() : []
    check(qwenReading.count == 1 && qwenReading.first?.provider == .qwen && qwenReading.first?.sessionID == "qwen-session"
          && qwenReading.first?.requestID == "chatcmpl-main-1" && qwenReading.first?.outputTokens == 80
          && qwenReading.first?.requestDurationMs == 1_600 && qwenReading.first?.ttftMs == 300 && qwen.lastBatchAt[.qwen] != nil,
          "A Qwen Code api_response did not decode to one main-session reading, or a subagent request was kept")
    check(!String(decoding: (try? JSONEncoder().encode(qwenReading)) ?? Data(), as: UTF8.self).contains("Code Reviewer"),
          "A Qwen Code subagent name was kept")
    let impostor = LocalTelemetryCollector()
    _ = impostor.ingest(Data(qwenBatch.replacingOccurrences(of: #""stringValue":"qwen-code"}}"#, with: #""stringValue":"gemini-cli"}}"#).utf8), path: "/v1/logs")
    check(impostor.snapshot().isEmpty, "A Qwen Code event under another client's service was decoded")

    let bounded = LocalTelemetryCollector()
    for index in 0..<270 {
        _ = bounded.ingest(logs(["session.id": "bounded-session", "request_id": "request-\(index)",
            "output_tokens": 1, "duration_ms": 10], time: String(1_750_000_000_000_000_000 + Int64(index) * 1_000_000)), path: "/v1/logs")
    }
    check(bounded.snapshot().count == 256 && bounded.snapshot().first?.requestID == "request-269"
          && !bounded.snapshot().contains(where: { $0.requestID == "request-0" }),
          "The in-memory request store did not evict its oldest records")

    func responseCode(_ decision: TelemetryHTTPDecision) -> Int? {
        if case .response(let code, _) = decision { return code }; return nil
    }
    func wire(_ text: String) -> Data { Data(text.utf8) }
    let valid = wire("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
    if case .request(let path, let body) = TelemetryHTTP.parse(valid) {
        check(path == "/v1/logs" && body == wire("{}"), "HTTP parser altered the JSON payload")
    } else { check(false, "Valid HTTP JSON export was rejected") }
    if case .waiting = TelemetryHTTP.parse(Data(valid.dropLast())) { check(true, "") }
    else { check(false, "Fragmented HTTP body did not wait for completion") }
    if case .request(let path, let body) = TelemetryHTTP.parse(wire("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")) {
        check(path == "/health" && body.isEmpty && LocalTelemetryCollector.health["owner"] as? String == "TokenCat"
              && LocalTelemetryCollector.health["schema"] as? Int == 1, "Health response did not identify this collector")
    } else { check(false, "Health endpoint was unavailable") }
    check(responseCode(TelemetryHTTP.parse(wire("GET /v1/readings HTTP/1.1\r\nHost: rebind.example:16493\r\n\r\n"))) == 403
          && responseCode(TelemetryHTTP.parse(wire("GET /v1/readings HTTP/1.1\r\nHost: 127.0.0.1.evil.example\r\n\r\n"))) == 403
          && responseCode(TelemetryHTTP.parse(wire("GET /health HTTP/1.1\r\nHost: 127.0.0.1:16493\r\n\r\n"))) == nil,
          "A DNS-rebound Host was not rejected, or the loopback Host was")
    check(responseCode(TelemetryHTTP.parse(wire("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2097153\r\n\r\n"))) == 413,
          "Oversized content length was not rejected before body allocation")
    check(responseCode(TelemetryHTTP.parse(wire("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}"))) == 400,
          "Duplicate content lengths permitted request smuggling")
    // Node's OTLP/HTTP exporters (Gemini CLI, Qwen Code) send chunked bodies without a length.
    let chunked = wire("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nHost: 127.0.0.1:16493\r\n\r\n"
                       + "5;ext=1\r\n{\"a\":\r\n3\r\n12}\r\n0\r\nX-Trailer: dropped\r\n\r\n")
    if case .request(let path, let body) = TelemetryHTTP.parse(chunked) {
        check(path == "/v1/logs" && body == wire("{\"a\":12}"), "A chunked body was not joined into its JSON")
    } else { check(false, "A chunked OTLP export was rejected") }
    var chunkedWaits = true
    for cut in [chunked.count - 1, chunked.count - 3, chunked.count - 30, chunked.count - 40] {
        if case .waiting = TelemetryHTTP.parse(Data(chunked.prefix(cut))) { continue }
        chunkedWaits = false
    }
    check(chunkedWaits, "A partial chunked body did not wait for the rest")
    func chunkedCode(_ headers: String, _ body: String) -> Int? {
        responseCode(TelemetryHTTP.parse(wire("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\n\(headers)\r\n" + body)))
    }
    check(chunkedCode("Transfer-Encoding: chunked\r\nContent-Length: 7\r\n", "2\r\n{}\r\n0\r\n\r\n") == 400
          && chunkedCode("Transfer-Encoding: gzip, chunked\r\n", "2\r\n{}\r\n0\r\n\r\n") == 400
          && chunkedCode("Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n", "2\r\n{}\r\n0\r\n\r\n") == 400
          && chunkedCode("Transfer-Encoding: chunked\r\n", "zz\r\n{}\r\n0\r\n\r\n") == 400
          && chunkedCode("Transfer-Encoding: chunked\r\n", "2\r\n{}xx0\r\n\r\n") == 400
          && chunkedCode("Transfer-Encoding: chunked\r\n", "2\r\n{}\r\n0\r\n\r\nextra") == 400
          && chunkedCode("Transfer-Encoding: chunked\r\n", "200001\r\n") == 413
          && responseCode(TelemetryHTTP.parse(wire("GET /health HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"))) == 400,
          "A chunked body with a length, another coding, bad framing, trailing bytes or an oversized chunk was accepted")
    // Bytes captured from @opentelemetry/exporter-logs-otlp-http 0.218.0 (the exporter Gemini CLI and Qwen Code ship) sending
    // a Gemini CLI api_response: chunked, no Content-Length, keep-alive.
    let nodeHead = "POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nUser-Agent: OTel-OTLP-Exporter-JavaScript/0.218.0\r\nHost: 127.0.0.1:62143\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\n\r\n"
    let nodePayload = #"{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"gemini-cli"}},{"key":"service.version","value":{"stringValue":"v24.0.0"}},{"key":"session.id","value":{"stringValue":"wire-session"}}],"droppedAttributesCount":0},"scopeLogs":[{"scope":{"name":"gemini-cli"},"logRecords":[{"timeUnixNano":"1791301155852000000","observedTimeUnixNano":"1791301155852000000","body":{"stringValue":"API response from gemini-2.5-pro. Status: 200. Duration: 2000ms."},"attributes":[{"key":"session.id","value":{"stringValue":"wire-session"}},{"key":"interactive","value":{"boolValue":true}},{"key":"event.name","value":{"stringValue":"gemini_cli.api_response"}},{"key":"event.timestamp","value":{"stringValue":"2026-10-07T01:02:03.456Z"}},{"key":"model","value":{"stringValue":"gemini-2.5-pro"}},{"key":"duration_ms","value":{"intValue":2000}},{"key":"input_token_count","value":{"intValue":1000}},{"key":"output_token_count","value":{"intValue":120}},{"key":"cached_content_token_count","value":{"intValue":0}},{"key":"thoughts_token_count","value":{"intValue":30}},{"key":"tool_token_count","value":{"intValue":0}},{"key":"total_token_count","value":{"intValue":1150}},{"key":"prompt_id","value":{"stringValue":"p1"}},{"key":"status_code","value":{"intValue":200}},{"key":"finish_reasons","value":{"arrayValue":{"values":[{"stringValue":"STOP"}]}}},{"key":"role","value":{"stringValue":"main"}}],"droppedAttributesCount":0}]}]}]}"#
    let nodeWire = wire(nodeHead + String(nodePayload.utf8.count, radix: 16) + "\r\n" + nodePayload + "\r\n0\r\n\r\n")
    if case .request(let path, let body) = TelemetryHTTP.parse(nodeWire) {
        let node = LocalTelemetryCollector()
        check(node.ingest(body, path: path) && node.snapshot().first?.provider == .gemini && node.snapshot().first?.sessionID == "wire-session"
              && node.snapshot().first.map { TokenSpeedMeasurement($0).tokensPerSecond } == 75,
              "The Node OTLP exporter's Gemini CLI request did not decode to 150 tokens in 2 s")
    } else { check(false, "The Node OTLP exporter's chunked request was rejected") }
    check(responseCode(TelemetryHTTP.parse(wire("POST /v1/logs HTTP/1.1\r\nContent-Type: application/x-protobuf\r\nContent-Length: 2\r\n\r\n{}"))) == 400,
          "Protobuf payload was incorrectly treated as JSON")
    check(responseCode(TelemetryHTTP.parse(valid + wire("another-request"))) == 400,
          "Pipelined bytes were allowed to contaminate a single-request connection")
    check(responseCode(TelemetryHTTP.parse(Data(repeating: 65, count: 16_385))) == 431,
          "Unterminated HTTP headers escaped the header limit")
    check(responseCode(TelemetryHTTP.parse(wire("POST /other HTTP/1.1\r\n\r\n"))) == 404,
          "Collector accepted an unconfigured endpoint")
    check(responseCode(TelemetryHTTP.parse(wire("GET /v1/readings HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n"))) == 403
          && responseCode(TelemetryHTTP.parse(wire("POST /v1/logs HTTP/1.1\r\nOrigin: null\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"))) == 403,
          "A browser Origin could read or write the local measurement store")
    if case .request(let path, let body) = TelemetryHTTP.parse(wire("GET /v1/readings HTTP/1.1\r\n\r\n")) {
        check(path == "/v1/readings" && body.isEmpty, "Metadata readings endpoint changed")
    } else { check(false, "Metadata readings endpoint was rejected") }
    if case .request(let path, let body) = TelemetryHTTP.parse(wire("GET /v1/diagnostics HTTP/1.1\r\n\r\n")) {
        check(path == "/v1/diagnostics" && body.isEmpty, "Diagnostic metadata endpoint changed")
    } else { check(false, "Diagnostic metadata endpoint was rejected") }
    check(responseCode(TelemetryHTTP.parse(wire("GET /v1/diagnostics HTTP/1.1\r\nOrigin: null\r\n\r\n"))) == 403
          && responseCode(TelemetryHTTP.parse(wire("POST /v1/diagnostics HTTP/1.1\r\nContent-Length: 0\r\n\r\n"))) == 405,
          "Diagnostic endpoint permitted a browser Origin or a write method")
    let encoded = String(data: TelemetryHTTP.encode(code: 200, body: wire("{}")), encoding: .utf8) ?? ""
    check(encoded.contains("Content-Length: 2\r\n") && encoded.contains("Connection: close\r\n")
          && !encoded.contains("Access-Control-Allow-Origin"), "Response framing or CORS contract changed")
    check(collector.lastReceivedAt != nil && collector.state == .receiving && collector.status == "실측 수신 중",
          "A successful export did not update connection freshness")
    check(LocalTelemetryCollector().state == .waiting && TelemetryCollectorState.busyTokenCat.status != TelemetryCollectorState.busyOtherApp.status,
          "Collector states did not separate another TokenCat from another app")
    AppLanguage.with(.en) {
        check(collector.status == "Receiving telemetry"
              && TelemetryCollectorState.busyOtherApp.status == "Telemetry off · another app is using port \(LocalTelemetryCollector.port)",
              "English collector states changed")
    }
    // Status-line session IDs route windows in memory only, without posing as an OTLP export.
    let status = LocalTelemetryCollector()
    func statusLimits() -> ClaudeUsageLimits {
        status.claudeLimits(tokens: [])[ClaudeLimitsByAccount.legacyKey] ?? ClaudeUsageLimits()
    }
    let statusBody = json(["session_id": "status-session", "cwd": "/Users/example/private-project", "transcript_path": "/Users/example/t.jsonl",
                           "model": ["id": "claude-opus-5-5", "display_name": "Opus"], "cost": ["total_cost_usd": 1.25],
                           "rate_limits": ["five_hour": ["used_percentage": 42, "resets_at": 1_790_007_980],
                                           "seven_day": ["used_percentage": 31.5, "resets_at": 1_790_300_000],
                                           "spend_limit": ["used_percentage": 99, "resets_at": 1_790_300_000]]])
    let before = Date()
    check(status.ingest(statusBody, path: LocalTelemetryCollector.claudeStatusPath)
          && statusLimits().fiveHour?.usedPercent == 42 && statusLimits().sevenDay?.usedPercent == 31.5
          && statusLimits().fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_790_007_980)
          && (statusLimits().fiveHour?.receivedAt ?? .distantPast) >= before,
          "Claude status line limits were not decoded")
    let kept = String(decoding: (try? JSONEncoder().encode(status.claudeLimits(tokens: []))) ?? Data(), as: UTF8.self)
    check(!["private-project", "status-session", "claude-opus", "cost", "transcript", "spend"].contains(where: kept.contains)
          && status.snapshot().isEmpty && status.lastBatchAt.isEmpty && status.lastReceivedAt == nil && status.state == .waiting
          && status.diagnostics().entries.isEmpty, "The status line copy kept more than the limits or posed as an OTLP export")
    let invalidWindows = json(["rate_limits": ["five_hour": ["used_percentage": 142, "resets_at": 1_790_007_980],
                                               "seven_day": ["used_percentage": true, "resets_at": 1_790_300_000_000]]])
    check(status.ingest(json(["cwd": "/tmp"]), path: LocalTelemetryCollector.claudeStatusPath)
          && status.ingest(invalidWindows, path: LocalTelemetryCollector.claudeStatusPath)
          && statusLimits().fiveHour?.usedPercent == 42 && statusLimits().sevenDay?.usedPercent == 31.5,
          "A status line without valid limits replaced the kept windows")
    check(!status.ingest(Data("not json".utf8), path: LocalTelemetryCollector.claudeStatusPath)
          && !status.ingest(Data("[1]".utf8), path: LocalTelemetryCollector.claudeStatusPath)
          && !status.ingest(Data(repeating: 32, count: LocalTelemetryCollector.maximumStatusBodyBytes + 1), path: LocalTelemetryCollector.claudeStatusPath),
          "Garbage or oversized status line bodies were accepted")
    let accountA = LimitAccount(id: "account-a", email: "a@example.test")
    let accountB = LimitAccount(id: "account-b", email: "b@example.test")
    var readingA = TokenReading(source: .claude, sessionID: "status-session")
    readingA.limitAccount = accountA
    let routed = status.claudeLimits(tokens: [readingA])
    check(routed[accountA.storageKey]?.fiveHour?.usedPercent == 42 && routed[accountB.storageKey] == nil,
          "Claude status line session attribution used the default account instead of its session")
    let unknown = LocalTelemetryCollector()
    var otherSession = TokenReading(source: .claude, sessionID: "other-session")
    otherSession.limitAccount = accountB
    let unmatched = unknown.ingest(statusBody, path: LocalTelemetryCollector.claudeStatusPath) ? unknown.claudeLimits(tokens: [otherSession]) : [:]
    check(unmatched[accountB.storageKey] == nil && unmatched[ClaudeLimitsByAccount.legacyKey]?.fiveHour?.usedPercent == 42
          && unknown.claudeLimits(tokens: [readingA])[accountA.storageKey]?.fiveHour?.usedPercent == 42,
          "An unmatched Claude status line receipt was attributed to another account instead of staying unattributed until its session is read")
    let secondBody = json(["session_id": "second-session", "rate_limits": ["five_hour": ["used_percentage": 11, "resets_at": 1_790_007_980]]])
    var readingB = TokenReading(source: .claude, sessionID: "second-session")
    readingB.limitAccount = accountB
    check(status.ingest(secondBody, path: LocalTelemetryCollector.claudeStatusPath)
          && status.claudeLimits(tokens: [readingA, readingB])[accountA.storageKey]?.fiveHour?.usedPercent == 42
          && status.claudeLimits(tokens: [readingA, readingB])[accountB.storageKey]?.fiveHour?.usedPercent == 11,
          "Claude status line receipts mixed windows from two session accounts")
    let routedJSON = String(decoding: (try? JSONEncoder().encode(routed)) ?? Data(), as: UTF8.self)
    check(!["account-a", "account-b", "example.test", "status-session"].contains(where: routedJSON.contains),
          "Encoded Claude status line limits exposed account or session identity")
    let statusWire = "POST /v1/claude/status HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
    if case .request(let path, let body) = TelemetryHTTP.parse(wire(statusWire)) {
        check(path == LocalTelemetryCollector.claudeStatusPath && body == wire("{}"), "Status line route altered its body")
    } else { check(false, "Status line route was rejected") }
    check(responseCode(TelemetryHTTP.parse(wire("POST /v1/claude/status HTTP/1.1\r\nOrigin: null\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"))) == 403
          && responseCode(TelemetryHTTP.parse(wire("POST /v1/claude/status HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 65537\r\n\r\n"))) == 413
          && responseCode(TelemetryHTTP.parse(wire("POST /v1/claude/status HTTP/1.1\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}"))) == 400
          && responseCode(TelemetryHTTP.parse(wire("GET /v1/claude/status HTTP/1.1\r\n\r\n"))) == 405,
          "Status line route accepted a browser Origin, an oversized body, a non-JSON type or a read")

    // Never started: retryNow has no retry to run and opens nothing (no port is touched).
    let unstarted = LocalTelemetryCollector(port: 1)
    unstarted.retryNow()
    Thread.sleep(forTimeInterval: 0.05)
    check(!unstarted.isRunning && unstarted.state == .waiting && unstarted.nextRetryAt == nil,
          "retryNow started a collector that was never started")
    print("Telemetry checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}

/// Explicit integration check: callers supply an unused test port, never the app's port.
func runTelemetryLifecycleChecks(port: UInt16) -> [String] {
    var failures: [String] = []
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }
    /// `deadline` is a hard end (something is scheduled at it), so it gets no last look past it.
    func until(timeout: TimeInterval = 2, deadline: Date? = nil, _ condition: () -> Bool) -> Bool {
        let end = deadline ?? Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return deadline == nil && condition()
    }
    let collector = LocalTelemetryCollector(port: port)
    let blocked = LocalTelemetryCollector(port: port, retryDelays: [0.05, 0.1])
    let callbacks = TelemetryCallbackProbe()
    defer { blocked.stop(); collector.stop() }
    collector.start { callbacks.didReady(collector.isRunning) }
    collector.start { callbacks.didDuplicate() }
    check(until { callbacks.snapshot.readyCount == 1 }, "Listener readiness did not deliver its callback")
    check(callbacks.snapshot.onlyReadyCallbacks && collector.isRunning,
          "The ready callback preceded listener readiness")
    // The status line bridge's route over a real loopback socket: limits are kept, a browser Origin is refused.
    final class Reply: @unchecked Sendable { var code: Int? }
    func postStatus(_ body: [String: Any], origin: String? = nil) -> Int? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(LocalTelemetryCollector.claudeStatusPath)")!, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let reply = Reply(), done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, response, _ in reply.code = (response as? HTTPURLResponse)?.statusCode; done.signal() }.resume()
        _ = done.wait(timeout: .now() + 3)
        return reply.code
    }
    let limited: [String: Any] = ["cwd": "/tmp/project", "rate_limits": ["five_hour": ["used_percentage": 12, "resets_at": 1_790_007_980]]]
    check(postStatus(limited, origin: "null") == 403 && collector.claudeLimits(tokens: []).isEmpty
          && postStatus(limited) == 200 && until {
              collector.claudeLimits(tokens: [])[ClaudeLimitsByAccount.legacyKey]?.fiveHour?.usedPercent == 12
          },
          "The status line route did not keep limits over loopback or accepted a browser Origin")
    // A streamed body goes out chunked, as Gemini CLI's and Qwen Code's Node exporters send it.
    func postChunked(_ path: String, _ body: Data) -> Int? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBodyStream = InputStream(data: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let reply = Reply(), done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, response, _ in reply.code = (response as? HTTPURLResponse)?.statusCode; done.signal() }.resume()
        _ = done.wait(timeout: .now() + 3)
        return reply.code
    }
    let qwenBatch = #"{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"qwen-code"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"1791000005000000000","attributes":[{"key":"session.id","value":{"stringValue":"qwen-wire"}},{"key":"event.name","value":{"stringValue":"qwen-code.api_response"}},{"key":"model","value":{"stringValue":"qwen3-coder-plus"}},{"key":"duration_ms","value":{"intValue":1600}},{"key":"output_token_count","value":{"intValue":80}}]}]}]}]}"#
    check(postChunked("/v1/logs", Data(qwenBatch.utf8)) == 200
          && until { collector.snapshot().contains { $0.provider == .qwen && $0.sessionID == "qwen-wire" && $0.outputTokens == 80 } },
          "A chunked Qwen Code export over loopback was not received")
    collector.start { callbacks.didDuplicate() }
    Thread.sleep(forTimeInterval: 0.05)
    check(callbacks.snapshot.readyCount == 1 && callbacks.snapshot.duplicateCount == 0,
          "A duplicate start delivered or replaced a callback")

    blocked.start { callbacks.didRetry() }
    check(until { blocked.state == .busyTokenCat }, "A port held by another TokenCat was not identified by its /health")
    check(until { blocked.nextRetryAt != nil } && !blocked.isRunning && callbacks.snapshot.retryCount == 0,
          "A failed listener delivered a ready callback or scheduled no retry")
    // Past the schedule the last delay repeats, so a port freed minutes later is still taken over.
    Thread.sleep(forTimeInterval: 0.6)
    check(until { blocked.nextRetryAt != nil && blocked.state == .busyTokenCat } && !blocked.isRunning,
          "Retrying stopped after the last scheduled delay")
    collector.stop()
    check(until { callbacks.snapshot.retryCount == 1 } && blocked.isRunning && blocked.state == .waiting,
          "A retry did not take over the port once it was released")
    blocked.stop()
    check(blocked.state == .stopped && blocked.nextRetryAt == nil, "Stopping did not cancel the retry state")

    // A port held by a non-TokenCat process (no /health answer) is reported as another app.
    let other = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = (port &+ 1).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(other, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0 && listen(other, 1) == 0
    defer { close(other) }
    let squatted = LocalTelemetryCollector(port: port &+ 1, retryDelays: [])
    squatted.start { callbacks.didDuplicate() }
    check(bound && until { squatted.state == .busyOtherApp } && !squatted.isRunning && squatted.nextRetryAt == nil,
          "A port held by another app was not reported as such, or retried past its schedule")
    squatted.stop()

    let stoppedCount = callbacks.snapshot.readyCount
    Thread.sleep(forTimeInterval: 0.05)
    check(!collector.isRunning && callbacks.snapshot.readyCount == stoppedCount,
          "A stopped listener delivered a late callback")
    collector.start { callbacks.didReady(collector.isRunning) }
    check(until { callbacks.snapshot.readyCount == 2 } && callbacks.snapshot.duplicateCount == 0,
          "A restart reused an old generation's callback")

    collector.stop()
    collector.start { callbacks.didReady(collector.isRunning) }
    collector.stop()
    let cancelledCount = callbacks.snapshot.readyCount
    Thread.sleep(forTimeInterval: 0.05)
    check(!collector.isRunning && callbacks.snapshot.readyCount == cancelledCount,
          "A cancelled pending start delivered a callback after stop")

    collector.start {
        collector.stop()
        callbacks.didCloseFromCallback()
    }
    check(until { callbacks.snapshot.closedCount == 1 } && !collector.isRunning,
          "Stopping from the ready callback deadlocked or left the listener running")

    // retryNow while a retry waits: one listener starts at once and the pending retry is cancelled. The retry waits 5 s,
    // so a slow release of the port (a busy Mac) still leaves time to start before it.
    let holder = LocalTelemetryCollector(port: port)
    let retrying = LocalTelemetryCollector(port: port, retryDelays: [5])
    let retryCallbacks = TelemetryCallbackProbe()
    defer { holder.stop(); retrying.stop() }
    holder.start()
    check(until { holder.isRunning }, "retryNow: the holder did not take the test port")
    retrying.start { retryCallbacks.didReady(retrying.isRunning) }
    check(until { retrying.nextRetryAt != nil } && !retrying.isRunning && retrying.state == .busyTokenCat,
          "retryNow: no retry was scheduled behind a busy port")
    let scheduled = retrying.nextRetryAt ?? Date()
    let releaseStart = Date()
    holder.stop()
    let released = until(timeout: 5) { telemetryTestPortIsFree(port) }
    let releaseMs = Int(Date().timeIntervalSince(releaseStart) * 1_000)
    check(released, "retryNow: the holder did not release the test port within 5 s (\(releaseMs) ms)")
    let retryStart = Date()
    retrying.retryNow()
    let startedEarly = until(deadline: scheduled) { retrying.isRunning }
    let startMs = Int(Date().timeIntervalSince(retryStart) * 1_000)
    check(startedEarly && retrying.state == .waiting && retrying.nextRetryAt == nil,
          "retryNow did not start the listener before the scheduled retry (release \(releaseMs) ms, start \(startMs) ms, retry due \(Int(scheduled.timeIntervalSince(retryStart) * 1_000)) ms)")
    retrying.retryNow()
    // Past the cancelled deadline a stale attempt would open a second listener, fail on the port and drop the first.
    Thread.sleep(until: scheduled.addingTimeInterval(0.4))
    check(retrying.isRunning && retrying.state == .waiting && retrying.nextRetryAt == nil
          && retryCallbacks.snapshot.readyCount == 1 && retryCallbacks.snapshot.onlyReadyCallbacks,
          "retryNow while waiting left more than one listener or did not cancel the pending retry")
    print("Telemetry lifecycle checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}

/// True when `port` can be bound on loopback right now (the socket is closed again at once). Like the collector's
/// listener, the probe reuses the address: a connection the holder closed first leaves its port in TIME_WAIT for
/// 2 × MSL (30 s), which blocks a plain bind but not the listener, so only a socket still bound there counts.
func telemetryTestPortIsFree(_ port: UInt16) -> Bool {
    let probe = socket(AF_INET, SOCK_STREAM, 0)
    guard probe >= 0 else { return false }
    defer { close(probe) }
    var reuse: Int32 = 1
    guard setsockopt(probe, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return false }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
}

/// A free loopback port whose next port is free too (the lifecycle checks use both); never the app's port.
/// Picked below the kernel's ephemeral range (49152+): there the "another app holds the port" check does not see
/// the squatting socket as busy (observed on macOS 27), so that case could not be exercised.
func telemetryTestPort() -> UInt16? {
    for _ in 0..<64 {
        let port = UInt16.random(in: 40_000...48_000)
        guard port != LocalTelemetryCollector.port, port &+ 1 != LocalTelemetryCollector.port,
              telemetryTestPortIsFree(port), telemetryTestPortIsFree(port &+ 1) else { continue }
        return port
    }
    return nil
}

private final class TelemetryCallbackProbe {
    private let lock = NSLock()
    private var readyCount = 0
    private var duplicateCount = 0
    private var closedCount = 0
    private var retryCount = 0
    private var onlyReadyCallbacks = true
    var snapshot: (readyCount: Int, duplicateCount: Int, closedCount: Int, retryCount: Int, onlyReadyCallbacks: Bool) {
        lock.withLock { (readyCount, duplicateCount, closedCount, retryCount, onlyReadyCallbacks) }
    }
    func didRetry() { lock.withLock { retryCount += 1 } }
    func didReady(_ isRunning: Bool) {
        lock.withLock { readyCount += 1; onlyReadyCallbacks = onlyReadyCallbacks && isRunning }
    }
    func didDuplicate() { lock.withLock { duplicateCount += 1 } }
    func didCloseFromCallback() { lock.withLock { closedCount += 1 } }
}
