namespace TokenCat;

// WP3 stub (DESIGN §11). WP4 (RunnerActivity) merges before WP3 and reads groups, so the small pure members below are
// already the Swift logic; the rest of SessionPresentation.swift arrives with WP3, which owns this file.

/// What a row shows. Derived only from the tracker's enum and exact timestamps, never re-guessed.
public enum SessionDisplayState { Input, Retrying, Tool, Working, Waiting, Complete, Interrupted, Unfinished, Idle, Measurement }

public static class SessionDisplayStateRules
{
    extension(SessionDisplayState)
    {
        /// The one urgency order: input > API retry > tool > progress > waiting for a log.
        public static IReadOnlyList<SessionDisplayState> LiveOrder =>
            [SessionDisplayState.Input, SessionDisplayState.Retrying, SessionDisplayState.Tool, SessionDisplayState.Working, SessionDisplayState.Waiting];

        /// The most urgent live state among `states`; null when none is live.
        public static SessionDisplayState? MostUrgent(IEnumerable<SessionDisplayState> states)
        {
            var present = states.ToHashSet();
            foreach (var state in SessionDisplayState.LiveOrder) if (present.Contains(state)) return state;
            return null;
        }
    }

    extension(SessionDisplayState state)
    {
        /// Shown as live in the list (includes waiting for a log).
        public bool IsLive => state.IsRunning || state == SessionDisplayState.Waiting;
        /// Counted as running. A turn waiting for the person is still open.
        public bool IsRunning => state is SessionDisplayState.Input or SessionDisplayState.Retrying or SessionDisplayState.Tool or SessionDisplayState.Working;
        public bool ExpectsSpeed => state is SessionDisplayState.Retrying or SessionDisplayState.Tool or SessionDisplayState.Working;
    }
}

public sealed record SessionMember(TokenReading Reading, SessionDisplayState State);

/// A top-level row with the subagents that belong to it by exact session identity.
public sealed record SessionGroup(SessionMember Lead)
{
    public IReadOnlyList<SessionMember> Children { get; init; } = [];
    public string Id => Lead.Reading.Id;
    public IReadOnlyList<SessionMember> Members => [Lead, .. Children];
    public bool IsOrphan => Lead.Reading.IsSubagent;

    public SessionDisplayState State => Lead.State == SessionDisplayState.Measurement
        ? SessionDisplayState.Measurement
        : SessionDisplayState.MostUrgent(Members.Select(member => member.State)) ?? SessionDisplayState.Idle;

    public DateTimeOffset LastActivity =>
        Members.Select(member => member.Reading.LastActivity ?? member.Reading.MeasurementAt).Max() ?? DateTimeOffset.MinValue;
}

public static class SessionPresentation
{
    public static List<SessionGroup> Groups(IReadOnlyList<TokenReading> readings, DateTimeOffset now) => throw new NotImplementedException();
}
