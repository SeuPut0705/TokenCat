import Foundation

/// Session titles: `SessionTitle.clean`, and per client a fixture that produces a title, a rename that replaces it and a
/// session without one (Claude Code, Codex, omp, Pi, Gemini CLI, Qwen Code; OpenCode, Copilot CLI, Amp and Droid are
/// covered beside their other fixtures). Synthetic metadata only, temp homes. Run from `runTrackerChecks`.
func sessionTitleChecks(_ check: (Bool, String) -> Void) {
    // Sanitising: one line, collapsed space, no invisible reordering, at most 80 characters ending in "…".
    let long = String(repeating: "abcdefghij ", count: 12)
    check(SessionTitle.clean("  Fix\tthe\n\nlogin \u{0007}bug\r\n ") == "Fix the login bug"
          && SessionTitle.clean("a\u{202E}b\u{2066}c\u{FEFF}d") == "abcd"
          && SessionTitle.clean("👩‍💻 Pair session") == "👩‍💻 Pair session"
          && SessionTitle.clean(long)?.count == SessionTitle.maximumLength && SessionTitle.clean(long)?.hasSuffix("…") == true
          && SessionTitle.clean(long)?.hasSuffix(" …") == false
          && SessionTitle.clean(String(repeating: "가", count: 80)) == String(repeating: "가", count: 80)
          && SessionTitle.clean(" \n\t ") == nil && SessionTitle.clean("") == nil && SessionTitle.clean(42) == nil
          && SessionTitle.clean(String(repeating: "x", count: 100_000))?.count == SessionTitle.maximumLength,
          "Session title: control characters, line breaks, bidi overrides or the 80-character cap were not handled")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokencat-titles-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let start = ISO8601DateFormatter().date(from: "2026-10-04T05:00:00Z")!
    func at(_ seconds: TimeInterval) -> String { ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)) }
    func line(_ record: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])) ?? Data()
        data.append(10)
        return data
    }
    func append(_ url: URL, _ records: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = records.reduce(into: Data()) { $0.append(line($1)) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return try data.write(to: url) }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }
    let now = start.addingTimeInterval(120)

    do {
        // Claude Code: a rename outranks the generated title whichever came last; a newer rename replaces it.
        let claudeHome = root.appendingPathComponent("claude")
        let claudeFolder = claudeHome.appendingPathComponent(".claude/projects/-tmp-ClaudeProject")
        func claudeTurn(_ session: String, _ seconds: TimeInterval) -> [[String: Any]] {
            [["type": "user", "uuid": "\(session)-u\(seconds)", "timestamp": at(seconds), "sessionId": session, "cwd": "/tmp/ClaudeProject",
              "message": ["role": "user", "content": [["type": "text", "text": "PRIVATE_PROMPT"]]]],
             ["type": "assistant", "uuid": "\(session)-a\(seconds)", "timestamp": at(seconds + 1), "sessionId": session,
              "message": ["id": "\(session)-m\(seconds)", "model": "claude-fixture", "stop_reason": "end_turn",
                          "usage": ["output_tokens": 5, "input_tokens": 10], "content": [["type": "text", "text": "PRIVATE_REPLY"]]]]]
        }
        let claudeLog = claudeFolder.appendingPathComponent("c-1.jsonl")
        try append(claudeLog, claudeTurn("c-1", 0) + [["type": "ai-title", "aiTitle": "Generated Claude title", "sessionId": "c-1"]])
        try append(claudeFolder.appendingPathComponent("c-2.jsonl"), claudeTurn("c-2", 0))
        let claude = TokenTracker(homeDirectory: claudeHome, environment: [:], now: { now }, discoveryInterval: 0)
        func claudeTitle(_ session: String) -> String?? { claude.sample().first { $0.sessionID == session }.map(\.title) }
        let generated = claudeTitle("c-1")
        try append(claudeLog, [["type": "custom-title", "customTitle": "Renamed\nClaude session", "sessionId": "c-1"]])
        let renamed = claudeTitle("c-1")
        try append(claudeLog, claudeTurn("c-1", 5) + [["type": "ai-title", "aiTitle": "Regenerated title", "sessionId": "c-1"]])
        let afterRegeneration = claudeTitle("c-1")
        try append(claudeLog, [["type": "custom-title", "customTitle": "Second rename", "sessionId": "c-1"]])
        check(generated == "Generated Claude title" && renamed == "Renamed Claude session"
              && afterRegeneration == "Renamed Claude session" && claudeTitle("c-1") == "Second rename"
              && claudeTitle("c-2") == .some(nil),
              "Claude Code: ai-title, a custom-title rename outranking it, a later rename, or a session without a title went wrong")
        // A title record only in the head of a long log is found by the bounded header scan.
        let headLog = claudeFolder.appendingPathComponent("c-3.jsonl")
        try append(headLog, [["type": "summary", "summary": "Older summary title", "leafUuid": "x"]] + claudeTurn("c-3", 0)
                   + (1...40).flatMap { claudeTurn("c-3", Double($0)) })
        let tailOnly = TokenTracker(homeDirectory: claudeHome, environment: [:], now: { now }, initialTailBytes: 2_048)
        check(tailOnly.sample().first { $0.sessionID == "c-3" }?.title == "Older summary title",
              "Claude Code: a summary title in the log's head was lost when the first read started mid-file")

        // Codex: names come from session_index.jsonl beside sessions/; the newest non-empty one per thread wins.
        let codexHome = root.appendingPathComponent("codex")
        let codexFolder = codexHome.appendingPathComponent(".codex/sessions/2026/10/04")
        let named = "019f0000-0000-7000-8000-00000000c0de", unnamed = "019f0000-0000-7000-8000-00000000beef"
        func rollout(_ id: String) -> [[String: Any]] {
            [["type": "session_meta", "timestamp": at(0), "payload": ["id": id, "cwd": "/tmp/CodexProject", "timestamp": at(0)]],
             ["type": "turn_context", "timestamp": at(0), "payload": ["model": "codex-fixture"]],
             ["type": "event_msg", "timestamp": at(1), "payload": ["type": "task_started", "turn_id": "t1"]],
             ["type": "event_msg", "timestamp": at(2), "payload": ["type": "token_count", "info": [
                 "total_token_usage": ["output_tokens": 7, "input_tokens": 100], "last_token_usage": ["output_tokens": 7, "input_tokens": 100]]]],
             ["type": "event_msg", "timestamp": at(3), "payload": ["type": "task_complete", "turn_id": "t1", "duration_ms": 1_000]]]
        }
        try append(codexFolder.appendingPathComponent("rollout-2026-10-04T05-00-00-\(named).jsonl"), rollout(named))
        try append(codexFolder.appendingPathComponent("rollout-2026-10-04T05-00-00-\(unnamed).jsonl"), rollout(unnamed))
        let index = codexHome.appendingPathComponent(".codex/session_index.jsonl")
        try append(index, [["id": named.uppercased(), "thread_name": "Codex thread name", "updated_at": at(3)]])
        let codex = TokenTracker(homeDirectory: codexHome, environment: [:], now: { now }, discoveryInterval: 0)
        func codexTitle(_ id: String) -> String?? { codex.sample().first { $0.sessionID == id }.map(\.title) }
        let first = codexTitle(named)
        try append(index, [["id": named, "thread_name": "Renamed Codex thread", "updated_at": at(4)],
                           ["id": named, "thread_name": "  ", "updated_at": at(5)]])
        let renamedThread = codexTitle(named)
        // A rewrite that removes a name (the index shrinks) is read again from the top.
        try line(["id": named, "thread_name": "Kept", "updated_at": at(6)]).write(to: index)
        check(first == "Codex thread name" && renamedThread == "Renamed Codex thread" && codexTitle(named) == "Kept"
              && codexTitle(unnamed) == .some(nil),
              "Codex: a session_index thread name, its rename, a rewritten index or a thread without a name went wrong")

        // omp: the title slot and header, then title_change records; Pi: session_info names, an empty one clears.
        let ompHome = root.appendingPathComponent("omp")
        let ompLog = ompHome.appendingPathComponent(".omp/agent/sessions/--tmp-OmpTitles--/2026-10-04T05-00-00-000Z_omp-t.jsonl")
        let ompTurn: [[String: Any]] = [
            ["type": "message", "id": "m1", "timestamp": at(1), "message": ["role": "user", "content": "PRIVATE", "timestamp": 0]],
            ["type": "message", "id": "m2", "timestamp": at(2), "message": ["role": "assistant", "stopReason": "stop",
                                                                            "usage": ["output": 3], "content": []]]]
        try append(ompLog, [["type": "title", "v": 1, "title": "Slot title", "source": "auto", "updatedAt": at(0)],
                            ["type": "session", "version": 3, "id": "omp-t", "timestamp": at(0), "cwd": "/tmp/OmpTitles",
                             "title": "Header title"]] + ompTurn)
        let piLog = ompHome.appendingPathComponent(".pi/agent/sessions/--tmp-PiTitles--/2026-10-04T05-00-00-000Z_pi-t.jsonl")
        try append(piLog, [["type": "session", "version": 3, "id": "pi-t", "timestamp": at(0), "cwd": "/tmp/PiTitles"]] + ompTurn)
        let omp = TokenTracker(homeDirectory: ompHome, environment: [:], now: { now }, discoveryInterval: 0)
        func ompTitle(_ id: String) -> String?? { omp.sample().first { $0.sessionID == id }.map(\.title) }
        let slot = ompTitle("omp-t"), piNone = ompTitle("pi-t")
        try append(ompLog, [["type": "title_change", "id": "tc1", "timestamp": at(3), "title": "Renamed omp", "source": "user"]])
        try append(piLog, [["type": "session_info", "id": "si1", "timestamp": at(3), "name": "Pi name"]])
        let ompRenamed = ompTitle("omp-t"), piNamed = ompTitle("pi-t")
        try append(piLog, [["type": "session_info", "id": "si2", "timestamp": at(4), "name": ""]])
        check(slot == "Slot title" && ompRenamed == "Renamed omp" && piNone == .some(nil) && piNamed == "Pi name"
              && ompTitle("pi-t") == .some(nil),
              "omp/Pi: the title slot, a title_change rename, a Pi session_info name or its clearing went wrong")
        // A tail that starts mid-file keeps its newer title_change over the head's slot.
        try append(ompLog, (10...60).flatMap { second in ompTurn.map { $0.merging(["timestamp": at(Double(second))]) { $1 } } })
        let ompTail = TokenTracker(homeDirectory: ompHome, environment: [:], now: { now }, initialTailBytes: 1_024)
        try append(ompLog, [["type": "title_change", "id": "tc2", "timestamp": at(61), "title": "Newest omp", "source": "auto"]])
        check(ompTail.sample().first { $0.sessionID == "omp-t" }?.title == "Newest omp",
              "omp: the head's title slot replaced a newer title_change read from the tail")

        // Gemini CLI: the generated summary in metadata or a $set; Qwen Code: custom_title records, newest first.
        let chatHome = root.appendingPathComponent("chats")
        let geminiLog = chatHome.appendingPathComponent(".gemini/tmp/proj/chats/session-2026-10-04T05-00-gt.jsonl")
        let geminiPlain = chatHome.appendingPathComponent(".gemini/tmp/proj/chats/session-2026-10-04T05-00-gn.jsonl")
        func geminiChat(_ id: String, summary: String? = nil) -> [[String: Any]] {
            var meta: [String: Any] = ["sessionId": id, "projectHash": "h", "startTime": at(0), "lastUpdated": at(0), "kind": "main"]
            if let summary { meta["summary"] = summary }
            return [meta, ["id": "\(id)-u1", "timestamp": at(1), "type": "user", "content": [["text": "PRIVATE"]]],
                    ["id": "\(id)-g1", "timestamp": at(2), "type": "gemini", "content": "PRIVATE", "tokens": ["output": 4, "total": 4]]]
        }
        try append(geminiLog, geminiChat("gem-t", summary: "Gemini summary"))
        try append(geminiPlain, geminiChat("gem-n"))
        let qwenFolder = chatHome.appendingPathComponent(".qwen/projects/-tmp-QwenTitles/chats")
        func qwen(_ uuid: String, _ type: String, _ seconds: TimeInterval, _ extra: [String: Any]) -> [String: Any] {
            ["uuid": uuid, "sessionId": "qt-1", "timestamp": at(seconds), "type": type, "cwd": "/tmp/QwenTitles"].merging(extra) { $1 }
        }
        let qwenTurn = [qwen("q1", "user", 1, ["message": ["role": "user", "parts": [["text": "PRIVATE"]]]]),
                        qwen("q2", "assistant", 2, ["message": ["role": "model", "parts": [["text": "PRIVATE"]]]])]
        try append(qwenFolder.appendingPathComponent("qt-1.jsonl"), qwenTurn)
        let chats = TokenTracker(homeDirectory: chatHome, environment: [:], now: { now }, discoveryInterval: 0)
        func chatTitle(_ id: String) -> String?? { chats.sample().first { $0.sessionID == id }.map(\.title) }
        let geminiFirst = chatTitle("gem-t"), qwenNone = chatTitle("qt-1")
        try append(geminiLog, [["$set": ["summary": "Gemini resummarised", "lastUpdated": at(5)]]])
        try append(qwenFolder.appendingPathComponent("qt-1.jsonl"), [
            qwen("q3", "system", 3, ["subtype": "custom_title", "systemPayload": ["customTitle": "Qwen auto title", "titleSource": "auto"]]),
            qwen("q4", "system", 4, ["subtype": "custom_title", "systemPayload": ["customTitle": "Qwen renamed", "titleSource": "manual"]])])
        check(geminiFirst == "Gemini summary" && chatTitle("gem-t") == "Gemini resummarised" && chatTitle("gem-n") == .some(nil)
              && qwenNone == .some(nil) && chatTitle("qt-1") == "Qwen renamed",
              "Gemini/Qwen: a metadata summary, its $set update, a chat without one, or Qwen's newest custom_title went wrong")
        let encoded = String(decoding: (try? JSONEncoder().encode(claude.sample() + omp.sample() + chats.sample())) ?? Data(), as: UTF8.self)
        check(!encoded.contains("PRIVATE"), "Session titles: prompt or reply text leaked into a reading")
    } catch {
        check(false, "Session title fixtures could not be written: \(error)")
    }
}
