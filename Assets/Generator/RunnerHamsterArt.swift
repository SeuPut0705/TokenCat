import Foundation

/// PLACEHOLDER hamster: the cat's body, legs, tail and poses with small round ears, pink cheeks and a cream palette,
/// so the app, self-test and docs work end to end. The hamster's artist replaces everything below (poses may be built
/// from scratch); keep the two symbols `palette` and `poses`. Rules: Assets/runner-v2.md › 캐릭터 추가 규칙.
enum RunnerHamsterArt {
    static let palette: [Character: RGBA] = [
        "K": RGBA(hex: 0x2E2622), // outline, eyes, nose
        "W": RGBA(hex: 0xF5DDB0), // fur
        "S": RGBA(hex: 0xE8988C), // ears, cheeks, belly line
        "G": RGBA(hex: 0xD9B98A), // far legs
        "C": RGBA(hex: 0x3F9F68), // collar
        "T": RGBA(hex: 0xC6F0D4), // tag
    ]

    static let head = [
        "..........",
        ".SS....SS.",
        ".SWWWWWWS.",
        "WWWWWWWWWW",
        "WWKWWWWKWW",
        "WWKWWWWKWW",
        "SWWWKKWWWS",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    static let headBlink = [
        "..........",
        ".SS....SS.",
        ".SWWWWWWS.",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WKKWWWWKKW",
        "SWWWKKWWWS",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    static let headAlert = [
        "..........",
        ".SS....SS.",
        ".SS....SS.",
        ".SWWWWWWS.",
        "WWWWWWWWWW",
        "WKKWWWWKKW",
        "WKKWWWWKKW",
        "SWWWKKWWWS",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    static let headYawn = [
        "..........",
        ".SS....SS.",
        ".SWWWWWWS.",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WKKWWWWKKW",
        "SWWWKKWWWS",
        ".WWWKKWWW.",
        "..CCCTCC..",
    ]

    static let poses = RunnerArt.catWithHeads(head: head, blink: headBlink, alert: headAlert, yawn: headYawn)
}
