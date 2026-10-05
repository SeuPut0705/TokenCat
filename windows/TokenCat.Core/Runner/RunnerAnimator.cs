using static TokenCat.Lang;

namespace TokenCat;

// RunnerAnimator.swift with an injected clock and no timer: the App owns one one-shot timer, (re)armed from `Scheduled`.

/// What drives the character. Raw values are persisted under "animationSource"; legacy "tokens" maps to Activity.
public enum RunnerMotion { Activity, Cpu, Measured, Still }

public static class RunnerMotionText
{
    extension(RunnerMotion)
    {
        /// Set on the first save by this version. Older builds wrote "cpu" (their default) whenever any setting changed, so an
        /// unconfirmed "cpu" was not a choice and moves to the new default once; later choices stay.
        public static string ConfirmedKey => "animationSourceConfirmed";

        public static RunnerMotion Stored(string? raw, bool confirmed) =>
            raw == "tokens" || raw == "cpu" && !confirmed ? RunnerMotion.Activity : RunnerCharacterText.Parse<RunnerMotion>(raw) ?? RunnerMotion.Activity;
    }

    extension(RunnerMotion motion)
    {
        /// The persisted raw value: "activity", "cpu", "measured", "still".
        public string Id => motion.ToString().ToLowerInvariant();

        public string Title => motion switch
        {
            RunnerMotion.Activity => Loc("AI 활동 상태", "AI Activity"),
            RunnerMotion.Cpu => Loc("CPU 사용률", "CPU Usage"),
            RunnerMotion.Measured => Loc("AI 실측 속도", "Measured AI Speed"),
            _ => Loc("멈춤", "Still"),
        };

        public string Caption => motion switch
        {
            RunnerMotion.Activity => Loc("캐릭터 움직임은 상태만 나타내며 속도가 아닙니다. 진행 중이면 걷고, 출력이 기록되면 잠깐 달리고, 입력이 필요하면 이쪽을 봅니다. 활동이 없으면 앉아 있다가 10분 뒤 잠듭니다.",
                                         "The character's motion shows state, not speed. It walks while a session is working, runs briefly when output is recorded and faces you when input is needed. With no activity it sits, then sleeps after 10 minutes."),
            RunnerMotion.Cpu => Loc("CPU 사용률이 4% 미만이면 앉고, 20%까지는 걷고, 그보다 높으면 달립니다. 높을수록 박자가 빨라집니다.",
                                    "Sits below 4% CPU usage, walks up to 20% and runs above that. The higher the usage, the faster the pace."),
            RunnerMotion.Measured => Loc("최근 5초 안에 받은 실측 속도에만 반응합니다. 40 tok/s 미만은 걷고 그 이상은 달리며, 실측이 없으면 앉아서 기다립니다.",
                                         "Reacts only to speeds measured in the last 5 s: walks below 40 tok/s, runs at 40 or more, and sits and waits when there's no measurement."),
            _ => Loc("캐릭터가 앉은 자세로 멈춰 있습니다.", "The character sits still."),
        };

        /// One line under the picker (T-2); the legend (T-4) says the rest.
        public string Subtitle => motion switch
        {
            RunnerMotion.Activity => Loc("움직임은 상태만 나타내며 속도가 아닙니다.", "Motion shows state, not speed."),
            RunnerMotion.Cpu => Loc("CPU 사용률에 따라 앉기·걷기·달리기가 바뀝니다.", "Sits, walks or runs with CPU usage."),
            RunnerMotion.Measured => Loc("최근 5초 안의 실측 속도에만 반응합니다.", "Reacts only to speed measured in the last 5 s."),
            _ => Loc("앉은 자세로 멈춰 있습니다.", "Sits still."),
        };
    }
}

/// What the director wants on screen. Fps 0 plays the pose's own timing, the only cadence source for AI activity; CPU and
/// measured modes set a cadence. `Until` asks for a re-plan (end of an output burst).
public sealed record RunnerPlan(RunnerPose Pose)
{
    /// Frames per second for CPU and measured modes; 0 plays the manifest timing.
    public double Fps { get; init; }
    /// Holds frame 0 with no timer (still motion, Reduce Motion); a still sleep shows its large z.
    public bool Still { get; init; }
    /// CPU and measured modes ease toward the target cadence.
    public bool Smooth { get; init; }
    public DateTimeOffset? Until { get; init; }
}

/// AI state for the character, computed once per publish from the shared top-level groups.
public sealed record RunnerActivity
{
    public RunnerActivity() { }

    public RunnerActivity(IReadOnlyList<SessionGroup> groups, double? cpu, DateTimeOffset now)
    {
        Cpu = cpu;
        foreach (var group in groups)
        {
            var measurement = group.State == SessionDisplayState.Measurement;
            if (!measurement && group.State.IsRunning) Running = true;
            if (!measurement && group.State == SessionDisplayState.Waiting) Waiting = true;
            foreach (var member in group.Members)
            {
                var reading = member.Reading;
                if (reading.SpeedMeasurement is { } speed && speed.Model == reading.Model && speed.TokensPerSecond is { } rate
                    && Math.Abs((now - speed.At).TotalSeconds) < 5) MeasuredRate = Math.Max(MeasuredRate ?? rate, rate);
                if (measurement) continue;
                if (reading.ActivityState == TokenActivityState.Input) Input = true;
                if (reading.LastOutputAt is { } output && (reading.LastOutputDelta ?? 0) > 0) NewestOutputAt = Max(NewestOutputAt, output);
                if (reading.LastActivity is { } activity) NewestActivityAt = Max(NewestActivityAt, activity);
            }
        }
    }

    public bool Input { get; init; }
    public bool Running { get; init; }
    public bool Waiting { get; init; }
    public DateTimeOffset? NewestOutputAt { get; init; }
    public DateTimeOffset? NewestActivityAt { get; init; }
    public double? MeasuredRate { get; init; }
    public double? Cpu { get; init; }
    /// False until the first token sample: an empty list then means "not read yet", not "quiet".
    public bool Known { get; init; } = true;

    static DateTimeOffset Max(DateTimeOffset? a, DateTimeOffset b) => a is { } value && value > b ? value : b;
}

/// State → plan. Cadences are fixed per state (AI activity) or follow CPU / a measured rate; never token or session counts.
public struct RunnerDirector
{
    public const double Burst = 1.2, SleepAfter = 600, Easing = 1.5;
    /// A burst that starts this soon after the previous run ended continues that run (no dwell, no frame 0) (K-5).
    public const double BurstMerge = 1.0;

    /// CPU gait with hysteresis (K-4): sit below 4 % (leaves above 6 %), walk to 20 %, run above 20 % (back below 15 %).
    public enum Gait { Rest, Walk, Run }

    DateTimeOffset? burstEventAt;
    DateTimeOffset? lastLiveAt;

    public RunnerDirector() { }

    public DateTimeOffset? BurstUntil { readonly get; private set; }
    public Gait CpuGait { readonly get; private set; }

    public static double WalkFps(double fraction) => 5 + 3 * Math.Min(1, Math.Max(0, fraction));
    public static double RunFps(double fraction) => 8 + 6 * Math.Min(1, Math.Max(0, fraction));
    /// Walk 6–20 % → 5–8 fps, run 20–100 % → 8–14 fps, linear.
    public static double Fps(double cpu, Gait gait) => gait == Gait.Run ? RunFps((cpu - 20) / 80) : WalkFps((cpu - 6) / 14);

    /// Measured: below 40 tok/s walk 5–8 fps over 0–40; from 40 run 8–14 fps over 40–200.
    public static RunnerPlan MeasuredPlan(double rate) => rate < 40
        ? new RunnerPlan(RunnerPose.Walk) { Fps = WalkFps(rate / 40), Smooth = true }
        : new RunnerPlan(RunnerPose.Run) { Fps = RunFps((rate - 40) / 160), Smooth = true };

    /// Called once per publish. A burst is keyed by the output event's own time, so refreshes never retrigger it.
    /// Every newer event runs (or keeps running) for `Burst`; the animator joins a run that ended under `BurstMerge` ago.
    public void Observe(RunnerActivity activity, DateTimeOffset now)
    {
        if (activity.Input || activity.Running || activity.Waiting) lastLiveAt = now;
        if (activity.NewestOutputAt is { } at && at > (burstEventAt ?? DateTimeOffset.MinValue) && Math.Abs((now - at).TotalSeconds) <= 5)
        {
            burstEventAt = at;
            BurstUntil = now.AddSeconds(Burst);
        }
        if (activity.Cpu is { } cpu)
            CpuGait = CpuGait switch
            {
                Gait.Rest => cpu > 6 ? (cpu > 20 ? Gait.Run : Gait.Walk) : Gait.Rest,
                Gait.Walk => cpu < 4 ? Gait.Rest : cpu > 20 ? Gait.Run : Gait.Walk,
                _ => cpu < 4 ? Gait.Rest : cpu < 15 ? Gait.Walk : Gait.Run,
            };
    }

    /// When the 10 minutes of quiet start: the last live moment or the newest activity. The flyout header uses the same time.
    public readonly DateTimeOffset? QuietSince(RunnerActivity activity) =>
        lastLiveAt is { } live && (activity.NewestActivityAt is not { } newest || live >= newest) ? live : activity.NewestActivityAt;

    public readonly RunnerPlan Plan(RunnerMotion motion, RunnerActivity activity, DateTimeOffset now, bool reduceMotion)
    {
        var plan = motion switch
        {
            RunnerMotion.Still => new RunnerPlan(RunnerPose.Sit) { Still = true },
            RunnerMotion.Cpu => activity.Cpu is { } cpu && CpuGait != Gait.Rest
                ? new RunnerPlan(CpuGait == Gait.Run ? RunnerPose.Run : RunnerPose.Walk) { Fps = Fps(cpu, CpuGait), Smooth = true }
                : new RunnerPlan(RunnerPose.Sit),
            RunnerMotion.Measured => activity.MeasuredRate is { } rate ? MeasuredPlan(rate) : new RunnerPlan(RunnerPose.Sit),
            _ when !activity.Known => new RunnerPlan(RunnerPose.Sit),
            _ when activity.Input => new RunnerPlan(RunnerPose.Alert),
            _ when BurstUntil is { } until && now < until => new RunnerPlan(RunnerPose.Run) { Until = until },
            _ when activity.Running => new RunnerPlan(RunnerPose.Walk),
            _ when activity.Waiting => new RunnerPlan(RunnerPose.Sit),
            _ => new RunnerPlan(QuietSince(activity) is { } quiet && (now - quiet).TotalSeconds < SleepAfter ? RunnerPose.Sit : RunnerPose.Sleep),
        };
        return reduceMotion ? plan with { Fps = 0, Smooth = false, Still = true } : plan;
    }
}

/// Plays the director's plan with one one-shot timer to the next change; nothing runs while the pose is held or the character
/// cannot be seen. Frame timing comes only from the manifest (K-6); the effect layer is the sleep z step (K-2).
/// - Sit and alert hold frame 0 (sit cycles `HoldSequence`) and blink frame 1; every `DoubleEvery`-th blink is double.
/// - Sleep breathes A (frame 0) → B (frame 1, small z) → C (frame 0, large z) on 1.6 s steps, then after `DeepSleepAfter`
///   holds frame 0 with the large z and no timer (K-3).
/// - Leaving sleep plays the yawn once; a confirmed turn end while sitting plays `content` once (K-5).
/// - walk ↔ run waits until the shown loop has run `Dwell`; input interrupts at once; an output burst within
///   `RunnerDirector.BurstMerge` after a run ended continues that run's stride at once (K-5).
/// - Nothing one-shot plays while paused: a yawn or `content` is dropped, not replayed later.
/// The App arms its timer with the delay `Scheduled` hands it (null: stop it), calls `Advance()` when it fires, and draws
/// `Current` (or from `Render`). It must not restart the timer on its own: an unchanged plan keeps the pending one.
public sealed class RunnerAnimator
{
    public const double Dwell = 1.0, DeepSleepAfter = 1_200;
    /// The open gap inside a double blink (closed · open · closed).
    public const double DoubleBlinkGap = 0.15;
    /// Effect steps for the sleep z, as the manifest numbers them (0 no z, 1 zS, 2 zL).
    public const int SmallZ = 1, LargeZ = 2;

    /// The effect step a held frame shows: a still or deep sleep keeps only the large z.
    public static int? StillFx(RunnerPose pose) => pose == RunnerPose.Sleep ? LargeZ : null;

    readonly Func<DateTimeOffset> clock;
    double fps = 5;
    DateTimeOffset? lastTick;
    DateTimeOffset shownSince = DateTimeOffset.MinValue;
    DateTimeOffset? sleepSince;
    int breath, holds, blinks, doubling;
    /// Remaining steps of the yawn or content one-shot.
    readonly List<(int Frame, double Seconds)> oneShot = [];
    DateTimeOffset? dwellUntil;
    /// When the last run left the screen and its frame, so a burst right after it continues the stride.
    DateTimeOffset? runEndedAt;
    int runFrame;
    bool armed, paused;

    public RunnerAnimator(RunnerManifest manifest, Func<DateTimeOffset> clock)
    {
        this.clock = clock;
        Timing = manifest.Timing;
    }

    /// Called with each frame change (pose, frame, fx step).
    public Action<RunnerPose, int, int?> Render { get; set; } = (_, _, _) => { };
    /// The burst ended: the App plans again and calls Apply.
    public Action Replan { get; set; } = () => { };
    /// The one-shot timer was (re)armed with this delay, or stopped (null).
    public Action<TimeSpan?> Scheduled { get; set; } = _ => { };
    /// The manifest's timing; checks replace it.
    public Func<RunnerPose, RunnerTiming> Timing { get; set; }

    public RunnerPlan Plan { get; private set; } = new(RunnerPose.Sit);
    /// What is drawn; differs from `Plan` during a one-shot or a dwell hold.
    public RunnerPlan Shown { get; private set; } = new(RunnerPose.Sit);
    public int Frame { get; private set; }
    public int? Fx { get; private set; }
    /// Seconds until the pending timer fires; null when nothing is scheduled.
    public double? ScheduledDelay { get; private set; }

    /// What to draw now; FxStep is the z glyph step while sleeping.
    public (RunnerPose Pose, int Frame, int? FxStep) Current => (Shown.Pose, Frame, Fx);
    /// Time until Advance(); null holds the frame (no timer).
    public TimeSpan? NextDelay() => armed && ScheduledDelay is { } delay ? TimeSpan.FromSeconds(delay) : null;

    public bool IsTimerRunning => armed;
    public bool IsPlayingOneShot => oneShot.Count > 0;
    public bool IsDeepSleep => Shown.Pose == RunnerPose.Sleep && oneShot.Count == 0
        && sleepSince is { } since && (clock() - since).TotalSeconds >= DeepSleepAfter;

    /// Hidden (locked session, suspend, icon not drawn): no timer, and a playing one-shot is dropped.
    public bool Paused
    {
        get => paused;
        set
        {
            if (paused == value) return;
            paused = value;
            if (paused && oneShot.Count > 0)
            {
                oneShot.Clear();
                Show(Plan, clock());
            }
            Schedule();
        }
    }

    public void Apply(RunnerPlan next)
    {
        if (next == Plan)
        {
            if (!armed) Schedule();
            return;
        }
        var previous = Plan;
        Plan = next;
        // Only the cadence or the burst end moved: keep the frame; the running timer eases toward it.
        if (next.Pose == previous.Pose && next.Still == previous.Still && oneShot.Count == 0 && dwellUntil is null && Shown.Pose == next.Pose)
        {
            if (next.Smooth && !previous.Smooth) fps = 5;
            Shown = next;
            if (!armed) Schedule();
            return;
        }
        Transition();
    }

    /// Plays `content` once (K-5) when the plan is a moving sit; the caller dedupes by signal id and event time.
    public bool PlayContent()
    {
        if (paused || Plan.Pose != RunnerPose.Sit || Plan.Still || Shown.Pose != RunnerPose.Sit || oneShot.Count > 0 || dwellUntil is not null)
            return false;
        StartOneShot(RunnerPose.Content);
        return true;
    }

    public void Stop()
    {
        armed = false;
        ScheduledDelay = null;
        Scheduled(null);
    }

    /// Chooses what to show for `Plan`: dwell hold, wake yawn, one-shot cancel, or the plan itself.
    void Transition()
    {
        var now = clock();
        var urgent = Plan.Pose is RunnerPose.Alert or RunnerPose.Run;
        if (oneShot.Count > 0)
        {
            if (!urgent)
            {
                if (!armed) Schedule(); // the one-shot finishes first
                return;
            }
            oneShot.Clear();
        }
        if (Plan.Pose == Shown.Pose && Plan.Still == Shown.Still)
        {
            // A deferred change was taken back: keep the frame.
            dwellUntil = null;
            Shown = Plan;
            Schedule();
            return;
        }
        if (Plan.Pose == RunnerPose.Run && Plan.Until is not null && !Plan.Still && Shown.Pose != RunnerPose.Run && runEndedAt is { } ended
            && (now - ended).TotalSeconds < RunnerDirector.BurstMerge)
        {
            dwellUntil = null;
            var frames = Math.Max(1, Timing(RunnerPose.Run).Durations.Count);
            Show(Plan, now, (runFrame + 1) % frames);
            return;
        }
        if (Plan.Pose != RunnerPose.Alert && IsLoop(Shown.Pose) && IsLoop(Plan.Pose) && Shown.Pose != Plan.Pose
            && (now - shownSince).TotalSeconds < Dwell)
        {
            dwellUntil = shownSince.AddSeconds(Dwell);
            Schedule();
            return;
        }
        dwellUntil = null;
        if (!paused && Shown.Pose == RunnerPose.Sleep && Plan.Pose != RunnerPose.Sleep && !Plan.Still && !urgent)
        {
            StartOneShot(RunnerPose.Yawn);
            return;
        }
        Show(Plan, now);
    }

    static bool IsLoop(RunnerPose pose) => pose is RunnerPose.Walk or RunnerPose.Run;

    void Show(RunnerPlan next, DateTimeOffset now, int start = 0)
    {
        var wasSmooth = Shown.Smooth && Shown.Fps > 0;
        if (Shown.Pose == RunnerPose.Run && next.Pose != RunnerPose.Run)
        {
            runEndedAt = now;
            runFrame = Frame;
        }
        Shown = next;
        shownSince = now;
        Frame = start;
        holds = 0;
        doubling = 0;
        breath = 0;
        if (next.Smooth && !wasSmooth) fps = 5;
        sleepSince = next.Pose == RunnerPose.Sleep ? sleepSince ?? now : null;
        Fx = next.Pose == RunnerPose.Sleep && (next.Still || IsDeepSleep) ? LargeZ : null;
        lastTick = now;
        Render(Shown.Pose, Frame, Fx);
        Schedule();
    }

    void StartOneShot(RunnerPose pose)
    {
        var timing = Timing(pose);
        var count = Math.Max(1, timing.Durations.Count);
        double Hold(int index) => timing.HoldSequence.Count == 0
            ? (timing.Durations.Count > 0 ? timing.Durations[0] : 0.5)
            : timing.HoldSequence[index % timing.HoldSequence.Count];
        oneShot.Clear();
        oneShot.Add((0, Hold(0)));
        for (var index = 1; index < count; index++) oneShot.Add((index, timing.Durations[index]));
        if (count > 1) oneShot.Add((0, Hold(1)));
        Shown = new RunnerPlan(pose);
        shownSince = clock();
        sleepSince = null;
        Frame = oneShot[0].Frame;
        Fx = null;
        Render(pose, Frame, Fx);
        Schedule();
    }

    /// The next frame's delay for what is shown; null holds the frame.
    double? FrameDelay()
    {
        if (oneShot.Count > 0) return oneShot[0].Seconds;
        if (Shown.Still) return null;
        var timing = Timing(Shown.Pose);
        var frames = Math.Max(1, timing.Durations.Count);
        if (Shown.Fps > 0) return frames > 1 ? 1 / Math.Max(0.5, Shown.Smooth ? fps : Shown.Fps) : null;
        if (Shown.Pose == RunnerPose.Sleep)
        {
            if (frames <= 1 || IsDeepSleep) return null;
            return timing.Durations[breath == 1 ? 1 : 0];
        }
        if (frames <= 1) return null;
        if (Frame == 0)
        {
            if (doubling == 2) return timing.DoubleGap ?? DoubleBlinkGap;
            return timing.HoldSequence.Count == 0 ? timing.Durations[0] : timing.HoldSequence[holds % timing.HoldSequence.Count];
        }
        return timing.Durations[Math.Min(Frame, frames - 1)];
    }

    void Schedule()
    {
        armed = false;
        ScheduledDelay = null;
        if (paused)
        {
            Scheduled(null);
            return;
        }
        var now = clock();
        if (IsDeepSleep && (Frame != 0 || Fx != LargeZ))
        {
            Frame = 0;
            Fx = LargeZ;
            Render(Shown.Pose, Frame, Fx);
        }
        var delay = FrameDelay();
        if (Plan.Until is { } until && until > now) delay = Math.Min(delay ?? double.MaxValue, Math.Max(0.02, (until - now).TotalSeconds));
        if (dwellUntil is { } held) delay = Math.Min(delay ?? double.MaxValue, Math.Max(0.02, (held - now).TotalSeconds));
        ScheduledDelay = delay;
        armed = delay is not null;
        Scheduled(delay is { } seconds ? TimeSpan.FromSeconds(seconds) : null);
    }

    /// The timer's action; checks call it directly with an injected clock.
    public void Advance()
    {
        armed = false;
        var now = clock();
        if (Plan.Until is { } until && now >= until)
        {
            Replan();
            if (!armed) Schedule();
            return;
        }
        if (dwellUntil is { } held && now >= held)
        {
            dwellUntil = null;
            Transition();
            return;
        }
        if (oneShot.Count > 0)
        {
            oneShot.RemoveAt(0);
            if (oneShot.Count == 0)
            {
                Show(Plan, now);
                return;
            }
            Frame = oneShot[0].Frame;
            Render(Shown.Pose, Frame, Fx);
            Schedule();
            return;
        }
        if (Shown.Smooth)
        {
            var elapsed = (now - (lastTick ?? now)).TotalSeconds;
            fps += (Shown.Fps - fps) * (1 - Math.Exp(-elapsed / RunnerDirector.Easing));
        }
        lastTick = now;
        var timing = Timing(Shown.Pose);
        var frames = Math.Max(1, timing.Durations.Count);
        if (Shown.Fps > 0)
            Frame = (Frame + 1) % frames;
        else if (Shown.Pose == RunnerPose.Sleep)
        {
            breath = IsDeepSleep ? 0 : (breath + 1) % 3;
            Frame = breath == 1 ? 1 : 0;
            Fx = IsDeepSleep ? LargeZ : breath switch { 1 => SmallZ, 2 => LargeZ, _ => null };
        }
        else if (frames == 2)
        {
            // Blink: hold → closed; every `DoubleEvery`-th blink adds open gap → closed again.
            if (Frame == 0)
            {
                Frame = 1;
                if (doubling == 0) blinks++;
                if (doubling == 2) doubling = 3;
            }
            else
            {
                Frame = 0;
                if (doubling == 0 && timing.DoubleEvery is { } every && every > 0 && blinks % every == 0) doubling = 2;
                else
                {
                    doubling = 0;
                    holds++;
                }
            }
        }
        else
        {
            if (Frame == 0) holds++;
            Frame = (Frame + 1) % frames;
        }
        Render(Shown.Pose, Frame, Fx);
        Schedule();
    }
}
