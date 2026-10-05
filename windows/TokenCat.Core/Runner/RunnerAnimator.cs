namespace TokenCat;

// WP4 stub (DESIGN §11): RunnerAnimator.swift with an injected clock and no timer (the App schedules NextDelay()).
// WP4 replaces the bodies and owns this file.

/// What drives the character. Raw values are persisted under "animationSource"; legacy "tokens" maps to Activity.
public enum RunnerMotion { Activity, Cpu, Measured, Still }

public static class RunnerMotionText
{
    extension(RunnerMotion)
    {
        public static string ConfirmedKey => "animationSourceConfirmed";
        public static RunnerMotion Stored(string? raw, bool confirmed) => throw new NotImplementedException();
    }

    extension(RunnerMotion motion)
    {
        public string Title => throw new NotImplementedException();
        public string Caption => throw new NotImplementedException();
        public string Subtitle => throw new NotImplementedException();
    }
}

/// Fps 0 plays the pose's own timing. `Until` asks for a re-plan (end of an output burst).
public sealed record RunnerPlan(RunnerPose Pose)
{
    public double Fps { get; init; }
    public bool Still { get; init; }
    public bool Smooth { get; init; }
    public DateTimeOffset? Until { get; init; }
}

/// AI state for the character, computed once per publish from the shared top-level groups.
public sealed record RunnerActivity
{
    public RunnerActivity() { }
    public RunnerActivity(IReadOnlyList<SessionGroup> groups, double? cpu, DateTimeOffset now) => throw new NotImplementedException();

    public bool Input { get; init; }
    public bool Running { get; init; }
    public bool Waiting { get; init; }
    public DateTimeOffset? NewestOutputAt { get; init; }
    public DateTimeOffset? NewestActivityAt { get; init; }
    public double? MeasuredRate { get; init; }
    public double? Cpu { get; init; }
    /// False until the first token sample: an empty list then means "not read yet", not "quiet".
    public bool Known { get; init; } = true;
}

/// State → plan. Cadences are fixed per state or follow CPU / a measured rate; never token or session counts.
public struct RunnerDirector
{
    public void Observe(RunnerActivity activity, DateTimeOffset now) => throw new NotImplementedException();
    public readonly DateTimeOffset? QuietSince(RunnerActivity activity) => throw new NotImplementedException();
    public readonly RunnerPlan Plan(RunnerMotion motion, RunnerActivity activity, DateTimeOffset now, bool reduceMotion) =>
        throw new NotImplementedException();
}

public sealed class RunnerAnimator
{
    public RunnerAnimator(RunnerManifest manifest, Func<DateTimeOffset> clock) => throw new NotImplementedException();
    public void Apply(RunnerPlan plan) => throw new NotImplementedException();
    /// What to draw now; FxStep is the z glyph step while sleeping.
    public (RunnerPose Pose, int Frame, int? FxStep) Current => throw new NotImplementedException();
    /// Time until Advance(); null holds the frame (no timer).
    public TimeSpan? NextDelay() => throw new NotImplementedException();
    public void Advance() => throw new NotImplementedException();
    public bool PlayContent() => throw new NotImplementedException();
    public void Stop() => throw new NotImplementedException();
}
