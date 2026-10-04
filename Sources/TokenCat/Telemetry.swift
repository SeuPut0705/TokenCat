import Foundation
import CoreFoundation
import Network

/// Only model/request identifiers and explicitly measured numeric fields survive ingestion.
struct TelemetryReading: Codable {
    var provider: TokenSource
    var sessionID: String?
    var agentID: String?
    var model: String?
    var requestID: String?
    var at: Date
    var outputTokens: Int?
    var requestDurationMs: Double?
    var requestDurationIncludesRetries: Bool = false
    var ttftMs: Double?
    var serverTokenIntervalMs: Double?
    var serverTokenIntervalMetric: String?
    var serverTokenIntervalSampleCount: Int?
    var metricWindowStartedAt: Date?
    var serverInferenceMs: Double?
}

struct TelemetryDiagnosticEntry: Codable, Equatable {
    var signal: String
    var resourceServiceName: String?
    var metricName: String?
    var unit: String?
    /// The service/name/unit are eligible; usable numeric points are counted separately.
    var recognized: Bool
}

struct TelemetryDiagnostics: Codable {
    var receivedBatches: [String: Int]
    var decodedReadings: [String: Int]
    var entries: [TelemetryDiagnosticEntry]
}

final class LocalTelemetryCollector {
    static let port: UInt16 = 16493
    static let boundHost = "127.0.0.1"
    static let maximumBodyBytes = 2_097_152
    static let maximumHeaderBytes = 16_384
    static let maximumConnections = 16
    static let maximumReadings = 256
    static let maximumDiagnostics = 32
    static let health: [String: Any] = ["owner": "TokenCat", "appIdentifier": "dev.seuput.TokenCat",
                                       "schema": 1, "port": Int(port)]

    private let queue = DispatchQueue(label: "dev.seuput.TokenCat.telemetry", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: TelemetryConnection] = [:]
    private var running = false
    private var generation = 0
    private var readyCallback: (() -> Void)?
    private var stored: [String: TelemetryRecord] = [:]
    private var diagnosticCounts = ["logs": 0, "metrics": 0, "traces": 0]
    private var diagnosticReadingCounts = ["logs": 0, "metrics": 0, "traces": 0]
    private var diagnosticEntries: [TelemetryDiagnosticEntry] = []
    private var storedStatus = "실측 수신 대기"
    private var receivedAt: Date?
    private var ready = false
    private let listeningPort: UInt16

    init(port: UInt16 = LocalTelemetryCollector.port) {
        listeningPort = port
        queue.setSpecific(key: queueKey, value: ())
    }
    deinit {
        listener?.cancel()
        for request in connections.values { request.close() }
    }

    var status: String { lock.withLock { storedStatus } }
    var lastReceivedAt: Date? { lock.withLock { receivedAt } }
    var isRunning: Bool { lock.withLock { ready } }
    func snapshot() -> [TelemetryReading] {
        lock.withLock {
            stored.sorted { a, b in a.value.reading.at == b.value.reading.at
                ? a.key < b.key : a.value.reading.at > b.value.reading.at }.map { $0.value.reading }
        }
    }
    func diagnostics() -> TelemetryDiagnostics {
        lock.withLock { TelemetryDiagnostics(receivedBatches: diagnosticCounts,
            decodedReadings: diagnosticReadingCounts, entries: diagnosticEntries) }
    }

    /// Invoked once on the collector queue after this start owns the listening port.
    /// Duplicate starts discard their callback; UI work must dispatch to the main queue.
    func start(onReady: (() -> Void)? = nil) {
        queue.async { [weak self] in self?.startOnQueue(onReady: onReady) }
    }

    private func startOnQueue(onReady: (() -> Void)?) {
        guard !running else { return }
        running = true
        generation += 1
        readyCallback = onReady
        let epoch = generation
        setStatus("계측 연결 준비 중")
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: listeningPort)!)
            parameters.allowLocalEndpointReuse = false
            // The port is already part of requiredLocalEndpoint. Passing it again to
            // NWListener(using:on:) rejects the fixed host/port with POSIX EINVAL.
            let server = try NWListener(using: parameters)
            listener = server
            server.stateUpdateHandler = { [weak self] state in
                guard let self, self.running, self.generation == epoch else { return }
                switch state {
                case .ready:
                    self.lock.withLock { self.ready = true }
                    self.setStatus("실측 수신 대기")
                    let callback = self.readyCallback
                    self.readyCallback = nil
                    callback?()
                case .failed:
                    self.setStatus("계측 연결 실패 · 포트 \(self.listeningPort)")
                    self.stopOnQueue(updateStatus: false)
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                guard let self, self.running, self.generation == epoch else { connection.cancel(); return }
                guard self.connections.count < Self.maximumConnections else { connection.cancel(); return }
                let request = TelemetryConnection(connection: connection, queue: self.queue,
                    handler: { [weak self] route, body in
                        guard let self, self.running, self.generation == epoch else { return .response(code: 400, body: Data("{}".utf8)) }
                        if route == "/v1/readings" {
                            let encoder = JSONEncoder()
                            encoder.dateEncodingStrategy = .iso8601
                            return .response(code: 200, body: (try? encoder.encode(self.snapshot())) ?? Data("[]".utf8))
                        }
                        if route == "/v1/diagnostics" {
                            return .response(code: 200, body: (try? JSONEncoder().encode(self.diagnostics())) ?? Data("{}".utf8))
                        }
                        if route == "/health" {
                            var health = Self.health
                            health["port"] = Int(self.listeningPort)
                            return .response(code: 200, body: (try? JSONSerialization.data(withJSONObject: health)) ?? Data("{}".utf8))
                        }
                        return .response(code: self.ingest(body, path: route) ? 200 : 400, body: Data("{}".utf8))
                    }, finished: { [weak self] id in self?.connections.removeValue(forKey: id) })
                self.connections[request.id] = request
                request.start()
            }
            server.start(queue: queue)
        } catch {
            setStatus("계측 연결 실패 · 포트 \(listeningPort)")
            stopOnQueue(updateStatus: false)
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { stopOnQueue(updateStatus: true) }
        else { queue.sync { stopOnQueue(updateStatus: true) } }
    }

    private func stopOnQueue(updateStatus: Bool) {
        running = false
        readyCallback = nil
        lock.withLock { ready = false }
        generation += 1
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let pending = Array(connections.values)
        connections.removeAll()
        for request in pending { request.close() }
        if updateStatus { setStatus("계측 연결 중지됨") }
    }

    private func setStatus(_ value: String) { lock.withLock { storedStatus = value } }

    static func isOwnCollectorRunning(timeout: TimeInterval = 1) -> Bool {
        let deadline = Date().addingTimeInterval(max(0.05, timeout))
        return verifiedHealth(deadline: deadline)
    }

    static func fetchSnapshot(timeout: TimeInterval = 1) -> [TelemetryReading] {
        let deadline = Date().addingTimeInterval(max(0.05, timeout))
        guard verifiedHealth(deadline: deadline),
              let data = TelemetryFetchOperation.fetch(path: "/v1/readings", deadline: deadline, maximumBytes: 1_048_576) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let readings = try? decoder.decode([TelemetryReading].self, from: data),
              readings.count <= maximumReadings else { return [] }
        return readings
    }

    private static func verifiedHealth(deadline: Date) -> Bool {
        guard let data = TelemetryFetchOperation.fetch(path: "/health", deadline: deadline, maximumBytes: 1024),
              let health = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              health["owner"] as? String == "TokenCat", health["appIdentifier"] as? String == "dev.seuput.TokenCat",
              let schema = health["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(),
              schema.doubleValue == 1, health["port"] as? Int == Int(port) else { return false }
        return true
    }

    /// Kept internal so the decoder and transport can be checked without opening a port.
    @discardableResult
    func ingest(_ data: Data, path: String) -> Bool {
        guard let signal = ["/v1/logs": "logs", "/v1/metrics": "metrics", "/v1/traces": "traces"][path] else { return false }
        lock.withLock { diagnosticCounts[signal] = min(diagnosticCounts[signal] ?? 0, Int.max - 1) + 1 }
        guard data.count <= Self.maximumBodyBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let records = TelemetryDecoder.decode(root, path: path) else { return false }
        let diagnostics = TelemetryDecoder.diagnostics(root, path: path)
        lock.withLock {
            diagnosticReadingCounts[signal] = min(diagnosticReadingCounts[signal] ?? 0, Int.max - records.count) + records.count
            for entry in diagnostics {
                diagnosticEntries.removeAll { $0 == entry }
                diagnosticEntries.append(entry)
                if diagnosticEntries.count > Self.maximumDiagnostics { diagnosticEntries.removeFirst() }
            }
            for record in records {
                let key = record.key
                if var previous = stored[key] {
                    // A request ID cannot silently move to another agent or model.
                    if let a = previous.reading.agentID, let b = record.reading.agentID, a != b { continue }
                    if let a = previous.reading.model, let b = record.reading.model, a != b { continue }
                    previous.merge(record)
                    stored[key] = previous
                } else { stored[key] = record }
            }
            if stored.count > Self.maximumReadings {
                let keep = stored.sorted { a, b in a.value.reading.at == b.value.reading.at
                    ? a.key < b.key : a.value.reading.at > b.value.reading.at }.prefix(Self.maximumReadings)
                stored = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            receivedAt = Date()
            storedStatus = "계측 연결됨"
        }
        return true
    }
}

private struct TelemetryRecord {
    var reading: TelemetryReading
    var durationPriority: Int = 0
    var intervalPriority: Int = 0
    var key: String {
        let scope = "\(reading.provider.rawValue)|\(reading.sessionID ?? "")|"
        if let request = reading.requestID { return scope + "request|" + request }
        // No request ID means that only an identical timestamped observation deduplicates.
        return scope + "observation|\(reading.agentID ?? "")|\(reading.model ?? "")|\(reading.at.timeIntervalSince1970)"
    }
    mutating func merge(_ incoming: Self) {
        reading.agentID = reading.agentID ?? incoming.reading.agentID
        reading.model = reading.model ?? incoming.reading.model
        reading.at = max(reading.at, incoming.reading.at)
        if let tokens = incoming.reading.outputTokens {
            reading.outputTokens = max(reading.outputTokens ?? 0, tokens)
        }
        if let duration = incoming.reading.requestDurationMs,
           reading.requestDurationMs == nil || incoming.durationPriority > durationPriority {
            reading.requestDurationMs = duration
            reading.requestDurationIncludesRetries = incoming.reading.requestDurationIncludesRetries
            durationPriority = incoming.durationPriority
        }
        if let ttft = incoming.reading.ttftMs { reading.ttftMs = ttft }
        if let interval = incoming.reading.serverTokenIntervalMs,
           reading.serverTokenIntervalMs == nil || incoming.intervalPriority > intervalPriority {
            reading.serverTokenIntervalMs = interval
            reading.serverTokenIntervalMetric = incoming.reading.serverTokenIntervalMetric
            reading.serverTokenIntervalSampleCount = incoming.reading.serverTokenIntervalSampleCount
            reading.metricWindowStartedAt = incoming.reading.metricWindowStartedAt
            intervalPriority = incoming.intervalPriority
        }
        reading.serverInferenceMs = incoming.reading.serverInferenceMs ?? reading.serverInferenceMs
    }
}

private enum TelemetryDecoder {
    private static let allowedKeys: Set<String> = ["service.name", "session.id", "session_id",
        "conversation.id", "conversation_id", "agent.id", "agent_id", "model", "gen_ai.request.model",
        "request_id", "request.id", "gen_ai.response.id", "event.name", "event_name", "event.timestamp",
        "duration_ms", "ttft_ms", "output_tokens", "success"]
    private static let metricKinds: [String: Int] = [
        "codex.responses_api_engine_service_tbt.duration_ms": 1,
        "codex.responses_api_engine_iapi_tbt.duration_ms": 2,
        "codex.responses_api_inference_time.duration_ms": 3
    ]

    static func decode(_ root: [String: Any], path: String) -> [TelemetryRecord]? {
        var result: [TelemetryRecord] = []
        let resourceKey: String
        switch path {
        case "/v1/logs": resourceKey = "resourceLogs"
        case "/v1/metrics": resourceKey = "resourceMetrics"
        case "/v1/traces": resourceKey = "resourceSpans"
        default: return nil
        }
        guard root.isEmpty || root[resourceKey] != nil else { return nil }
        guard let resources = root[resourceKey] as? [[String: Any]] ?? (root.isEmpty ? [] : nil) else { return nil }
        for resource in resources {
            let base = attributes((resource["resource"] as? [String: Any])?["attributes"])
            let scopeKey = path == "/v1/logs" ? "scopeLogs" : path == "/v1/metrics" ? "scopeMetrics" : "scopeSpans"
            guard let scopes = resource[scopeKey] as? [[String: Any]] else { return nil }
            for scope in scopes {
                if path == "/v1/logs" {
                    guard let logs = scope["logRecords"] as? [[String: Any]] else { return nil }
                    for log in logs {
                        let attrs = base.merging(attributes(log["attributes"]), uniquingKeysWith: { _, value in value })
                        if attrs["success"] as? Bool == false { continue }
                        let body = (log["body"] as? [String: Any])?["stringValue"] as? String
                        let name = attrs["event.name"] as? String ?? attrs["event_name"] as? String ?? body
                        guard name == "api_request" || name == "claude_code.api_request",
                              source(base, fallback: name) == .claude,
                              let tokens = integer(attrs["output_tokens"]),
                              let duration = number(attrs["duration_ms"]), duration > 0 else { continue }
                        var reading = metadata(attrs, source: .claude, at: timestamp(log["timeUnixNano"], attrs: attrs))
                        reading.outputTokens = tokens
                        reading.requestDurationMs = duration
                        result.append(TelemetryRecord(reading: reading, durationPriority: 2))
                    }
                } else if path == "/v1/traces" {
                    guard let spans = scope["spans"] as? [[String: Any]] else { return nil }
                    for span in spans {
                        guard span["name"] as? String == "claude_code.llm_request",
                              source(base, fallback: "claude_code.llm_request") == .claude else { continue }
                        let attrs = base.merging(attributes(span["attributes"]), uniquingKeysWith: { _, value in value })
                        if attrs["success"] as? Bool == false { continue }
                        if let status = span["status"] as? [String: Any], integer(status["code"]) == 2 { continue }
                        var reading = metadata(attrs, source: .claude, at: timestamp(span["endTimeUnixNano"], attrs: attrs))
                        reading.outputTokens = integer(attrs["output_tokens"])
                        reading.requestDurationMs = number(attrs["duration_ms"]).flatMap { $0 > 0 ? $0 : nil }
                        reading.requestDurationIncludesRetries = true
                        reading.ttftMs = number(attrs["ttft_ms"])
                        guard reading.outputTokens != nil || reading.ttftMs != nil else { continue }
                        result.append(TelemetryRecord(reading: reading, durationPriority: 1))
                    }
                } else {
                    guard let metrics = scope["metrics"] as? [[String: Any]] else { return nil }
                    for metric in metrics {
                        guard let name = metric["name"] as? String, let kind = metricKinds[name],
                              source(base, fallback: name) == .codex else { continue }
                        if let unit = metric["unit"] as? String, !unit.isEmpty && unit != "ms" { continue }
                        let histogram = metric["histogram"] as? [String: Any]
                        let gauge = metric["gauge"] as? [String: Any]
                        guard let points = (histogram ?? gauge)?["dataPoints"] as? [[String: Any]] else { continue }
                        for point in points {
                            let value: Double?
                            let count: Int
                            if histogram != nil {
                                guard let sampleCount = integer(point["count"]), sampleCount > 0,
                                      let sum = number(point["sum"]), sum > 0 else { continue }
                                count = sampleCount
                                value = sum / Double(sampleCount)
                            } else {
                                count = 1
                                value = number(point["asDouble"] ?? point["asInt"])
                            }
                            guard let value, value > 0 else { continue }
                            let attrs = base.merging(attributes(point["attributes"]), uniquingKeysWith: { _, value in value })
                            var reading = metadata(attrs, source: .codex, at: timestamp(point["timeUnixNano"], attrs: attrs))
                            if count > 1 {
                                // Multiple server observations are valid model-level measurements,
                                // never an individual session/request's generation rate.
                                reading.sessionID = nil
                                reading.agentID = nil
                                reading.requestID = nil
                            }
                            reading.metricWindowStartedAt = nanoDate(point["startTimeUnixNano"])
                            if kind == 3 { reading.serverInferenceMs = value }
                            else {
                                reading.serverTokenIntervalMs = value
                                reading.serverTokenIntervalMetric = name
                                reading.serverTokenIntervalSampleCount = count
                            }
                            result.append(TelemetryRecord(reading: reading, intervalPriority: kind == 1 ? 2 : 1))
                        }
                    }
                }
            }
        }
        return result
    }

    private static func source(_ attrs: [String: Any], fallback: String?) -> TokenSource? {
        if let service = attrs["service.name"] as? String {
            switch service {
            // CLI services and the exact service observed in Claude desktop OTLP.
            case "claude-code", "claude_code", "claude-code-desktop": return .claude
            // Fixed first-party surfaces present in the bundled 0.160.0 CLI's
            // service-name classification; unknown/custom services stay rejected.
            case "codex", "codex-cli", "codex_cli_rs", "codex_exec", "codex-app-server",
                 "codex_desktop", "codex-tui", "codex_vscode", "codex_mcp_server",
                 "codex_sdk_ts", "codex-app-server-sdk", "Codex Desktop": return .codex
            default: return nil
            }
        }
        if fallback?.hasPrefix("claude_code.") == true { return .claude }
        if fallback?.hasPrefix("codex.") == true { return .codex }
        return nil
    }

    /// Only bounded signal/service/metric/unit metadata is retained, never log bodies or attributes.
    static func diagnostics(_ root: [String: Any], path: String) -> [TelemetryDiagnosticEntry] {
        let signal = path == "/v1/logs" ? "logs" : path == "/v1/metrics" ? "metrics" : "traces"
        let resourceKey = path == "/v1/logs" ? "resourceLogs" : path == "/v1/metrics" ? "resourceMetrics" : "resourceSpans"
        let scopeKey = path == "/v1/logs" ? "scopeLogs" : path == "/v1/metrics" ? "scopeMetrics" : "scopeSpans"
        var result: [TelemetryDiagnosticEntry] = []
        func bounded(_ value: Any?) -> String? {
            guard let string = value as? String else { return value == nil ? nil : "__invalid_metadata__" }
            guard string.utf8.count <= 256, string.utf8.allSatisfy({ (32...126).contains($0) }) else { return "__invalid_metadata__" }
            return string
        }
        func append(_ entry: TelemetryDiagnosticEntry) {
            result.removeAll { $0 == entry }
            result.append(entry)
            if result.count > LocalTelemetryCollector.maximumDiagnostics { result.removeFirst() }
        }
        for resource in root[resourceKey] as? [[String: Any]] ?? [] {
            let base = attributes((resource["resource"] as? [String: Any])?["attributes"])
            let service = bounded(base["service.name"])
            if signal != "metrics" {
                append(TelemetryDiagnosticEntry(signal: signal, resourceServiceName: service,
                    recognized: source(base, fallback: nil) == .claude))
                continue
            }
            for scope in resource[scopeKey] as? [[String: Any]] ?? [] {
                for metric in scope["metrics"] as? [[String: Any]] ?? [] {
                    let name = metric["name"] as? String
                    let unit = metric["unit"] as? String
                    let recognized = name.flatMap { metricKinds[$0] } != nil
                        && source(base, fallback: name) == .codex && (unit == nil || unit == "" || unit == "ms")
                    append(TelemetryDiagnosticEntry(signal: signal, resourceServiceName: service,
                        metricName: bounded(metric["name"]), unit: bounded(metric["unit"]), recognized: recognized))
                }
            }
        }
        return result
    }

    private static func attributes(_ value: Any?) -> [String: Any] {
        guard let entries = value as? [[String: Any]] else { return [:] }
        var result: [String: Any] = [:]
        for entry in entries {
            guard let key = entry["key"] as? String, allowedKeys.contains(key) else { continue }
            if key == "service.name" {
                // An explicit unrecognized service must not disappear and activate
                // the absent-resource fallback. This value never enters a reading.
                let service = (entry["value"] as? [String: Any])?["stringValue"] as? String
                result[key] = service.flatMap { $0.utf8.count <= 256 ? $0 : nil } ?? "__invalid_service__"
                continue
            }
            guard let wrapped = entry["value"] as? [String: Any] else { continue }
            if key == "success", let value = wrapped["boolValue"] as? Bool { result[key] = value }
            else if let string = wrapped["stringValue"] as? String {
                if key == "event.timestamp" { result[key] = string.count <= 64 ? string : nil }
                else if let safe = identifier(string) { result[key] = safe }
            } else if let number = number(wrapped["intValue"] ?? wrapped["doubleValue"]) { result[key] = number }
        }
        return result
    }

    private static func metadata(_ attrs: [String: Any], source: TokenSource, at: Date) -> TelemetryReading {
        func string(_ names: [String]) -> String? { names.compactMap { attrs[$0] as? String }.first }
        return TelemetryReading(provider: source,
            sessionID: string(["session.id", "session_id", "conversation.id", "conversation_id"]),
            agentID: string(["agent_id", "agent.id"]), model: string(["model", "gen_ai.request.model"]),
            requestID: string(["request_id", "request.id", "gen_ai.response.id"]), at: at)
    }

    private static func identifier(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || "-_.:/@".utf8.contains($0) }) else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { parsed = n.doubleValue }
        else if let string = value as? String, string.count <= 32 { parsed = Double(string) }
        else { parsed = nil }
        guard let parsed, parsed.isFinite, parsed >= 0 else { return nil }
        return parsed
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.rounded(.towardZero) == number, number < Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func timestamp(_ value: Any?, attrs: [String: Any]) -> Date {
        if let date = nanoDate(value) { return date }
        if let iso = attrs["event.timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: iso) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: iso) { return date }
        }
        return Date()
    }

    private static func nanoDate(_ value: Any?) -> Date? {
        guard let n = number(value), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n / 1_000_000_000)
    }
}

enum TelemetryHTTPDecision {
    case waiting
    case request(path: String, body: Data)
    case response(code: Int, body: Data)
}

enum TelemetryHTTP {
    private static func response(_ code: Int) -> TelemetryHTTPDecision {
        .response(code: code, body: Data("{}".utf8))
    }
    static func parse(_ data: Data) -> TelemetryHTTPDecision {
        let terminator = Data([13, 10, 13, 10])
        guard let range = data.range(of: terminator) else {
            return data.count > LocalTelemetryCollector.maximumHeaderBytes ? response(431) : .waiting
        }
        guard range.upperBound <= LocalTelemetryCollector.maximumHeaderBytes,
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else { return response(431) }
        let lines = header.components(separatedBy: "\r\n")
        let start = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(start[2])) else { return response(400) }
        var length: Int?
        var contentType: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return response(400) }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return response(400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "origin" { return response(403) }
            if key == "transfer-encoding" { return response(400) }
            if key == "content-length" {
                guard length == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let count = Int(value) else { return response(400) }
                if count > LocalTelemetryCollector.maximumBodyBytes { return response(413) }
                length = count
            }
            if key == "content-type" {
                guard contentType == nil else { return response(400) }
                contentType = value.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            }
        }
        let method = String(start[0]), path = String(start[1])
        if ["/health", "/v1/readings", "/v1/diagnostics"].contains(path) {
            guard method == "GET" else { return response(405) }
            guard (length ?? 0) == 0, data.count == range.upperBound else { return response(400) }
            return .request(path: path, body: Data())
        }
        guard ["/v1/logs", "/v1/metrics", "/v1/traces"].contains(path) else { return response(404) }
        guard method == "POST" else { return response(405) }
        guard contentType == "application/json", let length else { return response(400) }
        let end = range.upperBound + length
        if data.count < end { return .waiting }
        guard data.count == end else { return response(400) }
        return .request(path: path, body: Data(data[range.upperBound..<end]))
    }

    static func encode(code: Int, body: Data) -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                       408: "Request Timeout", 413: "Content Too Large", 431: "Request Header Fields Too Large"]
        var data = Data("HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}

private final class TelemetryConnection {
    let id = UUID()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: (String, Data) -> TelemetryHTTPDecision
    private let finished: (UUID) -> Void
    private var buffer = Data()
    private var deadline: DispatchWorkItem?
    private var closed = false
    private var responding = false

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping (String, Data) -> TelemetryHTTPDecision,
         finished: @escaping (UUID) -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.finished = finished
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.close() }
        deadline = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        guard !closed, !responding else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed, !self.responding else { return }
            if let data { self.buffer.append(data) }
            switch TelemetryHTTP.parse(self.buffer) {
            case .response(let code, let body): self.respond(code: code, body: body)
            case .request(let path, let body):
                if case .response(let code, let response) = self.handler(path, body) { self.respond(code: code, body: response) }
                else { self.respond(code: 400, body: Data("{}".utf8)) }
            case .waiting:
                if complete || error != nil { self.close() }
                else { self.receive() }
            }
        }
    }

    private func respond(code: Int, body: Data) {
        guard !closed, !responding else { return }
        responding = true
        buffer.removeAll(keepingCapacity: false)
        connection.send(content: TelemetryHTTP.encode(code: code, body: body), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        deadline?.cancel()
        deadline = nil
        buffer.removeAll(keepingCapacity: false)
        connection.stateUpdateHandler = nil
        connection.cancel()
        finished(id)
    }
}

/// CLI readers use the running app's collector instead of binding a second listener.
/// Reads are bounded in time and bytes, and never follow redirects off loopback.
private final class TelemetryFetchOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let maximumBytes: Int
    private var body = Data()
    private var completed = false
    private var succeeded = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    static func fetch(path: String, deadline: Date, maximumBytes: Int) -> Data? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0,
              let url = URL(string: "http://127.0.0.1:\(LocalTelemetryCollector.port)\(path)") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = remaining
        configuration.timeoutIntervalForResource = remaining
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let operation = TelemetryFetchOperation(maximumBytes: maximumBytes)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: delegateQueue)
        let task = session.dataTask(with: url)
        defer { task.cancel(); session.invalidateAndCancel() }
        task.resume()
        guard operation.semaphore.wait(timeout: .now() + remaining) == .success else { return nil }
        return operation.lock.withLock { operation.succeeded ? operation.body : nil }
    }

    private func finish(_ successful: Bool) {
        let signal = lock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            succeeded = successful
            if !successful { body.removeAll(keepingCapacity: false) }
            return true
        }
        if signal { semaphore.signal() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (response.expectedContentLength <= Int64(maximumBytes) || response.expectedContentLength < 0) else {
            finish(false)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = lock.withLock { () -> Bool in
            guard !completed else { return false }
            guard body.count + data.count <= maximumBytes else { return true }
            body.append(data)
            return false
        }
        if tooLarge { finish(false); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        finish(false)
        completionHandler(nil)
    }
}
