import Foundation

/// Runner sprite v2. Every frame is composed from character grids on a 30 × 18 pixel cell:
/// fill-only parts are stacked back to front and each part gets a 1 px charcoal outline,
/// so far legs are cut by the body's outline while near legs and the tail merge into it.
enum RunnerArt {
    static let cell = (width: 30, height: 18)

    /// Character palette tokens (sRGB). Documented in Assets/runner-v2.md.
    static let palette: [Character: RGBA] = [
        "K": RGBA(hex: 0x24262D), // outline, eyes
        "W": RGBA(hex: 0xF8F9FB), // fur
        "S": RGBA(hex: 0xC4C9D3), // shade: inner ear, belly
        "G": RGBA(hex: 0xA3A9B6), // far legs
        "C": RGBA(hex: 0x3A4FE0), // collar (indigo cobalt, not systemBlue)
        "T": RGBA(hex: 0x9DABFF), // collar tag
    ]

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

    static let headSleep = [
        ".W......W.",
        ".WW....WW.",
        ".WSWWWWSW.",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WKKWWWWKKW",
        "WWWWWWWWWW",
        ".WWWWWWWW.",
    ]

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

    static let body = [
        "..WWWWWWWW...",
        ".WWWWWWWWWWW.",
        "WWWWWWWWWWWWW",
        "WWWWWWWWWWWWW",
        ".WWWWWWWWWWWW",
        "..SSSSSSSSSS.",
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

    /// Streaming tails for the run, alternating so the tip waves. Anchored like `tailUp`.
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
    struct Stride { var dy = 0; var front: Pair; var hind: Pair; var tail = tailUp; var tailX = 5; var head = RunnerArt.head; var headY = 2 }

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
            Part(rows: body, x: 7, y: 7 + s.dy),
            Part(rows: s.tail, x: s.tailX, y: 2 + s.dy, mergeInto: [.body]),
            leg(hindX, top, s.hind.near, near: true),
            leg(frontX, top, s.front.near, near: true),
            Part(rows: s.head, x: 18, y: s.headY + s.dy, group: .head, mergeInto: [.body]),
        ]
    }

    /// (near dx, near lift, far dx, far lift)
    static func pair(_ n: Int, _ nl: Int, _ f: Int, _ fl: Int) -> Pair {
        Pair(near: Leg(dx: n, lift: nl), far: Leg(dx: f, lift: fl))
    }

    static let walk: [Stride] = [
        Stride(front: pair(2, 0, -1, 0), hind: pair(-2, 0, 1, 0)),
        Stride(dy: -1, front: pair(0, 0, 0, 1), hind: pair(0, 1, 0, 0)),
        Stride(front: pair(-2, 0, 1, 0), hind: pair(2, 0, -1, 0)),
        Stride(dy: -1, front: pair(0, 1, 0, 0), hind: pair(0, 0, 0, 1)),
    ]

    static let tailTall = [
        ".W..",
        ".W..",
        ".W..",
        ".W..",
        "..W.",
        "...W",
        "...W",
    ]

    static let tailFlick = [
        "WW..",
        ".W..",
        ".W..",
        ".W..",
        "..W.",
        "...W",
        "...W",
    ]

    /// Ears up and eyes wide; the tail tip flicks and the near front paw taps.
    static let alert: [Stride] = [
        Stride(front: pair(0, 0, 1, 0), hind: pair(0, 0, 1, 0), tail: tailTall, head: headAlert, headY: 1),
        Stride(front: pair(1, 1, 1, 0), hind: pair(0, 0, 1, 0), tail: tailFlick, head: headAlert, headY: 1),
    ]

    /// Push-off, extension, front touchdown, front stance, gathered (raised, not crouched), hind touchdown.
    static let run: [Stride] = [
        Stride(front: pair(2, 2, 1, 2), hind: pair(-3, 0, -2, 1), tail: tailStream, tailX: 4),
        Stride(dy: -1, front: pair(4, 2, 3, 2), hind: pair(-4, 2, -3, 2), tail: tailWave, tailX: 4),
        Stride(front: pair(2, 0, 3, 1), hind: pair(-3, 2, -2, 2), tail: tailStream, tailX: 4),
        Stride(front: pair(0, 0, 1, 0), hind: pair(-1, 2, 0, 2), tail: tailWave, tailX: 4),
        Stride(dy: -1, front: pair(-2, 1, -1, 1), hind: pair(2, 1, 1, 2), tail: tailStream, tailX: 4),
        Stride(front: pair(-1, 2, 0, 2), hind: pair(1, 0, 2, 0), tail: tailWave, tailX: 4),
    ]

    // MARK: Still poses, drawn whole. W/S body, t tail and n near limb (merge into the body),
    // f far limb, z sleep mark (outlined like the cat). The head is placed on top.

    struct Still { var rows: [String]; var head: [String]; var headX: Int; var headY: Int }

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
            Part(rows: pick(["z"], as: "W"), group: .head),
        ]
    }

    //                     0         1         2
    //                     012345678901234567890123456789
    static let sitRows = [
        "..............................", // 0
        "..............................",
        "..............................",
        "..............................",
        "..............................",
        "..............................", // 5
        "..............................",
        "..............................",
        "..............................",
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

    static let sleepRows = [
        "..............................", // 0
        "..............................",
        "..............................",
        "..............................",
        "..............................",
        "..............................", // 5
        "..............................",
        "..............................",
        "..............................",
        "..............................",
        "...........WWWWW..............", // 10
        ".........WWWWWWWWW............",
        "........WWWWWWWWWWW...........",
        ".......WWWWWWWWWWWWW..........",
        ".......WWWWWWWWWWWWW..........",
        "...t...WWWWWWWWWWWWW..........", // 15
        "...tttt.SSSSSSSSSSSS..........",
        "..............................",
    ]

    static func breathe(_ rows: [String], inhale: Bool, z: (x: Int, y: Int)) -> [String] {
        var grid = rows.map(Array.init)
        if inhale { for x in 0..<cell.width where grid[10][x] == "W" { grid[9][x] = "W" } }
        for (r, line) in ["zzzz", "..z.", ".z..", "zzzz"].enumerated() {
            for (c, ch) in line.enumerated() where ch == "z" { grid[z.y + r][z.x + c] = "z" }
        }
        return grid.map { String($0) }
    }

    static let sit = [
        Still(rows: sitRows, head: head, headX: 18, headY: 3),
        Still(rows: sitRows, head: headBlink, headX: 18, headY: 3),
    ]

    static let sleep = [
        Still(rows: breathe(sleepRows, inhale: false, z: (24, 3)), head: headSleep, headX: 17, headY: 9),
        Still(rows: breathe(sleepRows, inhale: true, z: (25, 1)), head: headSleep, headX: 17, headY: 9),
    ]

    /// Suggested seconds per frame (manifest). Frame 0 of every pose is its still frame.
    static let durations: [String: [Double]] = [
        "sit": [3.2, 0.16],
        "sleep": [1.6, 1.6],
        "walk": [0.125, 0.125, 0.125, 0.125],
        "run": Array(repeating: 1.0 / 14, count: 6),
        "alert": [0.6, 0.3],
    ]

    // MARK: Composition

    static func compose(_ parts: [Part]) -> [[Character]] {
        let w = cell.width, h = cell.height
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
        var out = Bitmap(width: cell.width, height: cell.height)
        for (y, row) in grid.enumerated() { for (x, ch) in row.enumerated() where ch != "." { out[x, y] = palette[ch]! } }
        return out
    }

    static let poses: [(name: String, frames: [[Part]])] = [
        ("sit", sit.map(parts)),
        ("sleep", sleep.map(parts)),
        ("walk", walk.map(parts)),
        ("run", run.map(parts)),
        ("alert", alert.map(parts)),
    ]
}
