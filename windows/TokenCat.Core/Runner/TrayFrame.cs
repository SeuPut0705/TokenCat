namespace TokenCat;

// DESIGN §4.1: tray icon pixels from RunnerArtwork's sheets, integer nearest-neighbour only, centred. Body mode at 30 px and up
// (200 %+), the cat head below (100–175 %). Output is icon×icon BGRA, alpha 0 or 255 only, so straight and premultiplied agree.

/// The corner dot: yellow attention = input, orange warning = API retry. Nothing else.
public enum StateDot { None, Attention, Warning }

public static class TrayFrame
{
    const int Cell = RunnerManifest.CellWidth, Row = RunnerManifest.CellHeight, HeadWidth = 12;

    /// Full-body scale when a 30×18 cell fits at a whole scale (icon ≥ 30 px), else null → head mode.
    public static int? BodyScale(int icon) => icon >= Cell ? icon / Cell : null;

    /// Head art scale: 16/20 px → 1 (@1x), 24/28/32 px → 2 (@2x).
    public static int HeadScale(int icon) => Math.Max(1, icon / HeadWidth);

    /// What head mode shows for the animator's frame: the head variant and the bob in art pixels (DESIGN §4.1 table).
    /// Sit, alert and content blink on frame 1; walk and run bob on odd frames; yawn is the closed eyes.
    public static (RunnerHead Head, int Bob) HeadFor(RunnerPose pose, int frame) => pose switch
    {
        RunnerPose.Sleep => (RunnerHead.Sleep, 0),
        RunnerPose.Yawn => (RunnerHead.Blink, 0),
        RunnerPose.Walk or RunnerPose.Run => (RunnerHead.Normal, frame & 1),
        RunnerPose.Alert => (frame == 1 ? RunnerHead.Blink : RunnerHead.Alert, 0),
        _ => (frame == 1 ? RunnerHead.Blink : RunnerHead.Normal, 0),
    };

    /// icon×icon BGRA. `sheet` is RunnerArtwork.Sheet (@1x, a row per pose); `fx` its effect strip for `pose` (null: no z).
    public static byte[] Body(PixelSheet sheet, RunnerPose pose, int frame, PixelSheet? fx, int fxStep, int icon, StateDot dot, bool lightTaskbar)
    {
        var k = BodyScale(icon) ?? throw new ArgumentOutOfRangeException(nameof(icon), icon, "body mode needs an icon of 30 px or more");
        var pixels = new byte[icon * icon * 4];
        int x0 = (icon - Cell * k) / 2, y0 = (icon - Row * k) / 2;
        Blit(pixels, icon, sheet, Wrap(frame, RunnerManifest.Frames(pose)) * Cell, (int)pose * Row, Cell, Row, 1, x0, y0, k, null);
        if (fx is { Width: >= Cell })
            Blit(pixels, icon, fx, Wrap(fxStep, fx.Width / Cell) * Cell, 0, Cell, Row, 1, x0, y0, k, Ink(lightTaskbar));
        Dot(pixels, icon, k, dot, lightTaskbar);
        return pixels;
    }

    /// icon×icon BGRA; `head` is a RunnerArtwork head (12×11, or the 24×22 @2x art), `bob` in art pixels. The z from `fx`
    /// (the sleep strip) goes in the top-right corner only where it clears the head, so only some sizes show it.
    public static byte[] Head(PixelSheet head, int bob, PixelSheet? fx, int fxStep, int icon, StateDot dot, bool lightTaskbar)
    {
        var unit = Math.Max(1, head.Width / HeadWidth);
        int k = HeadScale(icon), width = head.Width / unit * k, height = head.Height / unit * k;
        var pixels = new byte[icon * icon * 4];
        // Bob uses spare rows when there are any: the resting head sits high enough for a 1 art-px drop, otherwise it shifts up.
        int x0 = (icon - width) / 2, rest = Math.Min((icon - height) / 2, icon - height - k);
        var y0 = rest + bob * k;
        if (y0 + height > icon) y0 = rest - bob * k;
        Blit(pixels, icon, head, 0, 0, head.Width / unit, head.Height / unit, unit, x0, y0, k, null);
        if (fx is { Width: >= Cell } && Bounds(fx, Wrap(fxStep, fx.Width / Cell) * Cell) is var (gx, gy, gw, gh) && gw > 0)
        {
            int left = icon - gw * k, bottom = gh * k;
            if (left >= x0 + width || bottom <= y0) Blit(pixels, icon, fx, gx, gy, gw, gh, 1, left, 0, k, Ink(lightTaskbar));
        }
        Dot(pixels, icon, k, dot, lightTaskbar);
        return pixels;
    }

    static int Wrap(int value, int count) => count <= 0 ? 0 : (value % count + count) % count;

    /// The taskbar's text tone: the z is drawn in it, the dot outline in it too ("opposite" of the taskbar background).
    static (byte B, byte G, byte R) Ink(bool lightTaskbar) => lightTaskbar ? ((byte)0, (byte)0, (byte)0) : ((byte)255, (byte)255, (byte)255);

    /// Copies the opaque pixels of `source` (w×h art px from sx, sy, sampled every `unit` px) as k×k blocks at x0, y0, clipped.
    /// `ink` replaces the colour (masks).
    static void Blit(byte[] target, int icon, PixelSheet source, int sx, int sy, int w, int h, int unit, int x0, int y0, int k,
        (byte B, byte G, byte R)? ink)
    {
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                int px = (sx + x) * unit, py = (sy + y) * unit;
                if (px >= source.Width || py >= source.Height) continue;
                var from = (py * source.Width + px) * 4;
                if (source.Bgra[from + 3] == 0) continue;
                for (var dy = 0; dy < k; dy++)
                    for (var dx = 0; dx < k; dx++)
                    {
                        int tx = x0 + x * k + dx, ty = y0 + y * k + dy;
                        if (tx < 0 || ty < 0 || tx >= icon || ty >= icon) continue;
                        var to = (ty * icon + tx) * 4;
                        if (ink is var (b, g, r)) (target[to], target[to + 1], target[to + 2]) = (b, g, r);
                        else source.Bgra.AsSpan(from, 3).CopyTo(target.AsSpan(to));
                        target[to + 3] = 255;
                    }
            }
    }

    /// The opaque bounding box of one 30×18 strip cell: (x, y, width, height) in strip pixels; width 0 when empty.
    static (int X, int Y, int W, int H) Bounds(PixelSheet strip, int sx)
    {
        int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
        for (var y = 0; y < Math.Min(Row, strip.Height); y++)
            for (var x = sx; x < sx + Cell; x++)
                if (strip.Bgra[(y * strip.Width + x) * 4 + 3] != 0)
                    (minX, minY, maxX, maxY) = (Math.Min(minX, x), Math.Min(minY, y), Math.Max(maxX, x), Math.Max(maxY, y));
        return maxX < 0 ? (0, 0, 0, 0) : (minX, minY, maxX - minX + 1, maxY - minY + 1);
    }

    /// 3×3 art px × k in the bottom-right corner inside a 1 art-px outline in the taskbar's text tone. Colours are DesignTokens'
    /// attention (systemYellow) and warning in the taskbar's appearance.
    static void Dot(byte[] pixels, int icon, int k, StateDot dot, bool lightTaskbar)
    {
        if (dot == StateDot.None) return;
        var (r, g, b) = (dot, lightTaskbar) switch
        {
            (StateDot.Attention, true) => (0xFF, 0xCC, 0x00),
            (StateDot.Attention, false) => (0xFF, 0xD6, 0x0A),
            (_, true) => (0xC8, 0x64, 0x00),
            _ => (0xFF, 0x9F, 0x0A),
        };
        var ink = Ink(lightTaskbar);
        for (var y = icon - 5 * k; y < icon; y++)
            for (var x = icon - 5 * k; x < icon; x++)
            {
                if (x < 0 || y < 0) continue;
                var inner = x >= icon - 4 * k && x < icon - k && y >= icon - 4 * k && y < icon - k;
                var to = (y * icon + x) * 4;
                (pixels[to], pixels[to + 1], pixels[to + 2], pixels[to + 3]) =
                    inner ? ((byte)b, (byte)g, (byte)r, (byte)255) : (ink.B, ink.G, ink.R, (byte)255);
            }
    }
}
