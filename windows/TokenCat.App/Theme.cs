using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using Microsoft.Win32;

namespace TokenCat;

/// DesignTokens.swift for WPF (DESIGN §4.5): the TCColor values for light and dark, picked by `AppsUseLightTheme`.
/// Views read the tokens while building, so appearance changes rebuild them (Shell). High Contrast uses the user's
/// system palette, not approximations of a dark/light theme; state shapes keep the meaning when colours coincide.
static class Theme
{
    public static bool Dark { get; set; } = !AppsUseLightTheme();
    internal static bool? HighContrastOverride { get; set; }
    public static bool HighContrast => HighContrastOverride ?? SystemParameters.HighContrast;
    public static bool Materials => !HighContrast && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621)
        && Registry.GetValue(Personalize, "EnableTransparency", 1) is not 0;

    const string Personalize = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    /// Flyout, dashboard window and Settings.
    public static bool AppsUseLightTheme() => Registry.GetValue(Personalize, "AppsUseLightTheme", 1) is not 0;
    /// The taskbar: the tray dot's outline takes the opposite tone.
    public static bool TaskbarUsesLightTheme() => Registry.GetValue(Personalize, "SystemUsesLightTheme", 0) is not 0;

    static Color Rgb(uint rgb, byte alpha = 255) => Color.FromArgb(alpha, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
    static Color Alpha(Color color, double opacity) => Color.FromArgb((byte)Math.Round(color.A * opacity), color.R, color.G, color.B);

    /// NSColor.labelColor: black / white at 0.85.
    public static Color Label => HighContrast ? SystemColors.WindowTextColor : Dark ? Rgb(0xFFFFFF, 217) : Rgb(0x000000, 217);
    public static Color Primary(double opacity) => HighContrast ? opacity >= 0.3 ? Label : SystemColors.ControlColor : Alpha(Label, opacity);

    public static Color Attention => HighContrast ? Label : Dark ? Rgb(0xFFD60A) : Rgb(0xFFCC00);
    /// Light #C86400 (systemOrange is 2.2:1 on the light container), dark systemOrange.
    public static Color Warning => HighContrast ? Label : Dark ? Rgb(0xFF9F0A) : Rgb(0xC86400);
    public static Color Critical => HighContrast ? Label : Dark ? Rgb(0xFF453A) : Rgb(0xFF3B30);
    public static Color Activity => HighContrast ? Label : Dark ? Rgb(0x30D158) : Rgb(0x248A3D);
    public static Color Tool => HighContrast ? Label : Dark ? Rgb(0x0A84FF) : Rgb(0x007AFF);
    public static Color Working => HighContrast ? Label : Dark ? Rgb(0xBF5AF2) : Rgb(0xAF52DE);
    public static Color Neutral => HighContrast ? Label : Primary(0.50);
    public static Color Track => HighContrast ? SystemColors.ControlDarkColor : Primary(0.08);
    public static Color Idle => HighContrast ? Label : Primary(0.30);
    public static Color Hairline => HighContrast ? Label : Primary(0.10);
    /// Informational secondary text remains fully opaque in High Contrast.
    public static Color Secondary => HighContrast ? Label : Dark ? Rgb(0xFFFFFF, 140) : Primary(0.66);
    public static Color Tertiary => HighContrast ? SystemColors.GrayTextColor : Dark ? Rgb(0xFFFFFF, 64) : Rgb(0x000000, 66);
    public static Color Hover => HighContrast ? SystemColors.HighlightColor : Primary(0.05);
    public static Color Pressed => HighContrast ? SystemColors.HighlightColor : Primary(0.12);
    public static Color Accent => HighContrast ? SystemColors.HotTrackColor : Dark ? Rgb(0x60CDFF) : Rgb(0x005FB8);
    public static Color Selection => HighContrast ? SystemColors.ControlColor : Alpha(Accent, 0.16);
    public static Color Background => HighContrast ? SystemColors.WindowColor : Dark ? Rgb(0x202020) : Rgb(0xF9F9F9);
    /// A conservative tint over the native material keeps the dense dashboard legible on any wallpaper.
    public static Color Surface => Materials ? Alpha(Background, 0.92) : Background;
    public static Color ContainerFill => HighContrast ? Background : Dark ? Rgb(0xFFFFFF, 13) : Rgb(0xFFFFFF, 184);
    public static Color ContainerRule => HighContrast ? Label : Dark ? Colors.Transparent : Rgb(0x000000, 15);
    public static Color TintFill => HighContrast ? Background : Alpha(Accent, 0.08);

    // Palette-sized, bounded cache: charts may request arbitrary opacity values. Frozen brushes are safe to share.
    static readonly Dictionary<Color, SolidColorBrush> brushes = [];
    public static SolidColorBrush Brush(Color color)
    {
        if (brushes.TryGetValue(color, out var cached)) return cached;
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        if (brushes.Count >= 512) brushes.Clear();
        brushes[color] = brush;
        return brush;
    }

    /// The state glyph colours (A0-3 table).
    public static Color GlyphColor(StateGlyphKind kind) => kind switch
    {
        StateGlyphKind.RecordEvent => Activity,
        StateGlyphKind.Tool => Tool,
        StateGlyphKind.Working => Working,
        StateGlyphKind.Input => Attention,
        StateGlyphKind.Retry => Warning,
        StateGlyphKind.Idle => Idle,
        _ => Neutral,
    };

    /// Neutral below 85 %, warning from 85 %, critical from 95 %.
    public static Color MeterColor(double? percent) =>
        percent is not { } p ? Neutral : p >= 95 ? Critical : p >= 85 ? Warning : Neutral;

    /// `color` over `background`, opaque.
    public static Color Over(Color color, Color background)
    {
        var a = color.A / 255.0;
        byte Mix(byte top, byte bottom) => (byte)Math.Round(top * a + bottom * (1 - a));
        return Color.FromRgb(Mix(color.R, background.R), Mix(color.G, background.G), Mix(color.B, background.B));
    }

    /// WCAG 2.1 contrast ratio of two opaque colours.
    public static double Contrast(Color a, Color b)
    {
        static double Luminance(Color c)
        {
            static double Channel(byte v) { var s = v / 255.0; return s <= 0.03928 ? s / 12.92 : Math.Pow((s + 0.055) / 1.055, 2.4); }
            return 0.2126 * Channel(c.R) + 0.7152 * Channel(c.G) + 0.0722 * Channel(c.B);
        }
        double x = Luminance(a), y = Luminance(b);
        return (Math.Max(x, y) + 0.05) / (Math.Min(x, y) + 0.05);
    }

    /// The light container as drawn: white 0.72 over the window background.
    public static Color ContainerOpaque => Over(ContainerFill, Background);
}

/// TCFont (A0-1): the only sizes and weights. "Mono" is tabular digits.
enum Font { Metric, Title, Body, Value, Meta, MetaMedium, MetaMono, MetaMonoSemibold, Micro, BodyMedium, Caption }

/// Small builders shared by the flyout, the dashboard window and Settings.
static class Ui
{
    public const double ContainerRadius = 8, ControlRadius = 4;
    public static readonly FontFamily Family = new("Segoe UI Variable Text, Segoe UI, Malgun Gothic");
    public static readonly FontFamily IconFamily = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    // Segoe Fluent Icons / MDL2 code points standing in for the SF Symbols the mac uses.
    public const char Gear = '\uE713', More = '\uE712', InfoIcon = '\uE946', Close = '\uE711', ChevronUp = '\uE70E', ChevronDown = '\uE70D',
        OpenOut = '\uE8A7', WarningIcon = '\uE7BA', Copy = '\uE8C8', Shield = '\uEA18', Sliders = '\uE9E9', Blocked = '\uE733',
        Speedometer = '\uEC4A', Bolt = '\uE945', Refresh = '\uE72C', Check = '\uE73E', Dashed = '\uEA3A';

    static (double Size, FontWeight Weight, bool Mono) Spec(Font font) => font switch
    {
        Font.Metric => (15, FontWeights.SemiBold, true),
        Font.Title => (13, FontWeights.SemiBold, false),
        Font.Body => (13, FontWeights.Normal, false),
        Font.Value => (13, FontWeights.SemiBold, true),
        Font.Meta => (11, FontWeights.Normal, false),
        Font.MetaMedium => (11, FontWeights.Medium, false),
        Font.MetaMono => (11, FontWeights.Normal, true),
        Font.MetaMonoSemibold => (11, FontWeights.SemiBold, true),
        Font.Micro => (10, FontWeights.Medium, false),
        Font.BodyMedium => (13, FontWeights.Medium, false),
        _ => (11, FontWeights.SemiBold, false),
    };

    public static T Styled<T>(T element, Font font, Color? color = null) where T : DependencyObject
    {
        var (size, weight, mono) = Spec(font);
        TextElement.SetFontFamily(element, Family);
        TextElement.SetFontSize(element, size);
        TextElement.SetFontWeight(element, weight);
        if (mono) Typography.SetNumeralAlignment(element, FontNumeralAlignment.Tabular);
        if (color is { } c) TextElement.SetForeground(element, Theme.Brush(c));
        return element;
    }

    public static TextBlock Text(string text, Font font, Color? color = null) =>
        Styled(new TextBlock { Text = text, TextTrimming = TextTrimming.CharacterEllipsis }, font, color ?? Theme.Label);

    public static Run Run(string text, Font font, Color? color = null) => Styled(new Run(text), font, color ?? Theme.Label);

    /// A line of runs (Swift `Text + Text`).
    public static TextBlock Line(params Run[] runs)
    {
        var block = Styled(new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis }, Font.Body, Theme.Label);
        block.Inlines.AddRange(runs);
        return block;
    }

    public static TextBlock Icon(char glyph, double size, Color color) => new()
    {
        Text = glyph.ToString(), FontFamily = IconFamily, FontSize = size, Foreground = Theme.Brush(color),
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// A borderless button whose content turns primary on hover, inside a circle or a 5 DIP rounded rectangle.
    public static Button HoverButton(UIElement content, Action click, string help, bool circle = false) => Hover(new Button(), content, click, help, circle);

    /// HoverButton on any button kind: a ToggleButton reports on/off and a RadioButton its selection to UI Automation.
    public static T Hover<T>(T button, UIElement content, Action click, string help, bool circle = false) where T : ButtonBase
    {
        var chrome = new Border { Child = content, CornerRadius = new CornerRadius(circle ? 99 : ControlRadius), Background = Brushes.Transparent };
        if (Theme.HighContrast) chrome.BorderThickness = new Thickness(1);
        void Paint(bool over, bool pressed = false)
        {
            chrome.Background = Theme.HighContrast ? Brushes.Transparent : over ? Theme.Brush(pressed ? Theme.Pressed : Theme.Hover) : Brushes.Transparent;
            chrome.BorderBrush = Theme.HighContrast && over ? Theme.Brush(SystemColors.HighlightColor) : Brushes.Transparent;
        }
        button.Content = chrome;
        button.Cursor = System.Windows.Input.Cursors.Hand;
        button.Focusable = true;
        button.ToolTip = string.IsNullOrEmpty(help) ? null : help;
        button.Padding = new Thickness(0);
        button.Template = PlainTemplate();
        button.FocusVisualStyle = FocusRing();
        System.Windows.Automation.AutomationProperties.SetHelpText(button, help);
        System.Windows.Automation.AutomationProperties.SetName(button, help);
        button.MouseEnter += (_, _) => Paint(true);
        button.MouseLeave += (_, _) => Paint(false);
        button.PreviewMouseLeftButtonDown += (_, _) => Paint(true, true);
        button.PreviewMouseLeftButtonUp += (_, _) => Paint(button.IsMouseOver);
        button.LostMouseCapture += (_, _) => Paint(button.IsMouseOver);
        button.PreviewKeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Space) Paint(true, true); };
        button.PreviewKeyUp += (_, e) => { if (e.Key == System.Windows.Input.Key.Space) Paint(button.IsMouseOver); };
        button.Click += (_, _) => click();
        return button;
    }

    /// A text link: 11 medium, underlined, accent when it is the next step.
    public static Button Link(string title, Action click, string help, bool emphasized = false)
    {
        var text = Text(title, Font.MetaMedium, emphasized ? Theme.Accent : Theme.Label);
        text.TextDecorations = TextDecorations.Underline;
        var button = HoverButton(text, click, help);
        // Named by its visible words (WCAG 2.5.3); `help` stays the tooltip and help text.
        System.Windows.Automation.AutomationProperties.SetName(button, title);
        return button;
    }

    /// `.bordered .small`; `menu` adds a chevron for a button that opens a list of choices.
    public static Button SmallButton(string title, Action click, string? help = null, bool menu = false)
    {
        var text = Text(title, Font.Meta);
        TextBlock? chevron = null;
        UIElement content = text;
        if (menu)
        {
            chevron = Icon(ChevronDown, 8, Theme.Secondary);
            chevron.Margin = new Thickness(6, 1, 0, 0);
            content = new StackPanel { Orientation = Orientation.Horizontal, Children = { content, chevron } };
        }
        var chrome = new Border
        {
            Child = content, Padding = new Thickness(8, 2, 8, 2), CornerRadius = new CornerRadius(ControlRadius),
            Background = Theme.Brush(Theme.Primary(0.1)),
            BorderBrush = Theme.HighContrast ? Theme.Brush(SystemColors.ControlTextColor) : null,
            BorderThickness = new Thickness(Theme.HighContrast ? 1 : 0),
        };
        var button = new Button { Content = chrome, Template = PlainTemplate(), FocusVisualStyle = FocusRing(), Cursor = System.Windows.Input.Cursors.Hand, ToolTip = help };
        // The content is a Border, which gives UI Automation no text: name it by its title.
        System.Windows.Automation.AutomationProperties.SetName(button, title);
        if (help is not null) System.Windows.Automation.AutomationProperties.SetHelpText(button, help);
        void Paint(bool over, bool pressed = false)
        {
            chrome.Background = Theme.Brush(over ? pressed ? Theme.Pressed : Theme.HighContrast ? Theme.Hover : Theme.Primary(0.15) : Theme.Primary(0.1));
            text.Foreground = Theme.Brush(Theme.HighContrast && over ? SystemColors.HighlightTextColor : Theme.Label);
            if (chevron is not null) chevron.Foreground = Theme.Brush(Theme.HighContrast && over ? SystemColors.HighlightTextColor : Theme.Secondary);
        }
        button.MouseEnter += (_, _) => Paint(true);
        button.MouseLeave += (_, _) => Paint(false);
        button.PreviewMouseLeftButtonDown += (_, _) => Paint(true, true);
        button.PreviewMouseLeftButtonUp += (_, _) => Paint(button.IsMouseOver);
        button.LostMouseCapture += (_, _) => Paint(button.IsMouseOver);
        button.PreviewKeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Space) Paint(true, true); };
        button.PreviewKeyUp += (_, e) => { if (e.Key == System.Windows.Input.Key.Space) Paint(button.IsMouseOver); };
        button.Click += (_, _) => click();
        return button;
    }

    /// A visible Fluent-style two-pixel focus outline. Cache by resolved colour; rebuilt views pick up palette changes.
    static Style? focusRing;
    static Color focusColor;
    static Style FocusRing()
    {
        if (focusRing is not null && focusColor == Theme.Label) return focusRing;
        focusColor = Theme.Label;
        var ring = new FrameworkElementFactory(typeof(System.Windows.Shapes.Rectangle));
        ring.SetValue(System.Windows.Shapes.Shape.StrokeProperty, Theme.Brush(Theme.Label));
        ring.SetValue(System.Windows.Shapes.Shape.StrokeThicknessProperty, 2.0);
        ring.SetValue(UIElement.SnapsToDevicePixelsProperty, true);
        ring.SetValue(System.Windows.Shapes.Rectangle.RadiusXProperty, 4.0);
        ring.SetValue(System.Windows.Shapes.Rectangle.RadiusYProperty, 4.0);
        ring.SetValue(FrameworkElement.MarginProperty, new Thickness(-2));
        var style = new Style();
        style.Setters.Add(new Setter(Control.TemplateProperty, new ControlTemplate { VisualTree = ring }));
        style.Seal();
        return focusRing = style;
    }

    /// Korean wraps between words as on the mac; WPF would break between any two syllables. A WORD JOINER (U+2060) between
    /// Hangul syllables leaves only the spaces as break points.
    public static string KeepWords(string text) =>
        Lang.Current == AppLanguage.Ko ? System.Text.RegularExpressions.Regex.Replace(text, "(?<=[가-힣])(?=[가-힣])", "\u2060") : text;

    /// Content only; FocusRing draws keyboard focus.
    static ControlTemplate? plain;
    public static ControlTemplate PlainTemplate()
    {
        if (plain is not null) return plain;
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        plain = new ControlTemplate(typeof(ButtonBase)) { VisualTree = presenter };
        plain.Seal();
        return plain;
    }

    /// Fluent surface corners, with the mac's information layout.
    public static Border Container(UIElement child, bool tint = false) => new()
    {
        Child = child, CornerRadius = new CornerRadius(ContainerRadius),
        Background = Theme.Brush(tint ? Theme.TintFill : Theme.ContainerFill),
        BorderBrush = Theme.Brush(Theme.HighContrast ? Theme.ContainerRule : tint ? Colors.Transparent : Theme.ContainerRule),
        BorderThickness = new Thickness(Theme.HighContrast ? 1 : tint || Theme.Dark ? 0 : 1),
    };

    public static Border Hairline(double left = 0, double right = 0) => new()
    {
        Height = 1, Background = Theme.Brush(Theme.Hairline), Margin = new Thickness(left, 0, right, 0), SnapsToDevicePixels = true,
    };

    public static void Help(FrameworkElement element, string? help)
    {
        if (!Equals(element.ToolTip, help)) element.ToolTip = string.IsNullOrEmpty(help) ? null : help;
    }
}

/// A 4 DIP meter: the track behind, the fill in `Color`.
sealed class Meter : FrameworkElement
{
    double fraction;
    Color color = Theme.Neutral;

    public Meter(double height = 4) { Height = height; SnapsToDevicePixels = true; }

    public void Set(double value, Color fill)
    {
        if (value == fraction && fill == color) return;
        fraction = value;
        color = fill;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext context)
    {
        var dpi = VisualTreeHelper.GetDpi(this);
        double width = Math.Round(ActualWidth * dpi.DpiScaleX) / dpi.DpiScaleX;
        double height = Math.Round(ActualHeight * dpi.DpiScaleY) / dpi.DpiScaleY, radius = height / 2;
        context.DrawRoundedRectangle(Theme.Brush(Theme.Track), null, new Rect(0, 0, width, height), radius, radius);
        if (fraction > 0)
        {
            var fillWidth = Math.Round(Math.Max(height, width * Math.Min(1, fraction)) * dpi.DpiScaleX) / dpi.DpiScaleX;
            context.DrawRoundedRectangle(Theme.Brush(color), null, new Rect(0, 0, fillWidth, height), radius, radius);
        }
    }
}

/// StateGlyph (A0-3): one shape per kind inside a `side` box. Retry is the refresh icon in the warning colour.
sealed class GlyphView : FrameworkElement
{
    public const double LineWidth = 1.5;
    StateGlyphKind kind;

    public GlyphView(StateGlyphKind kind, double side = 8)
    {
        this.kind = kind;
        Width = Height = side;
        VerticalAlignment = VerticalAlignment.Center;
    }

    public StateGlyphKind Kind
    {
        get => kind;
        set { if (kind != value) { kind = value; InvalidateVisual(); } }
    }

    /// The shape in `box`: filled with the even-odd rule, or stroked with `stroke` (rings).
    public static Geometry Shape(StateGlyphKind kind, Rect box, out Pen? stroke)
    {
        stroke = null;
        var side = Math.Min(box.Width, box.Height);
        var center = new Point(box.X + box.Width / 2, box.Y + box.Height / 2);
        double radius = side / 2, inner = Math.Max(0, radius - LineWidth), ring = radius - LineWidth / 2;
        Geometry Group(params Geometry[] parts)
        {
            var group = new GeometryGroup { FillRule = FillRule.EvenOdd };
            foreach (var part in parts) group.Children.Add(part);
            return group;
        }
        switch (kind)
        {
            case StateGlyphKind.RecordEvent or StateGlyphKind.Input:
                return new EllipseGeometry(center, radius, radius);
            case StateGlyphKind.Tool:
                var inset = side / 16;
                return new RectangleGeometry(new Rect(center.X - radius + inset, center.Y - radius + inset, side - 2 * inset, side - 2 * inset), 1.5, 1.5);
            case StateGlyphKind.Working or StateGlyphKind.Unfinished:
                stroke = new Pen(Brushes.Black, LineWidth);
                // WPF dashes are in stroke widths: 2 and 1.5 DIP.
                if (kind == StateGlyphKind.Unfinished && !Theme.HighContrast) stroke.DashStyle = new DashStyle([2 / LineWidth, 1.5 / LineWidth], 0);
                return new EllipseGeometry(center, ring, ring);
            case StateGlyphKind.Waiting:
                // Disc minus the right half of the hole: a ring with its left half filled.
                var half = new PathGeometry([new PathFigure(new Point(center.X, center.Y - inner),
                    [new ArcSegment(new Point(center.X, center.Y + inner), new Size(inner, inner), 0, false, SweepDirection.Clockwise, true)], true)]);
                return Group(new EllipseGeometry(center, radius, radius), half);
            case StateGlyphKind.Interrupted:
                // Ring plus a centred bar (⊖), kept clear of the ring on small glyphs.
                var bar = Math.Max(0, Math.Min(4, inner * 2 - 1));
                return Group(new EllipseGeometry(center, radius, radius), new EllipseGeometry(center, inner, inner),
                    new RectangleGeometry(new Rect(center.X - bar / 2, center.Y - LineWidth / 2, bar, LineWidth)));
            case StateGlyphKind.Idle:
                var dot = side * 0.75 / 2;
                return new EllipseGeometry(center, dot, dot);
            default:
                return Geometry.Empty;
        }
    }

    static readonly Typeface InputFace = new(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Black, FontStretches.Normal);
    static readonly Typeface RetryFace = new(Ui.IconFamily, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);

    /// The input glyph's "?": heavy, 7/8 of the box, centred.
    public static Geometry InputMark(Rect box)
    {
        var side = Math.Min(box.Width, box.Height);
        var text = new FormattedText("?", System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            InputFace, side * 7 / 8, Brushes.Black, 1);
        var geometry = text.BuildGeometry(new Point(0, 0));
        var bounds = geometry.Bounds;
        if (bounds.IsEmpty) return Geometry.Empty;
        geometry.Transform = new TranslateTransform(box.X + box.Width / 2 - (bounds.X + bounds.Width / 2), box.Y + box.Height / 2 - (bounds.Y + bounds.Height / 2));
        return geometry;
    }

    static readonly Dictionary<(StateGlyphKind Kind, Rect Box, Color Color, double Dpi, bool Contrast, Color Ink), DrawingGroup> drawings = [];

    /// Frozen, palette/DPI-aware glyph drawings are shared by dashboard rows and the animated widget.
    internal static DrawingGroup Drawing(StateGlyphKind kind, Rect box, Color color, double dpi)
    {
        var ink = Theme.HighContrast ? Theme.Background : Colors.Black;
        var key = (kind, box, color, dpi, Theme.HighContrast, ink);
        if (drawings.TryGetValue(key, out var cached)) return cached;
        var drawing = new DrawingGroup();
        using (var context = drawing.Open())
        {
            var brush = Theme.Brush(color);
            if (kind == StateGlyphKind.Retry)
            {
                var text = new FormattedText(Ui.Refresh.ToString(), System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                    RetryFace, box.Height, brush, dpi);
                context.DrawText(text, new Point(box.X + (box.Width - text.Width) / 2, box.Y + (box.Height - text.Height) / 2));
            }
            else
            {
                var shape = Shape(kind, box, out var stroke);
                if (stroke is not null) { stroke.Brush = brush; context.DrawGeometry(null, stroke, shape); }
                else context.DrawGeometry(brush, null, shape);
                if (kind == StateGlyphKind.Input) context.DrawGeometry(Theme.Brush(ink), null, InputMark(box));
            }
        }
        drawing.Freeze();
        if (drawings.Count >= 256) drawings.Clear();
        drawings[key] = drawing;
        return drawing;
    }

    protected override void OnRender(DrawingContext context) =>
        context.DrawDrawing(Drawing(kind, new Rect(0, 0, ActualWidth, ActualHeight), Theme.GlyphColor(kind), VisualTreeHelper.GetDpi(this).PixelsPerDip));

    /// A session row's glyph; null for measurement rows (they keep their own symbol).
    public static StateGlyphKind? For(SessionDisplayState state) => state switch
    {
        SessionDisplayState.Input => StateGlyphKind.Input,
        SessionDisplayState.Retrying => StateGlyphKind.Retry,
        SessionDisplayState.Tool => StateGlyphKind.Tool,
        SessionDisplayState.Working => StateGlyphKind.Working,
        SessionDisplayState.Waiting => StateGlyphKind.Waiting,
        SessionDisplayState.Interrupted => StateGlyphKind.Interrupted,
        SessionDisplayState.Unfinished => StateGlyphKind.Unfinished,
        SessionDisplayState.Complete or SessionDisplayState.Idle => StateGlyphKind.Idle,
        _ => null,
    };
}
