import AppKit
import ImageIO

/// Menu bar cat poses. Frame 0 of every pose is its still frame (Reduce Motion, paused states).
enum RunnerPose: String, CaseIterable {
    case sit, sleep, walk, run, alert
}

/// Runner sprite v2: pixel-art sheets (30 × 18 px cells @1x, 60 × 36 px @2x, alpha 0 or 255)
/// described by runner-v2.json. Frames are decoded once and returned as 32 × 20 pt images with
/// a 1 pt transparent margin, so the 32 × 20 status bar slot draws them 1:1 without resampling.
enum Runner {
    static let size = NSSize(width: 32, height: 20)
    static let expectedFrames: [RunnerPose: Int] = [.sit: 2, .sleep: 2, .walk: 4, .run: 6, .alert: 2]
    /// Run-only API kept for callers that predate poses.
    static let frameCount = 6
    private static let cell = (width: 30, height: 18)
    private static let cache = ArtworkCache()

    static func image(frame: Int) -> NSImage { image(pose: .run, frame: frame) }

    static func frames(_ pose: RunnerPose) -> Int { expectedFrames[pose] ?? 1 }

    static func image(pose: RunnerPose, frame: Int) -> NSImage {
        let images = cache.frames[pose] ?? [cache.blank]
        return images[((frame % images.count) + images.count) % images.count]
    }

    /// Suggested seconds for a frame (manifest): a long sit hold with a short blink, slow sleep breaths.
    static func duration(_ pose: RunnerPose, frame: Int) -> TimeInterval {
        let values = cache.durations[pose] ?? []
        return values.isEmpty ? 0.125 : values[((frame % values.count) + values.count) % values.count]
    }

    static func brandImage() -> NSImage { cache.brand }

    static func resourceErrors() -> [String] { cache.errors }

    private struct Manifest: Decodable {
        struct Size: Decodable { var width: Int; var height: Int }
        struct Pose: Decodable { var pose: String; var row: Int; var frames: Int; var durations: [Double] }
        var cell: Size
        var sheets: [String: String]
        var poses: [Pose]
    }

    /// Premultiplied sRGB RGBA bytes, row 0 at the top.
    private struct Pixels {
        var width: Int, height: Int, bytes: [UInt8]
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
        func pixel(_ x: Int, _ y: Int) -> ArraySlice<UInt8> { bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4] }
    }

    private struct ArtworkCache {
        var frames: [RunnerPose: [NSImage]] = [:]
        var durations: [RunnerPose: [TimeInterval]] = [:]
        var blank = NSImage(size: Runner.size)
        var brand = NSImage(size: NSSize(width: 32, height: 32))
        var errors: [String] = []

        init() {
            for pose in RunnerPose.allCases { frames[pose] = Array(repeating: blank, count: Runner.frames(pose)) }
            loadRunner()
            loadBrand()
            if !errors.isEmpty {
                FileHandle.standardError.write(Data(("TokenCat artwork: " + errors.joined(separator: "; ") + "\n").utf8))
            }
        }

        private mutating func loadRunner() {
            guard let url = Bundle.main.url(forResource: "runner-v2", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                errors.append("runner-v2.json: 앱 번들에 없거나 읽을 수 없습니다.")
                return
            }
            guard manifest.cell.width == Runner.cell.width, manifest.cell.height == Runner.cell.height else {
                errors.append("runner-v2.json: 프레임 크기는 \(Runner.cell.width)×\(Runner.cell.height)이어야 합니다.")
                return
            }
            var rows: [RunnerPose: Manifest.Pose] = [:]
            for entry in manifest.poses {
                guard let pose = RunnerPose(rawValue: entry.pose), rows[pose] == nil else {
                    errors.append("runner-v2.json: 알 수 없거나 중복된 자세 \(entry.pose)")
                    continue
                }
                if entry.frames != Runner.frames(pose) {
                    errors.append("runner-v2.json: \(pose.rawValue) 프레임 \(entry.frames)개, 필요한 수 \(Runner.frames(pose))개")
                }
                if entry.durations.count != entry.frames || entry.durations.contains(where: { !($0 > 0) }) {
                    errors.append("runner-v2.json: \(pose.rawValue) 프레임 시간이 프레임 수와 맞지 않습니다.")
                }
                rows[pose] = entry
            }
            for pose in RunnerPose.allCases where rows[pose] == nil { errors.append("runner-v2.json: \(pose.rawValue) 자세가 없습니다.") }
            guard errors.isEmpty,
                  let low = Self.load(manifest.sheets["1"], errors: &errors),
                  let high = Self.load(manifest.sheets["2"], errors: &errors) else { return }

            let columns = low.width / Runner.cell.width, rowCount = low.height / Runner.cell.height
            guard low.width == columns * Runner.cell.width, low.height == rowCount * Runner.cell.height,
                  high.width == low.width * 2, high.height == low.height * 2 else {
                errors.append("runner-v2 시트: @1x는 30×18 셀의 배수, @2x는 정확히 두 배여야 합니다.")
                return
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
                errors.append("runner-v2 시트: 알파는 0 또는 255만 허용됩니다.")
            }
            if !nearest { errors.append("runner-v2 시트: @2x가 @1x의 최근접 확대와 다릅니다.") }

            for (pose, entry) in rows {
                guard entry.row >= 0, entry.row < rowCount, entry.frames <= columns else {
                    errors.append("runner-v2 시트: \(pose.rawValue) 행이 시트 밖에 있습니다.")
                    continue
                }
                var cells: [[UInt8]] = []
                for column in 0..<columns {
                    let cellPixels = Self.cell(low, column: column, row: entry.row, scale: 1)
                    let opaque = stride(from: 3, to: cellPixels.count, by: 4).contains { cellPixels[$0] != 0 }
                    if column < entry.frames && !opaque { errors.append("runner-v2 시트: \(pose.rawValue) \(column + 1)번 프레임이 비었습니다.") }
                    if column >= entry.frames && opaque { errors.append("runner-v2 시트: \(pose.rawValue) 행에 매니페스트보다 많은 프레임이 있습니다.") }
                    if column < entry.frames { cells.append(cellPixels) }
                }
                for index in cells.indices where cells.count > 1 && cells[index] == cells[(index + 1) % cells.count] {
                    errors.append("runner-v2 시트: \(pose.rawValue) \(index + 1)번과 다음 프레임이 같습니다.")
                }
                frames[pose] = (0..<entry.frames).map { Self.frameImage(low: low, high: high, column: $0, row: entry.row) }
                durations[pose] = entry.durations
            }
        }

        private static func load(_ file: String?, errors: inout [String]) -> Pixels? {
            guard let file, let url = Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: "png") else {
                errors.append("\(file ?? "runner-v2 시트"): 앱 번들에 이미지가 없습니다.")
                return nil
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let pixels = pixels(image) else {
                errors.append("\(file): 이미지를 디코딩하지 못했습니다.")
                return nil
            }
            return pixels
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

        /// Copies one cell into a padded 32 × 20 pt image with exact @1x and @2x pixel representations.
        private static func frameImage(low: Pixels, high: Pixels, column: Int, row: Int) -> NSImage {
            let image = NSImage(size: Runner.size)
            for (sheet, scale) in [(low, 1), (high, 2)] {
                let width = Int(Runner.size.width) * scale, height = Int(Runner.size.height) * scale
                let art = cell(sheet, column: column, row: row, scale: scale)
                let artWidth = Runner.cell.width * scale, inset = scale
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                for y in 0..<Runner.cell.height * scale {
                    let target = ((y + inset) * width + inset) * 4
                    bytes.replaceSubrange(target..<target + artWidth * 4, with: art[y * artWidth * 4..<(y + 1) * artWidth * 4])
                }
                guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let raster = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                           space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { continue }
                let rep = NSBitmapImageRep(cgImage: raster)
                rep.size = Runner.size
                image.addRepresentation(rep)
            }
            image.isTemplate = false
            return image
        }

        private mutating func loadBrand() {
            guard let url = Bundle.main.url(forResource: "app-mark-v1", withExtension: "png"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                errors.append("app-mark-v1.png: 앱 번들에 없거나 디코딩하지 못했습니다.")
                return
            }
            guard let pixels = Self.pixels(image) else {
                errors.append("app-mark-v1: 알파 채널을 읽지 못했습니다.")
                return
            }
            var minX = pixels.width, minY = pixels.height, maxX = -1, maxY = -1, transparent = false
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    let alpha = pixels.alpha(x, y)
                    if alpha == 0 { transparent = true }
                    if alpha > 32 { minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) }
                }
            }
            guard maxX >= minX, transparent,
                  let cropped = image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else {
                errors.append("app-mark-v1: 투명 배경과 보이는 이미지가 필요합니다.")
                return
            }
            brand = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
            brand.isTemplate = false
        }
    }
}
