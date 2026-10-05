using System.Text.Json;
using static TokenCat.Lang;

namespace TokenCat;

// Runner.swift: poses, characters, heads, the v3 manifest (runner-v2.json) and the artwork checks. NSImage building is the
// App's: it decodes the embedded PNGs into PixelSheets and TrayFrame composes the tray pixels from them.

/// Frame 0 of every pose is its still frame. `Yawn` (1 frame) and `Content` (2 frames) are one-shots.
public enum RunnerPose { Sit, Sleep, Walk, Run, Alert, Yawn, Content }

/// All share runner-v2.json; only the sheet differs (cat: runner-v2@1x/@2x.png, others runner-<id>@1x/@2x.png).
public enum RunnerCharacter { Cat, Dog, Hamster, Penguin, Robot }

/// Pixel head variants (cat only): the tray below 30 px, the flyout header, onboarding, about.
public enum RunnerHead { Normal, Blink, Alert, Sleep }

public static class RunnerCharacterText
{
    /// The Swift raw values ("sit", "cat", "normal"): manifest names, resource names, persisted ids.
    extension(RunnerPose pose) { public string Id => pose.ToString().ToLowerInvariant(); }
    extension(RunnerHead head) { public string Id => head.ToString().ToLowerInvariant(); }

    extension(RunnerCharacter character)
    {
        public string Id => character.ToString().ToLowerInvariant();

        public string Title => character switch
        {
            RunnerCharacter.Cat => Loc("고양이", "Cat"),
            RunnerCharacter.Dog => Loc("강아지", "Dog"),
            RunnerCharacter.Hamster => Loc("햄스터", "Hamster"),
            RunnerCharacter.Penguin => Loc("펭귄", "Penguin"),
            _ => Loc("로봇", "Robot"),
        };

        /// Resource base name: "runner-v2" for the cat, "runner-<id>" otherwise.
        public string Sheet => character == RunnerCharacter.Cat ? "runner-v2" : $"runner-{character.Id}";
    }

    /// The raw value back to the case; null for anything else (an unknown stored id falls back to the caller's default).
    public static T? Parse<T>(string? raw) where T : struct, Enum =>
        Enum.GetValues<T>().Where(value => value.ToString().ToLowerInvariant() == raw).Cast<T?>().FirstOrDefault();
}

/// Frame timing for one pose (K-6), seconds. Equality compares the lists' contents (rule 2).
public sealed record RunnerTiming(IReadOnlyList<double> Durations)
{
    /// When not empty, successive holds of frame 0 cycle through these seconds instead of `Durations[0]` (the sit blink).
    public IReadOnlyList<double> HoldSequence { get; init; } = [];
    /// Every Nth blink is a double blink (closed · open · closed); null never doubles.
    public int? DoubleEvery { get; init; }
    /// Seconds the eyes stay open between the two closes of a double blink. Set exactly when `DoubleEvery` is.
    public double? DoubleGap { get; init; }

    public bool Equals(RunnerTiming? other) => other is not null && Durations.SequenceEqual(other.Durations)
        && HoldSequence.SequenceEqual(other.HoldSequence) && DoubleEvery == other.DoubleEvery && DoubleGap == other.DoubleGap;

    public override int GetHashCode() => HashCode.Combine(Durations.Count, HoldSequence.Count, DoubleEvery, DoubleGap);
}

/// runner-v2.json (manifest v3). `Parse` never throws: `Errors` holds Runner.swift's manifest messages.
public sealed record RunnerManifest
{
    public const int CellWidth = 30, CellHeight = 18;

    public static int Frames(RunnerPose pose) => pose switch
    {
        RunnerPose.Sit or RunnerPose.Sleep or RunnerPose.Alert or RunnerPose.Content => 2,
        RunnerPose.Walk => 4,
        RunnerPose.Run => 6,
        _ => 1,
    };

    public sealed record Size { public required int Width { get; init; } public required int Height { get; init; } }

    public sealed record PoseRow
    {
        public required string Pose { get; init; }
        public required int Row { get; init; }
        public required int Frames { get; init; }
        public required double[] Durations { get; init; }
        public double[]? HoldSequence { get; init; }
        public int? DoubleEvery { get; init; }
        public double? DoubleGap { get; init; }
    }

    public sealed record Glyph
    {
        public required int X { get; init; }
        public required int Y { get; init; }
        public required int Width { get; init; }
        public required int Height { get; init; }
    }

    public sealed record Effect
    {
        public required string Pose { get; init; }
        public required int Step { get; init; }
        public required string Glyph { get; init; }
        public required int X { get; init; }
        public required int Y { get; init; }
    }

    sealed record Payload
    {
        public required Size Cell { get; init; }
        public required Dictionary<string, string> Sheets { get; init; }
        public required Dictionary<string, string> FxSheets { get; init; }
        public required PoseRow[] Poses { get; init; }
        public required Dictionary<string, Glyph> Glyphs { get; init; }
        public required Effect[] Fx { get; init; }
    }

    // Decodable: every non-optional field present and non-null.
    static readonly JsonSerializerOptions Strict = new(Json.Options) { RespectNullableAnnotations = true };

    public IReadOnlyDictionary<string, string> Sheets { get; init; } = new Dictionary<string, string>();
    public IReadOnlyDictionary<string, string> FxSheets { get; init; } = new Dictionary<string, string>();
    /// The pose rows that parsed, first entry per pose.
    public IReadOnlyDictionary<RunnerPose, PoseRow> Rows { get; init; } = new Dictionary<RunnerPose, PoseRow>();
    public IReadOnlyDictionary<string, Glyph> Glyphs { get; init; } = new Dictionary<string, Glyph>();
    public IReadOnlyList<Effect> Fx { get; init; } = [];
    public IReadOnlyList<string> Errors { get; init; } = [];

    public static RunnerManifest Parse(ReadOnlySpan<byte> json)
    {
        Payload? payload;
        try { payload = JsonSerializer.Deserialize<Payload>(Json.StripBom(json), Strict); }
        catch (JsonException) { payload = null; }
        if (payload is null)
            return new() { Errors = [Loc("runner-v2.json: 앱 번들에 없거나 v3 형식으로 읽을 수 없습니다.", "runner-v2.json: missing from the app bundle or not readable as v3.")] };
        if (payload.Cell.Width != CellWidth || payload.Cell.Height != CellHeight)
            return new()
            {
                Errors = [Loc($"runner-v2.json: 프레임 크기는 {CellWidth}×{CellHeight}이어야 합니다.",
                              $"runner-v2.json: the frame size must be {CellWidth}×{CellHeight}.")],
            };

        var errors = new List<string>();
        var rows = new Dictionary<RunnerPose, PoseRow>();
        foreach (var entry in payload.Poses)
        {
            if (RunnerCharacterText.Parse<RunnerPose>(entry.Pose) is not { } pose || rows.ContainsKey(pose))
            {
                errors.Add(Loc($"runner-v2.json: 알 수 없거나 중복된 자세 {entry.Pose}", $"runner-v2.json: unknown or duplicate pose {entry.Pose}"));
                continue;
            }
            if (entry.Frames != Frames(pose))
                errors.Add(Loc($"runner-v2.json: {pose.Id} 프레임 {entry.Frames}개, 필요한 수 {Frames(pose)}개",
                               $"runner-v2.json: {pose.Id} has {Plural(entry.Frames, "frame")}, needs {Frames(pose)}"));
            if (entry.Durations.Length != entry.Frames || entry.Durations.Any(d => !(d > 0))
                || (entry.HoldSequence ?? []).Any(d => !(d > 0)) || entry.DoubleEvery < 1)
                errors.Add(Loc($"runner-v2.json: {pose.Id} 프레임 시간이 프레임 수와 맞지 않거나 양수가 아닙니다.",
                               $"runner-v2.json: {pose.Id} frame times don't match the frame count or aren't positive."));
            if ((entry.DoubleEvery is null) != (entry.DoubleGap is null) || entry.DoubleGap is { } gap && !(gap > 0))
                errors.Add(Loc($"runner-v2.json: {pose.Id} doubleGap은 양수이고 doubleEvery와 함께 있어야 합니다.",
                               $"runner-v2.json: {pose.Id} doubleGap must be positive and come with doubleEvery."));
            rows[pose] = entry;
        }
        foreach (var pose in Enum.GetValues<RunnerPose>().Where(pose => !rows.ContainsKey(pose)))
            errors.Add(Loc($"runner-v2.json: {pose.Id} 자세가 없습니다.", $"runner-v2.json: the {pose.Id} pose is missing."));
        return new()
        {
            Sheets = payload.Sheets, FxSheets = payload.FxSheets, Rows = rows, Glyphs = payload.Glyphs, Fx = payload.Fx, Errors = errors,
        };
    }

    /// The manifest's timing for `pose`; 0.125 s per frame when the manifest is unusable (Runner.timing's fallback).
    public RunnerTiming Timing(RunnerPose pose) =>
        Errors.Count == 0 && Rows.TryGetValue(pose, out var row)
            ? new RunnerTiming(row.Durations) { HoldSequence = row.HoldSequence ?? [], DoubleEvery = row.DoubleEvery, DoubleGap = row.DoubleGap }
            : new RunnerTiming(Enumerable.Repeat(0.125, Frames(pose)).ToArray());
}

/// Runner.swift's ArtworkCache without NSImage: checks one character's sheets against the manifest and keeps the @1x pixels
/// TrayFrame draws. `load(file)` returns the decoded PNG ("runner-v2@1x.png"), null when the file is missing, and throws when
/// it cannot decode it. A character whose sheet fails shows the cat and says so in `Errors`.
public sealed class RunnerArtwork
{
    const int Cell = RunnerManifest.CellWidth, Row = RunnerManifest.CellHeight, HeadWidth = 12, HeadHeight = 11;

    List<string> errors = [];
    readonly Dictionary<RunnerPose, PixelSheet> fx = [];
    readonly Dictionary<RunnerHead, PixelSheet> heads = [];
    readonly Func<string, PixelSheet?> load;

    RunnerArtwork(Func<string, PixelSheet?> load) => this.load = load;

    /// @1x, one row per pose in RunnerPose order (whatever rows the manifest names), frames left to right. Null when unusable.
    public PixelSheet? Sheet { get; private set; }
    /// The effect masks (the sleep z) per pose: @1x, one 30×18 cell per step side by side, alpha 255 on the glyph.
    public IReadOnlyDictionary<RunnerPose, PixelSheet> Fx => fx;
    /// The cat's pixel heads at @1x (12×11).
    public IReadOnlyDictionary<RunnerHead, PixelSheet> Heads => heads;
    public IReadOnlyList<string> Errors => errors;

    public static RunnerArtwork Load(RunnerCharacter character, RunnerManifest manifest, Func<string, PixelSheet?> load)
    {
        var art = new RunnerArtwork(load);
        art.LoadRunner(character, manifest);
        if (character == RunnerCharacter.Cat) art.LoadHeads();
        if (art.errors.Count > 0 && character != RunnerCharacter.Cat)
        {
            var failed = art.errors;
            art = Load(RunnerCharacter.Cat, manifest, load);
            art.errors = [.. failed, Loc($"{character.Sheet}: 시트를 쓸 수 없어 고양이로 표시합니다.", $"{character.Sheet}: sheet unusable, showing the cat instead.")];
        }
        return art;
    }

    /// Artwork errors of `characters` (the self-test: all), each message once. Runner.resourceErrors.
    public static List<string> ResourceErrors(RunnerManifest manifest, Func<string, PixelSheet?> load, IEnumerable<RunnerCharacter>? characters = null) =>
        (characters ?? Enum.GetValues<RunnerCharacter>()).SelectMany(character => Load(character, manifest, load).Errors).Distinct().ToList();

    void LoadRunner(RunnerCharacter character, RunnerManifest manifest)
    {
        errors.AddRange(manifest.Errors);
        if (errors.Count > 0) return;
        // Every character uses this manifest; only the cat's sheets are named in it.
        var sheet = character.Sheet;
        var names = character == RunnerCharacter.Cat ? manifest.Sheets
            : new Dictionary<string, string> { ["1"] = sheet + "@1x.png", ["2"] = sheet + "@2x.png" };
        if (Read(names.GetValueOrDefault("1")) is not { } low || Read(names.GetValueOrDefault("2")) is not { } high) return;

        int columns = low.Width / Cell, rowCount = low.Height / Row;
        if (low.Width != columns * Cell || low.Height != rowCount * Row)
        {
            errors.Add(Loc($"{sheet} 시트: @1x는 30×18 셀의 배수여야 합니다.", $"{sheet} sheet: @1x must be a multiple of 30×18 cells."));
            return;
        }
        if (!CheckPair(low, high, Loc($"{sheet} 시트", $"{sheet} sheet"))) return;

        var poses = Enum.GetValues<RunnerPose>();
        var packed = new byte[low.Width * 4 * Row * poses.Length];
        foreach (var pose in poses)
        {
            if (!manifest.Rows.TryGetValue(pose, out var entry)) continue;
            if (entry.Row < 0 || entry.Row >= rowCount || entry.Frames > columns)
            {
                errors.Add(Loc($"{sheet} 시트: {pose.Id} 행이 시트 밖에 있습니다.", $"{sheet} sheet: the {pose.Id} row is outside the sheet."));
                continue;
            }
            var cells = new List<byte[]>();
            for (var column = 0; column < columns; column++)
            {
                var cell = CellBytes(low, column, entry.Row);
                var opaque = Opaque(cell);
                if (column < entry.Frames && !opaque)
                    errors.Add(Loc($"{sheet} 시트: {pose.Id} {column + 1}번 프레임이 비었습니다.", $"{sheet} sheet: {pose.Id} frame {column + 1} is empty."));
                if (column >= entry.Frames && opaque)
                    errors.Add(Loc($"{sheet} 시트: {pose.Id} 행에 매니페스트보다 많은 프레임이 있습니다.",
                                   $"{sheet} sheet: the {pose.Id} row has more frames than the manifest."));
                if (column < entry.Frames) cells.Add(cell);
            }
            for (var index = 0; index < cells.Count; index++)
                if (cells.Count > 1 && cells[index].AsSpan().SequenceEqual(cells[(index + 1) % cells.Count]))
                    errors.Add(Loc($"{sheet} 시트: {pose.Id} {index + 1}번과 다음 프레임이 같습니다.",
                                   $"{sheet} sheet: {pose.Id} frame {index + 1} is the same as the next one."));
            var rowBytes = low.Width * 4 * Row;
            low.Bgra.AsSpan(entry.Row * rowBytes, rowBytes).CopyTo(packed.AsSpan((int)pose * rowBytes));
        }
        Sheet = new PixelSheet(packed, low.Width, Row * poses.Length);
        LoadEffects(manifest, low, sheet);
    }

    /// The sleep z (K-2): glyphs from the fx atlas placed in cell coordinates, one mask per step.
    void LoadEffects(RunnerManifest manifest, PixelSheet sprite, string sheet)
    {
        if (Read(manifest.FxSheets.GetValueOrDefault("1")) is not { } low || Read(manifest.FxSheets.GetValueOrDefault("2")) is not { } high
            || !CheckPair(low, high, Loc("runner-v2-fx 시트", "runner-v2-fx sheet"))) return;
        var steps = new Dictionary<RunnerPose, Dictionary<int, List<(int X, int Y)>>>();
        foreach (var effect in manifest.Fx)
        {
            var name = $"runner-v2.json: fx {effect.Pose} {effect.Step} {effect.Glyph}";
            if (RunnerCharacterText.Parse<RunnerPose>(effect.Pose) is not { } pose || !manifest.Rows.TryGetValue(pose, out var entry)
                || effect.Step < 0 || !manifest.Glyphs.TryGetValue(effect.Glyph, out var glyph))
            {
                errors.Add(Loc($"{name}: 자세나 글리프를 찾을 수 없습니다.", $"{name}: pose or glyph not found."));
                continue;
            }
            if (glyph.X < 0 || glyph.Y < 0 || glyph.Width <= 0 || glyph.Height <= 0 || glyph.X + glyph.Width > low.Width
                || glyph.Y + glyph.Height > low.Height || effect.X < 0 || effect.Y < 0 || effect.X + glyph.Width > Cell || effect.Y + glyph.Height > Row)
            {
                errors.Add(Loc($"{name}: 글리프가 fx 시트나 셀 밖에 있습니다.", $"{name}: the glyph is outside the fx sheet or the cell."));
                continue;
            }
            var pixels = new List<(int X, int Y)>();
            for (var gy = 0; gy < glyph.Height; gy++)
                for (var gx = 0; gx < glyph.Width; gx++)
                    if (Alpha(low, glyph.X + gx, glyph.Y + gy) != 0) pixels.Add((effect.X + gx, effect.Y + gy));
            if (pixels.Count == 0) errors.Add(Loc($"{name}: 글리프가 비었습니다.", $"{name}: the glyph is empty."));
            // At least one clear pixel (8 neighbours) between the effect and every frame of the pose.
            var touches = Enumerable.Range(0, entry.Frames).Any(column => pixels.Any(p =>
                Enumerable.Range(-1, 3).Any(dy => Enumerable.Range(-1, 3).Any(dx =>
                {
                    int x = p.X + dx, y = p.Y + dy, sx = column * Cell + x, sy = entry.Row * Row + y;
                    return x >= 0 && y >= 0 && x < Cell && y < Row && sx < sprite.Width && sy < sprite.Height && Alpha(sprite, sx, sy) != 0;
                }))));
            if (touches) errors.Add(Loc($"{name}: 스프라이트({sheet})와 1 px 간격이 없습니다.", $"{name}: no 1 px gap from the sprite ({sheet})."));
            if (!steps.TryGetValue(pose, out var placed)) steps[pose] = placed = [];
            if (!placed.TryGetValue(effect.Step, out var mask)) placed[effect.Step] = mask = [];
            mask.AddRange(pixels);
        }
        foreach (var (pose, placed) in steps)
        {
            var count = placed.Keys.Max() + 1;
            var strip = new byte[count * Cell * Row * 4];
            foreach (var (step, pixels) in placed)
                foreach (var (x, y) in pixels) strip[(y * count * Cell + step * Cell + x) * 4 + 3] = 255;
            fx[pose] = new PixelSheet(strip, count * Cell, Row);
        }
    }

    void LoadHeads()
    {
        foreach (var variant in Enum.GetValues<RunnerHead>())
        {
            var name = $"app-head-{variant.Id}";
            if (Read(name + "@1x.png") is not { } low || Read(name + "@2x.png") is not { } high) continue;
            if (low.Width != HeadWidth || low.Height != HeadHeight || !Opaque(low.Bgra))
            {
                errors.Add(Loc($"{name}: 12×11 px이고 비어 있지 않아야 합니다.", $"{name}: must be 12×11 px and not empty."));
                continue;
            }
            if (CheckPair(low, high, name)) heads[variant] = low;
        }
    }

    /// The decoded file with fully transparent pixels zeroed, so comparisons match Swift's premultiplied bytes.
    PixelSheet? Read(string? file)
    {
        PixelSheet? pixels = null;
        var undecodable = false;
        if (file is not null)
        {
            try { pixels = load(file); }
            catch (Exception) { undecodable = true; }
        }
        if (file is null || pixels is null && !undecodable)
        {
            errors.Add(Loc($"{file ?? "runner-v2 시트"}: 앱 번들에 이미지가 없습니다.", $"{file ?? "runner-v2 sheet"}: image missing from the app bundle."));
            return null;
        }
        if (pixels is null || pixels.Width <= 0 || pixels.Height <= 0 || pixels.Bgra.Length != pixels.Width * pixels.Height * 4)
        {
            errors.Add(Loc($"{file}: 이미지를 디코딩하지 못했습니다.", $"{file}: couldn't decode the image."));
            return null;
        }
        var bytes = pixels.Bgra.ToArray();
        for (var i = 0; i < bytes.Length; i += 4)
            if (bytes[i + 3] == 0) bytes[i] = bytes[i + 1] = bytes[i + 2] = 0;
        return pixels with { Bgra = bytes };
    }

    /// @2x is exactly twice @1x, both use alpha 0/255 only, and @2x equals the nearest-neighbour enlargement.
    bool CheckPair(PixelSheet low, PixelSheet high, string name)
    {
        if (high.Width != low.Width * 2 || high.Height != low.Height * 2)
        {
            errors.Add(Loc($"{name}: @2x는 @1x의 정확히 두 배여야 합니다.", $"{name}: @2x must be exactly twice @1x."));
            return false;
        }
        bool binary = true, nearest = true;
        for (var y = 0; y < high.Height; y++)
            for (var x = 0; x < high.Width; x++)
            {
                var alpha = Alpha(high, x, y);
                if (alpha != 0 && alpha != 255) binary = false;
                if (!high.Bgra.AsSpan((y * high.Width + x) * 4, 4).SequenceEqual(low.Bgra.AsSpan((y / 2 * low.Width + x / 2) * 4, 4))) nearest = false;
            }
        var lowBinary = true;
        for (var i = 3; i < low.Bgra.Length; i += 4) if (low.Bgra[i] != 0 && low.Bgra[i] != 255) lowBinary = false;
        if (!binary || !lowBinary) errors.Add(Loc($"{name}: 알파는 0 또는 255만 허용됩니다.", $"{name}: alpha must be 0 or 255."));
        if (!nearest) errors.Add(Loc($"{name}: @2x가 @1x의 최근접 확대와 다릅니다.", $"{name}: @2x differs from the nearest-neighbour enlargement of @1x."));
        return binary && nearest;
    }

    static byte Alpha(PixelSheet sheet, int x, int y) => sheet.Bgra[(y * sheet.Width + x) * 4 + 3];

    static bool Opaque(ReadOnlySpan<byte> bgra)
    {
        for (var i = 3; i < bgra.Length; i += 4) if (bgra[i] != 0) return true;
        return false;
    }

    static byte[] CellBytes(PixelSheet sheet, int column, int row)
    {
        var bytes = new byte[Cell * Row * 4];
        for (var y = 0; y < Row; y++)
            sheet.Bgra.AsSpan(((row * Row + y) * sheet.Width + column * Cell) * 4, Cell * 4).CopyTo(bytes.AsSpan(y * Cell * 4));
        return bytes;
    }
}
