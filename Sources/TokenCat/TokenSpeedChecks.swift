import Foundation

func runTokenSpeedChecks() -> [String] {
    var failures: [String] = []
    var checks = 0
    func check(_ name: String, _ condition: Bool) {
        checks += 1
        if !condition { failures.append("Token speed \(name)") }
    }
    func reading(_ values: [String: Any]) -> TelemetryReading {
        var data: [String: Any] = ["provider": "codex", "at": "2026-10-04T10:00:00Z", "model": "same-model", "requestDurationIncludesRetries": false]
        data.merge(values) { _, new in new }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(TelemetryReading.self, from: JSONSerialization.data(withJSONObject: data))
    }
    let server = reading(["sessionID": "a", "serverTokenIntervalMs": 40, "serverTokenIntervalSampleCount": 1,
                          "outputTokens": 200, "requestDurationMs": 1_000])
    let serverSpeed = TokenSpeedMeasurement(server)
    check("server interval gives generation rate, not request rate", serverSpeed.kind == .serverGeneration && serverSpeed.tokensPerSecond == 25)
    let request = reading(["provider": "claude", "sessionID": "a", "outputTokens": 120, "requestDurationMs": 2_400])
    let requestSpeed = TokenSpeedMeasurement(request)
    check("exact request fields give distinct processing rate", requestSpeed.kind == .requestProcessing && requestSpeed.tokensPerSecond == 50)
    let timingOnly = reading(["outputTokens": 1_000, "serverInferenceMs": 10, "ttftMs": 1])
    check("inference or TTFT cannot substitute a matched duration", TokenSpeedMeasurement(timingOnly).tokensPerSecond == nil)
    var invalid = server
    invalid.serverTokenIntervalMs = .infinity
    invalid.outputTokens = nil
    invalid.requestDurationMs = nil
    check("nonfinite fields produce no speed", TokenSpeedMeasurement(invalid).tokensPerSecond == nil)
    let zeroDuration = reading(["outputTokens": 120, "requestDurationMs": 0, "serverTokenIntervalMs": 0])
    check("zero time never produces invented speed", TokenSpeedMeasurement(zeroDuration).tokensPerSecond == nil)

    let a = TokenReading(source: .codex, id: "a", sessionID: "a", model: "same-model", lastOutputTokens: 999)
    let b = TokenReading(source: .codex, id: "b", sessionID: "b", model: "same-model", lastOutputTokens: 999)
    let matched = TokenSpeed.apply([a, b], measurements: [server])
    check("identical models do not mix sessions", matched.count == 2 && matched[0].speedMeasurement?.tokensPerSecond == 25 && matched[1].speedMeasurement == nil)
    check("log output counts never become measured speed", TokenSpeed.apply([a], measurements: []).first?.speedMeasurement == nil)
    let wrongProvider = TokenSpeed.apply([a], measurements: [request])
    check("providers cannot cross a shared session identifier", wrongProvider.count == 2 && wrongProvider[0].speedMeasurement == nil)
    let child = TokenReading(source: .codex, id: "child", sessionID: "a", agentID: "worker", model: "same-model", isSubagent: true)
    let ambiguous = TokenSpeed.apply([a, child], measurements: [server])
    check("missing agent cannot select a parent among shared sessions", ambiguous.count == 3 && ambiguous[0].speedMeasurement == nil && ambiguous[1].speedMeasurement == nil)
    // Codex subagents log in their own thread (own session ID, agent path set); telemetry names only that thread.
    let thread = TokenReading(source: .codex, id: "thread", sessionID: "worker-thread", agentID: "/root/worker", model: "same-model", isSubagent: true)
    var threadServer = server
    threadServer.sessionID = "worker-thread"
    let threaded = TokenSpeed.apply([a, thread], measurements: [threadServer])
    check("a Codex subagent's own-thread rate attaches to it without an extra row",
          threaded.count == 2 && threaded[0].speedMeasurement == nil && threaded[1].speedMeasurement?.tokensPerSecond == 25)
    let claudeMain = TokenReading(source: .claude, id: "claude-main", sessionID: "c", model: "main-model")
    let claudeChild = TokenReading(source: .claude, id: "claude-child", sessionID: "c", agentID: "helper",
                                   model: "main-model", isSubagent: true)
    let mainRequest = reading(["provider": "claude", "sessionID": "c", "model": "main-model",
                               "outputTokens": 300, "requestDurationMs": 3_000])
    let sideRequest = reading(["provider": "claude", "sessionID": "c", "model": "side-model", "at": "2026-10-04T10:00:05Z",
                               "outputTokens": 10, "requestDurationMs": 500])
    let claudeShared = TokenSpeed.apply([claudeMain, claudeChild], measurements: [mainRequest, sideRequest])
    check("untagged Claude request attaches to the main log, not its subagent or a new row",
          claudeShared.count == 2 && claudeShared[0].speedMeasurement?.tokensPerSecond == 100
          && claudeShared[1].speedMeasurement == nil)
    check("a newer side request on another model does not hide the current model's rate",
          claudeShared[0].speedMeasurement?.model == "main-model")
    let sideOnly = TokenSpeed.apply([claudeMain], measurements: [sideRequest])
    check("a different-model rate is kept when it is the only match", sideOnly.count == 1
          && sideOnly[0].speedMeasurement?.model == "side-model")
    var loggedMain = claudeMain
    loggedMain.requestIDs = ["req-main"]
    var loggedRequest = mainRequest
    loggedRequest.requestID = "req-main"
    let unloggedSide = reading(["provider": "claude", "sessionID": "c", "model": "main-model", "at": "2026-10-04T10:00:05Z",
                                "requestID": "req-side", "outputTokens": 8, "requestDurationMs": 2_773])
    let filtered = TokenSpeed.apply([loggedMain], measurements: [loggedRequest, unloggedSide])
    check("a same-model side request missing from the log does not replace the logged response",
          filtered.count == 1 && filtered[0].speedMeasurement?.requestID == "req-main")
    let logless = TokenSpeed.apply([], measurements: [sideRequest, mainRequest])
    check("a session without a log keeps one telemetry row per model", logless.count == 2
          && Set(logless.compactMap { $0.speedMeasurement?.model }) == ["main-model", "side-model"])
    var agent = server
    agent.agentID = "worker"
    let identified = TokenSpeed.apply([a, child], measurements: [agent])
    check("known agent attaches only to exact identity", identified.count == 2 && identified[0].speedMeasurement == nil && identified[1].speedMeasurement?.tokensPerSecond == 25)
    var untracked = server
    untracked.agentID = "untracked"
    check("an untracked agent of a logged session adds no row", TokenSpeed.apply([a], measurements: [untracked]).count == 1)
    let modelOnly = reading(["serverTokenIntervalMs": 40])
    let detached = TokenSpeed.apply([a, b], measurements: [modelOnly])
    check("model-only observations stay independently identified", detached.count == 3 && detached.last?.project == "모델 실측" && detached[0].speedMeasurement == nil && detached[1].speedMeasurement == nil)
    var aggregate = server
    aggregate.serverTokenIntervalSampleCount = 4
    let aggregates = TokenSpeed.apply([a], measurements: [aggregate])
    check("aggregate metrics never attach to a session", aggregates.count == 2 && aggregates[0].speedMeasurement == nil && aggregates[1].sessionID == nil && aggregates[1].speedMeasurement?.kind == .serverAggregate)
    var newerIncomplete = server
    newerIncomplete.at = server.at.addingTimeInterval(1)
    newerIncomplete.serverTokenIntervalMs = nil
    newerIncomplete.outputTokens = nil
    newerIncomplete.requestDurationMs = nil
    let retained = TokenSpeed.apply([a], measurements: [server, newerIncomplete])
    check("incomplete timing record does not erase latest measured rate", retained[0].speedMeasurement?.tokensPerSecond == 25 && retained[0].speedMeasurement?.at == server.at)
    AppLanguage.with(.en) {
        check("English kinds, details with a plural count, or project labels",
              TokenRateKind.serverGeneration.title == "generation tok/s"
              && TokenSpeedMeasurement(aggregate).details.hasPrefix("Measured server time between tokens 40.000 ms\nModel metric average · 4 measurements\n")
              && requestSpeed.details.hasPrefix("Request measurement: 120 output tokens / 2400 ms\nSuccessful request processing rate")
              && TokenSpeed.apply([], measurements: [modelOnly]).first?.project == "Model measurement")
    }
    print("Token speed checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
