import Darwin
import Foundation

/// `--bench-sample [samples] [--home <dir>] [--interval <s>] [--dump <json>]`: runs the token queue's work and the
/// presentation rebuild of one tick (`DashboardModel.refreshTokens` + `rebuildPresentation`) against a home folder,
/// read-only, and prints per-stage wall time, CPU time, RSS and, when a counting library is injected
/// (`DYLD_INSERT_LIBRARIES` exporting `tc_counters`), allocations and file system calls per sample.
enum SampleBench {
    private struct Counters {
        var values = [UInt64](repeating: 0, count: 8)
        static let read: (@convention(c) (UnsafeMutablePointer<UInt64>) -> Void)? = {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "tc_counters") else { return nil }
            return unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<UInt64>) -> Void).self)
        }()
        static func now() -> Counters {
            var counters = Counters()
            if let read { counters.values.withUnsafeMutableBufferPointer { read($0.baseAddress!) } }
            return counters
        }
        static func - (a: Counters, b: Counters) -> Counters {
            var result = Counters()
            for index in result.values.indices { result.values[index] = a.values[index] &- b.values[index] }
            return result
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func peakRSSMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    static func run(_ arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        let samples = value("--bench-sample").flatMap(Int.init) ?? 30
        let interval = value("--interval").flatMap(Double.init) ?? 1
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        let home = value("--home").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? realHome
        // A synthetic home must not pick up this Mac's CODEX_HOME, CLAUDE_CONFIG_DIR or XDG folders.
        let environment = home == realHome ? ProcessInfo.processInfo.environment : [:]
        // `--clock <unix seconds>` pins every sample's clock, so a frozen home gives comparable dumps across builds.
        let pinned = value("--clock").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let clock: () -> Date = { pinned ?? Date() }
        // As `DashboardModel`: one account reader shared by the tracker, the model and the omp usage history.
        let tracker = TokenTracker(homeDirectory: home, environment: environment, now: clock)
        let limitAccounts = tracker.accountReader
        let agentUsage = AgentUsageHistoryReader(home: home, environment: environment, accounts: limitAccounts)
        let sampler = SystemSampler()
        let stages = ["tracker", "accounts", "speed", "agentUsage", "presentation", "system"]
        var wall: [String: [Double]] = [:]
        var totals: [(wall: Double, cpu: Double, counters: Counters)] = []
        var last: (tokens: [TokenReading], sessions: SessionListModel, limits: [UsageLimitSummary])?
        print("bench: home \(home.path), \(samples) samples every \(interval) s, counters \(Counters.read == nil ? "off" : "on")")
        for index in 0...samples {
            let startWall = DispatchTime.now().uptimeNanoseconds
            let startCPU = cpuSeconds()
            let startCounters = Counters.now()
            var stageStart = startWall
            func lap(_ name: String) {
                let now = DispatchTime.now().uptimeNanoseconds
                if index > 0 { wall[name, default: []].append(Double(now - stageStart) / 1e6) }
                stageStart = now
            }
            let result: (tokens: [TokenReading], sessions: SessionListModel, limits: [UsageLimitSummary]) = autoreleasepool {
                let logs = tracker.sample()
                lap("tracker")
                limitAccounts.refresh()
                var defaults: [TokenSource: LimitAccount] = [:]
                var known: [TokenSource: [LimitAccount]] = [:]
                for provider in TokenSource.defaultClients {
                    defaults[provider] = limitAccounts.defaultAccount(provider)
                    known[provider] = limitAccounts.knownAccounts(provider)
                }
                lap("accounts")
                let tokens = TokenSpeed.apply(logs, measurements: [])
                lap("speed")
                let agent = agentUsage.read()
                for (provider, accounts) in agent.accounts {
                    known[provider] = Array(Set((known[provider] ?? []) + accounts)).sorted { $0.key < $1.key }
                }
                lap("agentUsage")
                let now = clock()
                let flow = FlowSeries.make(tokens, now: now)
                let groups = SessionPresentation.groups(tokens, now: now)
                let sessions = SessionListModel.make(tokens: tokens, now: now, expanded: false, flow: flow, groups: groups)
                let limits = SessionPresentation.usageLimits(tokens: tokens, codexReads: agent.codex, claudeLimits: agent.claude,
                                                             defaults: defaults, known: known, now: now)
                _ = tokens.filter { !SessionPresentation.isTelemetry($0) }.compactMap(\.lastOutputAt).max()
                lap("presentation")
                _ = sampler.sample()
                lap("system")
                return (tokens, sessions, limits)
            }
            last = result
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startWall) / 1e6
            let cpu = (cpuSeconds() - startCPU) * 1_000
            let counters = Counters.now() - startCounters
            if index == 0 {
                print(String(format: "cold: %.1f ms wall, %.1f ms cpu, %d readings, %.1f MB footprint", elapsed, cpu, result.tokens.count, footprintMB())
                      + (Counters.read == nil ? "" : ", \(describe(counters))"))
            } else {
                totals.append((elapsed, cpu, counters))
                if index % 60 == 0 { print(String(format: "sample %d: %.1f MB footprint, %.1f MB peak", index, footprintMB(), peakRSSMB())) }
            }
            if index < samples, interval > 0 { Thread.sleep(forTimeInterval: interval) }
        }
        func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
        func p90(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[min(values.count - 1, values.count * 9 / 10)] }
        print(String(format: "warm: median %.2f ms wall (p90 %.2f), median %.2f ms cpu (mean %.2f)", median(totals.map(\.wall)), p90(totals.map(\.wall)),
                     median(totals.map(\.cpu)), totals.map(\.cpu).reduce(0, +) / Double(max(1, totals.count))))
        print("stages (median ms): " + stages.map { String(format: "%@ %.2f", $0, median(wall[$0] ?? [])) }.joined(separator: ", "))
        if Counters.read != nil {
            var sum = Counters()
            for total in totals { sum.values = zip(sum.values, total.counters.values).map { $0 / 1 + $1 } }
            let n = UInt64(max(1, totals.count))
            sum.values = sum.values.map { $0 / n }
            print("per warm sample (mean): \(describe(sum))")
        }
        print(String(format: "memory: %.1f MB footprint, %.1f MB peak RSS, %d readings", footprintMB(), peakRSSMB(), last?.tokens.count ?? 0))
        if let path = value("--dump"), let last { dump(last, to: path) }
        return 0
    }

    private static func describe(_ counters: Counters) -> String {
        let v = counters.values
        return "\(v[0]) allocs (\(v[1] / 1024) KB), \(v[2]) opens, \(v[3]) stats, \(v[4]) getattrlist, \(v[5]) dir reads, \(v[6]) reads (\(v[7] / 1024) KB)"
    }

    /// Readings without their sample clock, plus the presentation's describable pieces, for before/after comparisons
    /// (run with SWIFT_DETERMINISTIC_HASHING=1 so dictionary order is stable).
    private static func dump(_ result: (tokens: [TokenReading], sessions: SessionListModel, limits: [UsageLimitSummary]), to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let tokens = result.tokens.map { reading -> TokenReading in
            var copy = reading
            copy.sampledAt = nil
            return copy
        }
        var text = (try? encoder.encode(tokens)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        text += "\n" + String(describing: result.sessions.counts) + "\n" + String(describing: result.limits) + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
