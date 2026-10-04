import AppKit
import Foundation
import SwiftUI
import UserNotifications

@main
@MainActor
enum TokenCatMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let failures = runTrackerChecks() + runPreferenceChecks() + runShellChecks() + runStatusBarChecks() + runSessionPresentationChecks()
                + runTelemetryChecks() + runTelemetrySetupChecks() + runTokenSpeedChecks() + Runner.resourceErrors()
            if Runner.resourceErrors().isEmpty { print("Bundled artwork: PASS (\(RunnerPose.allCases.map(Runner.frames).reduce(0, +)) frames in \(RunnerPose.allCases.count) poses, transparent brand mark)") }
            if failures.isEmpty { print("TokenCat checks: PASS") }
            else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
            return
        }
        if CommandLine.arguments.contains("--connect-telemetry") || CommandLine.arguments.contains("--disconnect-telemetry") {
            let connect = CommandLine.arguments.contains("--connect-telemetry")
            if connect, !LocalTelemetryCollector.isOwnCollectorRunning() {
                print("실행 중인 TokenCat 로컬 수집기가 없습니다. 앱을 먼저 실행하세요.")
                exit(1)
            }
            do {
                let result = try (connect ? TelemetrySetup().connect() : TelemetrySetup().disconnect())
                print(result.message)
                print("변경 파일 \(result.changedFiles.count)개 · 다음 실행부터 적용: \(result.restartRequired.map(\.title).joined(separator: ", "))")
            } catch {
                print("실측 연결: \(error.localizedDescription)")
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
        let resourceErrors = Runner.resourceErrors()
        guard resourceErrors.isEmpty else {
            resourceErrors.forEach { print("이미지 리소스 오류: \($0)") }
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
            print("TokenCat이 이미 실행 중이어서 기존 앱의 패널을 열었습니다.")
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
        guard done.wait(timeout: .now() + 5) == .success else { print("알림 상태를 읽지 못했습니다."); exit(1) }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private static func writePNG(_ image: NSImage, to path: String, label: String) {
        guard let png = MenuBarStrip.png(image) else { print("\(label) failed"); exit(1) }
        do { try png.write(to: URL(fileURLWithPath: path)); print("\(label) saved") }
        catch { print("\(label) failed: \(error.localizedDescription)"); exit(1) }
    }

    private static func snapshotMenuBar(path: String) {
        let arguments = CommandLine.arguments
        let light = arguments.contains("--light")
        let highlighted = arguments.contains("--highlighted")
        let layout: StatusBarLayout = arguments.contains("--minimal") ? .minimal : arguments.contains("--inline") ? .inline : .compact
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if arguments.contains("--fixtures") {
            guard let matrix = menuBarFixtures(layout: layout, showRunner: !arguments.contains("--no-runner")) else { print("Menu snapshot failed"); exit(1) }
            writePNG(matrix, to: path, label: "Menu fixture snapshot")
            return
        }
        let model = DashboardModel(telemetryProvider: { LocalTelemetryCollector.fetchSnapshot() },
                                   telemetryProbe: { LocalTelemetryCollector.isOwnCollectorRunning(timeout: 0.5) })
        model.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let view = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
            view.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            view.highlighted = highlighted
            let counts = model.sessions.counts
            view.update(metrics: StatusBarContent.metrics(system: model.system, counts: counts,
                ai: StatusAISummary(groups: model.groups, counts: counts), recorded: model.flow.total,
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

    /// Synthetic states only (no local logs, host names or paths): rows are AI states, columns light/dark × normal/highlighted.
    private static func menuBarFixtures(layout: StatusBarLayout, showRunner: Bool) -> NSImage? {
        let suite = "dev.seuput.TokenCat.MenuFixtures.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.statusBarLayout = layout
        let at = Date()
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
        func reading(_ index: Int, _ state: TokenActivityState) -> TokenReading {
            var reading = TokenReading(source: index % 2 == 0 ? .claude : .codex, id: "fixture-\(index)", sessionID: "f\(index)",
                                       project: "demo", model: "model-a", active: state != .stale,
                                       lastActivity: at.addingTimeInterval(state == .stale ? -180 : -2), activityState: state, sampledAt: at)
            if state == .output { reading.lastOutputAt = at; reading.lastOutputDelta = 12 }
            return reading
        }
        let rows: [(String, [TokenReading])] = [
            ("활동 없음", []), ("진행", [reading(0, .working)]), ("도구 실행", [reading(1, .tool)]),
            ("출력 기록", [reading(2, .output)]), ("로그 대기", [reading(3, .stale)]),
            ("입력 필요", [reading(4, .input), reading(5, .tool)]), ("세션 12개", (0..<12).map { reading($0, .tool) })
        ]
        var strips: [(String, [NSImage])] = []
        for (title, tokens) in rows {
            let groups = SessionPresentation.groups(tokens, now: at)
            let counts = SessionCounts(groups)
            let metrics = StatusBarContent.metrics(system: system, counts: counts, ai: StatusAISummary(groups: groups, counts: counts),
                                                   recorded: 0, preferences: preferences, hasSample: true, hasTokenSample: true)
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
                    view.updateRunner(pose: pose, frame: 0)
                    guard let strip = view.snapshotImage(scale: 2) else { return nil }
                    images.append(MenuBarStrip.backdrop(strip, dark: dark, highlighted: highlighted))
                }
            }
            strips.append((title, images))
        }
        let cellWidth = (strips.first?.1.map(\.size.width).max() ?? 100) + 8
        let rowHeight: CGFloat = 34
        let size = NSSize(width: 76 + cellWidth * 4, height: 22 + rowHeight * CGFloat(strips.count))
        return NSImage(size: size, flipped: true) { rect in
            NSColor(white: 0.55, alpha: 1).setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            for (index, title) in ["라이트", "다크", "라이트 · 열림", "다크 · 열림"].enumerated() {
                (title as NSString).draw(at: NSPoint(x: 76 + cellWidth * CGFloat(index), y: 4), withAttributes: attributes)
            }
            for (row, strip) in strips.enumerated() {
                let y = 22 + rowHeight * CGFloat(row)
                (strip.0 as NSString).draw(at: NSPoint(x: 6, y: y + 8), withAttributes: attributes)
                for (column, image) in strip.1.enumerated() {
                    image.draw(in: NSRect(x: 76 + cellWidth * CGFloat(column), y: y, width: image.size.width, height: image.size.height),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            return true
        }
    }

    /// Renders Settings in an off-screen borderless window; ImageRenderer cannot draw AppKit-backed Form controls.
    /// `--focus telemetry` renders the real window height after scrolling to that section.
    /// Also prints the scroll offset and the drag types registered in the view tree (drop targets exist).
    private static func snapshotSettings(path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        let light = arguments.contains("--light")
        let focus = arguments.firstIndex(of: "--focus").flatMap { arguments.indices.contains($0 + 1) ? SettingsFocus(rawValue: arguments[$0 + 1]) : nil }
        let model = DashboardModel(telemetryProvider: { LocalTelemetryCollector.fetchSnapshot() },
                                   telemetryProbe: { LocalTelemetryCollector.isOwnCollectorRunning(timeout: 0.5) })
        model.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let state = SettingsState(notifier: Notifier())
            state.focus = focus
            let hosting = NSHostingView(rootView: SettingsView(preferences: model.preferences, model: model, state: state))
            let window = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: SettingsView.width, height: focus == nil ? 2_200 : 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = hosting
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                hosting.layoutSubtreeIfNeeded()
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { print("Settings snapshot failed"); exit(1) }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
                let tree = views(hosting)
                let offset = tree.compactMap { $0 as? NSScrollView }.first.map { Int($0.contentView.bounds.minY) } ?? 0
                let dragTypes = Set(tree.flatMap { $0.registeredDraggedTypes.map(\.rawValue) }).sorted()
                window.orderOut(nil)
                guard let image = rep.cgImage, let cropped = focus == nil ? trimBottom(image) : image else { print("Settings snapshot failed"); exit(1) }
                guard let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else { exit(1) }
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    print("Settings snapshot saved (\(cropped.width)×\(cropped.height) px) · scroll \(offset)pt · drag types \(dragTypes)")
                }
                catch { print("Settings snapshot failed: \(error.localizedDescription)"); exit(1) }
                model.stop()
                app.terminate(nil)
            }
        }
        app.run()
    }

    /// Drops the uniform background below the last row of content.
    private static func trimBottom(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.assumingMemoryBound(to: UInt32.self)
        let background = pixels[(height - 1) * width]
        var last = height - 1
        while last > 0 && (0..<width).allSatisfy({ pixels[last * width + $0] == background }) { last -= 1 }
        return image.cropping(to: CGRect(x: 0, y: 0, width: width, height: min(height, last + 24)))
    }

    private static func snapshot(path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = DashboardModel(telemetryProvider: { LocalTelemetryCollector.fetchSnapshot() },
                                   telemetryProbe: { LocalTelemetryCollector.isOwnCollectorRunning(timeout: 0.5) })
        model.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let light = CommandLine.arguments.contains("--light")
            let content = DashboardView(model: model, settings: {}, quit: {}, scrollsSessions: false)
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
