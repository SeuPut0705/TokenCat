import AppKit
import SwiftUI

/// Synthetic popover states for review (`--snapshot-fixtures <dir>`). Every value is made up:
/// no local logs, collector, host name, address or home path is read. Each PNG is dark | light.
/// IDs are visibly fake (sessions `00000000-0000-4000-8000-…`, Claude Code agents `aNNNNNNN…`); the self-test checks this.
enum SnapshotFixtures {
    static let sessionPrefix = "00000000-0000-4000-8000-"
    struct Fixture {
        var name: String
        var tokens: [TokenReading] = []
        var sampled = true
        var expanded = false
        var telemetry = TelemetryCollectorState.receiving
        var note: String?
        var failure: TelemetrySetupFailure?
        var restart: Set<TokenSource> = []
        var pressure = 1
        var foldersFound = true
        var contrast = false
        /// Seconds the AI collection lags behind the system sample, for the footer's longest state.
        var lag: TimeInterval = 0
        var battery = true
        /// A keyboard-selected row and an open inline detail, by reading id.
        var selection: String?
        var detail: String?
        var update = UpdateState()
        /// Claude usage-limit windows as the status line bridge would have delivered them.
        var claudeLimits = ClaudeUsageLimits()
    }

    /// Thursday 15:00:03 local time, so 오늘/어제/이번 주/이전 all have members.
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 15, minute: 0, second: 3)) ?? Date(timeIntervalSince1970: 1_790_000_003)
    static func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    /// A made-up newer release (the digest is all zeros) checked 3 minutes before `now`.
    static func update(_ install: UpdateState.Install = .none, now: Date = now) -> UpdateState {
        let page = URL(string: "https://github.com/SeuPut0705/TokenCat/releases/tag/v1.0.0")!
        let asset = UpdateRelease.Asset(url: page, size: 5_242_880, sha256: String(repeating: "0", count: 64))
        return UpdateState(check: .done, install: install, checkedAt: now.addingTimeInterval(-180),
                           available: UpdateRelease(version: "1.0.0", tag: "v1.0.0", page: page, asset: asset))
    }

    @MainActor
    static func write(to directory: String) -> Int32 {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            print("Fixture folder failed: \(error.localizedDescription)")
            return 1
        }
        var written = 0
        for fixture in fixtures() {
            let images = [true, false].compactMap { dark in render(dashboard(fixture), dark: dark, contrast: fixture.contrast) }
            if save(images, to: folder.appendingPathComponent(fixture.name + ".png")) { written += 1 }
        }
        for (name, view) in components() {
            if save([true, false].compactMap { render(view, dark: $0, contrast: false) }, to: folder.appendingPathComponent(name + ".png")) { written += 1 }
        }
        print("Fixture snapshots saved: \(written)")
        return written == fixtures().count + components().count ? 0 : 1
    }

    /// Component sheets: the five first-run outcomes (never part of a dashboard snapshot) and the limit row states (Codex six, Claude four; the last ones live reads).
    @MainActor
    private static func components() -> [(String, AnyView)] {
        let down = SessionPresentation.telemetryNotice(state: .busyOtherApp, note: nil, restart: [])
        let outcomes: [OnboardingCard.Outcome] = [
            .added(bridged: true),
            OnboardingCard.outcome(notice: nil, note: OnboardingCard.notePrefix + loc("Claude Code에 기존 OTLP 전송 대상이 있어 덮어쓰지 않았습니다.",
                                                                                      "Claude Code already has an OTLP destination, so it wasn't overwritten."),
                                   failure: .conflict, state: .waiting),
            OnboardingCard.outcome(notice: nil, note: OnboardingCard.notePrefix + loc("설정 파일을 저장하지 못했습니다.", "Couldn't save the settings file."),
                                   failure: .writeFailed(restored: true), state: .waiting),
            OnboardingCard.outcome(notice: down, note: nil, failure: nil, state: .busyOtherApp),
            OnboardingCard.outcome(notice: nil, note: nil, failure: nil, state: .starting)
        ]
        let onboarding = VStack(spacing: 12) {
            ForEach(Array(outcomes.enumerated()), id: \.offset) { OnboardingCard(outcome: $0.element, settings: {}, dismiss: {}) }
        }
        // Codex: four log records, then a live read 20 s ago ("실시간") and one 5 minutes ago (back to the record age).
        let codex = [limit(28, resetsIn: 5 * 86_400 + 8 * 3_600, recorded: -4 * 3_600), limit(87, resetsIn: 2 * 86_400 + 4 * 3_600, recorded: -95),
                     limit(97, resetsIn: 3 * 3_600 + 20 * 60, recorded: -30), limit(64, resetsIn: -600, recorded: -7_000),
                     limit(31, resetsIn: 5 * 86_400 + 2 * 3_600, recorded: -20, live: true), limit(33, resetsIn: 5 * 86_400 + 2 * 3_600, recorded: -300, live: true)]
            .map { UsageLimitSummary(usedPercent: $0.usedPercent, windowMinutes: $0.windowMinutes, resetsAt: $0.resetsAt, recordedAt: $0.recordedAt,
                                     live: $0.live == true) }
        // Claude: both windows live (the higher one shown), the 5-hour window at the warning level, both reset, then a live read.
        let claude = [claudeLimits(fiveHour: (42, 2 * 3_600 + 13 * 60), weekly: (31, 3 * 86_400 + 4 * 3_600), recorded: -50),
                      claudeLimits(fiveHour: (91, 47 * 60), weekly: (64, 2 * 86_400), recorded: -20),
                      claudeLimits(fiveHour: (77, -1_200), weekly: (58, -600), recorded: -9_000),
                      claudeLimits(fiveHour: (48, 2 * 3_600 + 5 * 60), weekly: (33, 3 * 86_400 + 4 * 3_600), recorded: -15, live: true)]
            .compactMap { SessionPresentation.claudeUsageLimit($0, now: now) }
        let limits = codex + claude
        let rows = VStack(spacing: 12) {
            ForEach(Array(limits.enumerated()), id: \.offset) { UsageLimitRow(limit: $0.element, now: now).container() }
        }
        func sheet<V: View>(_ view: V) -> AnyView {
            AnyView(view.padding(.horizontal, DashboardLayout.gutter).padding(.vertical, 12).frame(width: DashboardLayout.width)
                .buttonStyle(HoverButtonStyle()).environment(\.tokenCatSnapshot, true))
        }
        return [("onboarding", sheet(onboarding)), ("usage-limits", sheet(rows))]
    }

    @MainActor
    private static func dashboard(_ fixture: Fixture) -> some View {
        let model = DashboardModel(telemetryProvider: { [] }, restoresRestartState: false)
        var system = SystemSnapshot()
        system.cpuPercent = 14
        system.memoryUsedBytes = 19_219_755_008
        system.memoryTotalBytes = 25_769_803_776
        system.diskUsedBytes = 676_115_828_736
        system.diskTotalBytes = 994_662_584_320
        system.uploadBytesPerSecond = 1_200
        system.downloadBytesPerSecond = 52_000
        system.localIPs = ["192.0.2.10"]
        system.batteryPresent = fixture.battery
        system.batteryPercent = 58
        system.isCharging = true
        system.memoryPressure = fixture.pressure
        system.sampledAt = now
        if !fixture.sampled { system.isCharging = nil }
        model.system = system
        model.hasSample = fixture.sampled
        let history: [Double] = (0..<30).map { index in
            let wave: Double = sin(Double(index) / 3)
            return 10 + 6 * wave + Double(index % 4)
        }
        model.cpuHistory = fixture.sampled ? history : []
        model.telemetryStatus = fixture.telemetry.status
        model.telemetryState = fixture.telemetry
        model.telemetrySetupNote = fixture.note
        model.telemetrySetupFailure = fixture.failure
        model.telemetryRestartNeeded = fixture.restart
        model.logFoldersFound = fixture.foldersFound
        model.update = fixture.update
        model.claudeLimits = fixture.claudeLimits
        model.tokens = fixture.tokens
        model.tokensSampledAt = fixture.sampled ? at(-fixture.lag) : nil
        // The model republishes its presentation (clock, flow, list) whenever the toggle changes.
        model.sessionsExpanded = !fixture.expanded
        model.sessionsExpanded = fixture.expanded
        return DashboardView(model: model, actions: .none, scrollsSessions: false, selection: fixture.selection, detail: fixture.detail)
    }

    @MainActor
    private static func render<V: View>(_ view: V, dark: Bool, contrast: Bool) -> CGImage? {
        let content = view
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.tokenCatHighContrast, contrast)
            .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color(red: 0.97, green: 0.97, blue: 0.98))
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: 420, height: nil)
        renderer.scale = 2
        renderer.isOpaque = true
        return renderer.cgImage
    }

    private static func save(_ images: [CGImage], to url: URL) -> Bool {
        guard images.count == 2 else { print("Fixture render failed: \(url.lastPathComponent)"); return false }
        let gap = 24
        let width = images.reduce(0) { $0 + $1.width } + gap
        let height = images.map(\.height).max() ?? 0
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0
        for image in images {
            context.draw(image, in: CGRect(x: x, y: height - image.height, width: image.width, height: image.height))
            x += image.width + gap
        }
        guard let composite = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: composite).representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true } catch {
            print("Fixture save failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Readings

    private static func reading(_ name: String, _ source: TokenSource, project: String, model: String?,
                                state: TokenActivityState, active: Bool = true, last: TimeInterval = -2,
                                turn: TimeInterval? = -420, output: Int? = nil, outputs: [TimeInterval: Int] = [:]) -> TokenReading {
        let session = sessionPrefix + String(repeating: "0", count: max(0, 12 - name.count)) + name.prefix(12)
        let folder = source == .codex ? ".codex/sessions/2026/10/01" : ".claude/projects/-work-\(project)"
        var value = TokenReading(source: source, id: "\(source.rawValue):\(folder)/\(session).jsonl", sessionID: session,
                                 project: project, model: model, active: active, lastActivity: at(last),
                                 activityState: state, currentTurnStartedAt: active || state == .stale ? turn.map(at) : nil,
                                 currentTurnOutputTokens: active || state == .stale ? output : nil, sampledAt: now)
        value.recentOutputs = outputs.sorted { $0.key < $1.key }.map { TokenOutputEvent(at: at($0.key), tokens: $0.value) }
        if let newest = value.recentOutputs.last { value.lastOutputAt = newest.at; value.lastOutputDelta = newest.tokens }
        value.lastLogAt = at(last)
        value.projectPath = "/work/\(project)"
        return value
    }

    private static func child(_ parent: TokenReading, _ agent: String, role: String?, state: TokenActivityState,
                              active: Bool = true, last: TimeInterval = -2, output: Int? = nil,
                              outputs: [TimeInterval: Int] = [:], project: String? = nil) -> TokenReading {
        var value = reading(agent, parent.source, project: project ?? parent.project ?? "", model: parent.model, state: state,
                            active: active, last: last, output: output, outputs: outputs)
        value.id = parent.id.replacingOccurrences(of: ".jsonl", with: "/subagents/agent-\(agent).jsonl")
        value.isSubagent = true
        value.agentID = parent.source == .codex ? "/root/\(agent)" : agent
        value.agentRole = role
        if parent.source == .codex { value.parentSessionID = parent.sessionID } else { value.sessionID = parent.sessionID }
        return value
    }

    private static func measured(_ value: inout TokenReading, tokens: Int, milliseconds: Double, ago: TimeInterval) {
        var measurement = TokenSpeedMeasurement(TelemetryReading(provider: value.source, at: at(ago)))
        measurement.model = value.model
        measurement.outputTokens = tokens
        measurement.requestDurationMs = milliseconds
        value.speedMeasurement = measurement
    }

    private static func idle(_ name: String, project: String, ago: TimeInterval, state: TokenActivityState = .complete,
                             source: TokenSource = .claude) -> TokenReading {
        var value = reading(name, source, project: project, model: source == .codex ? "gpt-6.1-sol" : "claude-opus-5-5",
                            state: state, active: false, last: ago)
        value.lastOutputTokens = 7_493
        value.lastOutputAt = at(ago)
        value.lastTurnDurationSeconds = 252
        return value
    }

    private static func limit(_ percent: Double, resetsIn: TimeInterval, recorded: TimeInterval, live: Bool = false) -> TokenRateLimit {
        TokenRateLimit(usedPercent: percent, windowMinutes: 10_080, resetsAt: at(resetsIn), recordedAt: at(recorded), live: live ? true : nil)
    }

    private static func claudeLimits(fiveHour: (Double, TimeInterval), weekly: (Double, TimeInterval), recorded: TimeInterval,
                                     live: Bool = false) -> ClaudeUsageLimits {
        ClaudeUsageLimits(fiveHour: ClaudeLimitWindow(usedPercent: fiveHour.0, resetsAt: at(fiveHour.1), receivedAt: at(recorded), live: live ? true : nil),
                          sevenDay: ClaudeLimitWindow(usedPercent: weekly.0, resetsAt: at(weekly.1), receivedAt: at(recorded), live: live ? true : nil))
    }

    /// A Codex server rate ("생성 tok/s"): one token every `interval` ms.
    private static func generated(_ value: inout TokenReading, interval: Double, ago: TimeInterval) {
        var measurement = TokenSpeedMeasurement(TelemetryReading(provider: value.source, at: at(ago)))
        measurement.model = value.model
        measurement.serverTokenIntervalMs = interval
        measurement.serverTokenIntervalSampleCount = 1
        value.speedMeasurement = measurement
    }

    static func fixtures() -> [Fixture] {
        let quiet: [TimeInterval: Int] = [-250: 820, -205: 1_460, -170: 380, -120: 2_210, -85: 640, -60: 1_120]

        // 1. A question waits for the person; it outranks everything in the capsule and the order.
        var question = reading("input01", .claude, project: "TokenCat", model: "claude-opus-5-5", state: .input,
                               last: -192, turn: -1_400, output: 12_480, outputs: quiet)
        question.toolCategory = .question
        question.toolName = "AskUserQuestion"
        question.context = TokenContextUsage(usedTokens: 182_331, windowTokens: nil, recordedAt: at(-192))
        var docs = reading("docs01", .codex, project: "docs-site", model: "gpt-6.1-sol", state: .working, last: -8,
                           output: 3_210, outputs: [-90: 410, -45: 760])
        docs.effort = "xhigh"
        docs.context = TokenContextUsage(usedTokens: 158_204, windowTokens: 258_400, recordedAt: at(-45))
        docs.rateLimit = limit(28, resetsIn: 5 * 86_400 + 11 * 3_600, recorded: -720)
        var plan = reading("plan01", .claude, project: "api-server", model: "claude-opus-5-5", state: .input, last: -40,
                           turn: -600, output: 4_020)
        plan.toolCategory = .question
        plan.toolName = "ExitPlanMode"
        // The Codex session's fresh server rate is the card's "지금 속도"; both account limits sit under the card.
        var docsMeasured = docs
        generated(&docsMeasured, interval: 18, ago: -12)
        let input = Fixture(name: "input-needed", tokens: [question, docsMeasured, plan, idle("idle01", project: "notes-app", ago: -1_800)],
                            claudeLimits: claudeLimits(fiveHour: (42, 2 * 3_600 + 13 * 60), weekly: (31, 3 * 86_400 + 4 * 3_600), recorded: -50))

        // 2. API retries: countdown and network-down.
        var retrying = reading("retry01", .claude, project: "api-server", model: "claude-opus-5-5", state: .working, last: -3,
                               output: 640, outputs: [-140: 640])
        retrying.retry = TokenRetryState(attempt: 2, maxAttempts: 10, retryAt: at(4), networkDown: false, at: at(-3))
        var offline = reading("retry02", .claude, project: "TokenCat", model: "claude-sonnet-5", state: .working, last: -1,
                              output: 0)
        offline.retry = TokenRetryState(attempt: 7, maxAttempts: 10, retryAt: at(20), networkDown: true, at: at(-1))
        var flowing = reading("out01", .codex, project: "docs-site", model: "gpt-6.1-sol", state: .output, last: -1,
                              output: 8_240, outputs: [-100: 900, -50: 1_400, -1: 786])
        flowing.effort = "high"
        measured(&flowing, tokens: 441, milliseconds: 6_210, ago: -20)
        let retry = Fixture(name: "retry", tokens: [retrying, offline, flowing])

        // 3. Running tools by category; the raw names stay in help.
        var command = reading("tool01", .codex, project: "TokenCat", model: "gpt-6.1-sol", state: .tool, last: -40,
                              output: 2_048, outputs: quiet)
        command.toolCategory = .command
        command.toolName = "exec"
        command.effort = "ultra"
        var file = reading("tool02", .claude, project: "docs-site", model: "claude-opus-5-5", state: .tool, last: -35,
                           output: 5_120, outputs: [-100: 1_200])
        file.toolCategory = .file
        file.toolName = "Edit"
        var web = reading("tool03", .claude, project: "api-server", model: "claude-opus-5-5", state: .tool, last: -50,
                          output: 960, outputs: [-115: 960])
        web.toolCategory = .web
        web.toolName = "WebFetch"
        var mcp = reading("tool04", .claude, project: "sample-chat", model: "claude-sonnet-5", state: .tool, last: -33,
                          output: 310, outputs: [-60: 310])
        mcp.toolCategory = .mcp
        mcp.toolName = "mcp__tracker__search"
        let tools = Fixture(name: "tool-categories", tokens: [command, file, web, mcp])

        // 4. Context usage and the Codex limit at the warning level; a quiet row folds to 44pt.
        var full = reading("ctx01", .codex, project: "TokenCat", model: "gpt-6.1-sol", state: .working, last: -6,
                           output: 9_870, outputs: [-30: 1_210, -12: 2_040])
        full.effort = "ultra"
        full.context = TokenContextUsage(usedTokens: 235_100, windowTokens: 258_400, recordedAt: at(-12))
        full.rateLimit = limit(87, resetsIn: 2 * 86_400 + 4 * 3_600, recorded: -95)
        var replayed = full
        replayed.id += ".fork"
        replayed.sessionID = sessionPrefix + "0000000fork1"
        replayed.rateLimit = limit(99, resetsIn: -86_400, recorded: -10)
        replayed.recentOutputs = []
        replayed.active = false
        replayed.activityState = .complete
        replayed.currentTurnStartedAt = nil
        replayed.currentTurnOutputTokens = nil
        replayed.lastActivity = at(-7_200)
        var compacted = reading("ctx02", .claude, project: "docs-site", model: "claude-opus-5-5", state: .output, last: -2,
                                output: 1_840, outputs: [-2: 312])
        compacted.context = TokenContextUsage(usedTokens: 18_204, windowTokens: nil, recordedAt: at(-2), compactedAt: at(-75))
        measured(&compacted, tokens: 200, milliseconds: 4_532, ago: -30)
        let silent = reading("ctx03", .claude, project: "api-server", model: "claude-sonnet-5", state: .stale, active: false,
                             last: -200, output: nil)
        let context = Fixture(name: "context-limit", tokens: [full, replayed, compacted, silent])

        // 5. Subagents fold under their session; waiting children go to the summary while one runs.
        let parent = reading("parent01", .claude, project: "TokenCat", model: "claude-opus-5-5", state: .working, last: -4,
                             output: 6_403, outputs: [-80: 900, -20: 1_300])
        var explore = child(parent, "a1111111e1", role: "Explore", state: .tool, last: -10, output: 2_269, outputs: [-70: 2_269])
        explore.toolCategory = .file
        explore.toolName = "Read"
        let writer = child(parent, "a2222222e2", role: "workflow-subagent", state: .output, last: -1, output: 15_448,
                           outputs: [-60: 4_200, -1: 812])
        var waiter = child(parent, "a3333333e3", role: nil, state: .tool, last: -25, output: 13_219, outputs: [-95: 3_100])
        waiter.toolCategory = .agent
        waiter.toolName = "Agent"
        let stale = (4...6).map { child(parent, "a\(String(repeating: String($0), count: 7))e\($0)", role: "workflow-subagent", state: .stale, active: false,
                                        last: Double(-40 - 20 * $0), output: 51_823) }
        let codexRoot = idle("root01", project: "docs-site", ago: -900, source: .codex)
        let review = child(codexRoot, "sample_reviewer", role: "guardian", state: .working, last: -6, output: 1_204,
                           outputs: [-40: 1_204])
        let chat = child(codexRoot, "sample_scout", role: "explorer", state: .working, last: -9, output: 88, project: "sample-chat")
        let grouped = Fixture(name: "grouped-children", tokens: [parent, explore, writer, waiter] + stale + [codexRoot, review, chat])

        // 6. Expanded list with date captions; older sessions fold behind one row.
        let day: TimeInterval = 86_400
        let dated = [idle("d1", project: "TokenCat", ago: -600), idle("d2", project: "notes-app", ago: -3_600 * 3, state: .interrupted),
                     idle("d3", project: "docs-site", ago: -day - 3_600, source: .codex),
                     idle("d5", project: "sample-chat", ago: -2 * day - 600, state: .unfinished),
                     idle("d6", project: "TokenCat", ago: -9 * day), idle("d7", project: "sandbox-app", ago: -20 * day),
                     idle("d8", project: "notes-app", ago: -47 * day)]
        let dates = Fixture(name: "expanded-dates", tokens: dated, expanded: true)

        // 7–11. Empty, loading and collector states.
        let empty = Fixture(name: "empty")
        let noFolders = Fixture(name: "empty-no-folders",
                                note: OnboardingCard.notePrefix + loc("Claude Code에 기존 OTLP 전송 대상이 있어 덮어쓰지 않았습니다.",
                                                                      "Claude Code already has an OTLP destination, so it wasn't overwritten."),
                                failure: .conflict, foldersFound: false)
        let loading = Fixture(name: "loading", sampled: false, telemetry: .starting)
        var waitingSpeed = reading("rs01", .claude, project: "TokenCat", model: "claude-opus-5-5", state: .working, last: -3,
                                   output: 1_024, outputs: [-50: 1_024])
        waitingSpeed.context = TokenContextUsage(usedTokens: 96_000, windowTokens: nil, recordedAt: at(-50))
        var reset = docs
        reset.rateLimit = limit(64, resetsIn: -600, recorded: -7_000)
        reset.activityState = .complete
        reset.active = false
        reset.lastActivity = at(-7_000)
        // The longest footer: both clients in the restart notice beside a failed update (it keeps only its buttons).
        let restart = Fixture(name: "restart-needed", tokens: [waitingSpeed, reset], restart: [.claude, .codex], pressure: 2,
                              update: update(.failed(.network)))
        let port = Fixture(name: "port-busy", tokens: [waitingSpeed, idle("p1", project: "notes-app", ago: -400)],
                           telemetry: .busyOtherApp, pressure: 4)
        // Another TokenCat holds the collector (the AI delay, which would take the footer first, is under update-available).
        let busy = Fixture(name: "collector-busy", tokens: [waitingSpeed], telemetry: .busyTokenCat)

        // 12. Increase Contrast over the hardest-to-see marks.
        let ring = [idle("c1", project: "sample-chat", ago: -2_000, state: .unfinished), idle("c2", project: "notes-app", ago: -2_400, state: .interrupted)]
        let contrast = Fixture(name: "contrast", tokens: [question, command, silent] + ring, contrast: true)

        // 13. Header "로그 대기 N개" alone: open turns with no new record, one with a stale child.
        let stuck = reading("wait01", .claude, project: "api-server", model: "claude-opus-5-5", state: .stale, active: false, last: -200,
                            output: 2_310)
        let stuckChild = child(stuck, "a7777777e7", role: "Explore", state: .stale, active: false, last: -260, output: 940)
        let logWait = Fixture(name: "log-wait", tokens: [stuck, stuckChild, reading("wait02", .codex, project: "docs-site", model: "gpt-6.1-sol",
                                                                                     state: .stale, active: false, last: -420, output: 0)],
                              battery: false)

        // 14. Nothing running for two hours: header "진행 중인 세션 없음 · 마지막 활동 2시간 전", sleeping head, collapsed flow card.
        var quietRows = [idle("q1", project: "TokenCat", ago: -7_300), idle("q2", project: "notes-app", ago: -9_000, state: .interrupted),
                         idle("q3", project: "docs-site", ago: -86_400 - 400, source: .codex)]
        quietRows[0].lastOutputAt = at(-7_320)
        quietRows[0].lastOutputDelta = 512
        let rest = Fixture(name: "quiet", tokens: quietRows)

        // 15–16. Keyboard: the selected row with its inline detail open; a selected child row in the tree.
        let detail = Fixture(name: "detail-open", tokens: [command, file, idle("idle02", project: "notes-app", ago: -1_800)],
                             selection: command.id, detail: command.id)
        let selected = Fixture(name: "keyboard-selection", tokens: [parent, explore, writer, waiter] + stale, selection: explore.id)

        // 17. Only Claude Code runs: its 5-hour limit at the warning level and the newer of two fresh request rates.
        var claudeRun = reading("cl01", .claude, project: "TokenCat", model: "claude-opus-5-5", state: .working, last: -3,
                                output: 4_812, outputs: [-140: 1_020, -70: 1_560, -3: 640])
        measured(&claudeRun, tokens: 612, milliseconds: 9_840, ago: -6)
        var claudeTool = reading("cl02", .claude, project: "api-server", model: "claude-sonnet-5", state: .tool, last: -25,
                                 output: 1_930, outputs: [-90: 1_930])
        claudeTool.toolCategory = .command
        claudeTool.toolName = "Bash"
        measured(&claudeTool, tokens: 380, milliseconds: 5_100, ago: -40)
        let claudeOnly = Fixture(name: "claude-only", tokens: [claudeRun, claudeTool, idle("cl03", project: "notes-app", ago: -2_400)],
                                 claudeLimits: claudeLimits(fiveHour: (87, 3_600 + 20 * 60), weekly: (46, 4 * 86_400 + 2 * 3_600), recorded: -40))

        // 18–20. The footer's update line: a new version, the download, and a failure beside a telemetry problem (the longest pair is under restart-needed).
        let working = [waitingSpeed, idle("u1", project: "notes-app", ago: -400)]
        let available = Fixture(name: "update-available", tokens: working, lag: 12, update: update())
        let downloading = Fixture(name: "update-downloading", tokens: working, update: update(.downloading(0.45)))
        let failed = Fixture(name: "update-failed", tokens: working, telemetry: .busyOtherApp, update: update(.failed(.network)))
        return [input, retry, tools, context, grouped, dates, empty, noFolders, loading, restart, port, busy, contrast,
                logWait, rest, detail, selected, claudeOnly, available, downloading, failed]
    }
}
