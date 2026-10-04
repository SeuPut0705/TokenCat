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
    func logs(_ values: [String: Any], time: String = "1750000000000000000") -> Data {
        json(["resourceLogs": [["resource": ["attributes": attrs(["service.name": "claude-code"])],
            "scopeLogs": [["logRecords": [["timeUnixNano": time, "body": ["stringValue": "claude_code.api_request"],
                "attributes": attrs(values)]]]]]]])
    }
    func trace(_ values: [String: Any]) -> Data {
        json(["resourceSpans": [["resource": ["attributes": attrs(["service.name": "claude-code"])],
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
    for index in 0..<40 {
        _ = diagnostics.ingest(metric("unknown.metric.\(index)"), path: "/v1/metrics")
    }
    check(diagnostics.diagnostics().entries.count == 32
          && diagnostics.diagnostics().entries.last?.metricName == "unknown.metric.39",
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
    check(responseCode(TelemetryHTTP.parse(wire("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2097153\r\n\r\n"))) == 413,
          "Oversized content length was not rejected before body allocation")
    check(responseCode(TelemetryHTTP.parse(wire("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}"))) == 400,
          "Duplicate content lengths permitted request smuggling")
    check(responseCode(TelemetryHTTP.parse(wire("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"))) == 400,
          "Unsupported transfer encoding was accepted")
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
    check(collector.lastReceivedAt != nil && collector.status == "계측 연결됨",
          "A successful export did not update connection freshness")
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
    func until(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }
    let collector = LocalTelemetryCollector(port: port)
    let blocked = LocalTelemetryCollector(port: port)
    let callbacks = TelemetryCallbackProbe()
    defer { blocked.stop(); collector.stop() }
    collector.start { callbacks.didReady(collector.isRunning) }
    collector.start { callbacks.didDuplicate() }
    check(until { callbacks.snapshot.readyCount == 1 }, "Listener readiness did not deliver its callback")
    check(callbacks.snapshot.onlyReadyCallbacks && collector.isRunning,
          "The ready callback preceded listener readiness")
    collector.start { callbacks.didDuplicate() }
    Thread.sleep(forTimeInterval: 0.05)
    check(callbacks.snapshot.readyCount == 1 && callbacks.snapshot.duplicateCount == 0,
          "A duplicate start delivered or replaced a callback")

    blocked.start { callbacks.didDuplicate() }
    check(until { blocked.status.hasPrefix("계측 연결 실패") }, "A port collision did not fail explicitly")
    check(!blocked.isRunning && callbacks.snapshot.duplicateCount == 0,
          "A failed listener delivered a ready callback")

    collector.stop()
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
    print("Telemetry lifecycle checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}

private final class TelemetryCallbackProbe {
    private let lock = NSLock()
    private var readyCount = 0
    private var duplicateCount = 0
    private var closedCount = 0
    private var onlyReadyCallbacks = true
    var snapshot: (readyCount: Int, duplicateCount: Int, closedCount: Int, onlyReadyCallbacks: Bool) {
        lock.withLock { (readyCount, duplicateCount, closedCount, onlyReadyCallbacks) }
    }
    func didReady(_ isRunning: Bool) {
        lock.withLock { readyCount += 1; onlyReadyCallbacks = onlyReadyCallbacks && isRunning }
    }
    func didDuplicate() { lock.withLock { duplicateCount += 1 } }
    func didCloseFromCallback() { lock.withLock { closedCount += 1 } }
}
