using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TokenCat;

/// The 23 artwork files embedded from ../../Assets (Runner.swift's loading half): decoded once into BGRA sheets for TrayFrame
/// and cut into frozen bitmaps for WPF. Pixel art is only ever drawn at whole multiples with nearest-neighbour scaling.
static class Sprites
{
    public const int CellWidth = 30, CellHeight = 18;
    static readonly Dictionary<string, PixelSheet> Sheets = [];

    public static byte[] Resource(string name)
    {
        using var stream = typeof(Sprites).Assembly.GetManifestResourceStream(name)
            ?? throw new FileNotFoundException($"{name}: not embedded in TokenCat.exe");
        using var bytes = new MemoryStream();
        stream.CopyTo(bytes);
        return bytes.ToArray();
    }

    /// A PNG resource as straight-alpha BGRA, rows top to bottom.
    public static PixelSheet Sheet(string name)
    {
        if (Sheets.TryGetValue(name, out var cached)) return cached;
        var decoder = BitmapDecoder.Create(new MemoryStream(Resource(name)), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var bitmap = new FormatConvertedBitmap(decoder.Frames[0], PixelFormats.Bgra32, null, 0);
        var pixels = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
        bitmap.CopyPixels(pixels, bitmap.PixelWidth * 4, 0);
        return Sheets[name] = new PixelSheet(pixels, bitmap.PixelWidth, bitmap.PixelHeight);
    }

    /// RunnerArtwork's loader: null when the file isn't embedded.
    public static PixelSheet? Load(string name) => typeof(Sprites).Assembly.GetManifestResourceInfo(name) is null ? null : Sheet(name);

    static readonly Dictionary<RunnerCharacter, RunnerArtwork> Arts = [];

    /// The checked @1x sheet and sleep-z strips TrayFrame draws (Core falls back to the cat when a sheet is unusable).
    public static RunnerArtwork Art(RunnerCharacter character) => Arts.TryGetValue(character, out var art) ? art
        : Arts[character] = RunnerArtwork.Load(character, RunnerManifest.Parse(Resource("runner-v2.json")), Load);

    public static string SheetName(RunnerCharacter character, int scale) => $"{character.Sheet}@{scale}x.png";
    public static string HeadName(RunnerHead head, int scale) => $"app-head-{head.ToString().ToLowerInvariant()}@{scale}x.png";
    public static string FxName(int scale) => $"runner-v2-fx@{scale}x.png";

    static readonly Dictionary<PixelSheet, BitmapSource> Sources = new(ReferenceEqualityComparer.Instance);

    public static BitmapSource Bitmap(PixelSheet sheet, Int32Rect? crop = null)
    {
        if (!Sources.TryGetValue(sheet, out var source))
        {
            source = BitmapSource.Create(sheet.Width, sheet.Height, 96, 96, PixelFormats.Bgra32, null, sheet.Bgra, sheet.Width * 4);
            source.Freeze();
            Sources[sheet] = source;
        }
        if (crop is not { } rect) return source;
        var cropped = new CroppedBitmap(source, rect);
        cropped.Freeze();
        return cropped;
    }

    /// The pose rows and the z glyph placements from runner-v2.json (the drawing half of the manifest; timing is WP4's).
    sealed record Layout(Dictionary<RunnerPose, int> Rows, List<(RunnerPose Pose, int Step, Int32Rect Glyph, int X, int Y)> Fx);
    static Layout? layout;
    static Layout Manifest()
    {
        if (layout is not null) return layout;
        var root = Json.Parse(Resource("runner-v2.json")) ?? throw new InvalidDataException("runner-v2.json is not JSON");
        var rows = new Dictionary<RunnerPose, int>();
        foreach (var pose in root.Field("poses")!.Value.EnumerateArray())
            if (Enum.TryParse<RunnerPose>(pose.Field("pose")?.Text, true, out var value)) rows[value] = (int)(pose.Field("row")?.Number ?? 0);
        var glyphs = root.Field("glyphs")!.Value;
        var fx = new List<(RunnerPose, int, Int32Rect, int, int)>();
        foreach (var effect in root.Field("fx")!.Value.EnumerateArray())
        {
            if (!Enum.TryParse<RunnerPose>(effect.Field("pose")?.Text, true, out var pose) || glyphs.Field(effect.Field("glyph")?.Text ?? "") is not { } g) continue;
            int N(System.Text.Json.JsonElement e, string key) => (int)(e.Field(key)?.Number ?? 0);
            fx.Add((pose, N(effect, "step"), new Int32Rect(N(g, "x"), N(g, "y"), N(g, "width"), N(g, "height")), N(effect, "x"), N(effect, "y")));
        }
        return layout = new Layout(rows, fx);
    }

    public static int Row(RunnerPose pose) => Manifest().Rows.GetValueOrDefault(pose);

    /// One 30 × 18 cell at `scale` (1 or 2).
    public static BitmapSource Frame(RunnerCharacter character, RunnerPose pose, int frame, int scale = 2) =>
        Bitmap(Sheet(SheetName(character, scale)), new Int32Rect(frame * CellWidth * scale, Row(pose) * CellHeight * scale, CellWidth * scale, CellHeight * scale));

    public static BitmapSource Head(RunnerHead head, int scale = 2) => Bitmap(Sheet(HeadName(head, scale)));

    /// A sprite image sized `CellWidth × CellHeight × zoom` DIPs, drawn without smoothing; the z of `fxStep` over it in `zColor`.
    /// Zoom 1 draws the @1x art and zoom 2 the @2x art, so whole-percent display scales stay whole multiples.
    public static FrameworkElement Sprite(RunnerCharacter character, RunnerPose pose, int frame, int zoom, int? fxStep = null, Color? zColor = null)
    {
        var scale = Math.Clamp(zoom, 1, 2);
        var grid = new Grid { Width = CellWidth * zoom, Height = CellHeight * zoom };
        grid.Children.Add(Pixel(new Image { Source = Frame(character, pose, frame, scale) }));
        foreach (var effect in Manifest().Fx.Where(e => e.Pose == pose && e.Step == fxStep))
        {
            // A template mask: the glyph's alpha filled with the given colour.
            var glyph = effect.Glyph;
            var mask = new ImageBrush(Bitmap(Sheet(FxName(scale)), new Int32Rect(glyph.X * scale, glyph.Y * scale, glyph.Width * scale, glyph.Height * scale)));
            RenderOptions.SetBitmapScalingMode(mask, BitmapScalingMode.NearestNeighbor);
            grid.Children.Add(Pixel(new Border
            {
                Width = glyph.Width * zoom, Height = glyph.Height * zoom, HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(effect.X * zoom, effect.Y * zoom, 0, 0),
                Background = Theme.Brush(zColor ?? Theme.Tertiary), OpacityMask = mask,
            }));
        }
        return grid;
    }

    /// The 12 × 11 head at `width × height` DIPs: the @2x art from 24 DIPs up, the @1x art below.
    public static Image HeadImage(RunnerHead head, double width, double height) =>
        Pixel(new Image { Source = Head(head, width >= 24 ? 2 : 1), Width = width, Height = height });

    public static T Pixel<T>(T element) where T : UIElement
    {
        RenderOptions.SetBitmapScalingMode(element, BitmapScalingMode.NearestNeighbor);
        element.SnapsToDevicePixels = true;
        return element;
    }
}
