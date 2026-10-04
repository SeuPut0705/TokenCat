import AppKit

// Deterministic asset generator for TokenCat. No network, no image-generation service.
// Usage (from the repository root):
//   mkdir -p work && swiftc -O Assets/Generator/*.swift -o work/asset-generator && work/asset-generator [runner] [head] [icon] [previews] [system] [ascii]
// With no arguments it writes runner, head, icon and previews. `system` (after ./build.sh) records how macOS draws the bundle icon.
let root = FileManager.default.currentDirectoryPath
let targets = Set(CommandLine.arguments.dropFirst())
let all = targets.isEmpty

func path(_ relative: String) -> String { root + "/" + relative }
func number(_ value: Double) -> String { String(format: "%g", (value * 10000).rounded() / 10000) }
func list(_ values: [Double]) -> String { "[" + values.map(number).joined(separator: ", ") + "]" }

if all || targets.contains("runner") {
    // Rows follow the manifest; unused cells stay fully transparent.
    let columns = RunnerArt.poses.map(\.frames.count).max()!
    var sheet = Bitmap(width: columns * RunnerArt.cell.width, height: RunnerArt.poses.count * RunnerArt.cell.height)
    var poses: [String] = []
    for (row, pose) in RunnerArt.poses.enumerated() {
        for (column, frame) in pose.frames.enumerated() {
            sheet.draw(RunnerArt.bitmap(RunnerArt.compose(frame)), x: column * RunnerArt.cell.width, y: row * RunnerArt.cell.height)
        }
        let timing = RunnerArt.timing[pose.name]!
        precondition(timing.durations.count == pose.frames.count, "\(pose.name) timing")
        var entry = "{\"pose\": \"\(pose.name)\", \"row\": \(row), \"frames\": \(pose.frames.count), \"durations\": \(list(timing.durations))"
        if !timing.holdSequence.isEmpty { entry += ", \"holdSequence\": \(list(timing.holdSequence))" }
        if let every = timing.doubleEvery { entry += ", \"doubleEvery\": \(every)" }
        if let gap = timing.doubleGap { entry += ", \"doubleGap\": \(number(gap))" }
        precondition((timing.doubleEvery == nil) == (timing.doubleGap == nil), "\(pose.name) double blink")
        poses.append("    " + entry + "}")
    }
    PNG.write(sheet, to: path("Assets/runner-v2@1x.png"))
    PNG.write(sheet.scaledNearest(2), to: path("Assets/runner-v2@2x.png"))

    // Effect glyph atlas: left to right with a 1 px gap, alpha 0/255.
    var glyphs: [String] = [], x = 0
    var atlas = Bitmap(width: RunnerArt.glyphs.reduce(-1) { $0 + $1.rows[0].count + 1 }, height: RunnerArt.glyphs.map(\.rows.count).max()!)
    for glyph in RunnerArt.glyphs {
        let mask = RunnerArt.mask(glyph.rows)
        atlas.draw(mask, x: x, y: 0)
        glyphs.append("    \"\(glyph.name)\": {\"x\": \(x), \"y\": 0, \"width\": \(mask.width), \"height\": \(mask.height)}")
        x += mask.width + 1
    }
    PNG.write(atlas, to: path("Assets/runner-v2-fx@1x.png"))
    PNG.write(atlas.scaledNearest(2), to: path("Assets/runner-v2-fx@2x.png"))
    let fx = RunnerArt.fx.map { "    {\"pose\": \"\($0.pose)\", \"step\": \($0.step), \"glyph\": \"\($0.glyph)\", \"x\": \($0.x), \"y\": \($0.y)}" }
    let manifest = """
    {
      "version": 3,
      "cell": {"width": \(RunnerArt.cell.width), "height": \(RunnerArt.cell.height)},
      "sheets": {"1": "runner-v2@1x.png", "2": "runner-v2@2x.png"},
      "fxSheets": {"1": "runner-v2-fx@1x.png", "2": "runner-v2-fx@2x.png"},
      "poses": [
    \(poses.joined(separator: ",\n"))
      ],
      "glyphs": {
    \(glyphs.joined(separator: ",\n"))
      },
      "fx": [
    \(fx.joined(separator: ",\n"))
      ]
    }

    """
    try! manifest.write(toFile: path("Assets/runner-v2.json"), atomically: true, encoding: .utf8)
}

if all || targets.contains("head") {
    for head in RunnerArt.heads {
        let art = RunnerArt.bitmap(RunnerArt.headGrid(head.rows))
        PNG.write(art, to: path("Assets/app-head-\(head.name)@1x.png"))
        PNG.write(art.scaledNearest(2), to: path("Assets/app-head-\(head.name)@2x.png"))
    }
}

if all || targets.contains("icon") {
    PNG.write(IconArt.master(mark: PNG.read(path("Assets/app-mark-v1.png"))), to: path("Assets/app-icon-v2-1024.png"))
    PNG.write(IconArt.small(size: 16), to: path("Assets/app-icon-v2-16.png"))
    PNG.write(IconArt.small(size: 32), to: path("Assets/app-icon-v2-32.png"))
}

if all || targets.contains("previews") {
    RunnerPreview.contactSheet(to: path("work/runner-v2-contact-8x.png"))
    RunnerPreview.menuBar(to: path("work/runner-v2-menubar.png"), zoomPath: path("work/runner-v2-menubar-3x.png"))
    RunnerPreview.heads(to: path("work/app-head-preview.png"))
    IconPreview.sheet(iconset: path("work/TokenCat.iconset"), to: path("work/app-icon-v2-preview.png"))
    IconPreview.v3(current: path("Assets"), to: path("work/app-icon-v3-preview.png"))
}

if targets.contains("system") {
    IconPreview.system(app: path("dist/TokenCat.app"), to: path("work/app-icon-v2-system-small.png"))
}

if targets.contains("ascii") {
    for pose in RunnerArt.poses {
        for (index, frame) in pose.frames.enumerated() {
            print("\(pose.name) \(index)")
            RunnerArt.compose(frame).forEach { print(String($0)) }
        }
    }
    for head in RunnerArt.heads {
        print("head \(head.name)")
        RunnerArt.headGrid(head.rows).forEach { print(String($0)) }
    }
}
