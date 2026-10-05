import Foundation

/// The penguin: a front-facing little blue penguin (slate back and flippers, white face and belly, orange beak and feet)
/// that turns to its right to waddle for walk and belly-slide for run. Frames are whole 30 × 18 grids composed into
/// parts: `o` foot (C, merges into the body), `n` flipper (W, outlined over the body), the rest body letters (K inside = eyes).
/// No far limb is ever visible, so G is unused. Rules: Assets/runner-v2.md › 캐릭터 추가 규칙.
enum RunnerPenguinArt {
    typealias Part = RunnerArt.Part

    static let palette: [Character: RGBA] = [
        "K": RGBA(hex: 0x1A1E2B), // outline, eyes
        "W": RGBA(hex: 0x5A6FA2), // slate-blue back, head and flippers
        "S": RGBA(hex: 0xC9D0DD), // belly shade
        "G": RGBA(hex: 0x3A4874), // far limb (unused, darker than W)
        "C": RGBA(hex: 0xF5992E), // beak, feet
        "T": RGBA(hex: 0xF7F8FA), // face and belly
    ]

    static func parts(_ rows: [String]) -> [Part] {
        func pick(_ keep: String, as paint: Character? = nil) -> [String] {
            rows.map { String($0.map { keep.contains($0) ? (paint ?? $0) : "." }) }
        }
        return [
            Part(rows: pick("KWSTC")),
            Part(rows: pick("o", as: "C"), group: .near, mergeInto: [.body]),
            Part(rows: pick("n", as: "W"), group: .near),
        ]
    }

    static let blank = Array(repeating: String(repeating: ".", count: 30), count: 18)

    /// `tops` over `base` in order, each moved by dx, dy.
    static func over(_ base: [String], _ tops: [String]..., dx: Int = 0, dy: Int = 0) -> [String] {
        var grid = base.map(Array.init)
        for top in tops { for (y, row) in top.enumerated() { for (x, ch) in row.enumerated() where ch != "." {
            grid[y + dy][x + dx] = ch
        }}}
        return grid.map { String($0) }
    }

    /// Sparse rows from `y`, padded to the cell.
    static func at(_ y: Int, _ rows: [String]) -> [String] {
        Array(blank[0..<y]) + rows.map { $0.padding(toLength: 30, withPad: ".", startingAt: 0) } + Array(blank[(y + rows.count)...])
    }

    /// Only rows `range` of `rows`.
    static func band(_ rows: [String], _ range: Range<Int>) -> [String] {
        rows.indices.map { range.contains($0) ? rows[$0] : blank[$0] }
    }

    // MARK: Standing (front), mirrored about x 17.5

    //                     0         1         2
    //                     012345678901234567890123456789
    static let stand = at(3, [
        "...............WWWWWW",
        ".............WWWWWWWWWW",
        "............WWWWWWWWWWWW", // 5
        "............WWTTTWWTTTWW",
        "...........WWTTKTTTTKTTWW",
        "...........WWTTKTTTTKTTWW",
        "...........WWWTTTCCTTTWWW",
        "...........WWWTTTTTTTTWWW", // 10
        "...........WWTTTTTTTTTTWW",
        "...........WWTTTTTTTTTTWW",
        "...........WWTTTTTTTTTTWW",
        "...........WWSTTTTTTTTSWW",
        "............WWSSSSSSSSWW", // 15
    ])

    static let feet = at(16, ["............ooo......ooo"])

    static let eyesShut = at(7, [
        "...............T....T",
        "..............KK....KK",
    ])

    static let eyesWide = at(7, [
        ".............TKKTTTTKKT",
        ".............TKKTTTTKKT",
    ])

    static let beakOpen = at(9, [
        ".................CC",
        ".................KK",
        ".................CC",
    ])

    static let flipperLeftDown = at(10, ["..........nn", "..........nn", ".........nn", ".........nn", ".........n"])
    static let flipperRightDown = at(10, ["........................nn", "........................nn",
                                          ".........................nn", ".........................nn", "..........................n"])
    static let flippersDown = over(flipperLeftDown, flipperRightDown)

    /// Yawn stretch: held out low.
    static let flipperLeftOut = at(10, ["..........nn", ".........nnn", "........nn", "........n"])
    static let flipperRightOut = at(10, ["........................nn", "........................nnn",
                                         "..........................nn", "...........................n"])

    /// Input: both flippers up and out in a V, tips level with the head.
    static let flippersUp = at(3, [
        ".......n....................n",
        ".......nn..................nn",
        "........nn................nn", // 5
        "........nn................nn",
        ".........nn..............nn",
        "..........nn............nn",
        "..........nn............nn",
    ])

    /// Turn done: spread out at the shoulders, tips up.
    static let flippersSpread = at(8, [
        ".......n....................n",
        ".......nnnn..............nnnn",
        "........nnn..............nnn", // 10
    ])

    // MARK: Sleep: puffed up on the belly, head sunk, mirrored about x 15.5 (x 21–29, y 0–7 stay clear for the z)

    static let sleepRows = at(9, [
        "...........WWWWWWWWWW",
        "........WWWWWWWWWWWWWWWW", // 10
        ".......WWWWWTTTWWTTTWWWWW",
        "......WWWWWTKKTTTTKKTWWWWW",
        "......WWWWWTTTTCCTTTTWWWWW",
        "......WWWWTTTTTTTTTTTTWWWW",
        "......WWWWSTTTTTTTTTTSWWWW", // 15
        ".......WWWWSSSSSSSSSSWWWW",
    ])

    static let sleepBreath = over(sleepRows, at(8, [".............WWWWWW"]))

    // MARK: Walk: upright waddle in profile, facing right like the slide

    //                     0         1         2
    //                     012345678901234567890123456789
    static let profile = at(3, [
        ".............WWWWWWW",
        "...........WWWWWWWWWWW",
        "..........WWWWWWWWWWWW", // 5
        "..........WWWWWWWWWTTKT",
        "..........WWWWWWWWTTTKTCC",
        "..........WWWWWWWWTTTTTC",
        "..........WWWWWWWWTTTTTT",
        ".........WWWWWWWWWTTTTTTT", // 10
        ".........WWWWWWWWWTTTTTTT",
        ".........WWWWWWWWWTTTTTTT",
        ".........WWWWWWWWWTTTTTTT",
        "..........WWWWWWWWSTTTTT",
        "...........WWWWWSSSSSS", // 15
    ])

    /// Stride: one foot planted, the other raised a row at the body's back or front corner.
    static let strideBack = at(15, ["..........oo", "...................ooo"])
    static let strideFront = at(15, ["......................oo", ".............ooo"])
    static let feetTogether = at(16, ["..............ooo.ooo"])
    /// Near flipper held out behind for balance, rooted at the shoulder (x 13–14, row 10).
    static let flipBalance = at(10, [".............nn", "...........nnnn", ".........nnnn", ".......nnnn"])

    // MARK: Run: belly slide facing right

    static let slide = at(8, [
        "...................WWWW",
        "...............WWWWWWWWWW",
        "............WWWWWWWWWWWWWW", // 10
        "...........WWWWWWWWWWWTTKTW",
        ".......WWWWWWWWWWWWWWWTTKTTCC",
        ".....WWWWWWWWWWWWWWWWTTTTTTC",
        "...WWWTTTTTTTTTTTTTTTTTTTTT",
        "....WTTTTTTTTTTTTTTTTTTTTT", // 15
        "......SSSSSSSSSSSSSSSSSS",
    ])

    static let slideFeetA = at(14, [".oo", ".ooo"])
    static let slideFeetB = at(13, ["..oo", ".oo"])
    /// Near flipper over the white side, rooted at the shoulder (x 16–17, row 13), in two-pixel steps.
    static let flipBack = at(13, ["................nn", "..............nnnn", "............nnnn", "..........nnnn"])
    static let flipReach = at(13, [".................nn", ".................nn", "..................nn", "..................nn"])
    static let flipDown = at(13, ["................nn", "................nn", "................nn", "................nn"])
    static let flipPush = at(13, ["...............nn", "...............nn", ".............nn", ".............nn"])

    // MARK: Poses

    static let sitFrame = over(stand, feet, flippersDown)
    static let sit = [sitFrame, over(sitFrame, eyesShut)]
    static let sleep = [sleepRows, sleepBreath]
    /// Step with the head leaning forward, pass (body one pixel up on planted feet, the flipper left a row lower),
    /// step upright, pass.
    static let pass = over(over(blank, profile, dy: -1), feetTogether, flipBalance)
    static let walk = [
        over(over(band(profile, 10..<16), band(profile, 3..<10), dx: 1), strideBack, flipBalance),
        pass,
        over(profile, strideFront, flipBalance),
        pass,
    ]
    static let run = [
        over(slide, slideFeetA, flipBack),
        over(slide, slideFeetB, flipBack),
        over(slide, slideFeetA, flipReach),
        over(slide, slideFeetB, flipDown),
        over(slide, slideFeetA, flipPush),
        over(slide, slideFeetB, flipPush),
    ]
    static let alertFrame = over(stand, feet, eyesWide, flippersUp)
    /// Frame 1: the flipper tips dip one row.
    static let alert = [alertFrame, over(stand, feet, eyesWide, band(flippersUp, 4..<10))]
    static let yawn = [over(stand, feet, eyesShut, beakOpen, flipperLeftOut, flipperRightOut)]
    static let contentFrame = over(stand, feet, flippersSpread)
    static let content = [contentFrame, over(contentFrame, eyesShut)]

    static let poses = RunnerArt.Poses(sit: sit.map(parts), sleep: sleep.map(parts), walk: walk.map(parts), run: run.map(parts),
                                       alert: alert.map(parts), yawn: yawn.map(parts), content: content.map(parts))
}
