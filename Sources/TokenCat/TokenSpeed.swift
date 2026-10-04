import Foundation

enum TokenRateKind: String, Codable {
    case serverGeneration, serverAggregate, requestProcessing
    var title: String {
        switch self {
        case .serverGeneration: return loc("생성 tok/s", "generation tok/s")
        case .serverAggregate: return loc("모델 tok/s", "model tok/s")
        case .requestProcessing: return loc("요청 tok/s", "request tok/s")
        }
    }
}

struct TokenSpeedMeasurement: Codable {
    var model: String?
    var at: Date
    var requestID: String?
    var outputTokens: Int?
    var requestDurationMs: Double?
    var requestDurationIncludesRetries: Bool
    var ttftMs: Double?
    var serverTokenIntervalMs: Double?
    var serverTokenIntervalMetric: String?
    var serverTokenIntervalSampleCount: Int?
    var metricWindowStartedAt: Date?
    var serverInferenceMs: Double?

    init(_ reading: TelemetryReading) {
        model = reading.model
        at = reading.at
        requestID = reading.requestID
        outputTokens = reading.outputTokens
        requestDurationMs = reading.requestDurationMs
        requestDurationIncludesRetries = reading.requestDurationIncludesRetries
        ttftMs = reading.ttftMs
        serverTokenIntervalMs = reading.serverTokenIntervalMs
        serverTokenIntervalMetric = reading.serverTokenIntervalMetric
        serverTokenIntervalSampleCount = reading.serverTokenIntervalSampleCount
        metricWindowStartedAt = reading.metricWindowStartedAt
        serverInferenceMs = reading.serverInferenceMs
    }

    var kind: TokenRateKind? {
        if let interval = serverTokenIntervalMs, interval.isFinite, interval > 0 {
            return (serverTokenIntervalSampleCount ?? 1) > 1 ? .serverAggregate : .serverGeneration
        }
        if let output = outputTokens, output >= 0, let duration = requestDurationMs,
           duration.isFinite, duration > 0 { return .requestProcessing }
        return nil
    }

    var tokensPerSecond: Double? {
        let rate: Double?
        switch kind {
        case .serverGeneration, .serverAggregate: rate = serverTokenIntervalMs.map { 1_000 / $0 }
        case .requestProcessing:
            rate = outputTokens.flatMap { output in requestDurationMs.map { Double(output) * 1_000 / $0 } }
        case nil: rate = nil
        }
        return rate.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    var details: String {
        var lines: [String] = []
        if (kind == .serverGeneration || kind == .serverAggregate), let interval = serverTokenIntervalMs {
            lines.append(String(format: loc("서버 실측 토큰 간 시간 %.3f ms", "Measured server time between tokens %.3f ms"), interval))
            if kind == .serverAggregate, let count = serverTokenIntervalSampleCount {
                lines.append(loc("모델 지표 평균 · 실측 \(count)회", "Model metric average · \(plural(count, "measurement"))"))
            }
            if let start = metricWindowStartedAt {
                let time = start.formatted(Date.FormatStyle(date: .numeric, time: .standard, locale: AppLanguage.current.locale))
                lines.append(loc("실측 구간 시작 \(time)", "Measurement window started \(time)"))
            }
            if let metric = serverTokenIntervalMetric { lines.append(metric) }
        } else if kind == .requestProcessing, let output = outputTokens, let duration = requestDurationMs {
            lines.append(String(format: loc("요청 실측: %d 출력 토큰 / %.0f ms", "Request measurement: %d output tokens / %.0f ms"), output, duration))
            lines.append(requestDurationIncludesRetries ? loc("재시도를 포함한 요청 처리율", "Request processing rate, retries included")
                : loc("성공 요청 처리율 · 첫 응답 대기·추론 포함", "Successful request processing rate · first-response wait and reasoning included"))
        } else { lines.append(loc("속도 미측정", "Speed not measured")) }
        if let ttft = ttftMs, ttft.isFinite, ttft >= 0 { lines.append(String(format: loc("첫 토큰 %.0f ms", "First token %.0f ms"), ttft)) }
        if let inference = serverInferenceMs, inference.isFinite, inference > 0 {
            lines.append(String(format: loc("서버 inference %.0f ms", "Server inference %.0f ms"), inference))
        }
        if let model { lines.append(loc("측정 모델 \(model)", "Measured model \(model)")) }
        if let requestID { lines.append(loc("요청 \(requestID)", "Request \(requestID)")) }
        return lines.joined(separator: "\n")
    }
}

enum TokenSpeed {
    /// Session and agent identities must match. Model names or timing never establish identity.
    static func apply(_ readings: [TokenReading], measurements: [TelemetryReading]) -> [TokenReading] {
        var result = readings
        var latest: [String: TelemetryReading] = [:]
        // Claude also sends unlogged side requests on the session's model right after a turn (a few tokens each); a request
        // missing from a log that has its session and agent is one of them. Dropped before the newest-per-identity pick below,
        // which would otherwise let it replace the real response.
        let logged = Set(readings.filter { $0.source == .claude && !$0.requestIDs.isEmpty }.map { "\($0.sessionID ?? "")|\($0.agentID ?? "")" })
        let known = Set(readings.flatMap(\.requestIDs))
        for var measurement in measurements {
            if (measurement.serverTokenIntervalSampleCount ?? 1) > 1 {
                measurement.sessionID = nil
                measurement.agentID = nil
                measurement.requestID = nil
            }
            if measurement.provider == .claude, let request = measurement.requestID, !known.contains(request),
               logged.contains("\(measurement.sessionID ?? "")|\(measurement.agentID ?? "")") { continue }
            let key = [measurement.provider.rawValue, measurement.sessionID ?? "", measurement.agentID ?? "", measurement.model ?? ""].joined(separator: "\u{1f}")
            if let prior = latest[key] {
                let priorHasRate = TokenSpeedMeasurement(prior).tokensPerSecond != nil
                let newHasRate = TokenSpeedMeasurement(measurement).tokensPerSecond != nil
                if priorHasRate && !newHasRate { continue }
                if priorHasRate == newHasRate && prior.at >= measurement.at { continue }
            }
            latest[key] = measurement
        }
        for measurement in latest.values.sorted(by: { $0.at < $1.at }) {
            let speed = TokenSpeedMeasurement(measurement)
            // Logs only: a telemetry row appended earlier in this loop must not capture a later measurement.
            let sessionMatches = readings.indices.filter { index in
                let reading = result[index]
                guard let session = measurement.sessionID, reading.source == measurement.provider,
                      reading.sessionID == session else { return false }
                return true
            }
            let matches: [Int]
            if (measurement.serverTokenIntervalSampleCount ?? 1) > 1 { matches = [] }
            else if let agent = measurement.agentID { matches = sessionMatches.filter { result[$0].agentID == agent } }
            else if measurement.provider == .claude {
                // Claude Code tags every subagent request with agent_id; an untagged request
                // belongs to the session's single main-thread log.
                let main = sessionMatches.filter { result[$0].agentID == nil && !result[$0].isSubagent }
                matches = main.count == 1 ? main : []
            }
            else { matches = sessionMatches.count == 1 && result[sessionMatches[0]].agentID == nil ? sessionMatches : [] }
            if matches.count == 1, let index = matches.first {
                // A side request on another model (e.g. title generation) must not hide the
                // current model's rate; a different model is shown only when nothing else matches.
                func current(_ value: TokenSpeedMeasurement) -> Bool { value.model != nil && value.model == result[index].model }
                if let existing = result[index].speedMeasurement,
                   current(existing) != current(speed) ? current(existing) : existing.at > speed.at {
                    continue
                }
                result[index].speedMeasurement = speed
            } else {
                let key = [measurement.provider.rawValue, measurement.sessionID ?? "model", measurement.agentID ?? "", measurement.model ?? ""].joined(separator: ":")
                var reading = TokenReading(source: measurement.provider, id: "telemetry:\(key)",
                    sessionID: measurement.sessionID, agentID: measurement.agentID,
                    project: measurement.sessionID == nil ? loc("모델 실측", "Model measurement") : loc("요청 실측", "Request measurement"),
                    model: measurement.model,
                    lastActivity: measurement.at, activityState: .complete)
                reading.speedMeasurement = speed
                result.append(reading)
            }
        }
        return result
    }
}
