/// The character palette (sRGB): the single colour source for the menu bar sprite, the pixel heads,
/// the 16 · 32 px icons and the master icon's collar. Documented in Assets/runner-v2.md (B-1).
enum Palette {
    static let outline = RGBA(hex: 0x24262D) // K: outline, eyes
    static let fur = RGBA(hex: 0xF8F9FB)     // W
    static let shade = RGBA(hex: 0xC4C9D3)   // S: inner ear, belly
    static let farLimb = RGBA(hex: 0xA3A9B6) // G
    static let collar = RGBA(hex: 0x3A4FE0)  // C: indigo cobalt, not systemBlue
    static let tag = RGBA(hex: 0x9DABFF)     // T: collar tag

    static let tokens: [Character: RGBA] = ["K": outline, "W": fur, "S": shade, "G": farLimb, "C": collar, "T": tag]
}
