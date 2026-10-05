import Foundation

/// Runner sprite v2, shared by every character: the 30 × 18 cell, part composition with a 1 px charcoal outline,
/// the manifest's timing and effect glyphs, the brand pixel heads and the character registry. Each character's grids
/// live in their own file (`Runner<Name>Art.swift`) exposing `palette` and `poses`; see Assets/runner-v2.md.
enum RunnerArt {
    static let cell = (width: 30, height: 18)

    /// Paint groups, back to front. A merging part does not outline over fills of `mergeInto` groups.
    enum Group { case far, body, near, head }

    struct Part {
        var rows: [String]
        var x = 0, y = 0
        var group = Group.body
        var mergeInto: Set<Group> = []
        var outline = true
    }

    /// One character's frames per pose, frame counts as in the manifest (sit 2, sleep 2, walk 4, run 6, alert 2, yawn 1,
    /// content 2). Frame 0 of every pose is its still frame.
    struct Poses {
        var sit, sleep, walk, run, alert, yawn, content: [[Part]]
        /// Sheet rows in manifest order.
        var ordered: [(name: String, frames: [[Part]])] {
            [("sit", sit), ("sleep", sleep), ("walk", walk), ("run", run), ("alert", alert), ("yawn", yawn), ("content", content)]
        }
    }

    /// Every character, registered once here. Output: `Assets/<sheet>@1x.png` and `@2x.png`; the cat keeps runner-v2.
    typealias CharacterArt = (id: String, sheet: String, palette: [Character: RGBA], poses: Poses)
    static let characters: [CharacterArt] = [
        ("cat", "runner-v2", RunnerCatArt.palette, RunnerCatArt.poses),
        ("dog", "runner-dog", RunnerDogArt.palette, RunnerDogArt.poses),
        ("hamster", "runner-hamster", RunnerHamsterArt.palette, RunnerHamsterArt.poses),
        ("penguin", "runner-penguin", RunnerPenguinArt.palette, RunnerPenguinArt.poses),
        ("robot", "runner-robot", RunnerRobotArt.palette, RunnerRobotArt.poses),
    ]

    static func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [(Int, Int)] {
        var points: [(Int, Int)] = []
        var x = x0, y = y0
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1, dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            points.append((x, y))
            if x == x1 && y == y1 { return points }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    // MARK: Timing (manifest v3, the animator's only source). Seconds; motion shows state, never speed.

    /// `doubleEvery` and `doubleGap` come together: every Nth blink closes, opens for `doubleGap` and closes again.
    struct Timing { var durations: [Double]; var holdSequence: [Double] = []; var doubleEvery: Int? = nil; var doubleGap: Double? = nil }

    static let timing: [String: Timing] = [
        // Irregular blink: holds cycle through the sequence, every 4th blink is double (closed 0.12 · open 0.15 · closed 0.12).
        "sit": Timing(durations: [6.0, 0.12], holdSequence: [6.0, 9.5, 4.5, 11.0, 7.5], doubleEvery: 4, doubleGap: 0.15),
        // Breathing steps A (frame 0, no z) · B (frame 1 + zS) · C (frame 0 + zL), 1.6 s each.
        "sleep": Timing(durations: [1.6, 1.6]),
        "walk": Timing(durations: Array(repeating: 0.15, count: 4)),
        "run": Timing(durations: Array(repeating: 1.0 / 14, count: 6)),
        "alert": Timing(durations: [2.4, 0.3]),
        "yawn": Timing(durations: [0.6]),
        // One-shot: frame 0 0.5 s → frame 1 0.45 s → frame 0 0.55 s (the second hold).
        "content": Timing(durations: [0.5, 0.45], holdSequence: [0.5, 0.55]),
    ]

    // MARK: Effects: label-coloured template glyphs, alpha only (K-2)

    static let glyphs: [(name: String, rows: [String])] = [
        ("zS", ["###", ".#.", "#..", "###"]),
        ("zL", ["####", "..#.", ".#..", "####"]),
    ]

    /// Cell coordinates. Step 0 of the sleep cycle draws no z; the still and deep-sleep frame uses the last step.
    /// zS sits one row above the spec's y 4 so it keeps a 1 px gap (8-neighbour) from the right ear's outline.
    static let fx: [(pose: String, step: Int, glyph: String, x: Int, y: Int)] = [
        ("sleep", 1, "zS", 22, 3),
        ("sleep", 2, "zL", 25, 0),
    ]

    // MARK: Pixel heads (B-3, B-2): 10 × 9 head + 1 px outline = 12 × 11

    /// Input head for the 9-row slot: `headAlert` without the row under the eyes, so the raised ears and the wide eyes
    /// both stay. Dropping the forehead row instead would put the inner-ear shade on the eyes like brows.
    static let headAlertShort = RunnerCatArt.headAlert.enumerated().filter { $0.offset != 7 }.map(\.element)

    static let heads: [(name: String, rows: [String])] = [
        ("normal", RunnerCatArt.head), ("blink", RunnerCatArt.headBlink), ("alert", headAlertShort),
        ("sleep", RunnerCatArt.headSleep + [RunnerCatArt.head.last!]),
    ]

    static let headSize = (width: 12, height: 11)

    static func headGrid(_ rows: [String]) -> [[Character]] {
        compose([Part(rows: rows, x: 1, y: 1, group: .head)], width: headSize.width, height: headSize.height)
    }

    // MARK: Composition

    /// `name` (character, pose, frame) only labels the isolated-pixel error.
    static func compose(_ parts: [Part], width w: Int = cell.width, height h: Int = cell.height, name: String = "") -> [[Character]] {
        var color = Array(repeating: Array(repeating: Character("."), count: w), count: h)
        var owner = Array(repeating: Array(repeating: Group?.none, count: w), count: h) // nil = empty or outline
        for part in parts {
            var mine: [Int: Character] = [:]
            for (r, row) in part.rows.enumerated() {
                for (c, ch) in row.enumerated() where ch != "." {
                    let x = part.x + c, y = part.y + r
                    precondition(x >= 0 && y >= 0 && x < w && y < h, "part out of cell at \(x),\(y)")
                    mine[y * w + x] = ch
                }
            }
            if part.outline {
                for index in mine.keys.sorted() {
                    let x = index % w, y = index / w
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                        guard nx >= 0, ny >= 0, nx < w, ny < h, mine[ny * w + nx] == nil else { continue }
                        if let group = owner[ny][nx], part.mergeInto.contains(group) { continue }
                        color[ny][nx] = "K"; owner[ny][nx] = nil
                    }
                }
            }
            for (index, ch) in mine { color[index / w][index % w] = ch; owner[index / w][index % w] = part.group }
        }
        // An outline pixel boxed in by fill on all four sides reads as a stray dot (a hole on dark bars).
        for y in 1..<h - 1 { for x in 1..<w - 1 where color[y][x] == "K" {
            let around = [color[y][x - 1], color[y][x + 1], color[y - 1][x], color[y + 1][x]]
            if around.allSatisfy("WSGCT".contains) { fatalError("isolated outline pixel at \(x),\(y) \(name)") }
        }}
        return color
    }

    static func bitmap(_ grid: [[Character]], palette: [Character: RGBA] = Palette.tokens) -> Bitmap {
        var out = Bitmap(width: grid[0].count, height: grid.count)
        for (y, row) in grid.enumerated() { for (x, ch) in row.enumerated() where ch != "." { out[x, y] = palette[ch]! } }
        return out
    }

    /// Opaque 1-bit mask (black, alpha 255) of `#` cells.
    static func mask(_ rows: [String]) -> Bitmap {
        var out = Bitmap(width: rows.map(\.count).max()!, height: rows.count)
        for (y, row) in rows.enumerated() { for (x, ch) in row.enumerated() where ch == "#" { out[x, y] = RGBA(r: 0, g: 0, b: 0) } }
        return out
    }
}
