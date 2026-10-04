import AppKit
import Foundation
import SwiftUI

@main
@MainActor
enum TokenCatMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let failures = runTrackerChecks() + runPreferenceChecks() + runStatusBarChecks() + runSessionPresentationChecks()
                + runTelemetryChecks() + runTelemetrySetupChecks() + runTokenSpeedChecks() + Runner.resourceErrors()
            if Runner.resourceErrors().isEmpty { print("Bundled artwork: PASS (8 animation frames, transparent icon)") }
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
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1) {
            snapshot(path: CommandLine.arguments[index + 1])
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
        let model = DashboardModel(telemetryProvider: { LocalTelemetryCollector.fetchSnapshot() })
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

    private static func snapshotMenuBar(path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = DashboardModel(telemetryProvider: { LocalTelemetryCollector.fetchSnapshot() })
        model.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let light = CommandLine.arguments.contains("--light")
            let layout: StatusBarLayout = CommandLine.arguments.contains("--inline") ? .inline : .compact
            let view = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
            view.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            view.update(metrics: StatusBarContent.metrics(system: model.system, counts: model.sessions.counts, recorded: model.flow.total,
                preferences: model.preferences, hasSample: model.hasSample, hasTokenSample: model.tokensSampledAt != nil),
                layout: layout, showRunner: model.preferences.showRunner)
            view.frame.size.width = view.requiredWidth
            view.updateRunner(frame: 2)
            guard let strip = view.snapshotImage(scale: 2) else { print("Menu snapshot failed"); exit(1) }
            let size = NSSize(width: view.requiredWidth + 24, height: 46)
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            (light ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            strip.draw(in: NSRect(x: 12, y: 12, width: view.requiredWidth, height: 22))
            canvas.unlockFocus()
            guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do { try png.write(to: URL(fileURLWithPath: path)); print("Menu snapshot saved") }
            catch { print("Menu snapshot failed: \(error.localizedDescription)"); exit(1) }
            model.stop()
            app.terminate(nil)
        }
        app.run()
    }

    private static func snapshot(path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = DashboardModel(telemetryProvider: { LocalTelemetryCollector.fetchSnapshot() })
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
