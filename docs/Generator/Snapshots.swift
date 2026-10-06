import CoreGraphics
import Foundation

// Runs TokenCat's synthetic snapshot flags and finds the pieces to crop.
// Only fixture renders are used: no `--snapshot` without fixtures and no `--diagnose` (those read this Mac's real data).

/// Runs the app binary with a CLI flag and waits (60 s watchdog). Output is shown only on failure.
func runSnapshot(_ binary: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    // The image language, whatever this Mac's language is.
    process.arguments = arguments + ["--language", language]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { fail("실행하지 못함: \(binary) (\(error.localizedDescription)). ./build.sh로 먼저 빌드하세요.") }
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        fail("스냅숏 실패: TokenCat \(arguments.joined(separator: " "))\n" + (String(data: output, encoding: .utf8) ?? ""))
    }
}

/// `--snapshot-fixtures` sheet: dark popover | separator | light popover, both halves with the same layout.
struct FixtureSheet {
    let image: CGImage
    let halves: [Theme: Range<Int>]          // x ranges
    let background: [Theme: UInt32]
    /// Vertical bands of cards (and other boxed areas) in the dark half, top to bottom.
    let cards: [Range<Int>]
    /// Rows where any content sits at the probe column (cards, labels, dividers), for padding limits.
    private let contentRows: [Range<Int>]

    var height: Int { image.height }

    init(_ path: String) {
        image = readPNG(path)
        let pixels = Pixels(image)
        let top = 2
        // Halves are the two long uniform runs on the top row.
        let runs = bands(pixels.width, mergeGap: 0, minLength: 200) { x in
            x > 0 && pixels.rgb(x, top) == pixels.rgb(x - 1, top)
        }
        guard runs.count == 2 else { fail("픽스처 좌우 분할을 찾지 못함: \(path)") }
        let dark = runs[0].lowerBound - 1..<runs[0].upperBound, light = runs[1].lowerBound - 1..<runs[1].upperBound
        let darkBackground = pixels.rgb(dark.lowerBound + 2, top), lightBackground = pixels.rgb(light.lowerBound + 2, top)
        guard dark.count == light.count, luminance(darkBackground) < luminance(lightBackground) else {
            fail("픽스처 다크·라이트 순서가 예상과 다름: \(path)")
        }
        halves = [.dark: dark, .light: light]
        background = [.dark: darkBackground, .light: lightBackground]
        // Cards span the full width, so they show at both probes; the header's head and buttons hit only one side.
        let left = dark.lowerBound + 40, right = dark.upperBound - 40
        cards = bands(pixels.height, mergeGap: 12, minLength: 40) {
            pixels.rgb(left, $0) != darkBackground && pixels.rgb(right, $0) != darkBackground
        }
        contentRows = bands(pixels.height, mergeGap: 0, minLength: 1) {
            pixels.rgb(left, $0) != darkBackground || pixels.rgb(right, $0) != darkBackground
        }
    }

    /// First content row at or after `y` (or the image height).
    func nextContent(from y: Int) -> Int { contentRows.first { $0.lowerBound >= y }?.lowerBound ?? height }

    func crop(_ theme: Theme, _ rows: Range<Int>) -> CGImage {
        let x = halves[theme]!
        return cropImage(image, CGRect(x: x.lowerBound, y: rows.lowerBound, width: x.count, height: rows.count))
    }

    /// Named regions used by the feature shots.
    enum Region {
        case all
        case section(Int)       // section label above card i + card i
        case through(Int)       // from the top through card i
        case card(Int)          // card i with even margins
    }

    func rows(_ region: Region) -> Range<Int> {
        let bottomPad = 24
        func end(_ card: Int) -> Int { min(cards[card].upperBound + bottomPad, nextContent(from: cards[card].upperBound) - 4) }
        switch region {
        case .all: return 0..<height
        case let .section(i): return cards[i - 1].upperBound + 14..<end(i)
        case let .through(i): return 0..<end(i)
        case let .card(i):
            let margin = min(28, cards[i].lowerBound)
            return cards[i].lowerBound - margin..<min(cards[i].upperBound + margin, nextContent(from: cards[i].upperBound) - 4)
        }
    }
}

/// `--snapshot-menubar --fixtures` matrix: 11 state rows (the last four with the average speed item: one, two and four clients, then
/// none) × 4 columns (light, dark, light·open, dark·open) on grey.
/// `stateNames` are the Korean row titles, used only as keys; drawn labels go through `loc`.
struct MenuMatrix {
    static let stateNames = ["활동 없음", "진행", "도구 실행", "방금 기록", "로그 대기", "입력 필요", "세션 12개",
                             "속도 · 1개", "속도 · 2개", "속도 · 4개", "속도 측정 없음"]
    enum Column: Int { case light = 0, dark, lightOpen, darkOpen }

    let image: CGImage
    let rows: [Range<Int>]
    /// Per row: each row's strips are as wide as its items (the average speed rows are wider), so columns are found per row.
    let columns: [[Range<Int>]]
    let bar: [Theme: UInt32]

    init(_ path: String) {
        image = readPNG(path)
        let pixels = Pixels(image)
        let grey = pixels.rgb(0, pixels.height - 1)
        // Cell rows are the rows that are mostly non-grey; labels are sparse.
        rows = bands(pixels.height, mergeGap: 0, minLength: 30) { y in
            var count = 0
            for x in 0..<pixels.width where pixels.rgb(x, y) != grey { count += 1 }
            return count * 2 > pixels.width
        }
        // Every column starts at the same x (row 0 finds them); a strip's width varies per row, and its middle line can have
        // wide gaps (`AVG —`), so each strip runs on while any of its lines isn't grey, up to a gap longer than 7 px.
        let first = rows.first.map { row in bands(pixels.width, mergeGap: 7, minLength: 100) { pixels.rgb($0, row.lowerBound + row.count / 2) != grey } } ?? []
        columns = rows.map { row in
            first.map { start in
                var end = start.lowerBound, x = start.lowerBound
                while x < pixels.width, x - end <= 8 {
                    if row.contains(where: { pixels.rgb(x, $0) != grey }) { end = x + 1 }
                    x += 1
                }
                return start.lowerBound..<end
            }
        }
        guard rows.count == MenuMatrix.stateNames.count, columns.allSatisfy({ $0.count == 4 }) else {
            fail("메뉴 막대 매트릭스 구조가 예상과 다름(\(rows.count)행 × \(columns.map(\.count))열): \(path)")
        }
        let middle = rows[0].lowerBound + rows[0].count / 2
        bar = [.light: pixels.rgb(columns[0][0].lowerBound + 4, middle), .dark: pixels.rgb(columns[0][1].lowerBound + 4, middle)]
        guard luminance(bar[.dark]!) < luminance(bar[.light]!) else { fail("메뉴 막대 열 순서가 예상과 다름: \(path)") }
    }

    func cell(_ state: Int, _ column: Column) -> CGRect {
        let x = columns[state][column.rawValue], y = rows[state]
        return CGRect(x: x.lowerBound, y: y.lowerBound, width: x.count, height: y.count)
    }

    /// Full-height slice without the rounded ends (all remaining edge pixels are bar colour).
    func slice(_ state: Int, _ column: Column, inset: CGFloat = 14) -> CGImage {
        cropImage(image, cell(state, column).insetBy(dx: inset, dy: 0))
    }

    /// Cell inset on every side, for re-clipping onto a new rounded bar.
    func inner(_ state: Int, _ column: Column, inset: CGFloat = 3) -> CGImage {
        cropImage(image, cell(state, column).insetBy(dx: inset, dy: inset))
    }

    static func column(_ theme: Theme, open: Bool = false) -> Column {
        switch (theme, open) {
        case (.light, false): return .light
        case (.dark, false): return .dark
        case (.light, true): return .lightOpen
        case (.dark, true): return .darkOpen
        }
    }
}

func luminance(_ rgb: UInt32) -> Double {
    0.2126 * Double((rgb >> 16) & 0xFF) + 0.7152 * Double((rgb >> 8) & 0xFF) + 0.0722 * Double(rgb & 0xFF)
}
