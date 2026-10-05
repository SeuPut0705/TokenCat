import Foundation

/// The hamster: a round golden ball with cream cheeks and belly, small round ears, pink nose and feet, no tail.
/// Each frame is painted into one 30 × 18 grid (body, head and legs stamped back to front), then split into parts by
/// letter: `g` far leg (G), `W S T C K` body, `w t c` near leg or paw merged into the body. `RunnerArt.compose` adds
/// the 1 px K outline. Rules: Assets/runner-v2.md › 캐릭터 추가 규칙.
enum RunnerHamsterArt {
    typealias Part = RunnerArt.Part

    static let palette: [Character: RGBA] = [
        "K": RGBA(hex: 0x2B201C), // outline, eyes, mouth
        "W": RGBA(hex: 0xEFA04A), // golden back
        "S": RGBA(hex: 0xDDB27C), // belly shade
        "G": RGBA(hex: 0xB86F2E), // far legs
        "C": RGBA(hex: 0xF28CA0), // nose, inner ears, feet, blush
        "T": RGBA(hex: 0xFFF1D8), // cream cheeks and belly
    ]

    // MARK: Heads (front-facing; K eyes, C nose and inner ears, T cheek pouches one pixel wider than the crown)

    static let head = [
        "..WW....WW..",
        ".WCWWWWWWCW.",
        ".WWWWWWWWWW.",
        ".WWKWWWWKWW.",
        ".WWKWWWWKWW.",
        "TTTTTCCTTTTT",
        "TTTTTTTTTTTT",
        ".TTTTTTTTTT.",
        "...TTTTTT...",
    ]

    static let headBlink = [
        "..WW....WW..",
        ".WCWWWWWWCW.",
        ".WWWWWWWWWW.",
        ".WWWWWWWWWW.",
        ".WKKWWWWKKW.",
        "TTTTTCCTTTTT",
        "TTTTTTTTTTTT",
        ".TTTTTTTTTT.",
        "...TTTTTT...",
    ]

    /// Ears perked one row taller, eyes wide (2 × 2).
    static let headAlert = [
        "..WW....WW..",
        "..WC....CW..",
        ".WWWWWWWWWW.",
        ".WWWWWWWWWW.",
        ".WKKWWWWKKW.",
        ".WKKWWWWKKW.",
        "TTTTTCCTTTTT",
        "TTTTTTTTTTTT",
        ".TTTTTTTTTT.",
        "...TTTTTT...",
    ]

    static let headYawn = [
        "..WW....WW..",
        ".WCWWWWWWCW.",
        ".WWWWWWWWWW.",
        ".WWWWWWWWWW.",
        ".WKKWWWWKKW.",
        "TTTTTCCTTTTT",
        "TTTTTKKTTTTT",
        ".TTTTKKTTTT.",
        "...TTTTTT...",
    ]

    /// Resting on the floor: eyes shut, no chin row.
    static let headSleep = Array(headBlink.dropLast())

    /// Turn complete: pouches stuffed (three pixels wider each side) with a pink blush.
    static let headPuff = [
        "....WW....WW....",
        "...WCWWWWWWCW...",
        "...WWWWWWWWWW...",
        "..TTWKWWWWKWTT..",
        "TTTTWKWWWWKWTTTT",
        "TTTTTTTCCTTTTTTT",
        "TTCTTTTTTTTTTCTT",
        "..TTTTTTTTTTTT..",
        "....TTTTTTTT....",
    ]

    static let headPuffBlink = [
        "....WW....WW....",
        "...WCWWWWWWCW...",
        "...WWWWWWWWWW...",
        "..TTWWWWWWWWTT..",
        "TTTTKKWWWWKKTTTT",
        "TTTTTTTCCTTTTTTT",
        "TTCTTTTTTTTTTCTT",
        "..TTTTTTTTTTTT..",
        "....TTTTTTTT....",
    ]

    // MARK: Painting

    typealias Layer = (rows: [String], x: Int, y: Int)

    static let blank = Array(repeating: String(repeating: ".", count: RunnerArt.cell.width), count: RunnerArt.cell.height)

    /// Paints layers back to front on an empty cell; later layers cover earlier ones.
    static func paint(_ layers: [Layer]) -> [String] {
        var grid = blank.map(Array.init)
        for layer in layers {
            for (r, row) in layer.rows.enumerated() {
                for (c, ch) in row.enumerated() where ch != "." { grid[layer.y + r][layer.x + c] = ch }
            }
        }
        return grid.map { String($0) }
    }

    /// `head`, if given, is drawn last and merges into the body: the stuffed pouches read by their width and colour,
    /// with no outline across the chest.
    static func parts(_ rows: [String], head: Layer? = nil) -> [Part] {
        func pick(_ map: [Character: Character]) -> [String] { rows.map { String($0.map { map[$0] ?? "." }) } }
        return [
            Part(rows: pick(["g": "G"]), group: .far),
            Part(rows: pick(["W": "W", "S": "S", "T": "T", "C": "C", "K": "K"])),
            Part(rows: pick(["w": "W", "t": "T", "c": "C"]), group: .near, mergeInto: [.body]),
        ] + (head.map { [Part(rows: $0.rows, x: $0.x, y: $0.y, group: .head, mergeInto: [.body, .near])] } ?? [])
    }

    // MARK: Still poses (body grids; the head is stamped on top)

    //                     0         1         2
    //                     012345678901234567890123456789
    static let sitBody = Array(blank[0..<6]) + [
        "............WWWW..............", // 6
        "..........WWWWWW..............",
        ".........WWWWWW...............",
        ".........WWWWWW...............",
        ".........WWWWWWW..............", // 10
        "........WWWWWWWWWW............",
        "........WWWWWWWWTTTTTTTT......",
        "........WWWWWWWTTTTTTTTT......",
        "........WWWWWWWTTTTTTTTT......",
        ".........WWWWWTTTTTTTTT.......", // 15
        "..........SSSSSSSccctccc......",
        "..............................",
    ]

    /// Curled up: a high round back with the head tucked in front of it, ears below the dome.
    static let sleepBody = Array(blank[0..<6]) + [
        "...........WWWW...............", // 6
        ".........WWWWWWW..............",
        "........WWWWWWWW..............",
        ".......WWWWWWWWW..............",
        ".......WWWWWWWWW..............", // 10
        ".......WWWWWWWWW..............",
        ".......WWWWWWWWW..............",
        ".......WWWWWWWWW..............",
        ".......WWWWWWWW...............",
        "........WWWWWWW...............", // 15
        ".........SSSSSS...............",
        "..............................",
    ]

    /// Inhale raises the whole back one row (each column's top pixel, left of the head).
    static func breathe(_ rows: [String]) -> [String] {
        var grid = rows.map(Array.init)
        for x in 0..<15 { if let top = grid.indices.first(where: { grid[$0][x] == "W" }) { grid[top - 1][x] = "W" } }
        return grid.map { String($0) }
    }

    /// Stand-up on the hind legs, facing the viewer: a pear under the head, feet splayed.
    static let alertBody = Array(blank[0..<10]) + [
        "................WTTTTTTTTW....", // 10
        "...............WWTTTTTTTTWW...",
        "...............WWTTTTTTTTWW...",
        "..............WWTTTTTTTTTTWW..",
        "..............WWTTTTTTTTTTWW..",
        "...............WTTTTTTTTTTW...", // 15
        "...............ccc......ccc...",
        "..............................",
    ]

    static let sit = paint([(sitBody, 0, 0), (head, 15, 3)])
    static let sitBlink = paint([(sitBody, 0, 0), (headBlink, 15, 3)])
    static let sleepA = paint([(sleepBody, 0, 0), (headSleep, 15, 9)])
    static let sleepB = paint([(breathe(sleepBody), 0, 0), (headSleep, 15, 9)])

    /// Front paws dangling together on the chest, 1 px each (2 × 2 blocks read as a snout at 1x).
    static let paws = ["c..c", "c..c"]

    static let alertA = paint([(alertBody, 0, 0), (headAlert, 15, 1), (paws, 19, 11)])
    static let alertB = paint([(alertBody, 0, 0), (headAlert, 15, 1), (paws, 19, 10)])
    static let yawn = paint([(sitBody, 0, 0), (headYawn, 15, 3)])
    static let content = [parts(sitBody, head: (headPuff, 13, 3)), parts(sitBody, head: (headPuffBlink, 13, 3))]

    // MARK: Strides (a body shape and its head lifted by dy, four 2 px legs)

    static let walkBody = [
        "...........WWWW...............", // 6
        ".........WWWWWWW..............",
        "........WWWWWWWW..............",
        ".......WWWWWWWWW..............",
        "......WWWWWWWWWW..............", // 10
        "......WWWWWWWWWWW.............",
        "......WWWWWWWWWWTTTTTTTT......",
        "......WWWWWWWWWTTTTTTTTT......",
        ".......SSSSSSSSTTTTTTTT.......", // 14
    ]

    /// Run reach: longer and lower, the head pushed one pixel forward.
    static let runLong = [
        "..........WWWWWW..............", // 7
        "........WWWWWWWW..............",
        "......WWWWWWWWWW..............",
        ".....WWWWWWWWWWW..............", // 10
        ".....WWWWWWWWWWWW.............",
        ".....WWWWWWWWWWWWTTTTTTTT.....",
        ".....WWWWWWWWWWTTTTTTTTTT.....",
        "......SSSSSSSSSTTTTTTT........", // 14
    ]

    /// Run gather: shorter with the back hunched up.
    static let runBall = [
        "...........WWWW...............", // 5
        ".........WWWWWWW..............",
        "........WWWWWWWW..............",
        ".......WWWWWWWWW..............",
        ".......WWWWWWWWW..............",
        ".......WWWWWWWWWW.............", // 10
        ".......WWWWWWWWWWW............",
        ".......WWWWWWWWWWTTTTTTT......",
        ".......WWWWWWWWTTTTTTTTT......",
        "........SSSSSSSTTTTTTT........", // 14
    ]

    /// Body grid, its top row, head origin and the near legs' columns (far legs stand 3 px further on).
    typealias Shape = (body: [String], top: Int, headX: Int, headY: Int, hindX: Int, frontX: Int)
    static let walking: Shape = (walkBody, 6, 15, 4, 8, 17)
    static let reaching: Shape = (runLong, 7, 16, 5, 7, 18)
    static let gathered: Shape = (runBall, 5, 15, 4, 9, 16)

    /// A 2 px leg from under the body (row 15 + dy) to the foot (row 16 - lift), the foot moved by `dx`.
    /// Near legs are golden with a pink foot, far legs dark.
    static func leg(_ x: Int, _ dy: Int, _ dx: Int, _ lift: Int, near: Bool) -> Layer {
        var rows = blank.map(Array.init)
        let points = RunnerArt.line(x, 15 + dy, x + dx, 16 - lift)
        for (i, (px, py)) in points.enumerated() {
            let paint: Character = near ? (i == points.count - 1 ? "c" : "w") : "g"
            rows[py][px] = paint; rows[py][px + 1] = paint
        }
        return (rows.map { String($0) }, 0, 0)
    }

    /// dy, then (dx, lift) for front near, front far, hind near, hind far.
    typealias Stride = (dy: Int, fn: (Int, Int), ff: (Int, Int), hn: (Int, Int), hf: (Int, Int))

    static func stride(_ s: Stride, _ shape: Shape = walking) -> [String] {
        paint([
            leg(shape.hindX + 3, s.dy, s.hf.0, s.hf.1, near: false),
            leg(shape.frontX + 3, s.dy, s.ff.0, s.ff.1, near: false),
            (shape.body, 0, shape.top + s.dy),
            (head, shape.headX, shape.headY + s.dy),
            leg(shape.hindX, s.dy, s.hn.0, s.hn.1, near: true),
            leg(shape.frontX, s.dy, s.fn.0, s.fn.1, near: true),
        ])
    }

    /// Tiny steps: diagonal pairs swap, the body rises a pixel on the passing frames.
    static let walk: [Stride] = [
        (0, (1, 0), (-1, 0), (-1, 0), (1, 0)),
        (-1, (0, 0), (0, 1), (0, 1), (0, 0)),
        (0, (-1, 0), (1, 0), (1, 0), (-1, 0)),
        (-1, (0, 1), (0, 0), (0, 0), (0, 1)),
    ]

    /// Bounding scamper, two bounces per cycle: flight (stretched, up), front landing, stance, gathered (hunched, up),
    /// hind landing, push-off.
    static let run: [(Stride, Shape)] = [
        ((-1, (2, 1), (2, 1), (-2, 1), (-2, 1)), reaching),
        ((0, (1, 0), (2, 1), (-2, 1), (-1, 1)), reaching),
        ((0, (0, 0), (-1, 0), (0, 1), (1, 1)), walking),
        ((-1, (-1, 1), (-1, 1), (1, 1), (1, 1)), gathered),
        ((0, (-1, 1), (0, 1), (1, 0), (1, 0)), gathered),
        ((0, (1, 1), (2, 1), (-1, 0), (-1, 0)), walking),
    ]

    static let poses = RunnerArt.Poses(
        sit: [sit, sitBlink].map { parts($0) }, sleep: [sleepA, sleepB].map { parts($0) },
        walk: walk.map { parts(stride($0)) }, run: run.map { parts(stride($0.0, $0.1)) },
        alert: [alertA, alertB].map { parts($0) }, yawn: [parts(yawn)], content: content)
}
