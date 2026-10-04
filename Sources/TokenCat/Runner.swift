import AppKit
import ImageIO

/// Generated source artwork is kept intact; decoding and scaling happen once.
enum Runner {
    static let frameCount = 8
    private static let cache = ArtworkCache()

    static func image(frame: Int) -> NSImage {
        cache.frames[((frame % frameCount) + frameCount) % frameCount]
    }

    static func brandImage() -> NSImage { cache.brand }

    static func resourceErrors() -> [String] { cache.errors }

    private struct ArtworkCache {
        var frames: [NSImage]
        var brand: NSImage
        var errors: [String] = []

        init() {
            frames = (0..<frameCount).map { _ in NSImage(size: NSSize(width: 32, height: 20)) }
            brand = NSImage(size: NSSize(width: 32, height: 32))

            if let source = Self.load("runner-sheet-v1", errors: &errors) {
                loadFrames(source)
            }
            if let source = Self.load("app-mark-v1", errors: &errors),
               let bounds = Self.alphaBounds(source, errors: &errors, name: "app-mark-v1") {
                if let cropped = source.cropping(to: bounds) {
                    brand = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
                    brand.isTemplate = false
                } else {
                    errors.append("app-mark-v1: 투명 여백을 제외한 이미지 영역을 읽지 못했습니다.")
                }
            }

            if !errors.isEmpty {
                FileHandle.standardError.write(Data(("TokenCat artwork: " + errors.joined(separator: "; ") + "\n").utf8))
            }
        }

        private static func load(_ name: String, errors: inout [String]) -> CGImage? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
                errors.append("\(name).png: 앱 번들에 이미지가 없습니다.")
                return nil
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                errors.append("\(name).png: 이미지를 디코딩하지 못했습니다.")
                return nil
            }
            return image
        }

        private mutating func loadFrames(_ source: CGImage) {
            guard source.width == source.height * 2 else {
                errors.append("runner-sheet-v1: 4열 × 2행의 같은 크기 정사각형 셀이 필요합니다.")
                return
            }
            guard source.height >= 2 else {
                errors.append("runner-sheet-v1: 프레임 크기가 0입니다.")
                return
            }

            var cells: [CGImage] = []
            var bounds: [CGRect] = []
            var rowBounds = [CGRect.null, CGRect.null]
            func edge(_ index: Int, length: Int, divisions: Int) -> Int {
                Int((Double(index) * Double(length) / Double(divisions)).rounded(.toNearestOrEven))
            }
            for index in 0..<frameCount {
                let column = index % 4
                let row = index / 4
                let left = edge(column, length: source.width, divisions: 4)
                let right = edge(column + 1, length: source.width, divisions: 4)
                let top = edge(row, length: source.height, divisions: 2)
                let bottom = edge(row + 1, length: source.height, divisions: 2)
                let cellRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                guard let cell = source.cropping(to: cellRect),
                      let frameBounds = Self.alphaBounds(cell, errors: &errors, name: "runner-sheet-v1 프레임 \(index + 1)") else { return }
                cells.append(cell)
                bounds.append(frameBounds)
                rowBounds[row] = rowBounds[row].union(frameBounds)
            }

            // Generated rows may be placed at different heights. Align each
            // row's shared floor, retaining the bounce between its four poses.
            let floor = rowBounds.map(\.maxY).max() ?? 0
            let rowOffsets = rowBounds.map { floor - $0.maxY }
            var sharedBounds = CGRect.null
            for index in 0..<frameCount {
                sharedBounds = sharedBounds.union(bounds[index].offsetBy(dx: 0, dy: rowOffsets[index / 4]))
            }
            sharedBounds = sharedBounds.insetBy(dx: -2, dy: -2).integral
            var prepared: [NSImage] = []
            for (index, cell) in cells.enumerated() {
                guard let image = Self.statusImage(cell, bounds: sharedBounds, verticalOffset: rowOffsets[index / 4]) else {
                    errors.append("runner-sheet-v1: 메뉴바 프레임을 만들지 못했습니다.")
                    return
                }
                prepared.append(image)
            }
            frames = prepared
        }

        private static func statusImage(_ source: CGImage, bounds: CGRect, verticalOffset: CGFloat) -> NSImage? {
            let width = 64
            let height = 40
            guard let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let scale = min(CGFloat(width) / bounds.width, CGFloat(height) / bounds.height)
            let insetX = (CGFloat(width) - bounds.width * scale) / 2
            let insetY = (CGFloat(height) - bounds.height * scale) / 2
            let drawnWidth = CGFloat(source.width) * scale
            let drawnHeight = CGFloat(source.height) * scale
            let rect = CGRect(x: insetX - bounds.minX * scale,
                              y: CGFloat(height) - insetY - (verticalOffset - bounds.minY) * scale - drawnHeight,
                              width: drawnWidth, height: drawnHeight)
            context.interpolationQuality = .high
            context.draw(source, in: rect)
            guard let raster = context.makeImage() else { return nil }
            let result = NSImage(cgImage: raster, size: NSSize(width: 32, height: 20))
            result.isTemplate = false
            return result
        }

        private static func alphaBounds(_ source: CGImage, errors: inout [String], name: String) -> CGRect? {
            let width = source.width
            let height = source.height
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = context.data else {
                errors.append("\(name): 알파 채널을 읽지 못했습니다.")
                return nil
            }
            // Bitmap memory rows match CGImage's top-left crop coordinates.
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1
            var hasTransparentBackground = false
            for y in 0..<height {
                for x in 0..<width {
                    let alpha = pixels[(y * width + x) * 4 + 3]
                    if alpha == 0 { hasTransparentBackground = true }
                    if alpha > 32 {
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else {
                errors.append("\(name): 보이는 이미지가 없습니다.")
                return nil
            }
            guard hasTransparentBackground else {
                errors.append("\(name): 투명 배경이 필요합니다.")
                return nil
            }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }
}
