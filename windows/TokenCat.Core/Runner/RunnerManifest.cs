namespace TokenCat;

// WP4 stub (DESIGN §11): Runner.swift's poses, characters, heads and timing; NSImage building moves to the App.
// WP4 adds the manifest fields, Title/Sheet and owns this file.

/// Frame 0 of every pose is its still frame. `Yawn` (1 frame) and `Content` (2 frames) are one-shots.
public enum RunnerPose { Sit, Sleep, Walk, Run, Alert, Yawn, Content }

/// All share runner-v2.json; only the sheet differs (cat: runner-v2@1x/@2x.png, others runner-<id>@1x/@2x.png).
public enum RunnerCharacter { Cat, Dog, Hamster, Penguin, Robot }

/// Pixel head variants (cat only): the tray below 30 px, the flyout header, onboarding, about.
public enum RunnerHead { Normal, Blink, Alert, Sleep }

public static class RunnerCharacterText
{
    extension(RunnerCharacter character)
    {
        public string Title => throw new NotImplementedException();
        /// Resource base name: "runner-v2" for the cat, "runner-<id>" otherwise.
        public string Sheet => throw new NotImplementedException();
    }
}

/// Frame timing for one pose (K-6), seconds. Content equality over the lists is WP4's (rule 2).
public sealed record RunnerTiming(IReadOnlyList<double> Durations)
{
    public IReadOnlyList<double> HoldSequence { get; init; } = [];
    public int? DoubleEvery { get; init; }
    public double? DoubleGap { get; init; }
}

public sealed record RunnerManifest
{
    public static RunnerManifest Parse(ReadOnlySpan<byte> json) => throw new NotImplementedException();
    public RunnerTiming Timing(RunnerPose pose) => throw new NotImplementedException();
}
