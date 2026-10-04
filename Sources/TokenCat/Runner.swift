import AppKit
import ImageIO

/// Menu bar cat poses. Frame 0 of every pose is its still frame (Reduce Motion, paused states).
/// `yawn` (wake-up, 1 frame) and `content` (turn finished, 2 frames) are one-shots (K-5).
enum RunnerPose: String, CaseIterable {
    case sit, sleep, walk, run, alert, yawn, content
}

/// Pixel head variants for the popover header, the first-run card and the about pane (B-3).
enum RunnerHead: String, CaseIterable {
    case normal, blink, alert, sleep
}

/// Frame timing for one pose (K-6); the animator reads only this.
struct RunnerTiming: Equatable {
    /// Seconds each frame shows, one entry per frame.
    var durations: [TimeInterval]
    /// When not empty, successive holds of frame 0 cycle through these seconds instead of `durations[0]`
    /// (the sit blink rhythm). Seconds, not frame indices.
    var holdSequence: [TimeInterval] = []
    /// Every Nth blink is a double blink (closed · open · closed); nil never doubles.
    var doubleEvery: Int? = nil
    /// Seconds the eyes stay open between the two closes of a double blink (closes use `durations[1]`).
    /// The manifest sets it exactly when `doubleEvery` is set.
    var doubleGap: TimeInterval? = nil
}

/// Runner sprite v2: pixel-art sheets (30 × 18 px cells @1x, 60 × 36 px @2x, alpha 0 or 255)
/// described by runner-v2.json (manifest v3). Frames are decoded once and returned as 32 × 20 pt images with
/// a 1 pt transparent margin, so the 32 × 20 status bar slot draws them 1:1 without resampling.
enum Runner {
    static let size = NSSize(width: 32, height: 20)
    static let headSize = NSSize(width: 12, height: 11)
    static let expectedFrames: [RunnerPose: Int] = [.sit: 2, .sleep: 2, .walk: 4, .run: 6, .alert: 2, .yawn: 1, .content: 2]
    private static let cell = (width: 30, height: 18)
    private static let cache = ArtworkCache()

    static func frames(_ pose: RunnerPose) -> Int { expectedFrames[pose] ?? 1 }

    static func image(pose: RunnerPose, frame: Int) -> NSImage {
        let images = cache.frames[pose] ?? [cache.blank]
        return images[((frame % images.count) + images.count) % images.count]
    }

    /// The 12 × 11 pt pixel head (`app-head-<variant>@1x/@2x.png`: 12 × 11 and 24 × 22 px, nearest, alpha 0/255).
    /// Draw it at whole multiples only (2 pt per art pixel = 24 × 22 pt) with interpolation off. `sleep` has the same
    /// closed eyes as `blink`, like the menu bar sleep head; `alert` has the input pose's wide eyes.
    static func headImage(_ variant: RunnerHead) -> NSImage { cache.heads[variant] ?? NSImage(size: headSize) }

    /// Effect layer for `pose` at animation `step` (the sleep z): a template mask, alpha 0/255, in the same 32 × 20 pt
    /// frame as `image(pose:frame:)`. Draw it at the sprite's snapped origin filled with `secondaryLabelColor`
    /// (Increase Contrast `labelColor`, highlighted the selected text colour) in its own transparency layer with a
    /// `sourceIn` fill (the menu bar's `drawRunner`), SwiftUI as `Image(nsImage:)` with `.renderingMode(.template)` and
    /// `.interpolation(.none)` over the sprite. nil draws nothing. The sprite has no z since K-2, so every place that shows
    /// a sleeping cat draws this after the sprite.
    /// Sleep cycles 3 steps (K-3): 0 = body frame 0 without z, 1 = frame 1 + zS, 2 = frame 0 + zL.
    /// Steps wrap; the still and deep-sleep frame use the last step (zL).
    static func fxMask(pose: RunnerPose, step: Int) -> NSImage? {
        guard let masks = cache.fx[pose], !masks.isEmpty else { return nil }
        return masks[((step % masks.count) + masks.count) % masks.count]
    }

    /// Frame timing for `pose` from the manifest (`durations`, `holdSequence`, `doubleEvery`, `doubleGap`).
    static func timing(_ pose: RunnerPose) -> RunnerTiming {
        cache.timings[pose] ?? RunnerTiming(durations: Array(repeating: 0.125, count: frames(pose)))
    }

    static func resourceErrors() -> [String] { cache.errors }

    private struct Manifest: Decodable {
        struct Size: Decodable { var width: Int; var height: Int }
        struct Pose: Decodable {
            var pose: String; var row: Int; var frames: Int; var durations: [Double]
            var holdSequence: [Double]?; var doubleEvery: Int?; var doubleGap: Double?
        }
        struct Glyph: Decodable { var x: Int; var y: Int; var width: Int; var height: Int }
        struct Effect: Decodable { var pose: String; var step: Int; var glyph: String; var x: Int; var y: Int }
        var cell: Size
        var sheets: [String: String]
        var fxSheets: [String: String]
        var poses: [Pose]
        var glyphs: [String: Glyph]
        var fx: [Effect]
    }

    /// Premultiplied sRGB RGBA bytes, row 0 at the top.
    private struct Pixels {
        var width: Int, height: Int, bytes: [UInt8]
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
        func pixel(_ x: Int, _ y: Int) -> ArraySlice<UInt8> { bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4] }
        var opaque: Bool { stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] != 0 } }
    }

    private struct ArtworkCache {
        var frames: [RunnerPose: [NSImage]] = [:]
        var timings: [RunnerPose: RunnerTiming] = [:]
        var fx: [RunnerPose: [NSImage?]] = [:]
        var heads: [RunnerHead: NSImage] = [:]
        var blank = NSImage(size: Runner.size)
        var errors: [String] = []

        init() {
            for pose in RunnerPose.allCases { frames[pose] = Array(repeating: blank, count: Runner.frames(pose)) }
            loadRunner()
            loadHeads()
            if !errors.isEmpty {
                FileHandle.standardError.write(Data(("TokenCat artwork: " + errors.joined(separator: "; ") + "\n").utf8))
            }
        }

        private mutating func loadRunner() {
            guard let url = Bundle.main.url(forResource: "runner-v2", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                errors.append(loc("runner-v2.json: 앱 번들에 없거나 v3 형식으로 읽을 수 없습니다.", "runner-v2.json: missing from the app bundle or not readable as v3."))
                return
            }
            guard manifest.cell.width == Runner.cell.width, manifest.cell.height == Runner.cell.height else {
                errors.append(loc("runner-v2.json: 프레임 크기는 \(Runner.cell.width)×\(Runner.cell.height)이어야 합니다.",
                                  "runner-v2.json: the frame size must be \(Runner.cell.width)×\(Runner.cell.height)."))
                return
            }
            var rows: [RunnerPose: Manifest.Pose] = [:]
            for entry in manifest.poses {
                guard let pose = RunnerPose(rawValue: entry.pose), rows[pose] == nil else {
                    errors.append(loc("runner-v2.json: 알 수 없거나 중복된 자세 \(entry.pose)", "runner-v2.json: unknown or duplicate pose \(entry.pose)"))
                    continue
                }
                if entry.frames != Runner.frames(pose) {
                    errors.append(loc("runner-v2.json: \(pose.rawValue) 프레임 \(entry.frames)개, 필요한 수 \(Runner.frames(pose))개",
                                      "runner-v2.json: \(pose.rawValue) has \(plural(entry.frames, "frame")), needs \(Runner.frames(pose))"))
                }
                if entry.durations.count != entry.frames || entry.durations.contains(where: { !($0 > 0) })
                    || (entry.holdSequence ?? []).contains(where: { !($0 > 0) }) || (entry.doubleEvery.map { $0 < 1 } ?? false) {
                    errors.append(loc("runner-v2.json: \(pose.rawValue) 프레임 시간이 프레임 수와 맞지 않거나 양수가 아닙니다.",
                                      "runner-v2.json: \(pose.rawValue) frame times don't match the frame count or aren't positive."))
                }
                if (entry.doubleEvery == nil) != (entry.doubleGap == nil) || (entry.doubleGap.map { !($0 > 0) } ?? false) {
                    errors.append(loc("runner-v2.json: \(pose.rawValue) doubleGap은 양수이고 doubleEvery와 함께 있어야 합니다.",
                                      "runner-v2.json: \(pose.rawValue) doubleGap must be positive and come with doubleEvery."))
                }
                rows[pose] = entry
            }
            for pose in RunnerPose.allCases where rows[pose] == nil {
                errors.append(loc("runner-v2.json: \(pose.rawValue) 자세가 없습니다.", "runner-v2.json: the \(pose.rawValue) pose is missing."))
            }
            guard errors.isEmpty,
                  let low = Self.load(manifest.sheets["1"], errors: &errors),
                  let high = Self.load(manifest.sheets["2"], errors: &errors) else { return }

            let columns = low.width / Runner.cell.width, rowCount = low.height / Runner.cell.height
            guard low.width == columns * Runner.cell.width, low.height == rowCount * Runner.cell.height else {
                errors.append(loc("runner-v2 시트: @1x는 30×18 셀의 배수여야 합니다.", "runner-v2 sheet: @1x must be a multiple of 30×18 cells."))
                return
            }
            guard Self.checkPair(low, high, loc("runner-v2 시트", "runner-v2 sheet"), errors: &errors) else { return }

            for (pose, entry) in rows {
                guard entry.row >= 0, entry.row < rowCount, entry.frames <= columns else {
                    errors.append(loc("runner-v2 시트: \(pose.rawValue) 행이 시트 밖에 있습니다.", "runner-v2 sheet: the \(pose.rawValue) row is outside the sheet."))
                    continue
                }
                var cells: [[UInt8]] = []
                for column in 0..<columns {
                    let cellPixels = Self.cell(low, column: column, row: entry.row, scale: 1)
                    let opaque = stride(from: 3, to: cellPixels.count, by: 4).contains { cellPixels[$0] != 0 }
                    if column < entry.frames && !opaque {
                        errors.append(loc("runner-v2 시트: \(pose.rawValue) \(column + 1)번 프레임이 비었습니다.", "runner-v2 sheet: \(pose.rawValue) frame \(column + 1) is empty."))
                    }
                    if column >= entry.frames && opaque {
                        errors.append(loc("runner-v2 시트: \(pose.rawValue) 행에 매니페스트보다 많은 프레임이 있습니다.",
                                          "runner-v2 sheet: the \(pose.rawValue) row has more frames than the manifest."))
                    }
                    if column < entry.frames { cells.append(cellPixels) }
                }
                for index in cells.indices where cells.count > 1 && cells[index] == cells[(index + 1) % cells.count] {
                    errors.append(loc("runner-v2 시트: \(pose.rawValue) \(index + 1)번과 다음 프레임이 같습니다.",
                                      "runner-v2 sheet: \(pose.rawValue) frame \(index + 1) is the same as the next one."))
                }
                frames[pose] = (0..<entry.frames).map { Self.frameImage(low: low, high: high, column: $0, row: entry.row) }
                timings[pose] = RunnerTiming(durations: entry.durations, holdSequence: entry.holdSequence ?? [],
                                             doubleEvery: entry.doubleEvery, doubleGap: entry.doubleGap)
            }
            loadEffects(manifest, rows: rows, sprite: low)
        }

        /// The sleep z (K-2): glyphs from the fx atlas placed in cell coordinates, one template mask per step.
        private mutating func loadEffects(_ manifest: Manifest, rows: [RunnerPose: Manifest.Pose], sprite: Pixels) {
            guard let low = Self.load(manifest.fxSheets["1"], errors: &errors),
                  let high = Self.load(manifest.fxSheets["2"], errors: &errors),
                  Self.checkPair(low, high, loc("runner-v2-fx 시트", "runner-v2-fx sheet"), errors: &errors) else { return }
            var steps: [RunnerPose: [Int: [(glyph: Manifest.Glyph, x: Int, y: Int)]]] = [:]
            for effect in manifest.fx {
                let name = "runner-v2.json: fx \(effect.pose) \(effect.step) \(effect.glyph)"
                guard let pose = RunnerPose(rawValue: effect.pose), let entry = rows[pose], effect.step >= 0,
                      let glyph = manifest.glyphs[effect.glyph] else {
                    errors.append(loc("\(name): 자세나 글리프를 찾을 수 없습니다.", "\(name): pose or glyph not found."))
                    continue
                }
                guard glyph.x >= 0, glyph.y >= 0, glyph.width > 0, glyph.height > 0,
                      glyph.x + glyph.width <= low.width, glyph.y + glyph.height <= low.height,
                      effect.x >= 0, effect.y >= 0, effect.x + glyph.width <= Runner.cell.width, effect.y + glyph.height <= Runner.cell.height else {
                    errors.append(loc("\(name): 글리프가 fx 시트나 셀 밖에 있습니다.", "\(name): the glyph is outside the fx sheet or the cell."))
                    continue
                }
                var pixels: [(x: Int, y: Int)] = []
                for gy in 0..<glyph.height { for gx in 0..<glyph.width where low.alpha(glyph.x + gx, glyph.y + gy) != 0 {
                    pixels.append((effect.x + gx, effect.y + gy))
                }}
                if pixels.isEmpty { errors.append(loc("\(name): 글리프가 비었습니다.", "\(name): the glyph is empty.")) }
                // At least one clear pixel (8 neighbours) between the effect and every frame of the pose.
                let touches = (0..<entry.frames).contains { column in
                    pixels.contains { p in (-1...1).contains { dy in (-1...1).contains { dx in
                        let x = p.x + dx, y = p.y + dy
                        return x >= 0 && y >= 0 && x < Runner.cell.width && y < Runner.cell.height
                            && sprite.alpha(column * Runner.cell.width + x, entry.row * Runner.cell.height + y) != 0
                    }}}
                }
                if touches { errors.append(loc("\(name): 스프라이트와 1 px 간격이 없습니다.", "\(name): no 1 px gap from the sprite.")) }
                steps[pose, default: [:]][effect.step, default: []].append((glyph, effect.x, effect.y))
            }
            for (pose, placed) in steps {
                fx[pose] = (0...placed.keys.max()!).map { step in
                    placed[step].map { Self.effectImage(low: low, high: high, placements: $0) }
                }
            }
        }

        private mutating func loadHeads() {
            for variant in RunnerHead.allCases {
                let name = "app-head-\(variant.rawValue)"
                guard let low = Self.load(name + "@1x.png", errors: &errors),
                      let high = Self.load(name + "@2x.png", errors: &errors) else { continue }
                guard low.width == Int(Runner.headSize.width), low.height == Int(Runner.headSize.height), low.opaque else {
                    errors.append(loc("\(name): 12×11 px이고 비어 있지 않아야 합니다.", "\(name): must be 12×11 px and not empty."))
                    continue
                }
                guard Self.checkPair(low, high, name, errors: &errors) else { continue }
                heads[variant] = Self.image(Runner.headSize, [(low.bytes, low.width, low.height), (high.bytes, high.width, high.height)], template: false)
            }
        }

        private static func load(_ file: String?, errors: inout [String]) -> Pixels? {
            guard let file, let url = Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: "png") else {
                errors.append(loc("\(file ?? "runner-v2 시트"): 앱 번들에 이미지가 없습니다.", "\(file ?? "runner-v2 sheet"): image missing from the app bundle."))
                return nil
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let pixels = pixels(image) else {
                errors.append(loc("\(file): 이미지를 디코딩하지 못했습니다.", "\(file): couldn't decode the image."))
                return nil
            }
            return pixels
        }

        /// @2x is exactly twice @1x, both use alpha 0/255 only, and @2x equals the nearest-neighbour enlargement.
        private static func checkPair(_ low: Pixels, _ high: Pixels, _ name: String, errors: inout [String]) -> Bool {
            guard high.width == low.width * 2, high.height == low.height * 2 else {
                errors.append(loc("\(name): @2x는 @1x의 정확히 두 배여야 합니다.", "\(name): @2x must be exactly twice @1x."))
                return false
            }
            var binary = true, nearest = true
            for y in 0..<high.height {
                for x in 0..<high.width {
                    let alpha = high.alpha(x, y)
                    if alpha != 0 && alpha != 255 { binary = false }
                    if high.pixel(x, y) != low.pixel(x / 2, y / 2) { nearest = false }
                }
            }
            if !binary || low.bytes.enumerated().contains(where: { $0.offset % 4 == 3 && $0.element != 0 && $0.element != 255 }) {
                errors.append(loc("\(name): 알파는 0 또는 255만 허용됩니다.", "\(name): alpha must be 0 or 255."))
            }
            if !nearest { errors.append(loc("\(name): @2x가 @1x의 최근접 확대와 다릅니다.", "\(name): @2x differs from the nearest-neighbour enlargement of @1x.")) }
            return binary && nearest
        }

        private static func pixels(_ image: CGImage) -> Pixels? {
            let width = image.width, height = image.height
            guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = context.data else { return nil }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return Pixels(width: width, height: height,
                          bytes: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)))
        }

        private static func cell(_ sheet: Pixels, column: Int, row: Int, scale: Int) -> [UInt8] {
            let width = Runner.cell.width * scale, height = Runner.cell.height * scale
            var out: [UInt8] = []
            out.reserveCapacity(width * height * 4)
            for y in 0..<height {
                let start = ((row * height + y) * sheet.width + column * width) * 4
                out += sheet.bytes[start..<start + width * 4]
            }
            return out
        }

        /// An image with one exact bitmap representation per buffer (premultiplied sRGB RGBA).
        private static func image(_ size: NSSize, _ reps: [(bytes: [UInt8], width: Int, height: Int)], template: Bool) -> NSImage {
            let image = NSImage(size: size)
            for rep in reps {
                guard let provider = CGDataProvider(data: Data(rep.bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let raster = CGImage(width: rep.width, height: rep.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rep.width * 4,
                                           space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { continue }
                let bitmap = NSBitmapImageRep(cgImage: raster)
                bitmap.size = size
                image.addRepresentation(bitmap)
            }
            image.isTemplate = template
            return image
        }

        /// Copies one cell into a padded 32 × 20 pt image with exact @1x and @2x pixel representations.
        private static func frameImage(low: Pixels, high: Pixels, column: Int, row: Int) -> NSImage {
            let reps = [(low, 1), (high, 2)].map { sheet, scale -> ([UInt8], Int, Int) in
                let width = Int(Runner.size.width) * scale, height = Int(Runner.size.height) * scale
                let art = cell(sheet, column: column, row: row, scale: scale)
                let artWidth = Runner.cell.width * scale, inset = scale
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                for y in 0..<Runner.cell.height * scale {
                    let target = ((y + inset) * width + inset) * 4
                    bytes.replaceSubrange(target..<target + artWidth * 4, with: art[y * artWidth * 4..<(y + 1) * artWidth * 4])
                }
                return (bytes, width, height)
            }
            return image(Runner.size, reps, template: false)
        }

        /// Opaque black mask pixels of the placed glyphs in a padded 32 × 20 pt template image.
        private static func effectImage(low: Pixels, high: Pixels, placements: [(glyph: Manifest.Glyph, x: Int, y: Int)]) -> NSImage {
            let reps = [(low, 1), (high, 2)].map { sheet, scale -> ([UInt8], Int, Int) in
                let width = Int(Runner.size.width) * scale, height = Int(Runner.size.height) * scale
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                for placed in placements {
                    for gy in 0..<placed.glyph.height * scale { for gx in 0..<placed.glyph.width * scale
                        where sheet.alpha(placed.glyph.x * scale + gx, placed.glyph.y * scale + gy) != 0 {
                        bytes[(((1 + placed.y) * scale + gy) * width + (1 + placed.x) * scale + gx) * 4 + 3] = 255
                    }}
                }
                return (bytes, width, height)
            }
            return image(Runner.size, reps, template: true)
        }
    }
}
