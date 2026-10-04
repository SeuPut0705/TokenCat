import Foundation

enum TokenRateKind: String, Codable {
    case serverGeneration, serverAggregate, requestProcessing
    var title: String {
        switch self { case .serverGeneration: return "생성 tok/s"; case .serverAggregate: return "모델 tok/s"; case .requestProcessing: return "요청 tok/s" }
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
            lines.append(String(format: "서버 실측 토큰 간 시간 %.3f ms", interval))
            if kind == .serverAggregate, let count = serverTokenIntervalSampleCount { lines.append("모델 지표 평균 · 실측 \(count)회") }
            if let start = metricWindowStartedAt { lines.append("계측 구간 시작 \(start.formatted(date: .numeric, time: .standard))") }
            if let metric = serverTokenIntervalMetric { lines.append(metric) }
        } else if kind == .requestProcessing, let output = outputTokens, let duration = requestDurationMs {
            lines.append(String(format: "요청 실측: %d 출력 토큰 / %.0f ms", output, duration))
            lines.append(requestDurationIncludesRetries ? "재시도를 포함한 요청 처리율" : "성공 요청 처리율 · 첫 응답 대기·추론 포함")
        } else { lines.append("속도 미측정") }
        if let ttft = ttftMs, ttft.isFinite, ttft >= 0 { lines.append(String(format: "첫 토큰 %.0f ms", ttft)) }
        if let inference = serverInferenceMs, inference.isFinite, inference > 0 {
            lines.append(String(format: "서버 inference %.0f ms", inference))
        }
        if let model { lines.append("측정 모델 \(model)") }
        if let requestID { lines.append("요청 \(requestID)") }
        return lines.joined(separator: "\n")
    }
}

enum TokenSpeed {
    /// Session and agent identities must match. Model names or timing never establish identity.
    static func apply(_ readings: [TokenReading], measurements: [TelemetryReading]) -> [TokenReading] {
        var result = readings
        var latest: [String: TelemetryReading] = [:]
        for var measurement in measurements {
            if (measurement.serverTokenIntervalSampleCount ?? 1) > 1 {
                measurement.sessionID = nil
                measurement.agentID = nil
                measurement.requestID = nil
            }
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
            let sessionMatches = result.indices.filter { index in
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
                    project: measurement.sessionID == nil ? "모델 실측" : "요청 실측",
                    model: measurement.model,
                    lastActivity: measurement.at, activityState: .complete,
                    status: measurement.sessionID == nil ? "세션 식별자가 없는 모델 계측" : "세션 로그와 정확한 식별자 연결 대기")
                reading.speedMeasurement = speed
                result.append(reading)
            }
        }
        return result
    }
}
