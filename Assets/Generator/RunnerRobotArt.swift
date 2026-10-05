import Foundation

/// PLACEHOLDER robot: the cat's body, legs, tail and poses with a square head, an antenna, a mouth grille and a steel
/// palette, so the app, self-test and docs work end to end. The robot's artist replaces everything below (poses may be
/// built from scratch); keep the two symbols `palette` and `poses`. Rules: Assets/runner-v2.md › 캐릭터 추가 규칙.
enum RunnerRobotArt {
    static let palette: [Character: RGBA] = [
        "K": RGBA(hex: 0x20242C), // outline, eyes
        "W": RGBA(hex: 0xC9D1DC), // plating
        "S": RGBA(hex: 0x7F8A9C), // antenna, grille, belly line
        "G": RGBA(hex: 0x9AA4B4), // far legs
        "C": RGBA(hex: 0x2FA8D6), // neck band
        "T": RGBA(hex: 0xFF7A59), // antenna light, band light
    ]

    static let head = [
        "....T.....",
        "....S.....",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WWKWWWWKWW",
        "WWKWWWWKWW",
        "WWWWWWWWWW",
        "WSSSSSSSSW",
        "..CCCTCC..",
    ]

    static let headBlink = [
        "....T.....",
        "....S.....",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WKKWWWWKKW",
        "WWWWWWWWWW",
        "WSSSSSSSSW",
        "..CCCTCC..",
    ]

    static let headAlert = [
        "....T.....",
        "....S.....",
        "....S.....",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WKKWWWWKKW",
        "WKKWWWWKKW",
        "WWWWWWWWWW",
        "WSSSSSSSSW",
        "..CCCTCC..",
    ]

    static let headYawn = [
        "....T.....",
        "....S.....",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "WKKWWWWKKW",
        "WWWWKKWWWW",
        "WSSSKKSSSW",
        "..CCCTCC..",
    ]

    static let poses = RunnerArt.catWithHeads(head: head, blink: headBlink, alert: headAlert, yawn: headYawn)
}
