import CoreGraphics
import Foundation

// Menu bar cat previews from the runner sheet and its manifest (Assets/runner-v2.json).

struct RunnerManifest: Decodable {
    struct Cell: Decodable { let width: Int, height: Int }
    struct Pose: Decodable {
        let pose: String, row: Int, frames: Int
        let durations: [Double]
        let holdSequence: [Double]?
        let doubleEvery: Int?
        let doubleGap: Double?
    }
    struct Glyph: Decodable { let x: Int, y: Int, width: Int, height: Int }
    struct Effect: Decodable { let pose: String, step: Int, glyph: String, x: Int, y: Int }

    let version: Int
    let cell: Cell
    let sheets: [String: String]
    let fxSheets: [String: String]
    let poses: [Pose]
    let glyphs: [String: Glyph]
    let fx: [Effect]
}

struct Runner {
    let manifest: RunnerManifest
    private let sheet: CGImage, fxSheet: CGImage

    init(assets: String) {
        guard let data = FileManager.default.contents(atPath: assets + "/runner-v2.json"),
              let manifest = try? JSONDecoder().decode(RunnerManifest.self, from: data) else { fail("러너 매니페스트를 읽지 못함") }
        guard manifest.version == 3 else { fail("러너 매니페스트 버전이 3이 아님: \(manifest.version)") }
        self.manifest = manifest
        sheet = readPNG(assets + "/" + manifest.sheets["1"]!)
        fxSheet = readPNG(assets + "/" + manifest.fxSheets["1"]!)
    }

    func pose(_ name: String) -> RunnerManifest.Pose {
        guard let pose = manifest.poses.first(where: { $0.pose == name }) else { fail("매니페스트에 자세 없음: \(name)") }
        return pose
    }

    /// Draws one frame at integer `scale` (nearest neighbour), plus the effect glyphs of `fxStep` tinted with `zTint`.
    func draw(_ canvas: Canvas, pose name: String, frame: Int, fxStep: Int?, origin: CGPoint, scale: Int, zTint: CGColor) {
        let pose = pose(name), cell = manifest.cell
        precondition(frame < pose.frames, "\(name) frame \(frame)")
        let art = cropImage(sheet, CGRect(x: frame * cell.width, y: pose.row * cell.height, width: cell.width, height: cell.height))
        canvas.draw(art, CGRect(x: origin.x, y: origin.y, width: CGFloat(cell.width * scale), height: CGFloat(cell.height * scale)),
                    quality: .none)
        guard let step = fxStep else { return }
        for effect in manifest.fx where effect.pose == name && effect.step == step {
            let glyph = manifest.glyphs[effect.glyph]!
            let mask = cropImage(fxSheet, CGRect(x: glyph.x, y: glyph.y, width: glyph.width, height: glyph.height))
            canvas.draw(tinted(mask, zTint), CGRect(x: origin.x + CGFloat(effect.x * scale), y: origin.y + CGFloat(effect.y * scale),
                                                    width: CGFloat(glyph.width * scale), height: CGFloat(glyph.height * scale)),
                        quality: .none)
        }
    }

    /// The effect sheet is an opaque-black mask; the app fills it with the secondary label colour (source-in).
    private func tinted(_ mask: CGImage, _ tint: CGColor) -> CGImage {
        let canvas = Canvas(mask.width, mask.height)
        canvas.context.beginTransparencyLayer(auxiliaryInfo: nil)
        canvas.draw(mask, canvas.bounds, quality: .none)
        canvas.context.setBlendMode(.sourceIn)
        canvas.fill(canvas.bounds, tint)
        canvas.context.endTransparencyLayer()
        return canvas.image()
    }
}

/// Bar and sleep-z colours for a theme (z = secondaryLabelColor over the bar, as in the menu bar fixtures).
private func catColors(_ theme: Theme, bar: UInt32) -> (bar: CGColor, z: CGColor, text: CGColor, idle: CGColor, idleText: CGColor) {
    switch theme {
    case .light: return (color(bar), color(0x787878), color(0x1D1D1F), color(0x000000, 0.06), color(0x6E6E73))
    case .dark: return (color(bar), color(0x9B9B9B), color(0xF5F5F7), color(0xFFFFFF, 0.08), color(0xA1A1A6))
    }
}

/// One cat cycling through the AI-activity poses, with the active state highlighted below.
/// Frame times come from the manifest; only the long sit hold (6–11 s) is shortened to keep the loop short.
/// The run lasts as long as the app's output burst (`RunnerDirector.burst`, 1.2 s).
func catAnimation(_ theme: Theme, runner: Runner, bar: UInt32) -> [(image: CGImage, seconds: Double)] {
    let colors = catColors(theme, bar: bar)
    let states = ["진행·도구", "출력 기록", "입력 필요", "로그 대기", "활동 없음"]
    struct Shot { let state: Int, label: String, pose: String, frame: Int, fx: Int?, seconds: Double }
    var shots: [Shot] = []

    let walk = runner.pose("walk")
    for _ in 0..<4 { for f in 0..<walk.frames { shots.append(Shot(state: 0, label: "걷기", pose: "walk", frame: f, fx: nil, seconds: walk.durations[f])) } }
    let run = runner.pose("run")
    var running = 0.0, frame = 0
    while running < 1.2 - 1e-9 {
        shots.append(Shot(state: 1, label: "달리기", pose: "run", frame: frame, fx: nil, seconds: run.durations[frame]))
        running += run.durations[frame]
        frame = (frame + 1) % run.frames
    }
    let alert = runner.pose("alert")
    for f in 0..<alert.frames { shots.append(Shot(state: 2, label: "정면 앉기", pose: "alert", frame: f, fx: nil, seconds: alert.durations[f])) }
    let sit = runner.pose("sit")
    let blink = sit.durations[1], gap = sit.doubleGap ?? 0.15
    for (frame, seconds) in [(0, 1.4), (1, blink), (0, 1.4), (1, blink), (0, gap), (1, blink), (0, 0.6)] {
        shots.append(Shot(state: 3, label: "앉기 · 깜빡임", pose: "sit", frame: frame, fx: nil, seconds: seconds))
    }
    let sleep = runner.pose("sleep")
    let sleepSteps = (runner.manifest.fx.filter { $0.pose == "sleep" }.map(\.step).max() ?? 0) + 1
    for step in 0..<sleepSteps {
        shots.append(Shot(state: 4, label: "잠", pose: "sleep", frame: step % sleep.frames, fx: step, seconds: sleep.durations[step % sleep.frames]))
    }
    let yawn = runner.pose("yawn")
    shots.append(Shot(state: 0, label: "깨어날 때 하품", pose: "yawn", frame: 0, fx: nil, seconds: yawn.durations[0]))

    let width = 800, height = 400, scale = 10, top = 34
    let cell = runner.manifest.cell
    let chipSize: CGFloat = 22, chipHeight: CGFloat = 46, chipPad: CGFloat = 18, chipGap: CGFloat = 10
    let chipWidths = states.map { Canvas.measure($0, size: chipSize, bold: true) + chipPad * 2 }
    let chipsWidth = chipWidths.reduce(0, +) + chipGap * CGFloat(states.count - 1)
    let accent = color(0x3A4FE0)                     // collar cobalt from the runner palette

    return shots.map { shot in
        let canvas = Canvas(width, height)
        // Rounded like the PNGs. Hard edges only: outside fully transparent (the GIF's transparent index), inside opaque.
        canvas.context.setShouldAntialias(false)
        canvas.fill(canvas.rounded(canvas.bounds, 28), colors.bar)
        canvas.context.setShouldAntialias(true)
        let origin = CGPoint(x: (width - cell.width * scale) / 2, y: top)
        runner.draw(canvas, pose: shot.pose, frame: shot.frame, fxStep: shot.fx, origin: origin, scale: scale, zTint: colors.z)
        canvas.text(shot.label, x: CGFloat(width) / 2, baseline: CGFloat(top + cell.height * scale) + 54, size: 34, bold: true,
                    color: colors.text, align: .center)
        var x = (CGFloat(width) - chipsWidth) / 2
        let y = CGFloat(height) - 36 - chipHeight
        for (index, name) in states.enumerated() {
            let rect = CGRect(x: x, y: y, width: chipWidths[index], height: chipHeight)
            let active = index == shot.state
            canvas.fill(canvas.rounded(rect, chipHeight / 2), active ? accent : colors.idle)
            canvas.text(name, x: rect.midX, baseline: rect.midY + chipSize * 0.36, size: chipSize, bold: true,
                        color: active ? color(0xFFFFFF) : colors.idleText, align: .center)
            x += rect.width + chipGap
        }
        return (canvas.image(), shot.seconds)
    }
}

/// Static specimen of all seven poses on a light and a dark menu bar, on the theme's backdrop.
func posesSheet(_ theme: Theme, runner: Runner, bars: [Theme: UInt32]) -> CGImage {
    let poses: [(pose: String, frame: Int, fx: Int?, name: String, state: String)] = [
        ("walk", 1, nil, "걷기", "진행 · 도구 실행"),
        ("run", 1, nil, "달리기", "출력 기록 직후"),
        ("alert", 0, nil, "정면 앉기", "입력 필요"),
        ("sit", 0, nil, "앉기", "로그 대기"),
        ("sleep", 0, 2, "잠", "10분간 활동 없음"),
        ("yawn", 0, nil, "하품", "깨어날 때 한 번"),
        ("content", 0, nil, "만족", "턴 완료 때 한 번"),
    ]
    let scale = 6, cell = runner.manifest.cell
    let tile = CGSize(width: cell.width * scale + 20, height: cell.height * scale + 20)
    let pad: CGFloat = 40, gap: CGFloat = 20, rowGap: CGFloat = 12
    let width = pad * 2 + CGFloat(poses.count) * tile.width + CGFloat(poses.count - 1) * gap
    let height = pad + tile.height * 2 + rowGap + 96 + pad - 10
    let canvas = Canvas(Int(width), Int(height))
    let look = Look.of(theme)
    look.paintWall(canvas, glowScale: 0.8)
    for (row, barTheme) in [Theme.light, .dark].enumerated() {
        let colors = catColors(barTheme, bar: bars[barTheme]!)
        for (index, item) in poses.enumerated() {
            let rect = CGRect(x: pad + CGFloat(index) * (tile.width + gap), y: pad + CGFloat(row) * (tile.height + rowGap),
                              width: tile.width, height: tile.height)
            canvas.fill(canvas.rounded(rect, 16), colors.bar)
            canvas.stroke(canvas.rounded(rect.insetBy(dx: 0.5, dy: 0.5), 15.5), look.border, width: 1)
            runner.draw(canvas, pose: item.pose, frame: item.frame, fxStep: item.fx, origin: CGPoint(x: rect.minX + 10, y: rect.minY + 10),
                        scale: scale, zTint: colors.z)
        }
    }
    let captionTop = pad + tile.height * 2 + rowGap
    for (index, item) in poses.enumerated() {
        let center = pad + CGFloat(index) * (tile.width + gap) + tile.width / 2
        canvas.text(item.name, x: center, baseline: captionTop + 42, size: 25, bold: true, color: look.text, align: .center)
        canvas.text(item.state, x: center, baseline: captionTop + 74, size: 19, color: look.secondary, align: .center)
    }
    return roundCorners(canvas, radius: 28)
}
