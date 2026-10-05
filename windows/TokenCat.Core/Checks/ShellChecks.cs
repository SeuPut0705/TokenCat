using static TokenCat.Lang;
using A = TokenCat.TokenActivityState;

namespace TokenCat;

/// PreferenceChecks.swift `runShellChecks`, notification and telemetry-restart part (DESIGN §6.1). The director and animator
/// cases are WP4's RunnerChecks; the sound, login item, settings rows, legend and VoiceOver gate cases are the App's or cut.
public static class ShellChecks
{
    public static List<string> Run()
    {
        var c = new Check("Shell", "Shell: ");
        void check(bool valid, string description) => c.That(valid, description);
        var at = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

        // Notifications: top-level transitions only, content-free bodies, no replay at launch.
        var tracker = new AttentionTracker();
        var signal = new AttentionSignal("claude:s1", TokenSource.Claude, "TokenCat", "claude-opus-5-5", Live: true, Input: false);
        check(tracker.Update([signal]).Count == 0, "The first publish replayed existing states");
        signal = signal with { Input = true };
        var asked = tracker.Update([signal]);
        check(asked.Count == 1 && asked[0].Title == "입력 필요 · TokenCat" && asked[0].Subtitle == "Claude Code · claude-opus-5-5"
              && asked[0].Body == "답변하면 계속됩니다" && asked[0].Identifier == "input-claude:s1",
              "Entering input did not notify once with the state-first title and metadata only");
        check(tracker.Update([signal]).Count == 0, "Input notified again on an unchanged publish");
        signal = signal with { Input = false, Live = false, Ended = A.Complete, OutputTokens = 12_480, DurationSeconds = 252 };
        var finished = tracker.Update([signal]);
        check(finished.Count == 1 && finished[0].Title == "턴 완료 · TokenCat" && finished[0].Body == "12,480 tok · 4분 12초"
              && finished[0].Identifier == "done-claude:s1", "Live → complete did not produce the metadata-only completion");
        check(tracker.Update([signal]).Count == 0, "A completed turn notified twice");
        var codex = new AttentionSignal("codex:t1", TokenSource.Codex, null, null, false, false) { Ended = A.Interrupted, OutputTokens = 0 };
        check(tracker.Update([signal, codex]).Count == 0, "A session first seen already finished was reported");
        codex = codex with { Live = true, Ended = null };
        tracker.Update([signal, codex]);
        codex = codex with { Live = false, Ended = A.Interrupted };
        var interrupted = tracker.Update([signal, codex]).FirstOrDefault();
        check(interrupted?.Title == "턴 중단 · 프로젝트 미확인" && interrupted?.Subtitle == "Codex" && interrupted?.Body == "",
              "An interrupted turn is not reported as 중단 without a project, model or body");
        With(AppLanguage.En, () => check(asked[0].Title == "Input needed · TokenCat" && asked[0].Body == "Reply to continue"
                                         && finished[0].Title == "Turn complete · TokenCat" && finished[0].Body == "12,480 tok · 4m 12s"
                                         && interrupted?.Title == "Turn interrupted · Unknown project" && AttentionEvent.Duration(3_725) == "1h 2m",
                                         "English notifications or login item captions are wrong"));
        check(AttentionEvent.Duration(3_725) == "1시간 2분" && AttentionEvent.Duration(5) == "5초",
              "Korean notification durations or login item captions changed");
        var repeated = signal with { Id = "claude:s2", Live = true, Ended = null };
        tracker.Update([repeated]);
        repeated = repeated with { Live = false, Ended = A.Interrupted };
        check(tracker.Update([repeated]).FirstOrDefault() is { Title: "턴 중단 · TokenCat", Body: "" },
              "An interrupted turn carried the previous completed turn's output and duration");
        repeated = repeated with { Live = true, Ended = null };
        tracker.Update([repeated]);
        repeated = repeated with { Live = false, Ended = A.Complete };
        check(tracker.Update([repeated]).FirstOrDefault() is { Title: "턴 완료 · TokenCat", Body: "" },
              "A completion without newly recorded values reused the previous turn's numbers");

        var groups = SessionPresentation.Groups([
            new TokenReading(TokenSource.Claude, "claude:parent") { SessionID = "p", Project = "demo", Model = "m", ActivityState = A.Complete, SampledAt = at },
            new TokenReading(TokenSource.Claude, "claude:child")
            { SessionID = "p", AgentID = "a", IsSubagent = true, Active = true, ActivityState = A.Input, SampledAt = at, ParentSessionID = "p" },
            new TokenReading(TokenSource.Codex, "telemetry:codex") { SampledAt = at },
        ], at);
        var signals = AttentionSignal.Make(groups);
        check(signals.Count == 1 && signals[0].Input && signals[0].Live && signals[0].Ended == null,
              "A subagent waiting for input does not keep its top-level group live, or telemetry rows were included");
        List<SessionGroup> staleChildGroup(A child, bool leadActive, A lead) => SessionPresentation.Groups([
            new TokenReading(TokenSource.Claude, "claude:lead") { SessionID = "q", Project = "demo", Model = "m", Active = leadActive, ActivityState = lead, SampledAt = at },
            new TokenReading(TokenSource.Claude, "claude:stale-child")
            { SessionID = "q", AgentID = "b", IsSubagent = true, ActivityState = child, SampledAt = at, ParentSessionID = "q" },
        ], at);
        var lateTracker = new AttentionTracker();
        lateTracker.Update(AttentionSignal.Make(staleChildGroup(A.Stale, leadActive: true, lead: A.Working)));
        var onTime = lateTracker.Update(AttentionSignal.Make(staleChildGroup(A.Stale, leadActive: false, lead: A.Complete)));
        var late = lateTracker.Update(AttentionSignal.Make(staleChildGroup(A.Unfinished, leadActive: false, lead: A.Complete)));
        check(onTime.Count == 1 && late.Count == 0,
              "A stale subagent held back the lead's completion or produced a late notification when it timed out");

        var connected = at;
        Dictionary<TokenSource, DateTimeOffset> times(params (TokenSource Source, DateTimeOffset At)[] entries) =>
            entries.ToDictionary(entry => entry.Source, entry => entry.At);
        var state = TelemetryRestartState.Resolve(times((TokenSource.Claude, connected), (TokenSource.Codex, connected)),
                                                  times((TokenSource.Claude, connected.AddSeconds(-1))), at.AddSeconds(60));
        check(state.Needed.SetEquals([TokenSource.Claude, TokenSource.Codex]) && state.Expired.Count == 0,
              "A reading from before the config change cleared the restart notice");
        state = TelemetryRestartState.Resolve(state.Pending, times((TokenSource.Claude, connected.AddSeconds(5))), at.AddSeconds(60));
        check(state.Needed.SetEquals([TokenSource.Codex]) && !state.Pending.ContainsKey(TokenSource.Claude),
              "The first reading after connecting did not clear its client");
        var unused = TelemetryRestartState.Resolve(state.Pending, times(), at.AddSeconds(86_401));
        check(unused.Needed.Count == 0 && unused.Expired.Count == 0 && unused.Pending.ContainsKey(TokenSource.Codex),
              "A client never used since its config changed was reported as failing after 24 h");
        state = TelemetryRestartState.Resolve(state.Pending, times(), at.AddSeconds(86_401), ran: times((TokenSource.Codex, connected.AddSeconds(600))));
        check(state.Needed.Count == 0 && state.Expired.SetEquals([TokenSource.Codex]) && state.Pending.ContainsKey(TokenSource.Codex),
              "A client used after its config change but silent for 24 h did not switch to the 'never received' message");
        return c.Done();
    }
}
