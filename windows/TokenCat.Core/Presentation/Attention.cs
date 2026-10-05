using static TokenCat.Lang;

namespace TokenCat;

// Notifier.swift 1–113 (DESIGN §6.1): which top-level transitions notify, and the texts. Delivery (balloons) is the App's.

/// Metadata of one top-level group for notifications. Never carries prompt, question or tool input text.
public sealed record AttentionSignal(string Id, TokenSource Source, string? Project, string? Model, bool Live, bool Input)
{
    /// Complete or Interrupted once the group stopped being live.
    public TokenActivityState? Ended { get; init; }
    public int? OutputTokens { get; init; }
    public double? DurationSeconds { get; init; }
    /// The lead's newest record: with `Id`, the key that keeps a turn end from replaying the cat's content.
    public DateTimeOffset? EndedAt { get; init; }
    /// Every member waiting for the person waits for a plan approval (ExitPlanMode).
    public bool Plan { get; init; }
    /// The character's `content` is a completed turn (Assets/runner-v2.md): an interruption or API error plays nothing.
    public string? ContentKey => Ended == TokenActivityState.Complete ? $"{Id}@{EndedAt?.ToUnixTimeMilliseconds() ?? 0}" : null;

    public static List<AttentionSignal> Make(IReadOnlyList<SessionGroup> groups) => groups
        .Where(group => group.State != SessionDisplayState.Measurement)
        .Select(group =>
        {
            var lead = group.Lead.Reading;
            var input = group.Members.Any(member => member.Reading.ActivityState == TokenActivityState.Input);
            // A subagent waiting for a log (stale) neither holds back the lead's completion nor, when it later times out,
            // produces a late one.
            var live = group.Members.Any(member => member.State.IsRunning) || input;
            var ended = !live && !lead.Active && lead.ActivityState is TokenActivityState.Complete or TokenActivityState.Interrupted
                ? lead.ActivityState : (TokenActivityState?)null;
            var plan = input && group.Members.Where(member => member.Reading.ActivityState == TokenActivityState.Input)
                .All(member => SessionPresentation.IsPlanApproval(member.Reading));
            return new AttentionSignal(group.Id, lead.Source, lead.Project, lead.Model, live, input)
            {
                Ended = ended, OutputTokens = lead.LastOutputTokens, DurationSeconds = lead.LastTurnDurationSeconds, EndedAt = lead.LastActivity,
                Plan = plan,
            };
        }).ToList();
}

public enum AttentionKind { Finished, Input }

public sealed record AttentionEvent(AttentionKind Kind, AttentionSignal Signal)
{
    /// The state first (P-5): "입력 필요 · TokenCat", "턴 완료 · TokenCat", "턴 중단 · 프로젝트 미확인".
    public string Title
    {
        get
        {
            var what = Kind == AttentionKind.Input ? Signal.Plan ? Loc("계획 승인 대기", "Waiting for plan approval") : Loc("입력 필요", "Input needed")
                : Signal.Ended == TokenActivityState.Interrupted ? Loc("턴 중단", "Turn interrupted") : Loc("턴 완료", "Turn complete");
            return what + " · " + (Signal.Project is { Length: > 0 } project ? project : Loc("프로젝트 미확인", "Unknown project"));
        }
    }

    /// "Claude Code · claude-opus-5-5".
    public string Subtitle => string.Join(" · ", new[] { Signal.Source.Title, Signal.Model }.Where(part => !string.IsNullOrEmpty(part)));

    /// Completion "12,480 tok · 4분 12초" (never divided), input "답변하면 계속됩니다" (a plan "승인하면 계속됩니다"), interruption nothing.
    public string Body
    {
        get
        {
            if (Kind == AttentionKind.Input) return Signal.Plan ? Loc("승인하면 계속됩니다", "Approve to continue") : Loc("답변하면 계속됩니다", "Reply to continue");
            if (Signal.Ended != TokenActivityState.Complete) return "";
            return string.Join(" · ", new[]
            {
                Signal.OutputTokens is int tokens and > 0 ? $"{Format.Tokens(tokens)} tok" : null,
                Signal.DurationSeconds is { } seconds ? Duration(seconds) : null,
            }.OfType<string>());
        }
    }

    /// One delivered notification per group and kind: a newer one replaces it, and leaving input removes it.
    public string Identifier => Kind == AttentionKind.Input ? InputIdentifier(Signal.Id) : "done-" + Signal.Id;
    public static string InputIdentifier(string group) => "input-" + group;

    /// Raw duration reported by the client ("4분 12초" / "4m 12s"); never combined with token counts.
    public static string? Duration(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 1) return null;
        var total = (int)Math.Round(seconds, MidpointRounding.AwayFromZero);
        if (total >= 3_600) return Format.Span(total / 3_600, Format.TimeUnit.Hour) + " " + Format.Span(total / 60 % 60, Format.TimeUnit.Minute);
        return total >= 60
            ? Format.Span(total / 60, Format.TimeUnit.Minute) + " " + Format.Span(total % 60, Format.TimeUnit.Second)
            : Format.Span(total, Format.TimeUnit.Second);
    }
}

/// Top-level transitions only: live → complete/interrupted, and → waiting for input.
/// The first update only records the baseline so launching never replays old states.
public sealed class AttentionTracker
{
    Dictionary<string, AttentionSignal> previous = [];
    bool primed;

    public List<AttentionEvent> Update(IReadOnlyList<AttentionSignal> signals)
    {
        var events = new List<AttentionEvent>();
        if (primed)
            foreach (var signal in signals)
            {
                var before = previous.GetValueOrDefault(signal.Id);
                if (signal.Input && before?.Input != true) { events.Add(new(AttentionKind.Input, signal)); continue; }
                if (signal.Ended is null || before is not { Live: true }) continue;
                // Output and duration describe the last completion; they belong to this turn only when a completed turn just
                // recorded new values.
                var fresh = signal.Ended == TokenActivityState.Complete
                            && (before.OutputTokens != signal.OutputTokens || before.DurationSeconds != signal.DurationSeconds);
                events.Add(new(AttentionKind.Finished, fresh ? signal : signal with { OutputTokens = null, DurationSeconds = null }));
            }
        previous = [];
        foreach (var signal in signals) previous.TryAdd(signal.Id, signal);
        primed = true;
        return events;
    }
}
