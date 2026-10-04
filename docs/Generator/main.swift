import CoreGraphics
import Foundation

// README preview images for TokenCat. Run from the repository root after ./build.sh:
//   mkdir -p work && swiftc -O docs/Generator/*.swift -o work/docs-generator && work/docs-generator
// Options: --app <TokenCat.app or its binary> (default dist/TokenCat.app), --out <dir> (default docs/images).
// Inputs are synthetic only: --snapshot-fixtures, --snapshot-menubar --fixtures, --snapshot-settings --fixtures and Assets/.

var temporary: URL?

func fail(_ message: String) -> Never {
    if let temporary { try? FileManager.default.removeItem(at: temporary) }
    FileHandle.standardError.write(Data(("docs-generator: " + message + "\n").utf8))
    exit(1)
}

let root = FileManager.default.currentDirectoryPath
guard FileManager.default.fileExists(atPath: root + "/Package.swift"),
      FileManager.default.fileExists(atPath: root + "/Assets/runner-v2.json") else { fail("저장소 루트에서 실행하세요") }

var appPath = "dist/TokenCat.app", outPath = "docs/images"
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    guard let value = arguments.first else { fail("값이 없는 옵션: \(flag)") }
    arguments.removeFirst()
    switch flag {
    case "--app": appPath = value
    case "--out": outPath = value
    default: fail("알 수 없는 옵션: \(flag)")
    }
}
func absolute(_ path: String) -> String { path.hasPrefix("/") ? path : root + "/" + path }
let binary = appPath.hasSuffix(".app") ? absolute(appPath) + "/Contents/MacOS/TokenCat" : absolute(appPath)
let out = absolute(outPath), assets = root + "/Assets"
guard FileManager.default.isExecutableFile(atPath: binary) else { fail("앱 실행 파일이 없음: \(binary). ./build.sh로 먼저 빌드하세요.") }

// 1. Synthetic snapshots into a private temporary folder (removed at the end, also on failure).
let snapshots = FileManager.default.temporaryDirectory.appendingPathComponent("tokencat-docs-" + UUID().uuidString)
temporary = snapshots
try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
func snap(_ name: String) -> String { snapshots.appendingPathComponent(name).path }

runSnapshot(binary, ["--snapshot-fixtures", snap("fixtures")])
runSnapshot(binary, ["--snapshot-menubar", snap("menubar-two-line.png"), "--fixtures"])
runSnapshot(binary, ["--snapshot-menubar", snap("menubar-one-line.png"), "--fixtures", "--inline"])
runSnapshot(binary, ["--snapshot-menubar", snap("menubar-minimal.png"), "--fixtures", "--minimal"])
let panes = ["general", "menubar", "cat", "telemetry", "about"]
for pane in panes {
    runSnapshot(binary, ["--snapshot-settings", snap("settings-\(pane)-dark.png"), "--pane", pane, "--fixtures"])
    runSnapshot(binary, ["--snapshot-settings", snap("settings-\(pane)-light.png"), "--pane", pane, "--fixtures", "--light"])
}

func fixture(_ name: String) -> FixtureSheet { FixtureSheet(snap("fixtures/\(name).png")) }
let twoLine = MenuMatrix(snap("menubar-two-line.png"))
let oneLine = MenuMatrix(snap("menubar-one-line.png"))
let minimal = MenuMatrix(snap("menubar-minimal.png"))
let runner = Runner(assets: assets)

// 2. Compose.
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
var written: [String] = []
func save(_ image: CGImage, _ name: String) { writePNG(image, out + "/" + name); written.append(name) }

let inputNeeded = fixture("input-needed")
let features: [(name: String, sheet: FixtureSheet, region: FixtureSheet.Region)] = [
    ("popover-flow", inputNeeded, .top),
    ("popover-sessions", fixture("context-limit"), .section(1)),   // 요청 tok/s on a Claude Code row, as the app reports it
    ("popover-subagents", fixture("grouped-children"), .section(1)),
    ("popover-detail", fixture("detail-open"), .section(1)),
    ("popover-limits", fixture("usage-limits"), .all),
    ("popover-empty", fixture("empty"), .through(1)),
    ("popover-onboarding", fixture("onboarding"), .card(0)),
]

for theme in Theme.allCases {
    let suffix = "-\(theme.rawValue).png"
    var images: [String: CGImage] = [:]
    for pane in panes { images[pane] = readPNG(snap("settings-\(pane)-\(theme.rawValue).png")) }
    // input-needed has two input sessions and one working session: the app's item reads "? 3".
    save(hero(theme, popover: inputNeeded, menu: minimal, window: images["cat"]!), "hero" + suffix)
    for feature in features { save(featureShot(theme, feature.sheet, feature.region), feature.name + suffix) }
    save(menubarLayouts(theme, minimal: minimal, twoLine: twoLine, oneLine: oneLine), "menubar-layouts" + suffix)
    save(menubarStates(theme, minimal: minimal), "menubar-states" + suffix)
    save(architecture(theme, menu: minimal, assets: assets), "architecture" + suffix)
    save(settingsCollage(theme, panes: images), "settings" + suffix)
    save(iconShowcase(theme, assets: assets), "app-icon" + suffix)
    save(posesSheet(theme, runner: runner, bars: twoLine.bar), "poses" + suffix)
    writeGIF(catAnimation(theme, runner: runner, bar: twoLine.bar[theme]!), out + "/cat-\(theme.rawValue).gif")
    written.append("cat-\(theme.rawValue).gif")
}
save(downscale(readPNG(assets + "/app-icon-v2-1024.png"), to: 256), "icon.png") // README header, shown at 128 pt

try? FileManager.default.removeItem(at: snapshots)
temporary = nil

// 3. Report.
var total = 0
for name in written.sorted() {
    let path = out + "/" + name
    let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    total += bytes
    let image = readPNG(path)
    print(name.padding(toLength: 30, withPad: " ", startingAt: 0) + String(format: "%5d × %-5d %9d bytes", image.width, image.height, bytes))
}
print("\(written.count) files, \(total) bytes → \(outPath)")
