import Foundation

/// PLACEHOLDER penguin: the cat's body, legs, tail and poses with an earless navy-capped head, an orange beak and orange
/// far feet, so the app, self-test and docs work end to end. The penguin's artist replaces everything below (a real
/// penguin waddles on two feet, so the poses will likely be built from scratch); keep the two symbols `palette` and
/// `poses`. Rules: Assets/runner-v2.md › 캐릭터 추가 규칙.
enum RunnerPenguinArt {
    static let palette: [Character: RGBA] = [
        "K": RGBA(hex: 0x1F2430), // outline, eyes
        "W": RGBA(hex: 0xF4F6F8), // face, belly
        "S": RGBA(hex: 0x3A4A66), // cap, belly line
        "G": RGBA(hex: 0xF29A38), // far feet
        "C": RGBA(hex: 0xF29A38), // beak, scarf
        "T": RGBA(hex: 0xFFD25A), // scarf knot
    ]

    static let head = [
        "..........",
        "..SSSSSS..",
        ".SSSSSSSS.",
        "SSSSSSSSSS",
        "SSKWWWWKSS",
        "SWKWWWWKWS",
        "SWWWCCWWWS",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    static let headBlink = [
        "..........",
        "..SSSSSS..",
        ".SSSSSSSS.",
        "SSSSSSSSSS",
        "SSWWWWWWSS",
        "SKKWWWWKKS",
        "SWWWCCWWWS",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    static let headAlert = [
        "....SS....",
        "..SSSSSS..",
        ".SSSSSSSS.",
        "SSSSSSSSSS",
        "SSWWWWWWSS",
        "SKKWWWWKKS",
        "SKKWWWWKKS",
        "SWWWCCWWWS",
        ".WWWWWWWW.",
        "..CCCTCC..",
    ]

    static let headYawn = [
        "..........",
        "..SSSSSS..",
        ".SSSSSSSS.",
        "SSSSSSSSSS",
        "SSWWWWWWSS",
        "SKKWWWWKKS",
        "SWWWCCWWWS",
        ".WWWKKWWW.",
        "..CCCTCC..",
    ]

    static let poses = RunnerArt.catWithHeads(head: head, blink: headBlink, alert: headAlert, yawn: headYawn)
}
