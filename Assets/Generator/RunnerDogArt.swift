import Foundation

/// PLACEHOLDER dog: the cat's body, legs, tail and poses with a flat-topped head, floppy side ears and a caramel palette,
/// so the app, self-test and docs work end to end. The dog's artist replaces everything below (poses may be built from
/// scratch); keep the two symbols `palette` and `poses`. Rules: Assets/runner-v2.md › 캐릭터 추가 규칙.
enum RunnerDogArt {
    static let palette: [Character: RGBA] = [
        "K": RGBA(hex: 0x2B2420), // outline, eyes, nose
        "W": RGBA(hex: 0xD9A066), // fur
        "S": RGBA(hex: 0x7A4E2D), // ears, belly line
        "G": RGBA(hex: 0xB07D4C), // far legs
        "C": RGBA(hex: 0xD2453B), // collar
        "T": RGBA(hex: 0xF4C64E), // tag
    ]

    static let head = [
        "..........",
        "..WWWWWW..",
        "SSWWWWWWSS",
        "SSWWWWWWSS",
        "SWKWWWWKWS",
        "SWKWWWWKWS",
        "WWWWKKWWWW",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    static let headBlink = [
        "..........",
        "..WWWWWW..",
        "SSWWWWWWSS",
        "SSWWWWWWSS",
        "SWWWWWWWWS",
        "SKKWWWWKKS",
        "WWWWKKWWWW",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    static let headAlert = [
        "..........",
        ".S......S.",
        ".SWWWWWWS.",
        "SSWWWWWWSS",
        "SSWWWWWWSS",
        "SKKWWWWKKS",
        "SKKWWWWKKS",
        "WWWWKKWWWW",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    static let headYawn = [
        "..........",
        "..WWWWWW..",
        "SSWWWWWWSS",
        "SSWWWWWWSS",
        "SWWWWWWWWS",
        "SKKWWWWKKS",
        "WWWWKKWWWW",
        ".WWWKKWWW.",
        "..CCCTCC..",
    ]

    static let poses = RunnerArt.catWithHeads(head: head, blink: headBlink, alert: headAlert, yawn: headYawn)
}
