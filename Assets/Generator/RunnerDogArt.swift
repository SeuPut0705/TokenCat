import Foundation

/// The dog: a tan dog with floppy brown ears, a snout with a dark nose and a wagging tail. Profile head on a side body;
/// the input sit faces the viewer with the ears perked. Same part contract as RunnerCatArt (Assets/runner-v2.md).
enum RunnerDogArt {
    typealias Part = RunnerArt.Part
    static let cell = RunnerArt.cell

    static let palette: [Character: RGBA] = [
        "K": RGBA(hex: 0x2A201B), // outline, eyes, nose
        "W": RGBA(hex: 0xE2A660), // tan fur
        "S": RGBA(hex: 0x95562C), // floppy ears
        "G": RGBA(hex: 0xB0743F), // far legs, belly shade, paw split
        "C": RGBA(hex: 0xD63A35), // red collar
        "T": RGBA(hex: 0xF7CD45), // gold tag
    ]

    // MARK: Heads (fill only; K = eye and nose, S = ear, last row = collar)

    /// Profile, facing right: ear hanging at the back, eye, snout with the nose on its tip.
    static let head = [
        "...WWWW....",
        "..WWWWWW...",
        ".SSWWWWWW..",
        "SSSWKWWWWWK",
        "SSSWKWWWWWK",
        "SSSWWWWWWW.",
        ".SSWWWWWW..",
        "..CCCTCC...",
    ]

    static let headBlink = [
        "...WWWW....",
        "..WWWWWW...",
        ".SSWWWWWW..",
        "SSSWWWWWWWK",
        "SSSKKWWWWWK",
        "SSSWWWWWWW.",
        ".SSWWWWWW..",
        "..CCCTCC...",
    ]

    /// Eye shut, jaw dropped: the outline fills the gap as an open mouth.
    static let headYawn = [
        "...WWWW....",
        "..WWWWWWWWK",
        ".SSWWWWWWWK",
        "SSSWWWWW...",
        "SSSKKWW....",
        "SSSWWWWWW..",
        ".SSWWWWWW..",
        "..CCCTCC...",
    ]

    /// Trot bounce: the body rises and the ear lags one row behind.
    static let headBounce = [
        "...WWWW....",
        "..WWWWWW...",
        "..WWWWWWW..",
        "SSSWKWWWWWK",
        "SSSWKWWWWWK",
        "SSSWWWWWWW.",
        "SSSWWWWWW..",
        ".SCCCTCC...",
    ]

    /// Gallop: the ears stream back off the skull.
    static let headRun = [
        "...WWWW....",
        "..WWWWWW...",
        "SSSSWWWWW..",
        ".SSWKWWWWWK",
        "..WWKWWWWWK",
        "..WWWWWWWW.",
        "..WWWWWWW..",
        "..CCCTCC...",
    ]

    /// Resting on the paws, so no collar row.
    static let headSleep = Array(headBlink.dropLast())

    /// Facing the viewer for input: wide eyes and nose, the floppy ears hanging beside the cheeks (ears on top of the
    /// skull read as a bear at 1x).
    static let headAlert = [
        "...WWWWWW...",
        "..WWWWWWWW..",
        "SSSWWWWWWSSS",
        "SSWWWWWWWWSS",
        "SSWKKWWKKWSS",
        "SSWKKWWKKWSS",
        "SSWWWKKWWWSS",
        "..WWWWWWWW..",
        "...CCCTCC...",
    ]

    // MARK: Walk and run (side body, legs as strides)

    static let body = [
        ".WWWWWWWWWWW.",
        "WWWWWWWWWWWWW",
        "WWWWWWWWWWWWW",
        "WWWWWWWWWWWWW",
        ".WWWWWWWWWWWW",
        "..GGGGGGGGGG.",
    ]

    static let bodyLong = [
        ".WWWWWWWWWWWW.",
        "WWWWWWWWWWWWWW",
        "WWWWWWWWWWWWWW",
        "WWWWWWWWWWWWWW",
        ".WWWWWWWWWWWWW",
        "..GGGGGGGGGGG.",
    ]

    static let bodyArch = [
        "...WWWWWW...",
        ".WWWWWWWWWW.",
        "WWWWWWWWWWWW",
        "WWWWWWWWWWWW",
        ".WWWWWWWWWWW",
        "..GGGGGGGGG.",
    ]

    /// Tails anchored with the base at the bottom right, on the back's first row.
    static let tailBack = [
        "W...",
        "W...",
        ".W..",
        ".W..",
        "..W.",
        "..WW",
    ]

    static let tailHigh = [
        "..W.",
        ".W..",
        ".W..",
        ".W..",
        "..W.",
        "..WW",
    ]

    static let tailStream = [
        "....",
        "....",
        "....",
        "WW..",
        "..WW",
        "...W",
    ]

    /// Gallop frames 4–6: the tip flicks up, so the tail waves once per stride.
    static let tailFlick = [
        "....",
        "....",
        "W...",
        ".W..",
        "..WW",
        "...W",
    ]

    struct Leg { var dx: Int; var lift = 0 }
    struct Pair { var near: Leg; var far: Leg }
    struct Stride {
        var dy = 0; var front: Pair; var hind: Pair; var tail = tailBack; var tailX = -2
        var body = RunnerDogArt.body; var bodyX = 7; var head = RunnerDogArt.head; var headY = 2
    }

    /// Two-pixel leg from the body's last row to the foot; the upper row stays vertical so the joint reads.
    static func leg(_ x: Int, _ top: Int, _ leg: Leg, near: Bool) -> Part {
        var rows = Array(repeating: Array(repeating: Character("."), count: cell.width), count: cell.height)
        let paint: Character = near ? "W" : "G"
        for (px, py) in [(x, top)] + RunnerArt.line(x, top + 1, x + leg.dx, 16 - leg.lift) {
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
            Part(rows: s.head, x: 18, y: s.headY + s.dy, group: .head, mergeInto: [.body]),
        ]
    }

    /// (near dx, near lift, far dx, far lift)
    static func pair(_ n: Int, _ nl: Int, _ f: Int, _ fl: Int) -> Pair {
        Pair(near: Leg(dx: n, lift: nl), far: Leg(dx: f, lift: fl))
    }

    /// Happy trot: legs cross, 1 px bounce on the passing frames, the tail wags every other frame.
    static let walk: [Stride] = [
        Stride(front: pair(2, 0, -1, 0), hind: pair(-2, 0, 1, 0)),
        Stride(dy: -1, front: pair(0, 0, 0, 1), hind: pair(0, 1, 0, 0), tail: tailHigh, head: headBounce),
        Stride(front: pair(-2, 0, 1, 0), hind: pair(2, 0, -1, 0)),
        Stride(dy: -1, front: pair(0, 1, 0, 0), hind: pair(0, 0, 0, 1), tail: tailHigh, head: headBounce),
    ]

    /// Gallop: push-off, extension (long body), front touchdown, front stance, gathered (arched), hind touchdown.
    static let run: [Stride] = [
        Stride(front: pair(2, 2, 1, 2), hind: pair(-3, 0, -2, 1), tail: tailStream, tailX: -3, head: headRun),
        Stride(dy: -1, front: pair(4, 2, 3, 2), hind: pair(-4, 2, -3, 2), tail: tailStream, tailX: -3, body: bodyLong, bodyX: 6, head: headRun),
        Stride(front: pair(2, 0, 3, 1), hind: pair(-3, 2, -2, 2), tail: tailStream, tailX: -3, head: headRun),
        Stride(front: pair(0, 0, 1, 0), hind: pair(-1, 2, 0, 2), tail: tailFlick, tailX: -3, head: headRun),
        Stride(dy: -1, front: pair(-2, 1, -1, 1), hind: pair(2, 1, 1, 2), tail: tailFlick, tailX: -3, body: bodyArch, bodyX: 8, head: headRun),
        Stride(front: pair(-1, 2, 0, 2), hind: pair(1, 0, 2, 0), tail: tailFlick, tailX: -3, head: headRun),
    ]

    // MARK: Still poses, drawn whole. W/S/G body, t tail and n near limb (merge into the body), f far limb.

    struct Still { var rows: [String]; var head: [String]; var headX = 17; var headY = 2 }

    static func parts(_ still: Still) -> [Part] {
        func pick(_ keep: Set<Character>, as paint: Character? = nil) -> [String] {
            still.rows.map { String($0.map { keep.contains($0) ? (paint ?? $0) : "." }) }
        }
        return [
            Part(rows: pick(["f"], as: "G"), group: .far),
            Part(rows: pick(["W", "S", "G"])),
            Part(rows: pick(["t"], as: "W"), mergeInto: [.body]),
            Part(rows: pick(["n"], as: "W"), group: .near, mergeInto: [.body]),
            Part(rows: still.head, x: still.headX, y: still.headY, group: .head, mergeInto: [.body, .near]),
        ]
    }

    static let empty = Array(repeating: String(repeating: ".", count: 30), count: 10)

    //                     0         1         2
    //                     012345678901234567890123456789
    static let sitRows = Array(empty[0..<9]) + [
        "................WWWWWW........", // 9
        "..............WWWWWWWWW.......", // 10
        "............WWWWWWWWWWW.......",
        "...........WWWWWWWWWWWW.......",
        "......t...WWWWWWWWWWfnn.......",
        ".....t....WWWWWWWWWWfnn.......",
        ".....t....WWWWWWWWWWfnn.......", // 15
        "......tttt.GGGGGnnn.fnnn......",
        "..............................",
    ]

    /// Turn complete: the tail stands high and wags.
    static let contentRows = Array(empty[0..<5]) + [
        "..........t...................", // 5
        ".........t....................",
        ".........t....................",
        ".........t....................",
        "..........t.....WWWWWW........",
        "..........t...WWWWWWWWW.......", // 10
        "..........tWWWWWWWWWWWW.......",
        "...........WWWWWWWWWWWW.......",
        "..........WWWWWWWWWWfnn.......",
        "..........WWWWWWWWWWfnn.......",
        "..........WWWWWWWWWWfnn.......", // 15
        "...........GGGGGnnn.fnnn......",
        "..............................",
    ]

    static let contentWag = Array(empty[0..<5]) + [
        "......t.......................", // 5
        ".......t......................",
        ".......t......................",
        "........t.....................",
        ".........t......WWWWWW........",
        "..........t...WWWWWWWWW.......", // 10
        "..........tWWWWWWWWWWWW.......",
        "...........WWWWWWWWWWWW.......",
        "..........WWWWWWWWWWfnn.......",
        "..........WWWWWWWWWWfnn.......",
        "..........WWWWWWWWWWfnn.......", // 15
        "...........GGGGGnnn.fnnn......",
        "..............................",
    ]

    /// Lying down, chin on the front paws; nothing in x 21–29, y 0–7 (the z).
    static let sleepRows = empty + [
        ".........WWWWW................", // 10
        ".......WWWWWWWWW..............",
        "......WWWWWWWWWWWW............",
        ".....WWWWWWWWWWWWW............",
        ".....WWWWWWWWWWWWW............",
        ".tt..WWWWWWWWWWWWW............", // 15
        "..tttWWGGGGGGGGGGGnnnnnnnnnn..",
        "..............................",
    ]

    /// Front-facing sit for input; the tail wags at the side.
    static let alertRows = empty + [
        "...................WWWWWWWW...", // 10
        "..................WWWWWWWWWW..",
        "...............t.WWWWWWWWWWWW.",
        "...............t.WWWWWWWWWWWW.",
        "................tWWWWWWWWWWWW.",
        ".................WWWWnnGnWWWW.", // 15
        ".................WWWWnnGnWWWW.",
        "..............................",
    ]

    static let alertWag = empty + [
        "...................WWWWWWWW...", // 10
        "..................WWWWWWWWWW..",
        ".............t...WWWWWWWWWWWW.",
        "..............t..WWWWWWWWWWWW.",
        "...............ttWWWWWWWWWWWW.",
        ".................WWWWnnGnWWWW.", // 15
        ".................WWWWnnGnWWWW.",
        "..............................",
    ]

    /// Inhale raises the back one row.
    static func breathe(_ rows: [String]) -> [String] {
        var grid = rows.map(Array.init)
        for x in 0..<cell.width where grid[10][x] == "W" { grid[9][x] = "W" }
        return grid.map { String($0) }
    }

    static let sit = [Still(rows: sitRows, head: head), Still(rows: sitRows, head: headBlink)]
    static let sleep = [Still(rows: sleepRows, head: headSleep, headX: 17, headY: 9),
                        Still(rows: breathe(sleepRows), head: headSleep, headX: 17, headY: 9)]
    static let alert = [Still(rows: alertRows, head: headAlert, headX: 17, headY: 1),
                        Still(rows: alertWag, head: headAlert, headX: 17, headY: 1)]
    static let yawn = [Still(rows: sitRows, head: headYawn)]
    static let content = [Still(rows: contentRows, head: head), Still(rows: contentWag, head: headBlink)]

    static let poses = RunnerArt.Poses(sit: sit.map(parts), sleep: sleep.map(parts), walk: walk.map(parts), run: run.map(parts),
                                       alert: alert.map(parts), yawn: yawn.map(parts), content: content.map(parts))
}
