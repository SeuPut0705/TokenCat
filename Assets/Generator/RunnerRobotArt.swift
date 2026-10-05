import Foundation

/// The robot: a boxy little robot with an antenna, a silver shell and a gunmetal screen face whose cyan LEDs are its
/// eyes. Each frame is stamped from the pieces below onto one 30 × 18 grid and split into parts by letter (`frame`),
/// then outlined by `RunnerArt.compose`. Rules: Assets/runner-v2.md › 캐릭터 추가 규칙.
enum RunnerRobotArt {
    typealias Part = RunnerArt.Part

    static let palette: [Character: RGBA] = [
        "K": RGBA(hex: 0x1F232B), // outline
        "W": RGBA(hex: 0xE3E8EE), // silver shell
        "S": RGBA(hex: 0x98A2B2), // ear bolts, neck, antenna stalk, belt, LEDs off
        "G": RGBA(hex: 0x4D576A), // screen, far limbs (lighter than a dark bar, so the face stays solid there)
        "C": RGBA(hex: 0x27D0E0), // LED eyes, antenna light, chest light, jet
        "T": RGBA(hex: 0xFFD447), // antenna flash, jet core
    ]

    // MARK: Pieces. Letters: W S G C T shell (one part), n near limb and a arm (W, merge into the shell), f far limb
    // (G, behind the shell), j jet (C) and y jet core (T) behind everything. Every part gets the 1 px outline.

    /// Head 16 × 6: a rounded silver shell around a gunmetal screen (the four screen rows carry the face), ear bolts
    /// on both sides at eye height.
    static func head(_ face: [String]) -> [String] {
        let ears = [".", "S", "S", "."]
        return ["..WWWWWWWWWWWW.."] + face.enumerated().map { ears[$0.offset] + "W" + $0.element + "W" + ears[$0.offset] }
            + ["..WWWWWWWWWWWW.."]
    }
    static let eyes = head(["WGGGGGGGGGGW", "GGGCGGGGCGGG", "GGGCGGGGCGGG", "WGGGGGGGGGGW"])
    static let eyesAhead = head(["WGGGGGGGGGGW", "GGGGGCGGGGCG", "GGGGGCGGGGCG", "WGGGGGGGGGGW"])
    static let eyesBlink = head(["WGGGGGGGGGGW", "GGGGGGGGGGGG", "GGCCGGGGCCGG", "WGGGGGGGGGGW"])
    static let eyesBig = head(["WGGGGGGGGGGW", "GGCCGGGGCCGG", "GGCCGGGGCCGG", "WGGGGGGGGGGW"])
    static let eyesOff = head(["WGGGGGGGGGGW", "GGGGGGGGGGGG", "GGSSGGGGSSGG", "WGGGGGGGGGGW"])
    static let eyesHappy = head(["WGGGGGGGGGGW", "GGGCGGGGCGGG", "GGCGCGGCGCGG", "WGGGGGGGGGGW"])
    static let eyesYawn = head(["WGGGGGGGGGGW", "GGCCGGGGCCGG", "GGGGGCCGGGGG", "WGGGGCCGGGGW"])

    static let neck = ["SSSS"]
    /// Front and side torsos; the side one is a row shorter so the striding legs keep three rows.
    static let torso = ["WWWWWWWWWWWW", "WWWWWCCWWWWW", "WWWWWWWWWWWW", "SSSSSSSSSSSS"]
    static let torsoSide = ["WWWWWWWWWWWW", "WWWWWWWWWCCW", "SSSSSSSSSSSS"]

    // MARK: Frames

    typealias Stamp = (rows: [String], x: Int, y: Int)

    static func frame(_ stamps: [Stamp]) -> [Part] {
        var grid = Array(repeating: Array(repeating: Character("."), count: RunnerArt.cell.width), count: RunnerArt.cell.height)
        for stamp in stamps {
            for (r, row) in stamp.rows.enumerated() { for (c, ch) in row.enumerated() where ch != "." { grid[stamp.y + r][stamp.x + c] = ch } }
        }
        let rows = grid.map { String($0) }
        func pick(_ keep: String, _ paint: [Character: Character] = [:]) -> [String] {
            rows.map { String($0.map { keep.contains($0) ? (paint[$0] ?? $0) : "." }) }
        }
        return [
            Part(rows: pick("jy", ["j": "C", "y": "T"]), group: .far),
            Part(rows: pick("f", ["f": "G"]), group: .far),
            Part(rows: pick("WSGCTK")),
            Part(rows: pick("na", ["n": "W", "a": "W"]), group: .near, mergeInto: [.body]),
        ]
    }

    static func far(_ rows: [String]) -> [String] { rows.map { String($0.map { "na".contains($0) ? "f" : $0 }) } }
    static func mirror(_ rows: [String]) -> [String] { rows.map { String($0.reversed()) } }

    // MARK: Standing, facing the viewer (sit, alert, yawn, content)

    static let arm = ["aa", "aa", "aa"]
    /// Arms hang beside the torso with a 1 px gap.
    static let armsDown: [Stamp] = [(arm, 9, 10), (arm, 25, 10)]
    /// Raised up and out beside the head.
    static let armUp = ["aa..", "aa..", "aa..", ".aa.", "..aa", "..aa"]
    static let leg = ["nn.", "nn.", "nnn"]

    static func standing(face: [String], light: Character = "C", arms: [Stamp] = armsDown) -> [Part] {
        frame([([String(light), "S"], 17, 1), (face, 10, 3), (neck, 16, 9), (torso, 12, 10), (mirror(leg), 13, 14), (leg, 20, 14)] + arms)
    }

    static let sit = [standing(face: eyes), standing(face: eyesBlink)]
    static let yawn = [standing(face: eyesYawn)]
    /// Input: both arms up in a V beside the head, eyes wide; frame 2 flashes the antenna.
    static let armsUp: [Stamp] = [(armUp, 7, 5), (mirror(armUp), 25, 5)]
    static let alert = [standing(face: eyesBig, arms: armsUp), standing(face: eyesBig, light: "T", arms: armsUp)]
    /// Turn done: one arm waving, happy eyes, antenna lit; frame 2 is a slow blink.
    static let wave: [Stamp] = [(arm, 9, 10), (mirror(armUp), 25, 5)]
    static let content = [standing(face: eyesHappy, light: "T", arms: wave), standing(face: eyesBlink, light: "T", arms: wave)]

    // MARK: Walk (side on, eyes ahead)

    static let legForward = ["nn...", ".nn..", "..nnn"], legBack = ["..nn", ".nn.", "nnn."]
    static let legStraight = ["nn.", "nn.", "nn.", "nnn"], legLifted = ["nn", "nn", "nn"]
    /// Arms swing opposite the legs, clear of the torso by a pixel; on the passing frames they hang short at the sides.
    static let armBack = [".aa", "aa.", "aa."], armFront = ["aa.", ".aa", ".aa"], armHang = ["aa", "aa"]

    /// `dy` 0 is the contact frame (legs spread, body low); -1 the passing frame (body up a pixel, one foot lifted).
    static func walker(dy: Int, limbs: [Stamp]) -> [Part] {
        frame(limbs + [(["C", "S"], 18, 2 + dy), (eyesAhead, 11, 4 + dy), (neck, 17, 10 + dy), (torsoSide, 13, 11 + dy)])
    }

    static let walk = [
        walker(dy: 0, limbs: [(far(legBack), 14, 14), (legForward, 19, 14), (armBack, 9, 11), (far(armFront), 26, 11)]),
        walker(dy: -1, limbs: [(far(legLifted), 15, 13), (legStraight, 18, 13), (armHang, 10, 10), (far(armHang), 26, 10)]),
        walker(dy: 0, limbs: [(far(legForward), 19, 14), (legBack, 14, 14), (far(armBack), 9, 11), (armFront, 26, 11)]),
        walker(dy: -1, limbs: [(far(legStraight), 18, 13), (legLifted, 15, 13), (far(armHang), 10, 10), (armHang, 26, 10)]),
    ]

    // MARK: Run: jetpack dash, leaning in with the boots swept back and a jet flickering from the back

    static let legSwept = ["..nn", ".nn.", "nn.."]

    static func dash(dy: Int, flame: [String]) -> [Part] {
        frame([
            (flame, 11 - flame[0].count, 10 + dy),
            (far(legSwept), 18, 13 + dy), (legSwept, 14, 13 + dy),
            (["C.", ".S"], 18, 1 + dy), (eyesAhead, 13, 3 + dy), (neck, 18, 9 + dy), (torsoSide, 12, 10 + dy),
        ])
    }

    static let flameLong = ["...jjy", "jjjjyy", "...jjy"]
    static let flameShort = ["....jy", "..jjyy", "....jy"]
    static let run = [
        dash(dy: 0, flame: flameLong), dash(dy: 0, flame: flameShort), dash(dy: 0, flame: flameLong),
        dash(dy: 1, flame: flameShort), dash(dy: 1, flame: flameLong), dash(dy: 1, flame: flameShort),
    ]

    // MARK: Sleep: powered down, sitting with the head sunk, antenna drooped, LEDs off. Breathing lifts the head 1 px.
    // The ear bolts end at x 19, so nothing reaches x 21–29 above row 8 (the z).

    static func slump(_ headY: Int) -> [Part] {
        frame([
            (["GS.", "..S"], 9, headY - 2), (eyesOff, 4, headY), (Array(repeating: "SSSS", count: 7 - headY), 10, headY + 6),
            (torso, 6, 13), (["nnn", "nnn"], 18, 15),
        ])
    }

    static let sleep = [slump(6), slump(5)]

    static let poses = RunnerArt.Poses(sit: sit, sleep: sleep, walk: walk, run: run, alert: alert, yawn: yawn, content: content)
}
