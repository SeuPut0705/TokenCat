import Foundation

/// The turn bookkeeping the Copilot CLI, Amp and Droid readers share, with `TokenLogParser`'s liveness rules: an open turn
/// counts as running for 600 s of silence, 900 s while a tool runs and 24 h while it waits for the person; past that it
/// is `stale` for up to 30 minutes after the newest record, then `unfinished`. Only counts, times, names and ids are kept.
final class LogTurnState {
    /// Tool names that wait for the person rather than run.
    private let inputTools: Set<String>
    private(set) var lastActivity: Date?
    /// Newest record of any kind; liveness only.
    private(set) var lastLogAt: Date?
    private(set) var turnOpen = false
    private var startedAt: Date?
    /// The open turn was seen from its start, so its output is whole.
    private var accurate = false
    private var output = 0
    private var observedState: TokenActivityState = .idle
    private var pendingTools: [(id: String, name: String?)] = []
    /// A permission prompt or another request for the person that is not a tool.
    private var pendingRequests = Set<String>()
    private(set) var recentOutputs: [TokenOutputEvent] = []
    private var lastOutputAt: Date?
    private var lastOutputDelta: Int?
    /// The last completed turn. Output logged after its close (before anything else happens) still belongs to it.
    private var closed: (output: Int, accurate: Bool, finishedAt: Date, model: String?)?
    private var closedTakesOutput = false

    init(inputTools: Set<String> = []) { self.inputTools = inputTools }

    func logged(_ date: Date?) {
        if let date { lastLogAt = max(lastLogAt ?? date, date) }
    }

    func touch(_ date: Date?) {
        if let date { lastActivity = max(lastActivity ?? date, date) }
    }

    /// A record stamped ahead of the clock must not keep the newest times in the future.
    func clamp(to ceiling: Date) {
        lastLogAt = lastLogAt.map { min($0, ceiling) }
        lastActivity = lastActivity.map { min($0, ceiling) }
    }

    /// A new turn from the person's input. `whole` is false when its start may lie before what was read.
    func begin(at date: Date?, whole: Bool = true) {
        turnOpen = true
        startedAt = date
        accurate = whole
        output = 0
        observedState = .working
        pendingTools.removeAll(keepingCapacity: true)
        pendingRequests.removeAll()
        lastOutputAt = nil
        lastOutputDelta = nil
        closedTakesOutput = false
        touch(date)
    }

    /// Turn content while no turn is open: the turn began before what was read, so its output is not whole.
    func resume(at date: Date?) {
        if !turnOpen { begin(at: date, whole: false) }
    }

    func setState(_ state: TokenActivityState, at date: Date?) {
        if turnOpen { observedState = state }
        touch(date)
    }

    /// One logged output increment at its log time.
    func addOutput(_ tokens: Int, at date: Date?) {
        guard tokens > 0 else { return }
        touch(date)
        if turnOpen { output += tokens } else if closedTakesOutput { closed?.output += tokens }
        lastOutputAt = date
        lastOutputDelta = tokens
        guard let date else { return }
        recentOutputs.append(TokenOutputEvent(at: date, tokens: tokens))
        if recentOutputs.count > 512 { recentOutputs.removeFirst(recentOutputs.count - 512) }
    }

    func startTool(_ id: String, name: String?, at date: Date?) {
        pendingTools.removeAll { $0.id == id }
        pendingTools.append((id, name))
        if pendingTools.count > 256 { pendingTools.removeFirst(pendingTools.count - 256) }
        setState(.tool, at: date)
    }

    func finishTool(_ id: String, at date: Date?) {
        guard let index = pendingTools.firstIndex(where: { $0.id == id }) else { return }
        pendingTools.remove(at: index)
        setState(pendingTools.isEmpty ? .working : .tool, at: date)
    }

    func startRequest(_ id: String, at date: Date?) {
        if turnOpen { pendingRequests.insert(id) }
        touch(date)
    }

    func finishRequest(_ id: String) { pendingRequests.remove(id) }

    var hasPendingTools: Bool { !pendingTools.isEmpty }

    /// Ends the open turn. A completed one becomes the last completed turn (its output counts when the whole turn was
    /// read); an interrupted one leaves the previous completed turn in place.
    func close(_ state: TokenActivityState, at date: Date?, model: String?) {
        guard turnOpen else { return }
        turnOpen = false
        observedState = state
        pendingTools.removeAll(keepingCapacity: true)
        pendingRequests.removeAll()
        touch(date)
        closedTakesOutput = state == .complete
        if state == .complete { closed = (output, accurate, date ?? lastActivity ?? .distantPast, model) }
    }

    var completion: TokenTurnCompletion? {
        guard let closed, closed.accurate, closed.output > 0 else { return nil }
        return TokenTurnCompletion(output: closed.output, durationSeconds: nil, finishedAt: closed.finishedAt, model: closed.model)
    }

    /// The outstanding tool that holds an open turn: one waiting for the person, else the newest.
    var runningTool: (id: String, name: String?)? {
        guard turnOpen else { return nil }
        return pendingTools.last { inputTools.contains($0.name ?? "") } ?? pendingTools.last
    }

    private var waitsForInput: Bool {
        turnOpen && (!pendingRequests.isEmpty || pendingTools.contains { inputTools.contains($0.name ?? "") })
    }

    private var liveAt: Date? { [lastLogAt, lastActivity].compactMap { $0 }.max() }

    private var liveHorizon: TimeInterval {
        if waitsForInput { return 86_400 }
        return pendingTools.isEmpty ? 600 : 900
    }

    func isActive(at now: Date) -> Bool {
        guard turnOpen, let liveAt else { return false }
        let age = now.timeIntervalSince(liveAt)
        return age >= -5 && age <= liveHorizon
    }

    func isRecent(at now: Date) -> Bool {
        turnOpen || liveAt.map { now.timeIntervalSince($0) <= 3_600 } == true
    }

    func activityState(at now: Date) -> TokenActivityState {
        guard turnOpen else { return observedState }
        if waitsForInput { return isActive(at: now) ? .input : .unfinished }
        if isActive(at: now) { return observedState }
        guard let liveAt, now.timeIntervalSince(liveAt) <= 1_800 else { return .unfinished }
        return .stale
    }

    /// The shared reading fields; nil until the log showed content. `cwd` gives project and projectPath.
    func reading(source: TokenSource, id: String, model: String?, cwd: String?, now: Date) -> TokenReading? {
        guard lastActivity != nil else { return nil }
        let completion = completion
        var reading = TokenReading(source: source, id: id)
        reading.model = model ?? completion?.model
        if let tool = runningTool {
            reading.toolName = tool.name
            reading.toolCategory = tool.name.map(TokenLogParser.category) ?? .other
        }
        if let cwd, !cwd.isEmpty {
            reading.project = URL(fileURLWithPath: cwd).lastPathComponent
            reading.projectPath = cwd
        }
        reading.lastActivity = lastActivity
        reading.lastLogAt = lastLogAt
        reading.measurementAt = completion?.finishedAt ?? lastActivity
        reading.active = isActive(at: now)
        reading.activityState = activityState(at: now)
        reading.currentTurnStartedAt = turnOpen ? startedAt : nil
        reading.currentTurnOutputTokens = turnOpen && accurate ? output : nil
        reading.lastOutputAt = lastOutputAt
        reading.lastOutputDelta = lastOutputDelta
        reading.recentOutputs = recentOutputs.filter {
            let age = now.timeIntervalSince($0.at)
            return age >= -5 && age <= TokenTracker.recentOutputWindow
        }
        reading.lastOutputTokens = completion?.output
        reading.sampledAt = now
        return reading
    }
}
