import AppKit

// Deterministic asset generator for TokenCat. No network, no image-generation service.
// Usage (from the repository root):
//   mkdir -p work && swiftc -O Assets/Generator/*.swift -o work/asset-generator && work/asset-generator [runner] [icon] [previews] [system] [ascii]
// With no arguments it writes runner, icon and previews. `system` (after ./build.sh) records how macOS draws the bundle icon.
let root = FileManager.default.currentDirectoryPath
let targets = Set(CommandLine.arguments.dropFirst())
let all = targets.isEmpty

func path(_ relative: String) -> String { root + "/" + relative }

if all || targets.contains("runner") {
    // Rows follow the manifest; unused cells stay fully transparent.
    let columns = RunnerArt.poses.map(\.frames.count).max()!
    var sheet = Bitmap(width: columns * RunnerArt.cell.width, height: RunnerArt.poses.count * RunnerArt.cell.height)
    var poses: [String] = []
    for (row, pose) in RunnerArt.poses.enumerated() {
        for (column, frame) in pose.frames.enumerated() {
            sheet.draw(RunnerArt.bitmap(RunnerArt.compose(frame)), x: column * RunnerArt.cell.width, y: row * RunnerArt.cell.height)
        }
        let durations = RunnerArt.durations[pose.name]!.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        poses.append("    {\"pose\": \"\(pose.name)\", \"row\": \(row), \"frames\": \(pose.frames.count), \"durations\": [\(durations)]}")
    }
    PNG.write(sheet, to: path("Assets/runner-v2@1x.png"))
    PNG.write(sheet.scaledNearest(2), to: path("Assets/runner-v2@2x.png"))
    let manifest = """
    {
      "version": 2,
      "cell": {"width": \(RunnerArt.cell.width), "height": \(RunnerArt.cell.height)},
      "sheets": {"1": "runner-v2@1x.png", "2": "runner-v2@2x.png"},
      "poses": [
    \(poses.joined(separator: ",\n"))
      ]
    }

    """
    try! manifest.write(toFile: path("Assets/runner-v2.json"), atomically: true, encoding: .utf8)
}

if all || targets.contains("icon") {
    PNG.write(IconArt.master(mark: PNG.read(path("Assets/app-mark-v1.png"))), to: path("Assets/app-icon-v2-1024.png"))
    PNG.write(IconArt.small(size: 16), to: path("Assets/app-icon-v2-16.png"))
    PNG.write(IconArt.small(size: 32), to: path("Assets/app-icon-v2-32.png"))
}

if all || targets.contains("previews") {
    RunnerPreview.contactSheet(to: path("work/runner-v2-contact-8x.png"))
    RunnerPreview.menuBar(to: path("work/runner-v2-menubar.png"), zoomPath: path("work/runner-v2-menubar-3x.png"))
    IconPreview.sheet(iconset: path("work/TokenCat.iconset"), to: path("work/app-icon-v2-preview.png"))
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
}
