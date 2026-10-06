import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

@main
@MainActor
enum TokenCatMain {
    static func main() {
        // `--language ko|en` picks the display language for any command, including the app itself.
        if let raw = AppLanguage.flagValue(CommandLine.arguments), AppLanguage(rawValue: raw) == nil {
            print("Unknown --language '\(raw)': ko or en")
            exit(1)
        }
        if CommandLine.arguments.contains("--self-test") {
            // Existing suites assert Korean text; the localization suite switches to English where it checks it.
            AppLanguage.current = .ko
            let failures = runLocalizationChecks() + runTrackerChecks() + runPreferenceChecks() + runShellChecks() + runStatusBarChecks() + runSessionPresentationChecks()
                + runDesignTokenChecks() + runTelemetryChecks() + runTelemetrySetupChecks() + runTokenSpeedChecks() + runUpdaterChecks()
                + runLiveLimitChecks()
                + Runner.resourceErrors()
            if Runner.resourceErrors().isEmpty { print("Bundled artwork: PASS (\(RunnerCharacter.allCases.count) characters × \(RunnerPose.allCases.map(Runner.frames).reduce(0, +)) frames in \(RunnerPose.allCases.count) poses, \(RunnerHead.allCases.count) pixel heads)") }
            if failures.isEmpty { print("TokenCat checks: PASS") }
            else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
            return
        }
        // Opens real loopback listeners on two free test ports (never the app's port), so it stays out of --self-test.
        // `--telemetry-lifecycle-checks [port]` uses `port` and `port + 1`.
        if CommandLine.arguments.contains("--telemetry-lifecycle-checks") {
            let arguments = CommandLine.arguments
            let explicit = arguments.firstIndex(of: "--telemetry-lifecycle-checks").flatMap { arguments.indices.contains($0 + 1) ? UInt16(arguments[$0 + 1]) : nil }
            guard let port = explicit ?? telemetryTestPort(), port != LocalTelemetryCollector.port, port &+ 1 != LocalTelemetryCollector.port
            else { print("FAIL: no free loopback test port"); exit(1) }
            let failures = runTelemetryLifecycleChecks(port: port)
            if failures.isEmpty { print("Telemetry lifecycle: PASS (ports \(port), \(port + 1))") }
            else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
            return
        }
        if CommandLine.arguments.contains("--connect-telemetry") || CommandLine.arguments.contains("--disconnect-telemetry") {
            let connect = CommandLine.arguments.contains("--connect-telemetry")
            // The app's automatic connection follows the last command, a refused disconnect included: the intent is the same.
            UserDefaults.standard.set(!connect, forKey: TelemetrySetup.optOutKey)
            if connect, !LocalTelemetryCollector.isOwnCollectorRunning() {
                print(loc("실행 중인 TokenCat 로컬 수집기가 없습니다. 앱을 먼저 실행하세요.", "No TokenCat collector is running. Open the app first."))
                exit(1)
            }
            do {
                let result = try (connect ? TelemetrySetup().connect() : TelemetrySetup().disconnect())
                print(result.message)
                let count = result.changedFiles.count, names = result.restartRequired.map(\.title).joined(separator: ", ")
                print(loc("변경 파일 \(count)개 · 다음 실행부터 적용: \(names)", "\(plural(count, "file")) changed · applies from the next launch: \(names)"))
            } catch {
                print(loc("실측 연결: \(error.localizedDescription)", "Telemetry: \(error.localizedDescription)"))
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--telemetry-readings") {
            guard LocalTelemetryCollector.isOwnCollectorRunning() else { exit(1) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(LocalTelemetryCollector.fetchSnapshot()) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        // Read-only: one GET of the latest release, printed; nothing is stored, downloaded or installed.
        if CommandLine.arguments.contains("--update-check") {
            exit(Updater.commandLineCheck())
        }
        // Read-only: one live usage read per provider (Codex app-server, Anthropic usage), numbers only; never a token.
        if CommandLine.arguments.contains("--live-limits") {
            exit(LiveLimits.commandLineCheck())
        }
        if CommandLine.arguments.contains("--notification-status") {
            notificationStatus()
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let sampler = SystemSampler()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 1)
            let system = sampler.sample()
            let tokens = TokenSpeed.apply(TokenTracker().sample(), measurements: LocalTelemetryCollector.fetchSnapshot())
            struct Diagnostic: Encodable { var system: SystemSnapshot; var tokens: [TokenReading] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(Diagnostic(system: system, tokens: tokens)) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        let resourceErrors = Runner.resourceErrors([.cat])
        guard resourceErrors.isEmpty else {
            resourceErrors.forEach { print(loc("이미지 리소스 오류: \($0)", "Image resource error: \($0)")) }
            exit(1)
        }
        if CommandLine.arguments.contains("--live-check") {
            liveCheck()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-menubar"), CommandLine.arguments.indices.contains(index + 1) {
            snapshotMenuBar(path: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-settings"), CommandLine.arguments.indices.contains(index + 1) {
            snapshotSettings(path: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-fixtures"), CommandLine.arguments.indices.contains(index + 1) {
            exit(SnapshotFixtures.write(to: CommandLine.arguments[index + 1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1) {
            snapshot(path: CommandLine.arguments[index + 1])
            return
        }
        if handOffToRunningInstance() {
            print(loc("TokenCat이 이미 실행 중이어서 기존 앱의 상세 화면을 열었습니다.", "TokenCat is already running, so its dashboard was opened."))
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func liveCheck() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = DashboardModel(telemetryProvider: { LocalTelemetryCollector.fetchSnapshot() },
                                   telemetryProbe: { LocalTelemetryCollector.isOwnCollectorRunning(timeout: 0.5) })
        var systemTimes: [Date] = []
        var tokenTimes: [Date] = []
        var recentDeltas = 0
        var observedLiveStates = Set<String>()
        var nativeReadyBeforeTokens = false
        model.onUpdate = {
            if model.hasSample, systemTimes.last != model.system.sampledAt { systemTimes.append(model.system.sampledAt) }
            if let at = model.tokensSampledAt, tokenTimes.last != at {
                tokenTimes.append(at)
                for reading in model.tokens where reading.currentTurnStartedAt != nil {
                    observedLiveStates.insert(reading.activityState.rawValue)
                    if let at = reading.lastOutputAt, let delta = reading.lastOutputDelta,
                       delta > 0, Date().timeIntervalSince(at) >= -5,
                       Date().timeIntervalSince(at) <= 5 { recentDeltas += 1 }
                }
            }
            nativeReadyBeforeTokens = nativeReadyBeforeTokens || (model.hasSample && model.tokensSampledAt == nil)
        }
        model.start()
        model.start() // Repeated starts must keep one sampling timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            model.refresh()
            model.stop()
            let stoppedSystems = systemTimes.count
            let stoppedTokens = tokenTimes.count
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let intervals = zip(systemTimes.dropFirst(), systemTimes).map { $0.timeIntervalSince($1) }.sorted()
                let median = intervals.isEmpty ? 0 : intervals[intervals.count / 2]
                let cadence = DashboardModel.samplingInterval
                let noLatePublish = stoppedSystems == systemTimes.count && stoppedTokens == tokenTimes.count
                let cadenceMatches = !intervals.isEmpty && abs(median - cadence) < max(0.2, cadence * 0.25)
                let oneTimer = systemTimes.count <= Int(ceil(6 / cadence)) + 2
                let passed = cadenceMatches && oneTimer && noLatePublish && !tokenTimes.isEmpty
                let report: [String: Any] = [
                    "cadenceSeconds": cadence, "systemSamples": systemTimes.count, "tokenSamples": tokenTimes.count,
                    "medianSystemInterval": median, "cadenceMatches": cadenceMatches,
                    "repeatedStartKeepsOneTimer": oneTimer, "noPublishAfterStop": noLatePublish,
                    "nativeReadyBeforeTokens": nativeReadyBeforeTokens,
                    "observedLiveStates": observedLiveStates.sorted(), "samplesWithRecentLogDelta": recentDeltas,
                    "logFileEvents": model.logEventCount,
                    "pass": passed
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                model.onUpdate = nil
                if !passed { exit(1) }
                app.terminate(nil)
            }
        }
        app.run()
    }

    /// A second launch asks the running instance (payload-free) to open its dashboard and exits once it acknowledges.
    /// Verification commands of the same bundle never acknowledge, so they never block a real launch.
    private static func handOffToRunningInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier,
              NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() })
        else { return false }
        let center = DistributedNotificationCenter.default()
        var acknowledged = false
        let token = center.addObserver(forName: AppDelegate.openAcknowledged, object: nil, queue: nil) { _ in acknowledged = true }
        defer { center.removeObserver(token) }
        // The running instance may still be launching; ask again until it answers.
        let deadline = Date().addingTimeInterval(3)
        var nextPost = Date.distantPast
        while !acknowledged && Date() < deadline {
            if Date() >= nextPost {
                center.postNotificationName(AppDelegate.openRequest, object: nil, userInfo: nil, deliverImmediately: true)
                nextPost = Date().addingTimeInterval(0.2)
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return acknowledged
    }

    /// Read-only: reports whether this bundle can use UserNotifications and its current permission. Never prompts.
    private static func notificationStatus() {
        let done = DispatchSemaphore(value: 0)
        var report: [String: Any] = ["bundleIdentifier": Bundle.main.bundleIdentifier ?? "", "version": AppInfo.title]
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let names: [UNAuthorizationStatus: String] = [.notDetermined: "notDetermined", .denied: "denied",
                                                          .authorized: "authorized", .provisional: "provisional"]
            report["authorizationStatus"] = names[settings.authorizationStatus] ?? "unknown(\(settings.authorizationStatus.rawValue))"
            report["alertSetting"] = settings.alertSetting == .enabled ? "enabled" : settings.alertSetting == .disabled ? "disabled" : "notSupported"
            report["alertStyle"] = settings.alertStyle == .banner ? "banner" : settings.alertStyle == .alert ? "alert" : "none"
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success else { print(loc("알림 상태를 읽지 못했습니다.", "Couldn't read the notification status.")); exit(1) }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private static func writePNG(_ image: NSImage, to path: String, label: String) {
        guard let png = MenuBarStrip.png(image) else { print("\(label) failed"); exit(1) }
        do { try png.write(to: URL(fileURLWithPath: path)); print("\(label) saved") }
        catch { print("\(label) failed: \(error.localizedDescription)"); exit(1) }
    }

    /// `--character cat|dog|hamster|penguin|robot` for the snapshot commands; an unknown value exits.
    private static func characterFlag() -> RunnerCharacter? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--character") else { return nil }
        let raw = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
        guard let character = RunnerCharacter(rawValue: raw) else {
            print("Unknown --character '\(raw)': \(RunnerCharacter.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(1)
        }
        return character
    }

    private static func snapshotMenuBar(path: String) {
        let arguments = CommandLine.arguments
        let character = characterFlag()
        let light = arguments.contains("--light")
        let highlighted = arguments.contains("--highlighted")
        let layout: StatusBarLayout = arguments.contains("--minimal") ? .minimal : arguments.contains("--inline") ? .inline : .compact
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if arguments.contains("--fixtures") {
            Runner.character = character ?? .cat
            guard let matrix = menuBarFixtures(layout: layout, showRunner: !arguments.contains("--no-runner")) else { print("Menu snapshot failed"); exit(1) }
            writePNG(matrix, to: path, label: "Menu fixture snapshot")
            return
        }
        let model = DashboardModel(telemetryProvider: { LocalTelemetryCollector.fetchSnapshot() },
                                   telemetryProbe: { LocalTelemetryCollector.isOwnCollectorRunning(timeout: 0.5) })
        Runner.character = character ?? model.preferences.character
        model.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let view = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
            view.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            view.highlighted = highlighted
            let counts = model.sessions.counts
            view.update(metrics: StatusBarContent.metrics(system: model.system, counts: counts,
                ai: StatusAISummary(groups: model.groups, counts: counts), recorded: model.flow.total,
                speeds: StatusBarContent.speeds(model.sessions, now: model.now, restart: model.telemetryRestartNeeded),
                preferences: model.preferences, layout: layout, hasSample: model.hasSample, hasTokenSample: model.tokensSampledAt != nil),
                layout: layout, showRunner: model.preferences.showRunner && !arguments.contains("--no-runner"))
            view.frame.size.width = view.requiredWidth
            view.updateRunner(pose: .walk, frame: 2)
            guard let strip = view.snapshotImage(scale: 2) else { print("Menu snapshot failed"); exit(1) }
            writePNG(MenuBarStrip.backdrop(strip, dark: !light, highlighted: highlighted, inset: 12), to: path, label: "Menu snapshot")
            model.stop()
            app.terminate(nil)
        }
        app.run()
    }

    /// The synthetic system sample of the menu bar fixtures and the Settings preview.
    private static var fixtureSystem: SystemSnapshot {
        var system = SystemSnapshot()
        system.cpuPercent = 18
        system.memoryUsedBytes = 17_900_000_000
        system.memoryTotalBytes = 25_769_803_776
        system.diskUsedBytes = 629_700_000_000
        system.diskTotalBytes = 994_662_584_320
        system.batteryPresent = true
        system.batteryPercent = 76
        system.uploadBytesPerSecond = 1_499
        system.downloadBytesPerSecond = 3_100_000
        return system
    }

    /// Synthetic states only (no local logs, host names or paths): rows are AI states, columns light/dark × normal/highlighted.
    private static func menuBarFixtures(layout: StatusBarLayout, showRunner: Bool) -> NSImage? {
        let suite = "dev.seuput.TokenCat.MenuFixtures.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.statusBarLayout = layout
        let at = Date()
        let system = fixtureSystem
        func reading(_ index: Int, _ state: TokenActivityState) -> TokenReading {
            var reading = TokenReading(source: index % 2 == 0 ? .claude : .codex, id: "fixture-\(index)", sessionID: "f\(index)",
                                       project: "demo", model: "model-a", active: state != .stale,
                                       lastActivity: at.addingTimeInterval(state == .stale ? -180 : -2), activityState: state, sampledAt: at)
            if state == .output { reading.lastOutputAt = at; reading.lastOutputDelta = 12 }
            return reading
        }
        let rows: [(String, [TokenReading])] = [
            (loc("활동 없음", "No activity"), []), (loc("진행", "Working"), [reading(0, .working)]),
            (loc("도구 실행", "Running tool"), [reading(1, .tool)]),
            // A fresh record is an event: the cat runs while the mark stays 진행.
            (loc("방금 기록", "Just recorded"), [reading(2, .output)]), (loc("로그 대기", "Waiting for log"), [reading(3, .stale)]),
            (loc("입력 필요", "Input needed"), [reading(4, .input), reading(6, .input), reading(5, .working)]),
            (loc("세션 12개", plural(12, "session")), (0..<12).map { reading($0, .tool) })
        ]
        // The speed items, turned on for the last rows: measured 3 s ago on the session's model (Codex 55.6, Claude 312.5 tok/s), then none.
        func measured(_ index: Int, interval: Double) -> TokenReading {
            var value = reading(index, .working)
            var measurement = TokenSpeedMeasurement(TelemetryReading(provider: value.source, at: at.addingTimeInterval(-3)))
            measurement.model = value.model
            measurement.serverTokenIntervalMs = interval
            value.speedMeasurement = measurement
            return value
        }
        let speedRows: [(String, [TokenReading])] = [
            (loc("속도", "Speed"), [measured(1, interval: 18), measured(0, interval: 3.2)]),
            (loc("속도 측정 없음", "No speed measured"), [reading(1, .working), reading(0, .working)])
        ]
        var strips: [(String, [NSImage])] = []
        for (index, (title, tokens)) in (rows + speedRows).enumerated() {
            if index == rows.count { preferences.visible.formUnion([.codexSpeed, .claudeSpeed, .averageSpeed]) }
            let groups = SessionPresentation.groups(tokens, now: at)
            let counts = SessionCounts(groups)
            let speeds = StatusBarContent.speeds(SessionListModel.make(tokens: tokens, now: at, expanded: false), now: at, restart: [])
            let metrics = StatusBarContent.metrics(system: system, counts: counts, ai: StatusAISummary(groups: groups, counts: counts),
                                                   recorded: 0, speeds: speeds, preferences: preferences, hasSample: true, hasTokenSample: true)
            var director = RunnerDirector()
            let activity = RunnerActivity(groups: groups, cpu: system.cpuPercent, now: at)
            director.observe(activity, now: at)
            let pose = director.plan(.activity, activity: activity, now: at, reduceMotion: false).pose
            var images: [NSImage] = []
            for highlighted in [false, true] {
                for dark in [false, true] {
                    let view = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
                    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    view.highlighted = highlighted
                    view.update(metrics: metrics, layout: layout, showRunner: showRunner)
                    view.frame.size.width = view.requiredWidth
                    view.updateRunner(pose: pose, frame: 0, fx: RunnerAnimator.stillFX(pose))
                    guard let strip = view.snapshotImage(scale: 2) else { return nil }
                    images.append(MenuBarStrip.backdrop(strip, dark: dark, highlighted: highlighted))
                }
            }
            strips.append((title, images))
        }
        let cellWidth = (strips.flatMap(\.1).map(\.size.width).max() ?? 100) + 8
        let rowHeight: CGFloat = 34
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        // The row label column: 76 pt, wider when a label (English) needs it.
        let gutter = max(76, (strips.map { ($0.0 as NSString).size(withAttributes: attributes).width }.max() ?? 0) + 12).rounded(.up)
        let size = NSSize(width: gutter + cellWidth * 4, height: 22 + rowHeight * CGFloat(strips.count))
        return NSImage(size: size, flipped: true) { rect in
            NSColor(white: 0.55, alpha: 1).setFill()
            rect.fill()
            for (index, title) in [loc("라이트", "Light"), loc("다크", "Dark"), loc("라이트 · 열림", "Light · open"), loc("다크 · 열림", "Dark · open")].enumerated() {
                (title as NSString).draw(at: NSPoint(x: gutter + cellWidth * CGFloat(index), y: 4), withAttributes: attributes)
            }
            for (row, strip) in strips.enumerated() {
                let y = 22 + rowHeight * CGFloat(row)
                (strip.0 as NSString).draw(at: NSPoint(x: 6, y: y + 8), withAttributes: attributes)
                for (column, image) in strip.1.enumerated() {
                    image.draw(in: NSRect(x: gutter + cellWidth * CGFloat(column), y: y, width: image.size.width, height: image.size.height),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            return true
        }
    }

    /// Renders the real Settings window (toolbar tabs and the selected pane) off screen; ImageRenderer cannot draw
    /// AppKit-backed Form controls. `--pane general|menubar|cat|telemetry|about|all` (default all; `--focus telemetry`
    /// is the telemetry pane; `cat` is the 캐릭터 tab) stacks the chosen panes vertically. `--character <id>` draws that character. The tab choice is kept in a throwaway defaults domain.
    /// `--fixtures` uses synthetic state instead of this Mac's logs and preferences: the menu bar fixtures' system sample, the collector off with a retry in
    /// 25 s, Codex waiting for a relaunch, the Claude limit bridge received 50 s ago, version 0.9.1 available (checked
    /// 3 min ago), default preferences, the login item not registered and notification permission not asked yet.
    /// `--update-failure network|translocated|not-writable|no-digest|invalid-bundle` adds that failed install to it;
    /// `--setup-note unknown|skipped|recreated` the connection's status line note; `--login requires-approval|enabled`
    /// that login item state; `--notifications denied|authorized` that permission (denied also turns every notification
    /// choice on, the tallest case). Prints each pane's content height and the drag types registered in the view tree
    /// (drop targets exist).
    private static func snapshotSettings(path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        let light = arguments.contains("--light")
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        let requested = value("--pane") ?? (value("--focus") == SettingsFocus.telemetry.rawValue ? SettingsPane.telemetry.rawValue : "all")
        let panes = requested == "all" ? SettingsPane.allCases : SettingsPane(rawValue: requested).map { [$0] } ?? []
        guard !panes.isEmpty else { print("Unknown pane '\(requested)': general, menubar, cat, telemetry, about or all"); exit(1) }
        let fixtures = arguments.contains("--fixtures")
        let model = fixtures ? DashboardModel(telemetryProvider: { [] }, restoresRestartState: false)
            : DashboardModel(telemetryProvider: { LocalTelemetryCollector.fetchSnapshot() },
                             telemetryProbe: { LocalTelemetryCollector.isOwnCollectorRunning(timeout: 0.5) })
        let suite = "dev.seuput.TokenCat.SettingsSnapshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { print("Settings snapshot failed"); exit(1) }
        let preferences = fixtures ? Preferences(defaults: defaults) : model.preferences
        // Fixtures show the flag's character in the picker too; this Mac's own preferences are never written.
        let character = characterFlag()
        if fixtures { if let character { preferences.character = character } } else { Runner.character = character ?? preferences.character }
        func option<Value>(_ flag: String, _ values: [String: Value]) -> Value? {
            guard let raw = value(flag) else { return nil }
            guard let chosen = values[raw] else { print("Unknown \(flag) '\(raw)': \(values.keys.sorted())"); exit(1) }
            return chosen
        }
        let login = option("--login", ["requires-approval": SMAppService.Status.requiresApproval, "enabled": .enabled])
        let notifications = option("--notifications", ["denied": UNAuthorizationStatus.denied, "authorized": .authorized])
        if fixtures {
            AppInfo.executablePath = "/Applications/TokenCat.app/Contents/MacOS/TokenCat"
            // The menu bar preview draws the same sample as the menu bar fixtures, with no AI session.
            model.system = fixtureSystem
            model.hasSample = true
            model.tokensSampledAt = model.now
            model.telemetryState = .busyOtherApp
            model.telemetryNextRetryAt = model.now.addingTimeInterval(25)
            model.telemetryRestartNeeded = [.codex]
            let failures: [String: UpdateFailure] = ["network": .network, "translocated": .translocated, "not-writable": .notWritable,
                                                     "no-digest": .noDigest, "invalid-bundle": .invalidBundle(loc("코드 서명을 확인하지 못했습니다", "couldn't verify the code signature"))]
            model.update = SnapshotFixtures.update(option("--update-failure", failures).map { .failed($0) } ?? .none, now: model.now)
            let received = model.now.addingTimeInterval(-50)
            model.claudeLimits = ClaudeUsageLimits(fiveHour: ClaudeLimitWindow(usedPercent: 42, resetsAt: model.now.addingTimeInterval(7_980), receivedAt: received),
                                                   sevenDay: ClaudeLimitWindow(usedPercent: 31, resetsAt: model.now.addingTimeInterval(273_600), receivedAt: received))
            let note = option("--setup-note", ["unknown": TelemetrySetupNote.originalUnknown, "skipped": .statusLineSkipped, "recreated": .originalRecreated])
            model.telemetryConnectNotes = note.map { [$0] } ?? []
            model.claudeBridged = note != .statusLineSkipped
            if notifications == .denied {
                preferences.notifyTurnComplete = true
                preferences.notifyInput = true
                preferences.notifyInputSound = true
                preferences.notifyUpdate = true
            }
        } else {
            model.start()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (fixtures ? 0.5 : 4)) {
            let state = fixtures ? SettingsState(notifier: Notifier(), login: login ?? .notRegistered, notifications: notifications ?? .notDetermined,
                                                 sound: notifications == .denied ? .disabled : nil)
                : SettingsState(notifier: Notifier())
            // The preview shows the pose the cat would plan for these sessions now.
            var director = RunnerDirector()
            let activity = RunnerActivity(groups: model.groups, cpu: model.hasSample ? model.system.cpuPercent : nil, now: Date())
            director.observe(activity, now: Date())
            state.runnerPose = director.plan(preferences.animationSource, activity: activity, now: Date(), reduceMotion: false).pose
            let tabs = SettingsTabsController(preferences: preferences, model: model, state: state, actions: .none, defaults: defaults)
            let window = OffscreenWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: SettingsTabsController.width, height: 400),
                                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            SettingsTabsController.configure(window, with: tabs)
            window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
            window.orderFrontRegardless()
            var shots: [CGImage] = []
            var report: [String] = []
            var dragTypes = Set<String>()
            func capture(_ remaining: ArraySlice<SettingsPane>) {
                guard let pane = remaining.first else { finish(); return }
                tabs.select(pane)
                tabs.fitWindow(animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard let frameView = window.contentView?.superview else { print("Settings snapshot failed"); exit(1) }
                    frameView.layoutSubtreeIfNeeded()
                    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { print("Settings snapshot failed"); exit(1) }
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    if let image = rep.cgImage { shots.append(image) }
                    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
                    dragTypes.formUnion(views(frameView).flatMap { $0.registeredDraggedTypes.map(\.rawValue) })
                    let height = Int(window.contentLayoutRect.height.rounded())
                    report.append("\(pane.rawValue) \(height)pt\(height > Int(SettingsTabsController.maximumHeight) ? " (over \(Int(SettingsTabsController.maximumHeight)))" : "") title '\(window.title)'")
                    capture(remaining.dropFirst())
                }
            }
            func finish() {
                window.orderOut(nil)
                UserDefaults.standard.removePersistentDomain(forName: suite)
                guard let image = stack(shots, gap: 24, dark: !light),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { print("Settings snapshot failed"); exit(1) }
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    print("Settings snapshot saved (\(image.width)×\(image.height) px) · \(report.joined(separator: " · ")) · drag types \(dragTypes.sorted())")
                } catch { print("Settings snapshot failed: \(error.localizedDescription)"); exit(1) }
                model.stop()
                app.terminate(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { capture(panes[...]) }
        }
        app.run()
    }

    /// Window captures one above another on a neutral backdrop.
    nonisolated private static func stack(_ images: [CGImage], gap: Int, dark: Bool) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let width = images.map(\.width).max() ?? 0
        let height = images.map(\.height).reduce(0, +) + gap * (images.count - 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(gray: dark ? 0.32 : 0.82, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var top = height
        for image in images {
            top -= image.height
            context.draw(image, in: CGRect(x: 0, y: top, width: image.width, height: image.height))
            top -= gap
        }
        return context.makeImage()
    }

    private static func snapshot(path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = DashboardModel(telemetryProvider: { LocalTelemetryCollector.fetchSnapshot() },
                                   telemetryProbe: { LocalTelemetryCollector.isOwnCollectorRunning(timeout: 0.5) })
        model.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let light = CommandLine.arguments.contains("--light")
            let content = DashboardView(model: model, actions: .none, scrollsSessions: false)
                .environment(\.colorScheme, light ? .light : .dark)
                .background(light ? Color(red: 0.97, green: 0.97, blue: 0.98) : Color(red: 0.12, green: 0.12, blue: 0.13))
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: 420, height: nil)
            renderer.scale = 2
            renderer.isOpaque = true
            guard let cgImage = renderer.cgImage else { print("Snapshot failed"); exit(1) }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do { try png.write(to: URL(fileURLWithPath: path)); print("Snapshot saved") }
            catch { print("Snapshot failed: \(error.localizedDescription)"); exit(1) }
            model.stop()
            app.terminate(nil)
        }
        app.run()
    }
}

/// Never pulled back onto a screen, so verification renders stay invisible.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
