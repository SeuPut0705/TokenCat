using System.Reflection;
using System.Text;
using static TokenCat.RunnerPose;

namespace TokenCat;

/// PreferenceChecks.swift `runShellChecks`, the director and animator half (descriptions verbatim), plus the Windows parts of
/// Runner.swift: the manifest, the artwork checks and the tray frames. Synthetic sheets only: Core has no PNG decoder; the App's
/// --self-test runs RunnerArtwork on the embedded PNGs.
public static class RunnerChecks
{
    public static List<string> Run()
    {
        var c = new Check("Runner", "Runner: ");
        void check(bool valid, string description) => c.That(valid, description);
        var at = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        DateTimeOffset after(double seconds) => at.AddSeconds(seconds);
        const RunnerMotion activityMotion = RunnerMotion.Activity;

        // Director (K-4, K-5): CPU gait with hysteresis and linear cadences, measured gait, bursts.
        const RunnerDirector.Gait walkGait = RunnerDirector.Gait.Walk, runGait = RunnerDirector.Gait.Run;
        check(RunnerDirector.Fps(6, walkGait) == 5 && RunnerDirector.Fps(20, walkGait) == 8
              && RunnerDirector.Fps(20, runGait) == 8 && RunnerDirector.Fps(100, runGait) == 14
              && Math.Abs(RunnerDirector.Fps(13, walkGait) - 6.5) < 0.001 && Math.Abs(RunnerDirector.Fps(60, runGait) - 11) < 0.001,
              "CPU cadence is not walk 6–20% → 5–8 fps, run 20–100% → 8–14 fps");
        var director = new RunnerDirector();
        check(new RunnerDirector().Plan(activityMotion, new RunnerActivity { Known = false }, at, false).Pose == Sit,
              "Before the first token sample the cat slept (and would yawn when the sample arrived)");
        RunnerPose cpuPose(double cpu)
        {
            var value = new RunnerActivity { Cpu = cpu };
            director.Observe(value, at);
            return director.Plan(RunnerMotion.Cpu, value, at, false).Pose;
        }
        var gaits = new[] { 5, 7, 5, 3.9, 12, 25, 18, 14.9, 21, 3 }.Select(cpuPose).ToArray();
        check(gaits.SequenceEqual([Sit, Walk, Walk, Sit, Walk, RunnerPose.Run, RunnerPose.Run, Walk, RunnerPose.Run, Sit]),
              $"CPU gait lacks sit <4%/>6% and walk <15%/run >20% hysteresis: [{string.Join(", ", gaits.Select(gait => gait.Id))}]");
        director.Observe(new RunnerActivity { Cpu = 50 }, at);
        var cpuRun = director.Plan(RunnerMotion.Cpu, new RunnerActivity { Cpu = 50 }, at, false);
        check(cpuRun.Smooth && cpuRun.Pose == RunnerPose.Run && cpuRun.Fps == RunnerDirector.Fps(50, runGait), "CPU motion does not ease toward its target");
        check(RunnerDirector.MeasuredPlan(30) == new RunnerPlan(Walk) { Fps = 7.25, Smooth = true }
              && RunnerDirector.MeasuredPlan(40) == new RunnerPlan(RunnerPose.Run) { Fps = 8, Smooth = true }
              && RunnerDirector.MeasuredPlan(500) == new RunnerPlan(RunnerPose.Run) { Fps = 14, Smooth = true }
              && new RunnerDirector().Plan(RunnerMotion.Measured, new RunnerActivity(), at, false) == new RunnerPlan(Sit),
              "Measured motion is not walk below 40 tok/s, run from 40, sit without a measurement");

        director = new RunnerDirector();
        var working = new RunnerActivity { Running = true, NewestActivityAt = at };
        check(director.Plan(activityMotion, working, at, false) == new RunnerPlan(Walk), "Working or tool sessions do not walk on the manifest timing");
        var output = working with { NewestOutputAt = at };
        director.Observe(output, at);
        var burst = director.Plan(activityMotion, output, after(0.5), false);
        director.Observe(output, after(1));
        check(burst == new RunnerPlan(RunnerPose.Run) { Until = after(1.2) } && director.BurstUntil == after(1.2),
              "A fresh output event does not run once for 1.2 s, or a refresh of the same event retriggers it");
        check(director.Plan(activityMotion, output, after(1.3), false).Pose == Walk, "The run burst does not end after 1.2 s");
        var during = new RunnerDirector();
        double burstEnd() => ((during.BurstUntil ?? at) - at).TotalSeconds;
        during.Observe(output with { NewestOutputAt = at }, at);
        during.Observe(output with { NewestOutputAt = after(0.8) }, after(0.9));
        check(Math.Abs(burstEnd() - 2.1) < 0.001, "A newer output during a run does not extend it");
        during.Observe(output with { NewestOutputAt = after(2.5) }, after(2.6));
        check(Math.Abs(burstEnd() - 3.8) < 0.001, "An output within 1 s after a run ended did not run again");
        during.Observe(output with { NewestOutputAt = after(4) }, after(4.1));
        check(Math.Abs(burstEnd() - 5.3) < 0.001, "An output well after a run ended did not start a new one");
        var quiet = new RunnerDirector();
        quiet.Observe(working with { NewestOutputAt = after(-30) }, at);
        check(quiet.BurstUntil is null, "An output event older than 5 s triggered a burst");
        var input = new RunnerActivity { Input = true, Running = true };
        director.Observe(new RunnerActivity { NewestOutputAt = after(2.4), Running = true }, after(2.4));
        check(director.Plan(activityMotion, input, after(2.5), false).Pose == Alert, "Waiting for input does not outrank a run burst");
        check(director.Plan(activityMotion, input, at, true) == new RunnerPlan(Alert) { Still = true }, "Reduce Motion does not hold a still pose for the state");
        check(new RunnerDirector().Plan(activityMotion, new RunnerActivity { Waiting = true }, at, false).Pose == Sit, "A log wait does not sit");
        var idle = new RunnerDirector();
        var recent = new RunnerActivity { NewestActivityAt = after(-120) };
        check(idle.Plan(activityMotion, recent, at, false).Pose == Sit && idle.Plan(activityMotion, recent, after(481), false) == new RunnerPlan(Sleep),
              "No live group does not sit, then sleep 10 minutes after the last activity");
        idle.Observe(working, after(400));
        check(idle.Plan(activityMotion, new RunnerActivity(), after(900), false).Pose == Sit, "Sleep is not measured from the last time a session was live");
        check(idle.Plan(RunnerMotion.Still, working, at, false) == new RunnerPlan(Sit) { Still = true }, "Still motion does not hold the sit pose");

        // Animator (K-2, K-3, K-5, K-6): driven by an injected clock; `Advance()` is the timer's action.
        var manifest = Bundled();
        check(manifest is { Errors.Count: 0 }, $"runner-v2.json is missing or invalid: {string.Join("; ", manifest?.Errors ?? ["not found"])}");
        manifest ??= RunnerManifest.Parse([]);
        var clock = at;
        var drawn = new List<(RunnerPose Pose, int Frame, int? Fx)>();
        RunnerAnimator animator(Dictionary<RunnerPose, RunnerTiming>? timing = null)
        {
            var value = new RunnerAnimator(manifest, () => clock);
            value.Timing = pose => timing?.GetValueOrDefault(pose) ?? manifest.Timing(pose);
            value.Render = (pose, frame, fx) => drawn.Add((pose, frame, fx));
            return value;
        }
        // Advances `count` timer steps, returning each step's (delay, frame, fx) before it fires.
        List<(double Delay, int Frame, int? Fx)> run(RunnerAnimator value, int count)
        {
            var steps = new List<(double, int, int?)>();
            for (var i = 0; i < count && value.ScheduledDelay is { } delay; i++)
            {
                steps.Add((delay, value.Frame, value.Fx));
                clock = clock.AddSeconds(delay);
                value.Advance();
            }
            return steps;
        }
        static bool near(IEnumerable<double> a, IReadOnlyList<double> b) => a.Count() == b.Count && a.Zip(b).All(pair => Math.Abs(pair.First - pair.Second) < 0.0001);

        var interim = animator();
        interim.Apply(new RunnerPlan(Sit));
        check(near(run(interim, 2).Select(step => step.Delay), [manifest.Timing(Sit).Durations[0], manifest.Timing(Sit).Durations[1]]),
              "The sit blink does not read Runner.timing");
        interim.Stop();

        var sitTiming = new RunnerTiming([6, 0.12]) { HoldSequence = [6, 9.5, 4.5, 11, 7.5], DoubleEvery = 4 };
        var blinker = animator(new() { [Sit] = sitTiming });
        blinker.Apply(new RunnerPlan(Walk));
        clock = clock.AddSeconds(5);
        blinker.Apply(new RunnerPlan(Sit));
        var rhythm = run(blinker, 12);
        check(near(rhythm.Select(step => step.Delay), [6, 0.12, 9.5, 0.12, 4.5, 0.12, 11, 0.12, 0.15, 0.12, 7.5, 0.12])
              && rhythm.Select(step => step.Frame).SequenceEqual([0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]),
              $"Sit blinks do not cycle the hold sequence with a double blink every 4th: [{string.Join(", ", rhythm.Select(step => step.Delay))}]");
        blinker.Stop();

        var walkTiming = new RunnerTiming([0.15, 0.15, 0.15, 0.15]);
        var walker = animator(new() { [Walk] = walkTiming, [RunnerPose.Run] = new RunnerTiming(Enumerable.Repeat(1.0 / 14, 6).ToArray()) });
        walker.Apply(new RunnerPlan(Walk));
        var steps = run(walker, 5);
        check(near(steps.Select(step => step.Delay), [0.15, 0.15, 0.15, 0.15, 0.15]) && steps.Select(step => step.Frame).SequenceEqual([0, 1, 2, 3, 0]),
              "Walking does not step 4 frames at the manifest's 0.150 s");
        // Dwell: walk → run waits until the walk has shown 1 s; input never waits.
        clock = after(100);
        walker.Apply(new RunnerPlan(Sit));
        walker.Apply(new RunnerPlan(Walk));
        clock = clock.AddSeconds(0.3);
        walker.Apply(new RunnerPlan(RunnerPose.Run) { Until = clock.AddSeconds(1.2) });
        var held = walker.Shown.Pose == Walk && (walker.ScheduledDelay ?? 1) <= 0.7 + 0.0001;
        clock = clock.AddSeconds(0.7);
        walker.Advance();
        check(held && walker.Shown.Pose == RunnerPose.Run && walker.Frame == 0, "walk → run did not wait for the 1 s dwell, or never switched");
        clock = clock.AddSeconds(0.1);
        walker.Apply(new RunnerPlan(RunnerPose.Run) { Until = clock.AddSeconds(1.2) });
        var extended = walker.Shown.Pose == RunnerPose.Run && walker.Frame == 0;
        walker.Apply(new RunnerPlan(Alert));
        check(extended && walker.Shown.Pose == Alert, "A burst extension restarted the run, or input waited for the dwell");
        // A burst within 1 s after a run ended continues that run's stride at once; a later one starts at frame 0.
        clock = clock.AddSeconds(5);
        walker.Apply(new RunnerPlan(Sit));
        walker.Apply(new RunnerPlan(RunnerPose.Run) { Until = clock.AddSeconds(1.2) });
        var strides = run(walker, 3).Select(step => step.Frame).ToArray();
        clock = clock.AddSeconds(1.2 - 3.0 / 14);
        walker.Apply(new RunnerPlan(Walk));
        var walked = walker.Shown.Pose == Walk;
        clock = clock.AddSeconds(0.6);
        walker.Apply(new RunnerPlan(RunnerPose.Run) { Until = clock.AddSeconds(1.2) });
        var joined = walker.Shown.Pose == RunnerPose.Run && walker.Frame == 4 && Math.Abs((walker.ScheduledDelay ?? 0) - 1.0 / 14) < 0.0001;
        clock = clock.AddSeconds(1.2);
        walker.Apply(new RunnerPlan(Walk));
        clock = clock.AddSeconds(1.1);
        walker.Apply(new RunnerPlan(RunnerPose.Run) { Until = clock.AddSeconds(1.2) });
        check(strides.SequenceEqual([0, 1, 2]) && walked && joined && walker.Shown.Pose == RunnerPose.Run && walker.Frame == 0,
              "A burst within 1 s after a run ended did not continue the run's stride at once, or a later one did not start afresh");
        walker.Apply(new RunnerPlan(Alert));
        walker.Paused = true;
        var pausedStops = !walker.IsTimerRunning;
        walker.Paused = false;
        walker.Apply(new RunnerPlan(Alert) { Still = true });
        check(pausedStops && !walker.IsTimerRunning, "The cat timer runs while hidden or for a still pose");
        walker.Stop();

        // Sleep: 1.6 s breaths A → B (small z) → C (large z), deep sleep after 20 min with no timer; Reduce Motion holds zL.
        clock = at;
        drawn.Clear();
        var sleeper = animator();
        sleeper.Apply(new RunnerPlan(Sleep));
        var breaths = run(sleeper, 4);
        check(breaths.Select(step => step.Frame).SequenceEqual([0, 1, 0, 0])
              && breaths.Select(step => step.Fx).SequenceEqual([null, RunnerAnimator.SmallZ, RunnerAnimator.LargeZ, null])
              && breaths.All(step => step.Delay >= 1.0) && sleeper.IsTimerRunning && !sleeper.IsDeepSleep,
              $"Sleep does not breathe A/B/C on 1.6 s steps (fewer than one wake a second): [{string.Join(", ", breaths)}]");
        clock = after(RunnerAnimator.DeepSleepAfter);
        sleeper.Advance();
        check(sleeper.IsDeepSleep && !sleeper.IsTimerRunning && sleeper.ScheduledDelay is null && sleeper.Frame == 0
              && sleeper.Fx == RunnerAnimator.LargeZ && drawn is [.., (Sleep, _, RunnerAnimator.LargeZ)],
              "Deep sleep after 20 minutes does not hold frame 0 with the large z and stop the timer");
        sleeper.Paused = true;
        sleeper.Paused = false;
        check(!sleeper.IsTimerRunning, "Resuming a deep sleep restarted the breathing timer");
        // Waking yawns once (0.6 s), then the plan; waking for input does not yawn.
        sleeper.Apply(new RunnerPlan(Walk));
        var yawning = sleeper.Shown.Pose == Yawn && sleeper.IsPlayingOneShot
                      && Math.Abs((sleeper.ScheduledDelay ?? 0) - manifest.Timing(Yawn).Durations[0]) < 0.001;
        clock = clock.AddSeconds(sleeper.ScheduledDelay ?? 0);
        sleeper.Advance();
        check(yawning && sleeper.Shown.Pose == Walk && !sleeper.IsDeepSleep, "Waking does not yawn once before the next pose");
        sleeper.Apply(new RunnerPlan(Sleep));
        sleeper.Apply(new RunnerPlan(Alert));
        check(sleeper.Shown.Pose == Alert && !sleeper.IsPlayingOneShot, "Input waited for a wake-up yawn");
        sleeper.Apply(new RunnerPlan(Sleep) { Still = true });
        check(sleeper.Frame == 0 && sleeper.Fx == RunnerAnimator.LargeZ && !sleeper.IsTimerRunning,
              "Reduce Motion sleep is not a still frame with the large z");
        sleeper.Apply(new RunnerPlan(Sit) { Still = true });
        check(sleeper.Shown.Pose == Sit && !sleeper.IsPlayingOneShot, "Reduce Motion played the wake-up yawn");
        check(!sleeper.PlayContent(), "Reduce Motion played the turn-end content");
        sleeper.Stop();

        // Content: only on a moving sit; 0.5 → blink 0.45 → 0.55 from the manifest; input and run cancel it, walk waits.
        clock = at;
        var contentTiming = new RunnerTiming([0.5, 0.45]) { HoldSequence = [0.5, 0.55] };
        var content = animator(new() { [Content] = contentTiming });
        content.Apply(new RunnerPlan(Walk));
        var refusesWalk = !content.PlayContent();
        content.Apply(new RunnerPlan(Sit));
        var started = content.PlayContent();
        var played = run(content, 3);
        check(refusesWalk && started && near(played.Select(step => step.Delay), [0.5, 0.45, 0.55]) && played.Select(step => step.Frame).SequenceEqual([0, 1, 0])
              && content.Shown.Pose == Sit && !content.IsPlayingOneShot,
              "Turn-end content is not sit 0.5 → blink 0.45 → sit 0.55, only while sitting");
        content.PlayContent();
        content.Apply(new RunnerPlan(Walk));
        var waits = content.Shown.Pose == Content;
        content.Apply(new RunnerPlan(RunnerPose.Run) { Until = clock.AddSeconds(1.2) });
        check(waits && content.Shown.Pose == RunnerPose.Run && !content.IsPlayingOneShot, "A walk interrupted content, or a run did not cancel it");
        // Hidden cat: a playing content is dropped, none starts, and waking does not queue a yawn for later.
        content.Apply(new RunnerPlan(Sit));
        content.PlayContent();
        content.Paused = true;
        var dropped = !content.IsPlayingOneShot && content.Shown.Pose == Sit && !content.IsTimerRunning;
        var refusedHidden = !content.PlayContent();
        content.Apply(new RunnerPlan(Sleep));
        content.Apply(new RunnerPlan(Walk));
        check(dropped && refusedHidden && content.Shown.Pose == Walk && !content.IsPlayingOneShot,
              "A one-shot stays queued while the cat is hidden and plays late");
        content.Paused = false;
        content.Stop();
        check(RunnerAnimator.StillFx(Sleep) == RunnerAnimator.LargeZ && RunnerAnimator.StillFx(Sit) is null,
              "A still sleep frame does not keep only the large z");
        check(RunnerMotion.Stored("tokens", true) == RunnerMotion.Activity && RunnerMotion.Stored(null, false) == RunnerMotion.Activity
              && RunnerMotion.Stored("cpu", true) == RunnerMotion.Cpu && RunnerMotion.Stored("cpu", false) == RunnerMotion.Activity
              && RunnerMotion.Stored("still", false) == RunnerMotion.Still,
              "Motion migration is wrong");

        // Windows: the App's timer follows `Scheduled` only; an unchanged plan keeps the pending timer (no restart per publish).
        var armings = new List<TimeSpan?>();
        clock = at;
        var publisher = animator();
        publisher.Scheduled = armings.Add;
        publisher.Apply(new RunnerPlan(Walk));
        publisher.Apply(new RunnerPlan(Walk));
        clock = clock.AddSeconds(0.15);
        publisher.Advance();
        publisher.Stop();
        check(armings is [{ } first, { } second, null] && Math.Abs(first.TotalSeconds - 0.15) < 0.0001 && Math.Abs(second.TotalSeconds - 0.15) < 0.0001
              && publisher.Current == (Walk, 1, null),
              "Scheduled does not arm once per frame and stop on Stop, or a repeated plan re-armed the timer");

        // Windows: activity from groups ignores measurement-only groups (RunnerAnimator.swift RunnerActivity.init).
        SessionMember member(SessionDisplayState state, TokenReading reading) => new(reading, state);
        var asking = new TokenReading(TokenSource.Claude, "claude:a")
        {
            ActivityState = TokenActivityState.Input, LastOutputAt = after(-2), LastOutputDelta = 5, LastActivity = after(-1),
        };
        var measured = new TokenReading(TokenSource.Codex, "codex:m") { LastActivity = after(10), LastOutputAt = after(9), LastOutputDelta = 3 };
        var read = new RunnerActivity([new SessionGroup(member(SessionDisplayState.Input, asking)),
                                       new SessionGroup(member(SessionDisplayState.Measurement, measured))], 12, at);
        check(read is { Input: true, Running: true, Waiting: false, Cpu: 12, MeasuredRate: null, Known: true }
              && read.NewestOutputAt == after(-2) && read.NewestActivityAt == after(-1),
              "Runner activity counts a measurement-only group as live, or misses input, output or activity times");

        Manifest(check, manifest);
        Artwork(check, manifest);
        Tray(check);
        return c.Done();
    }

    /// runner-v2.json as the app ships it: the App's embedded copy, else the repo's Assets folder (the Checks console).
    static RunnerManifest? Bundled()
    {
        using var embedded = Assembly.GetEntryAssembly()?.GetManifestResourceStream("runner-v2.json");
        if (embedded is not null)
        {
            using var bytes = new MemoryStream();
            embedded.CopyTo(bytes);
            return RunnerManifest.Parse(bytes.ToArray());
        }
        for (var folder = new DirectoryInfo(AppContext.BaseDirectory); folder is not null; folder = folder.Parent)
        {
            var path = Path.Combine(folder.FullName, "Assets", "runner-v2.json");
            if (File.Exists(path)) return RunnerManifest.Parse(File.ReadAllBytes(path));
        }
        return null;
    }

    /// Runner.swift's manifest rules and texts.
    static void Manifest(Action<bool, string> check, RunnerManifest manifest)
    {
        check(manifest.Timing(Sit) == new RunnerTiming([6, 0.12]) { HoldSequence = [6, 9.5, 4.5, 11, 7.5], DoubleEvery = 4, DoubleGap = 0.15 }
              && manifest.Timing(RunnerPose.Run).Durations.Count == 6 && manifest.Timing(Sleep) != manifest.Timing(Sit),
              "runner-v2.json does not give the sit blink timing, or timings compare by reference");
        var unreadable = RunnerManifest.Parse("{"u8);
        var nullPose = RunnerManifest.Parse("""{"cell":{"width":30,"height":18},"sheets":{},"fxSheets":{},"glyphs":{},"fx":[],"poses":[{"pose":null,"row":0,"frames":2,"durations":[1,1]}]}"""u8);
        var wrongCell = RunnerManifest.Parse("""{"cell":{"width":32,"height":18},"sheets":{},"fxSheets":{},"glyphs":{},"fx":[],"poses":[]}"""u8);
        check(unreadable.Errors is ["runner-v2.json: 앱 번들에 없거나 v3 형식으로 읽을 수 없습니다."] && nullPose.Errors.SequenceEqual(unreadable.Errors)
              && wrongCell.Errors is ["runner-v2.json: 프레임 크기는 30×18이어야 합니다."]
              && unreadable.Timing(Walk) == new RunnerTiming([0.125, 0.125, 0.125, 0.125]),
              "an unreadable manifest or cell size is not reported, or the timing fallback is not 0.125 s a frame");
        var broken = RunnerManifest.Parse("""
            {"cell":{"width":30,"height":18},"sheets":{},"fxSheets":{},"glyphs":{},"fx":[],"poses":[
              {"pose":"sit","row":0,"frames":3,"durations":[1,1,1]},{"pose":"sit","row":0,"frames":2,"durations":[1,1]},
              {"pose":"walk","row":2,"frames":4,"durations":[1,1,1,0]},{"pose":"alert","row":4,"frames":2,"durations":[1,1],"doubleEvery":2},
              {"pose":"dance","row":5,"frames":1,"durations":[1]}]}
            """u8);
        check(broken.Errors.SequenceEqual([
                  "runner-v2.json: sit 프레임 3개, 필요한 수 2개", "runner-v2.json: 알 수 없거나 중복된 자세 sit",
                  "runner-v2.json: walk 프레임 시간이 프레임 수와 맞지 않거나 양수가 아닙니다.",
                  "runner-v2.json: alert doubleGap은 양수이고 doubleEvery와 함께 있어야 합니다.", "runner-v2.json: 알 수 없거나 중복된 자세 dance",
                  "runner-v2.json: sleep 자세가 없습니다.", "runner-v2.json: run 자세가 없습니다.", "runner-v2.json: yawn 자세가 없습니다.",
                  "runner-v2.json: content 자세가 없습니다."])
              && Lang.With(AppLanguage.En, () => RunnerManifest.Parse("""{"cell":{"width":30,"height":18},"sheets":{},"fxSheets":{},"glyphs":{},"fx":[],"poses":[{"pose":"sit","row":0,"frames":3,"durations":[1,1,1]}]}"""u8).Errors[0])
                 == "runner-v2.json: sit has 3 frames, needs 2",
              "manifest pose errors differ from Runner.swift");
    }

    /// RunnerArtwork on synthetic sheets laid out like runner-v2: a 10×9 body per frame plus a marker pixel, z glyphs clear of it.
    static void Artwork(Action<bool, string> check, RunnerManifest manifest)
    {
        var files = new Dictionary<string, PixelSheet>();
        void add(string name, PixelSheet low)
        {
            files[name + "@1x.png"] = low;
            files[name + "@2x.png"] = Double(low);
        }
        IEnumerable<(int, int)> frame(RunnerPose pose, int index) =>
            from y in Enumerable.Range(9, 9) from x in Enumerable.Range(0, 10) select (index * 30 + x, (int)pose * 18 + y);
        var body = Enum.GetValues<RunnerPose>().SelectMany(pose => Enumerable.Range(0, RunnerManifest.Frames(pose))
            .SelectMany(index => frame(pose, index).Append((index * 30 + 12 + index, (int)pose * 18 + 12))));
        add("runner-v2", Sheet(180, 126, body));
        add("runner-v2-fx", Sheet(8, 4, from y in Enumerable.Range(0, 4) from x in Enumerable.Range(0, 8) where x != 3 select (x, y)));
        foreach (var head in Enum.GetValues<RunnerHead>())
            add($"app-head-{head.Id}", Sheet(12, 11, from y in Enumerable.Range(0, 11) from x in Enumerable.Range(0, 12) select (x, y)));
        PixelSheet? load(string file) => files.GetValueOrDefault(file);

        var cat = RunnerArtwork.Load(RunnerCharacter.Cat, manifest, load);
        var strip = cat.Fx.GetValueOrDefault(Sleep);
        check(cat.Errors.Count == 0 && cat.Sheet is { Width: 180, Height: 126 } && cat.Heads.Count == 4 && strip is { Width: 90, Height: 18 }
              && Opaque(strip, 30 + 22, 3) && Opaque(strip, 60 + 25, 0) && !Opaque(strip, 22, 3) && !Opaque(strip, 30 + 25, 0)
              && Opaque(cat.Sheet, 30 + 13, 2 * 18 + 12),
              $"valid artwork does not load with its z strip and heads: {string.Join("; ", cat.Errors)}");
        var dog = RunnerArtwork.Load(RunnerCharacter.Dog, manifest, load);
        check(dog.Errors.SequenceEqual(["runner-dog@1x.png: 앱 번들에 이미지가 없습니다.", "runner-dog: 시트를 쓸 수 없어 고양이로 표시합니다."])
              && dog.Sheet!.Bgra.SequenceEqual(cat.Sheet!.Bgra) && dog.Heads.Count == 4
              && RunnerArtwork.ResourceErrors(manifest, load, [RunnerCharacter.Cat]).Count == 0
              && RunnerArtwork.ResourceErrors(manifest, load).Count == 8,
              "a character without its sheet does not fall back to the cat and say so once");

        var emptied = Sheet(180, 126, body.Where(p => !(p.Item2 / 18 == (int)Walk && p.Item1 / 30 == 1)));
        files["runner-v2@1x.png"] = emptied;
        files["runner-v2@2x.png"] = Double(emptied);
        files["runner-dog@1x.png"] = emptied;
        files["runner-dog@2x.png"] = Double(Sheet(180, 126, body));
        files["app-head-blink@1x.png"] = Sheet(12, 11, []);
        var errors = RunnerArtwork.ResourceErrors(manifest, file => file == "runner-robot@1x.png" ? throw new InvalidDataException() : load(file));
        check(errors.Contains("runner-v2 시트: walk 2번 프레임이 비었습니다.")
              && errors.Contains("runner-dog 시트: @2x가 @1x의 최근접 확대와 다릅니다.") && errors.Contains("app-head-blink: 12×11 px이고 비어 있지 않아야 합니다.")
              && errors.Contains("runner-robot@1x.png: 이미지를 디코딩하지 못했습니다.") && errors.Contains("runner-robot: 시트를 쓸 수 없어 고양이로 표시합니다."),
              $"artwork errors differ from Runner.swift: {string.Join("; ", errors)}");
    }

    /// TrayFrame: integer scales, exact nearest-neighbour placement, the z, the dot and the head bob.
    static void Tray(Action<bool, string> check)
    {
        check(new[] { 16, 20, 24, 28 }.All(icon => TrayFrame.BodyScale(icon) is null) && TrayFrame.BodyScale(30) == 1 && TrayFrame.BodyScale(32) == 1
              && TrayFrame.BodyScale(40) == 1 && TrayFrame.BodyScale(64) == 2
              && TrayFrame.HeadScale(16) == 1 && TrayFrame.HeadScale(20) == 1 && TrayFrame.HeadScale(24) == 2 && TrayFrame.HeadScale(28) == 2,
              "tray scales are not body ≥ 30 px at a whole scale, head @1x at 16/20 and @2x at 24/28");
        var sheet = Sheet(180, 126, [(30 + 2, 2 * 18 + 3)]);
        var z = Sheet(90, 18, [(60 + 25, 0)]);
        var small = TrayFrame.Body(sheet, Walk, 5, z, -1, 32, StateDot.None, true);
        var large = TrayFrame.Body(sheet, Walk, 1, z, 2, 64, StateDot.None, false);
        check(Pixel(small, 32, 3, 10) == (40, 40, 40, 255) && Pixel(small, 32, 26, 7) == (0, 0, 0, 255) && Count(small) == 2
              && Pixel(large, 64, 6, 20) == (40, 40, 40, 255) && Pixel(large, 64, 7, 21).A == 255 && Pixel(large, 64, 52, 14) == (255, 255, 255, 255)
              && Count(large) == 8,
              "the body is not centred at a whole scale with frames wrapping, or the z is not in the taskbar's text tone");
        var input = TrayFrame.Body(sheet, Sit, 0, null, 0, 32, StateDot.Attention, true);
        var retry = TrayFrame.Body(sheet, Sit, 0, null, 0, 32, StateDot.Warning, false);
        check(Pixel(input, 32, 24, 24) == (0x00, 0xCC, 0xFF, 255) && Pixel(input, 32, 29, 29) == (0x00, 0xCC, 0xFF, 255)
              && Pixel(input, 32, 23, 27) == (0, 0, 0, 255) && Pixel(input, 32, 31, 31) == (0, 0, 0, 255)
              && Pixel(retry, 32, 26, 26) == (0x0A, 0x9F, 0xFF, 255) && Pixel(retry, 32, 22, 31) == (255, 255, 255, 255) && Count(input) == 100,
              "the corner dot is not 3×3 art px at the head scale (2 at 32 px) with a 1 art-px outline in the taskbar's text tone");

        var head = Sheet(12, 11, [(0, 0), (11, 10)]);
        var rest = TrayFrame.Head(head, 0, null, 0, 16, StateDot.None, true);
        var bob = TrayFrame.Head(head, 1, null, 0, 16, StateDot.None, true);
        var doubled = TrayFrame.Head(Double(head), 1, null, 0, 16, StateDot.None, true);
        var high = TrayFrame.Head(head, 1, null, 0, 24, StateDot.None, true);
        check(Pixel(rest, 16, 2, 2).A == 255 && Pixel(rest, 16, 13, 12).A == 255 && Pixel(bob, 16, 2, 3).A == 255 && Pixel(bob, 16, 13, 13).A == 255
              && bob.SequenceEqual(doubled) && Pixel(high, 24, 0, 2).A == 255 && Pixel(high, 24, 23, 23).A == 255 && Count(high) == 8,
              "the head is not centred, does not bob 1 art px into spare rows, or reads @2x differently from @1x");
        var block = Sheet(90, 18, from y in Enumerable.Range(0, 4) from x in Enumerable.Range(60 + 25, 4) select (x, y));
        var corner = TrayFrame.Head(head, 0, block, 2, 20, StateDot.None, false);
        var crowded = TrayFrame.Head(head, 0, block, 2, 16, StateDot.None, false);
        check(Pixel(corner, 20, 16, 0) == (255, 255, 255, 255) && Pixel(corner, 20, 19, 3).A == 255 && Count(corner) == 18 && Count(crowded) == 2,
              "the head-mode z is not in the top-right corner where it clears the head, or is drawn over it");
        check(TrayFrame.HeadFor(Walk, 1) == (RunnerHead.Normal, 1) && TrayFrame.HeadFor(RunnerPose.Run, 4) == (RunnerHead.Normal, 0)
              && TrayFrame.HeadFor(Sit, 1) == (RunnerHead.Blink, 0) && TrayFrame.HeadFor(Alert, 0) == (RunnerHead.Alert, 0)
              && TrayFrame.HeadFor(Alert, 1) == (RunnerHead.Blink, 0) && TrayFrame.HeadFor(Sleep, 1) == (RunnerHead.Sleep, 0)
              && TrayFrame.HeadFor(Yawn, 0) == (RunnerHead.Blink, 0) && TrayFrame.HeadFor(Content, 0) == (RunnerHead.Normal, 0),
              "head mode does not map poses to head variants and bobs as DESIGN §4.1");
    }

    static PixelSheet Sheet(int width, int height, IEnumerable<(int X, int Y)> opaque)
    {
        var bytes = new byte[width * height * 4];
        foreach (var (x, y) in opaque)
        {
            var i = (y * width + x) * 4;
            (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = (40, 40, 40, 255);
        }
        return new PixelSheet(bytes, width, height);
    }

    static PixelSheet Double(PixelSheet low)
    {
        var bytes = new byte[low.Bgra.Length * 4];
        for (var y = 0; y < low.Height * 2; y++)
            for (var x = 0; x < low.Width * 2; x++)
                low.Bgra.AsSpan((y / 2 * low.Width + x / 2) * 4, 4).CopyTo(bytes.AsSpan((y * low.Width * 2 + x) * 4));
        return new PixelSheet(bytes, low.Width * 2, low.Height * 2);
    }

    static bool Opaque(PixelSheet? sheet, int x, int y) => sheet is not null && sheet.Bgra[(y * sheet.Width + x) * 4 + 3] != 0;

    static (byte B, byte G, byte R, byte A) Pixel(byte[] bgra, int size, int x, int y)
    {
        var i = (y * size + x) * 4;
        return (bgra[i], bgra[i + 1], bgra[i + 2], bgra[i + 3]);
    }

    static int Count(byte[] bgra) => Enumerable.Range(0, bgra.Length / 4).Count(i => bgra[i * 4 + 3] != 0);
}
