namespace TokenCat;

// WP4 stub (DESIGN §4.1, §11): tray icon pixels from the sprite sheets, integer nearest-neighbour only. WP4 owns this file.

/// The corner dot: yellow attention = input, orange warning = API retry. Nothing else.
public enum StateDot { None, Attention, Warning }

public static class TrayFrame
{
    /// Full-body scale when a 30×18 cell fits at a whole scale (icon ≥ 30 px), else null → head mode.
    public static int? BodyScale(int icon) => throw new NotImplementedException();
    /// Head art scale: 16/20 px → 1 (@1x), 24/28/32 px → 2 (@2x).
    public static int HeadScale(int icon) => throw new NotImplementedException();
    /// icon×icon BGRA.
    public static byte[] Body(PixelSheet sheet, RunnerPose pose, int frame, PixelSheet? fx, int fxStep, int icon, StateDot dot, bool lightTaskbar) =>
        throw new NotImplementedException();
    /// icon×icon BGRA; `bob` in art pixels.
    public static byte[] Head(PixelSheet head, int bob, PixelSheet? fx, int fxStep, int icon, StateDot dot, bool lightTaskbar) =>
        throw new NotImplementedException();
}
