import AppKit
import CoreText
import SwiftUI

// MARK: - Type scale (A0-1)

/// The popover type scale; no other sizes. Weights are regular, medium and semibold only
/// (the heavy "?" inside the input glyph is the one exception, drawn by `StateGlyph`).
/// "mono" means `monospacedDigit()`, so digits keep their width while values change.
/// Units go one step down in `TCColor.textSecondary`: hero 26 + "tok" in `body` (13);
/// metric 15 and value 13 + unit in `micro` (10). Korean text never goes below 10 pt.
/// Inline SF Symbols take the font of the text beside them; chevrons use `.imageScale(.small)`.
enum TCFont {
    /// 26 semibold mono: the 5-minute output total.
    static let hero = Font.system(size: 26, weight: .semibold).monospacedDigit()
    /// 15 semibold mono: a live row's current-turn total.
    static let metric = Font.system(size: 15, weight: .semibold).monospacedDigit()
    /// 13 semibold: header sentence, "출력 토큰", "세션", a live row's project.
    static let title = Font.system(size: 13, weight: .semibold)
    /// 13 regular: an idle row's project.
    static let body = Font.system(size: 13)
    /// 13 semibold mono: limit %, system values.
    static let value = Font.system(size: 13, weight: .semibold).monospacedDigit()
    /// 11 regular: second and third lines, captions.
    static let meta = Font.system(size: 11)
    /// 11 medium: chips, buttons, labels.
    static let metaMedium = Font.system(size: 11, weight: .medium)
    /// 11 regular mono: ages, clocks and numbers in secondary lines.
    static let metaMono = Font.system(size: 11).monospacedDigit()
    /// 11 semibold mono: child-row numbers.
    static let metaMonoSemibold = Font.system(size: 11, weight: .semibold).monospacedDigit()
    /// 10 medium: axes, units (tok · % · kB/s), system labels, ticks.
    static let micro = Font.system(size: 10, weight: .medium)
    /// Spec-named weights inside the same sizes: 13 medium (empty-list title), 13 medium mono (the flow card's
    /// last-record value) and 11 semibold (expanded-list date captions).
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let bodyMediumMono = Font.system(size: 13, weight: .medium).monospacedDigit()
    static let caption = Font.system(size: 11, weight: .semibold)

    /// AppKit equivalents for menus, the menu bar and AppKit-drawn glyphs.
    enum NS {
        static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let body = NSFont.systemFont(ofSize: 13)
        static let value = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        static let meta = NSFont.systemFont(ofSize: 11)
        static let metaMedium = NSFont.systemFont(ofSize: 11, weight: .medium)
        static let metaMono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        static let micro = NSFont.systemFont(ofSize: 10, weight: .medium)
        /// The "?" inside the input glyph: the only heavy weight, 7/8 of the glyph box (7 pt in an 8 pt glyph).
        static func inputMark(glyphSide: CGFloat) -> NSFont { .systemFont(ofSize: glyphSide * 7 / 8, weight: .heavy) }
    }
}

// MARK: - Colour tokens (A0-2)

/// One SwiftUI `Color` and one dynamic `NSColor` per token. The SwiftUI colour wraps the AppKit one, so both
/// resolve per light/dark appearance (also under `ImageRenderer` with `.environment(\.colorScheme, …)`).
/// "primary x" is the label colour at x of its own opacity, exactly `Color.primary.opacity(x)`.
/// Increase Contrast variants are functions taking `contrast`.
enum TCColor {
    /// Input needed, and nothing else.
    static let attention = Color(nsColor: NS.attention)
    /// API retry, meter ≥ 85 %, memory-pressure warning, collection delay, telemetry problem.
    /// Light #C86400 (systemOrange measured 2.2:1 on the light container), dark systemOrange.
    static let warning = Color(nsColor: NS.warning)
    /// Meter ≥ 95 %, critical memory pressure, battery ≤ 10 %.
    static let critical = Color(nsColor: NS.critical)
    /// A record from the last 5 s, the newest bar, receiving: light #248A3D, dark #30D158.
    static let activity = Color(nsColor: NS.activity)
    /// Running tool.
    static let tool = Color(nsColor: NS.tool)
    /// Turn in progress.
    static let working = Color(nsColor: NS.working)
    /// primary 0.50 (0.45 measured 2.7:1 on the light container): log wait, interrupted, no end record, ordinary meters.
    static let neutral = Color(nsColor: NS.neutral)
    /// primary 0.08: meter background.
    static let track = Color(nsColor: NS.track)
    /// primary 0.30: the complete / no-recent-activity glyph.
    static let idle = Color(nsColor: NS.idle)

    /// `Color.primary.opacity(opacity)`, for one-off strokes such as chart baselines and ticks.
    static func primary(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }
    /// primary 0.10, Increase Contrast 0.25: separators.
    static func hairline(contrast: Bool) -> Color { contrast ? hairlineContrast : hairlineNormal }
    /// Every informational secondary text: dark `.secondary`, light primary 0.66 (0.62 measured 4.3:1), Increase Contrast primary 0.80.
    static func textSecondary(contrast: Bool) -> Color { contrast ? secondaryContrast : secondaryNormal }
    /// Decoration only ("·", placeholder "—", disabled): `.tertiary`, Increase Contrast `.secondary`.
    static func textTertiary(contrast: Bool) -> Color { contrast ? tertiaryContrast : tertiaryNormal }
    /// Row and button hover: primary 0.05, Increase Contrast 0.08.
    static func hover(contrast: Bool) -> Color { contrast ? hoverContrast : hoverNormal }
    /// Row and button press: primary 0.08, Increase Contrast 0.12.
    static func pressed(contrast: Bool) -> Color { contrast ? pressedContrast : pressedNormal }
    /// Keyboard selection: accent 0.16, or primary 0.08 while the window is not key.
    static func selection(keyWindow: Bool) -> Color { keyWindow ? selectionKey : selectionInactive }

    private static let hairlineNormal = Color(nsColor: NS.hairline(contrast: false))
    private static let hairlineContrast = Color(nsColor: NS.hairline(contrast: true))
    private static let secondaryNormal = Color(nsColor: NS.textSecondary(contrast: false))
    private static let secondaryContrast = Color(nsColor: NS.textSecondary(contrast: true))
    private static let tertiaryNormal = Color(nsColor: NS.textTertiary(contrast: false))
    private static let tertiaryContrast = Color(nsColor: NS.textTertiary(contrast: true))
    private static let hoverNormal = Color(nsColor: NS.hover(contrast: false))
    private static let hoverContrast = Color(nsColor: NS.hover(contrast: true))
    private static let pressedNormal = Color(nsColor: NS.pressed(contrast: false))
    private static let pressedContrast = Color(nsColor: NS.pressed(contrast: true))
    private static let selectionKey = Color(nsColor: NS.selection(keyWindow: true))
    private static let selectionInactive = Color(nsColor: NS.selection(keyWindow: false))

    /// The dynamic AppKit colours behind every token; they resolve against the current drawing appearance.
    enum NS {
        static let attention = NSColor.systemYellow
        static let warning = NSColor(name: nil) { appearance in
            isDark(appearance) ? resolved(.systemOrange, in: appearance)
                : NSColor(srgbRed: 0xC8 / 255, green: 0x64 / 255, blue: 0, alpha: 1)
        }
        static let critical = NSColor.systemRed
        static let activity = NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)
                : NSColor(srgbRed: 0x24 / 255, green: 0x8A / 255, blue: 0x3D / 255, alpha: 1)
        }
        static let tool = NSColor.systemBlue
        static let working = NSColor.systemPurple
        static let neutral = primary(0.50)
        static let track = primary(0.08)
        static let idle = primary(0.30)

        static func hairline(contrast: Bool) -> NSColor { contrast ? hairlineContrast : hairlineNormal }
        static func textSecondary(contrast: Bool) -> NSColor { contrast ? secondaryContrast : secondaryNormal }
        static func textTertiary(contrast: Bool) -> NSColor { contrast ? .secondaryLabelColor : .tertiaryLabelColor }
        static func hover(contrast: Bool) -> NSColor { contrast ? hoverContrast : hoverNormal }
        static func pressed(contrast: Bool) -> NSColor { contrast ? pressedContrast : pressedNormal }
        static func selection(keyWindow: Bool) -> NSColor { keyWindow ? selectionKey : selectionInactive }

        /// The appearance's label colour at `opacity` of its own alpha (= SwiftUI `Color.primary.opacity`).
        static func primary(_ opacity: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let label = resolved(.labelColor, in: appearance)
                return label.withAlphaComponent(label.alphaComponent * opacity)
            }
        }

        private static let hairlineNormal = primary(0.10)
        private static let hairlineContrast = primary(0.25)
        private static let secondaryNormal = NSColor(name: nil) { appearance in
            if isDark(appearance) { return resolved(.secondaryLabelColor, in: appearance) }
            let label = resolved(.labelColor, in: appearance)
            return label.withAlphaComponent(label.alphaComponent * 0.66)
        }
        private static let secondaryContrast = primary(0.80)
        private static let hoverNormal = primary(0.05)
        private static let hoverContrast = primary(0.08)
        private static let pressedNormal = primary(0.08)
        private static let pressedContrast = primary(0.12)
        private static let selectionKey = NSColor(name: nil) { appearance in
            resolved(.controlAccentColor, in: appearance).withAlphaComponent(0.16)
        }
        private static let selectionInactive = primary(0.08)

        static func isDark(_ appearance: NSAppearance) -> Bool { appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

        /// A catalog colour's sRGB components as `appearance` draws it.
        private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
            var result = color
            appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
            return result
        }
    }
}

// MARK: - State glyphs (A0-3)

/// One glyph set for the popover and the menu bar. Output is an event, not a state: `recordEvent` marks
/// a record from the last 5 s (hero, row line 3); no session state maps to it.
/// Sizes: popover 8 pt inside a 10 pt column; menu bar 7 pt, the input disc 8 pt. Every API takes the glyph box itself.
enum StateGlyph {
    enum Kind: CaseIterable {
        case recordEvent, tool, working, waiting, input, retry, interrupted, unfinished, idle
    }

    /// Ring and bar thickness in points, at every glyph size.
    static let lineWidth: CGFloat = 1.5
    /// Dashed ring for "종료 기록 없음": dash 2, gap 1.5 (solid under Increase Contrast).
    static let unfinishedDash: [CGFloat] = [2, 1.5]
    /// The SF Symbol callers draw for `.retry` (semibold, inheriting the neighbouring text size).
    static let retrySymbol = "arrow.clockwise"

    /// The shape of `kind` in `rect`, in a top-left-origin (y-down) space like SwiftUI; AppKit draws it in a flipped context.
    /// - `stroke == nil`: fill `path` with the even-odd rule (the half-filled ring and ⊖ are single fills).
    /// - `stroke != nil`: stroke `path` with that style; do not fill it.
    /// `.input` is the disc only: fill `inputMark(in:)` over it in black. `.retry` is an empty path: callers draw
    /// `retrySymbol` in `TCColor.warning` (`StateGlyphView` and `image(_:side:highlighted:)` already do).
    /// `contrast` (Increase Contrast) turns the dashed ring solid.
    static func drawing(_ kind: Kind, in rect: CGRect, contrast: Bool = false) -> (path: CGPath, stroke: StrokeStyle?) {
        let side = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let center = CGPoint(x: box.midX, y: box.midY)
        let inner = max(0, side / 2 - lineWidth)
        let ring = box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = CGMutablePath()
        switch kind {
        case .recordEvent, .input:
            path.addEllipse(in: box)
        case .tool:
            let inset = side / 16
            path.addRoundedRect(in: box.insetBy(dx: inset, dy: inset), cornerWidth: 1.5, cornerHeight: 1.5)
        case .working:
            path.addEllipse(in: ring)
            return (path, StrokeStyle(lineWidth: lineWidth))
        case .unfinished:
            path.addEllipse(in: ring)
            return (path, StrokeStyle(lineWidth: lineWidth, dash: contrast ? [] : unfinishedDash))
        case .waiting:
            // Disc minus the right half of the hole: a ring with its left half filled.
            path.addEllipse(in: box)
            path.move(to: CGPoint(x: center.x, y: center.y - inner))
            path.addArc(center: center, radius: inner, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            path.closeSubpath()
        case .interrupted:
            // Ring plus a centred 4 pt bar (⊖), kept clear of the ring on small glyphs.
            path.addEllipse(in: box)
            path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            let bar = max(0, min(4, inner * 2 - 1))
            path.addRect(CGRect(x: center.x - bar / 2, y: center.y - lineWidth / 2, width: bar, height: lineWidth))
        case .idle:
            let diameter = side * 0.75
            path.addEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
        case .retry:
            break
        }
        return (path, nil)
    }

    /// The input glyph's "?" (heavy, 7/8 of the box), centred in `rect`, y-down.
    static func inputMark(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let font = TCFont.NS.inputMark(glyphSide: side) as CTFont
        var character: UniChar = 0x3F
        var glyph: CGGlyph = 0
        guard side > 0, CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
              let raw = CTFontCreatePathForGlyph(font, glyph, nil) else { return CGMutablePath() }
        let bounds = raw.boundingBoxOfPath
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.midX - bounds.midX, ty: rect.midY + bounds.midY)
        return raw.copy(using: &flip) ?? CGMutablePath()
    }

    /// The glyph's state colour (A0-3 table).
    static func nsColor(_ kind: Kind) -> NSColor {
        switch kind {
        case .recordEvent: return TCColor.NS.activity
        case .tool: return TCColor.NS.tool
        case .working: return TCColor.NS.working
        case .input: return TCColor.NS.attention
        case .retry: return TCColor.NS.warning
        case .waiting, .interrupted, .unfinished: return TCColor.NS.neutral
        case .idle: return TCColor.NS.idle
        }
    }

    static func color(_ kind: Kind) -> Color { Color(nsColor: nsColor(kind)) }

    /// Draws the glyph into a flipped (y-down) `context`. Colours resolve against the current drawing appearance.
    /// `highlighted` (open menu-bar item or menu) drops the state colour and draws the shape in the label colour;
    /// the input disc then knocks its "?" out.
    static func draw(_ kind: Kind, in rect: CGRect, context: CGContext, highlighted: Bool, contrast: Bool = false) {
        let colour = highlighted ? NSColor.labelColor : nsColor(kind)
        context.saveGState()
        defer { context.restoreGState() }
        if kind == .retry {
            let configuration = NSImage.SymbolConfiguration(pointSize: min(rect.width, rect.height), weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
            guard let symbol = NSImage(systemSymbolName: retrySymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration), symbol.size.width > 0, symbol.size.height > 0 else { return }
            let fit = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
            let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let shape = drawing(kind, in: rect, contrast: contrast)
        context.setFillColor(colour.cgColor)
        context.setStrokeColor(colour.cgColor)
        if let stroke = shape.stroke {
            context.setLineWidth(stroke.lineWidth)
            context.setLineCap(stroke.lineCap)
            context.setLineJoin(stroke.lineJoin)
            context.setLineDash(phase: stroke.dashPhase, lengths: stroke.dash)
            context.addPath(shape.path)
            context.strokePath()
            return
        }
        context.addPath(shape.path)
        if kind == .input && highlighted { context.addPath(inputMark(in: rect)) }
        context.fillPath(using: .evenOdd)
        if kind == .input && !highlighted {
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(inputMark(in: rect))
            context.fillPath(using: .evenOdd)
        }
    }

    /// A `side` × `side` pt image (menus, the menu bar), drawn at display time so it follows appearance and backing scale.
    static func image(_ kind: Kind, side: CGFloat, highlighted: Bool, contrast: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(kind, in: rect, context: context, highlighted: highlighted, contrast: contrast)
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension StateGlyph.Kind {
    /// A session row's glyph; nil for telemetry measurement rows, which keep their own symbol.
    init?(_ state: SessionDisplayState) {
        switch state {
        case .input: self = .input
        case .retrying: self = .retry
        case .tool: self = .tool
        case .working: self = .working
        case .waiting: self = .waiting
        case .interrupted: self = .interrupted
        case .unfinished: self = .unfinished
        case .complete, .idle: self = .idle
        case .measurement: return nil
        }
    }

    /// The menu-bar phase mark (`SessionCounts.phase` / `StatusAISummary.phase`); nil draws no mark.
    /// The tracker's `.output` has no mark: output is an event.
    init?(phase: TokenActivityState) {
        switch phase {
        case .input: self = .input
        case .tool: self = .tool
        case .working: self = .working
        case .stale: self = .waiting
        default: return nil
        }
    }
}

/// `side` × `side` pt glyph for SwiftUI. Shape-based, so `ImageRenderer` snapshots draw it.
struct StateGlyphView: View {
    var kind: StateGlyph.Kind
    var side: CGFloat = 8
    /// Increase Contrast: the dashed ring turns solid and the faint idle dot takes the neutral colour (≥ 3:1).
    var contrast = false

    var body: some View {
        let color = kind == .idle && contrast ? TCColor.neutral : StateGlyph.color(kind)
        Group {
            if kind == .retry {
                Image(systemName: StateGlyph.retrySymbol).font(.system(size: side, weight: .semibold))
                    .foregroundStyle(color)
            } else {
                let shape = StateGlyphShape(kind: kind, contrast: contrast)
                ZStack {
                    if let stroke = shape.strokeStyle {
                        shape.stroke(color, style: stroke)
                    } else {
                        shape.fill(color, style: FillStyle(eoFill: true))
                    }
                    if kind == .input { InputMarkShape().fill(Color.black, style: FillStyle(eoFill: true)) }
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

private struct StateGlyphShape: Shape {
    var kind: StateGlyph.Kind
    var contrast: Bool
    var strokeStyle: StrokeStyle? { StateGlyph.drawing(kind, in: CGRect(x: 0, y: 0, width: 8, height: 8), contrast: contrast).stroke }
    func path(in rect: CGRect) -> Path { Path(StateGlyph.drawing(kind, in: rect, contrast: contrast).path) }
}

private struct InputMarkShape: Shape {
    func path(in rect: CGRect) -> Path { Path(StateGlyph.inputMark(in: rect)) }
}

// MARK: - Checks

@MainActor
func runDesignTokenChecks() -> [String] {
    var failures: [String] = []
    var checks = 0
    func check(_ passed: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if !passed() { failures.append("Design tokens: \(name)") }
    }

    // Shapes: every kind but retry draws inside its box at the popover, menu-bar and menu sizes.
    var outside: [String] = []
    for side in [CGFloat(7), 8, 10] {
        let rect = CGRect(x: 3, y: 5, width: side, height: side)
        for kind in StateGlyph.Kind.allCases where kind != .retry {
            let shape = StateGlyph.drawing(kind, in: rect)
            let reach = shape.stroke.map { $0.lineWidth / 2 } ?? 0
            let bounds = shape.path.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach)
            if shape.path.isEmpty || !rect.insetBy(dx: -0.01, dy: -0.01).contains(bounds) { outside.append("\(kind)@\(side)") }
        }
    }
    check(outside.isEmpty, "every glyph but retry is a non-empty shape inside its box: \(outside.joined(separator: ", "))")
    let box = CGRect(x: 0, y: 0, width: 8, height: 8)
    check(StateGlyph.drawing(.retry, in: box).path.isEmpty, "retry is an empty path (callers draw arrow.clockwise)")
    let stroked = StateGlyph.Kind.allCases.filter { StateGlyph.drawing($0, in: box).stroke != nil }
    check(stroked == [.working, .unfinished] && StateGlyph.drawing(.unfinished, in: box).stroke?.dash == [2, 1.5]
          && StateGlyph.drawing(.unfinished, in: box, contrast: true).stroke?.dash.isEmpty == true
          && StateGlyph.drawing(.working, in: box).stroke?.lineWidth == 1.5,
          "rings are 1.5 pt strokes; the dashed ring turns solid under Increase Contrast")
    func filled(_ kind: StateGlyph.Kind, _ x: CGFloat, _ y: CGFloat) -> Bool {
        StateGlyph.drawing(kind, in: box).path.contains(CGPoint(x: x, y: y), using: .evenOdd)
    }
    check(filled(.waiting, 2.5, 4) && !filled(.waiting, 5.5, 4) && filled(.waiting, 7.6, 4) && filled(.waiting, 4, 0.4),
          "log wait is a ring with its left half filled")
    check(filled(.interrupted, 4, 4) && !filled(.interrupted, 4, 2.2) && filled(.interrupted, 4, 0.4) && !filled(.interrupted, 1.85, 4),
          "interrupted is a ring with a clear centred bar")
    check(filled(.recordEvent, 4, 4) && filled(.tool, 4, 0.8) && filled(.input, 4, 4)
          && StateGlyph.drawing(.idle, in: box).path.boundingBoxOfPath.width == 6, "filled shapes; idle is a 6 pt dot in an 8 pt box")
    let mark = StateGlyph.inputMark(in: box).boundingBoxOfPath
    check(!mark.isEmpty && box.contains(mark) && mark.width < 6 && abs(mark.midX - 4) < 0.01 && abs(mark.midY - 4) < 0.01,
          "the input mark is centred inside the disc")
    let rowStates: [SessionDisplayState] = [.input, .retrying, .tool, .working, .waiting, .complete, .interrupted, .unfinished, .idle]
    check(rowStates.allSatisfy { StateGlyph.Kind($0) != nil } && StateGlyph.Kind(.measurement) == nil
          && !rowStates.contains { StateGlyph.Kind($0) == .recordEvent }
          && StateGlyph.Kind(phase: .output) == nil && StateGlyph.Kind(phase: .stale) == .waiting && StateGlyph.Kind(phase: .idle) == nil,
          "no state maps to the record-event glyph; output has no menu-bar mark")

    // Images: exact point size, drawn pixels for every kind (retry through its symbol), both highlight modes.
    var blank: [String] = []
    var sized = true
    for kind in StateGlyph.Kind.allCases {
        for highlighted in [false, true] {
            let image = StateGlyph.image(kind, side: 10, highlighted: highlighted)
            sized = sized && image.size == NSSize(width: 10, height: 10)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { blank.append("\(kind)"); continue }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { image.draw(in: NSRect(x: 0, y: 0, width: 10, height: 10)) }
            NSGraphicsContext.restoreGraphicsState()
            let drawn = (0..<20).contains { x in (0..<20).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 } }
            if !drawn { blank.append("\(kind)\(highlighted ? "/highlighted" : "")") }
        }
    }
    check(sized && blank.isEmpty, "menu images are side × side and draw every kind: \(blank.joined(separator: ", "))")
    // SwiftUI: ImageRenderer (fixture snapshots) draws every glyph in both appearances.
    var unrendered: [String] = []
    for kind in StateGlyph.Kind.allCases {
        for dark in [false, true] {
            let renderer = ImageRenderer(content: StateGlyphView(kind: kind, side: 8).environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            guard let image = renderer.cgImage, image.width == 16, image.height == 16 else { unrendered.append("\(kind)"); continue }
            let rep = NSBitmapImageRep(cgImage: image)
            let drawn = (0..<16).contains { x in (0..<16).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 } }
            if !drawn { unrendered.append("\(kind)\(dark ? "/dark" : "")") }
        }
    }
    check(unrendered.isEmpty, "StateGlyphView renders under ImageRenderer: \(unrendered.joined(separator: ", "))")

    // Colours resolve per appearance and keep their contrast variants.
    func rgba(_ color: NSColor, dark: Bool) -> [CGFloat] {
        var resolved: NSColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let resolved else { return [] }
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
    }
    func near(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.01 } }
    let label = (light: rgba(.labelColor, dark: false), dark: rgba(.labelColor, dark: true))
    check(near(rgba(TCColor.NS.activity, dark: false), [0x24 / 255, 0x8A / 255, 0x3D / 255, 1])
          && near(rgba(TCColor.NS.activity, dark: true), [0x30 / 255, 0xD1 / 255, 0x58 / 255, 1]), "activity green per appearance")
    check(near(rgba(TCColor.NS.warning, dark: false), [0xC8 / 255, 0x64 / 255, 0, 1])
          && near(rgba(TCColor.NS.warning, dark: true), rgba(.systemOrange, dark: true)),
          "warning: a darker orange in light (≥ 3:1 on the light container), systemOrange in dark")
    check(label.light.count == 4 && label.dark.count == 4
          && abs((rgba(TCColor.NS.neutral, dark: false).last ?? 0) - label.light[3] * 0.50) < 0.01
          && abs((rgba(TCColor.NS.neutral, dark: true).last ?? 0) - label.dark[3] * 0.50) < 0.01
          && near(Array(rgba(TCColor.NS.neutral, dark: true).prefix(3)), Array(label.dark.prefix(3))),
          "neutral is the label colour at 0.50 of its opacity, like Color.primary.opacity")
    check(abs((rgba(TCColor.NS.textSecondary(contrast: false), dark: false).last ?? 0) - label.light[3] * 0.66) < 0.01
          && near(rgba(TCColor.NS.textSecondary(contrast: false), dark: true), rgba(.secondaryLabelColor, dark: true))
          && abs((rgba(TCColor.NS.textSecondary(contrast: true), dark: true).last ?? 0) - label.dark[3] * 0.8) < 0.01,
          "secondary text: light primary 0.66, dark system secondary, Increase Contrast primary 0.80")
    check((rgba(TCColor.NS.hairline(contrast: true), dark: false).last ?? 0) > (rgba(TCColor.NS.hairline(contrast: false), dark: false).last ?? 1)
          && (rgba(TCColor.NS.hover(contrast: true), dark: true).last ?? 0) > (rgba(TCColor.NS.hover(contrast: false), dark: true).last ?? 1)
          && (rgba(TCColor.NS.pressed(contrast: false), dark: true).last ?? 0) > (rgba(TCColor.NS.hover(contrast: false), dark: true).last ?? 1)
          && abs((rgba(TCColor.NS.selection(keyWindow: true), dark: false).last ?? 0) - 0.16) < 0.01,
          "contrast variants are stronger; selection is accent 0.16")
    check(TCFont.NS.title.pointSize == 13 && TCFont.NS.meta.pointSize == 11 && TCFont.NS.micro.pointSize == 10
          && TCFont.NS.inputMark(glyphSide: 8).pointSize == 7, "AppKit type scale")
    print("Design token checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
