import Foundation

/// Runner sprite v2. Every frame is composed from character grids on a 30 × 18 pixel cell:
/// fill-only parts are stacked back to front and each part gets a 1 px charcoal outline,
/// so far legs are cut by the body's outline while near legs and the tail merge into it.
/// Colours come from `Palette` only.
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

    // MARK: Parts (fill only; K = eye, last head row = collar)

    static let head = [
        ".W......W.",
        ".WW....WW.",
        ".WSWWWWSW.",
        "WWWWWWWWWW",
        "WWKWWWWKWW",
        "WWKWWWWKWW",
        "WWWWWWWWWW",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    static let headBlink = [
        ".W......W.",
        ".WW....WW.",
        ".WSWWWWSW.",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WKKWWWWKKW",
        "WWWWWWWWWW",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    /// Resting on the body, so no collar row.
    static let headSleep = Array(headBlink.dropLast())

    /// Ears up and eyes wide (the front-facing input sit).
    static let headAlert = [
        ".W......W.",
        ".WW....WW.",
        ".WW....WW.",
        ".WSWWWWSW.",
        "WWWWWWWWWW",
        "WKKWWWWKKW",
        "WKKWWWWKKW",
        "WWWWWWWWWW",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    /// Wake-up yawn: eyes shut, mouth open.
    static let headYawn = [
        ".W......W.",
        ".WW....WW.",
        ".WSWWWWSW.",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WKKWWWWKKW",
        "WWWWKKWWWW",
        ".WWWKKWWW.",
        "..CCCTCC..",
    ]

    static let body = [
        "..WWWWWWWW...",
        ".WWWWWWWWWWW.",
        "WWWWWWWWWWWWW",
        "WWWWWWWWWWWWW",
        ".WWWWWWWWWWWW",
        "..SSSSSSSSSS.",
    ]

    /// Run extension (frame 1): one pixel longer at the back.
    static let bodyLong = [
        "..WWWWWWWWW...",
        ".WWWWWWWWWWWW.",
        "WWWWWWWWWWWWWW",
        "WWWWWWWWWWWWWW",
        ".WWWWWWWWWWWWW",
        "..SSSSSSSSSSS.",
    ]

    /// Run gather (frame 4): one pixel shorter with the back peaked.
    static let bodyArch = [
        "....WWWW....",
        "..WWWWWWWW..",
        "WWWWWWWWWWWW",
        "WWWWWWWWWWWW",
        ".WWWWWWWWWWW",
        "..SSSSSSSSS.",
    ]

    static let tailUp = [
        "..WW",
        ".W..",
        ".W..",
        ".W..",
        "..W.",
        "...W",
        "...W",
    ]

    /// Walk frames 2–3: the tip leans back once per cycle.
    static let tailSway = [
        ".WW.",
        ".W..",
        ".W..",
        ".W..",
        "..W.",
        "...W",
        "...W",
    ]

    /// Streaming tails for the run, three frames each so the tip waves at 2.33 Hz. Anchored like `tailUp`.
    static let tailStream = [
        "....",
        "....",
        "W...",
        ".W..",
        ".WW.",
        "...W",
        "...W",
    ]

    static let tailWave = [
        "....",
        "....",
        "....",
        "WW..",
        "..W.",
        "..WW",
        "...W",
    ]

    // MARK: Strides

    /// Two-pixel leg from the body's last row to the foot; `dx` moves the foot, `lift` raises it.
    struct Leg { var dx: Int; var lift = 0 }
    struct Pair { var near: Leg; var far: Leg }
    /// `tailX` is relative to `bodyX`, so a longer or shorter body carries its tail along.
    struct Stride {
        var dy = 0; var front: Pair; var hind: Pair; var tail = tailUp; var tailX = -2
        var body = RunnerArt.body; var bodyX = 7; var headY = 2
    }

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

    static func leg(_ x: Int, _ top: Int, _ leg: Leg, near: Bool) -> Part {
        var rows = Array(repeating: Array(repeating: Character("."), count: cell.width), count: cell.height)
        let paint: Character = near ? "W" : "G"
        // The upper leg stays vertical for one row so the joint reads, then angles to the foot.
        for (px, py) in [(x, top)] + line(x, top + 1, x + leg.dx, 16 - leg.lift) {
            rows[py][px] = paint; rows[py][px + 1] = paint
        }
        return Part(rows: rows.map { String($0) }, group: near ? .near : .far, mergeInto: near ? [.body] : [])
    }

    static let frontX = 18, hindX = 9

    static func parts(_ s: Stride) -> [Part] {
        let top = 12 + s.dy
        return [
            leg(hindX + 1, top, s.hind.far, near: false),
            leg(frontX - 1, top, s.front.far, near: false),
            Part(rows: s.body, x: s.bodyX, y: 7 + s.dy),
            Part(rows: s.tail, x: s.bodyX + s.tailX, y: 2 + s.dy, mergeInto: [.body]),
            leg(hindX, top, s.hind.near, near: true),
            leg(frontX, top, s.front.near, near: true),
            Part(rows: head, x: 18, y: s.headY + s.dy, group: .head, mergeInto: [.body]),
        ]
    }

    /// (near dx, near lift, far dx, far lift)
    static func pair(_ n: Int, _ nl: Int, _ f: Int, _ fl: Int) -> Pair {
        Pair(near: Leg(dx: n, lift: nl), far: Leg(dx: f, lift: fl))
    }

    static let walk: [Stride] = [
        Stride(front: pair(2, 0, -1, 0), hind: pair(-2, 0, 1, 0)),
        Stride(dy: -1, front: pair(0, 0, 0, 1), hind: pair(0, 1, 0, 0)),
        Stride(front: pair(-2, 0, 1, 0), hind: pair(2, 0, -1, 0), tail: tailSway),
        Stride(dy: -1, front: pair(0, 1, 0, 0), hind: pair(0, 0, 0, 1), tail: tailSway),
    ]

    /// Push-off, extension (long body), front touchdown, front stance, gathered (arched, raised), hind touchdown.
    static let run: [Stride] = [
        Stride(front: pair(2, 2, 1, 2), hind: pair(-3, 0, -2, 1), tail: tailStream, tailX: -3),
        Stride(dy: -1, front: pair(4, 2, 3, 2), hind: pair(-4, 2, -3, 2), tail: tailStream, tailX: -3, body: bodyLong, bodyX: 6),
        Stride(front: pair(2, 0, 3, 1), hind: pair(-3, 2, -2, 2), tail: tailStream, tailX: -3),
        Stride(front: pair(0, 0, 1, 0), hind: pair(-1, 2, 0, 2), tail: tailWave, tailX: -3),
        Stride(dy: -1, front: pair(-2, 1, -1, 1), hind: pair(2, 1, 1, 2), tail: tailWave, tailX: -3, body: bodyArch, bodyX: 8),
        Stride(front: pair(-1, 2, 0, 2), hind: pair(1, 0, 2, 0), tail: tailWave, tailX: -3),
    ]

    // MARK: Still poses, drawn whole. W/S body, t tail and n near limb (merge into the body),
    // f far limb. The head is placed on top. The sleep z is not art: it is the fx mask below.

    struct Still { var rows: [String]; var head: [String]; var headX = 18; var headY = 3 }

    static func parts(_ still: Still) -> [Part] {
        func pick(_ keep: Set<Character>, as paint: Character? = nil) -> [String] {
            still.rows.map { String($0.map { keep.contains($0) ? (paint ?? $0) : "." }) }
        }
        return [
            Part(rows: pick(["f"], as: "G"), group: .far),
            Part(rows: pick(["W", "S"])),
            Part(rows: pick(["t"], as: "W"), mergeInto: [.body]),
            Part(rows: pick(["n"], as: "W"), group: .near, mergeInto: [.body]),
            Part(rows: still.head, x: still.headX, y: still.headY, group: .head, mergeInto: [.body]),
        ]
    }

    static let empty = Array(repeating: String(repeating: ".", count: 30), count: 10)

    //                     0         1         2
    //                     012345678901234567890123456789
    static let sitRows = Array(empty[0..<9]) + [
        "..............WWWW............",
        "............WWWWWWW...........", // 10
        "...........WWWWWWWWW..........",
        "..........WWWWWWWWWWWW........",
        "..........WWWWWWWWWWfnn.......",
        "..........WWWWWWWWWWfnn.......",
        "...t......WWWWWWWWWWfnn.......", // 15
        "...ttttttt.SSSSSnnn.fnnn......",
        "..............................",
    ]

    /// Turn-complete sit: the tail stands up behind the back instead of lying on the ground.
    static let contentRows = Array(empty[0..<5]) + [
        ".........t....................", // 5
        "........t.....................",
        "........t.....................",
        "........t.....................",
        "........t.....WWWW............",
        "........t...WWWWWWW...........", // 10
        "........t..WWWWWWWWW..........",
        "........t.WWWWWWWWWWWW........",
        "........t.WWWWWWWWWWfnn.......",
        ".........tWWWWWWWWWWfnn.......",
        "..........WWWWWWWWWWfnn.......", // 15
        "...........SSSSSnnn.fnnn......",
        "..............................",
    ]

    static let sleepRows = empty + [
        "...........WWWWW..............", // 10
        ".........WWWWWWWWW............",
        "........WWWWWWWWWWW...........",
        ".......WWWWWWWWWWWWW..........",
        ".......WWWWWWWWWWWWW..........",
        "...t...WWWWWWWWWWWWW..........", // 15
        "...tttt.SSSSSSSSSSSS..........",
        "..............................",
    ]

    /// Front-facing sit for input: ears up, both eyes on the viewer, tail curled at the side. The paw split is a
    /// 1 px shade in the bottom two rows only (a 2 px band down the chest read as a necktie under the collar),
    /// in column 23 right under the collar tag so tag and split line up.
    static let alertRows = empty + [
        "...................WWWWWWWW...", // 10
        "..................WWWWWWWWWW..",
        ".................WWWWWWWWWWWW.",
        "...............t.WWWWWWWWWWWW.",
        "..............t..WWWWWWWWWWWW.",
        "..............t..WWWWnnSnWWWW.", // 15
        "...............ttWWWWnnSnWWWW.",
        "..............................",
    ]

    /// Frame 1 of the input sit: the tail tip rises one row.
    static let alertFlick = Array(alertRows[0..<12]) + [
        "..............t..WWWWWWWWWWWW.",
        "..............t..WWWWWWWWWWWW.",
        "..............t..WWWWWWWWWWWW.",
    ] + alertRows[15...]

    /// Inhale raises the back one row.
    static func breathe(_ rows: [String]) -> [String] {
        var grid = rows.map(Array.init)
        for x in 0..<cell.width where grid[10][x] == "W" { grid[9][x] = "W" }
        return grid.map { String($0) }
    }

    static let sit = [Still(rows: sitRows, head: head), Still(rows: sitRows, head: headBlink)]
    static let sleep = [Still(rows: sleepRows, head: headSleep, headX: 17, headY: 9),
                        Still(rows: breathe(sleepRows), head: headSleep, headX: 17, headY: 9)]
    static let alert = [Still(rows: alertRows, head: headAlert, headY: 1), Still(rows: alertFlick, head: headAlert, headY: 1)]
    static let yawn = [Still(rows: sitRows, head: headYawn)]
    static let content = [Still(rows: contentRows, head: head), Still(rows: contentRows, head: headBlink)]

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
    static let headAlertShort = headAlert.enumerated().filter { $0.offset != 7 }.map(\.element)

    static let heads: [(name: String, rows: [String])] = [
        ("normal", head), ("blink", headBlink), ("alert", headAlertShort), ("sleep", headSleep + [head.last!]),
    ]

    static let headSize = (width: 12, height: 11)

    static func headGrid(_ rows: [String]) -> [[Character]] {
        compose([Part(rows: rows, x: 1, y: 1, group: .head)], width: headSize.width, height: headSize.height)
    }

    // MARK: Composition

    static func compose(_ parts: [Part], width w: Int = cell.width, height h: Int = cell.height) -> [[Character]] {
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
            if around.allSatisfy("WSGCT".contains) { fatalError("isolated outline pixel at \(x),\(y)") }
        }}
        return color
    }

    static func bitmap(_ grid: [[Character]]) -> Bitmap {
        var out = Bitmap(width: grid[0].count, height: grid.count)
        for (y, row) in grid.enumerated() { for (x, ch) in row.enumerated() where ch != "." { out[x, y] = Palette.tokens[ch]! } }
        return out
    }

    /// Opaque 1-bit mask (black, alpha 255) of `#` cells.
    static func mask(_ rows: [String]) -> Bitmap {
        var out = Bitmap(width: rows.map(\.count).max()!, height: rows.count)
        for (y, row) in rows.enumerated() { for (x, ch) in row.enumerated() where ch == "#" { out[x, y] = RGBA(r: 0, g: 0, b: 0) } }
        return out
    }

    /// Sheet rows in manifest order. Frame 0 of every pose is its still frame.
    static let poses: [(name: String, frames: [[Part]])] = [
        ("sit", sit.map(parts)),
        ("sleep", sleep.map(parts)),
        ("walk", walk.map(parts)),
        ("run", run.map(parts)),
        ("alert", alert.map(parts)),
        ("yawn", yawn.map(parts)),
        ("content", content.map(parts)),
    ]
}
