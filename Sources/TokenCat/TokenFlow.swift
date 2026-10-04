import Foundation
import SwiftUI

/// Log-recorded output volume in 5 s wall-clock buckets. Counts only, never a rate:
/// `at` is when a client wrote the usage record, not when tokens streamed.
/// Rebuilt from scratch on every update; there is no incremental state.
struct FlowSeries: Equatable {
    static let bucketSeconds: TimeInterval = 5
    static let heroCount = 60
    static let freshSeconds: TimeInterval = 5
    /// Writers' clocks may run slightly ahead; such records land in the newest bucket.
    static let futureTolerance: TimeInterval = 5

    /// Start of the newest bucket: `floor(now / 5) * 5`.
    var newest: Date
    /// Oldest → newest.
    var hero: [Int]
    var fresh: [Bool]
    var byProvider: [TokenSource: Int]
    var last: TokenOutputEvent?

    var total: Int { hero.reduce(0, +) }
    var peak: Int { hero.max() ?? 0 }

    static let empty = FlowSeries(newest: .distantPast, hero: Array(repeating: 0, count: heroCount),
                                  fresh: Array(repeating: false, count: heroCount), byProvider: [:], last: nil)

    static func bucketStart(_ now: Date) -> Date {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 / bucketSeconds).rounded(.down) * bucketSeconds)
    }

    /// Buckets back from the newest one (0 = newest), or nil when the record is outside the window.
    static func offset(of at: Date, now: Date, newest: Date, count: Int) -> Int? {
        guard at.timeIntervalSince(now) <= futureTolerance else { return nil }
        let behind = newest.timeIntervalSince(at)
        let offset = behind <= 0 ? 0 : Int((behind / bucketSeconds).rounded(.up))
        return offset < count ? offset : nil
    }

    static func make(_ readings: [TokenReading], now: Date) -> FlowSeries {
        let newest = bucketStart(now)
        var series = FlowSeries(newest: newest, hero: Array(repeating: 0, count: heroCount),
                                fresh: Array(repeating: false, count: heroCount), byProvider: [:], last: nil)
        for reading in readings where !reading.id.hasPrefix("telemetry:") {
            for event in reading.recentOutputs where event.tokens > 0 {
                guard let offset = offset(of: event.at, now: now, newest: newest, count: heroCount) else { continue }
                series.hero[heroCount - 1 - offset] += event.tokens
                if now.timeIntervalSince(event.at) <= freshSeconds { series.fresh[heroCount - 1 - offset] = true }
                series.byProvider[reading.source, default: 0] += event.tokens
                if let last = series.last, last.at >= event.at {
                    if last.at == event.at { series.last?.tokens += event.tokens }
                } else {
                    series.last = event
                }
            }
        }
        return series
    }
}

/// Rounds up to {1, 1.5, 2, 3, 4, 5, 6, 8} × 10ⁿ, so the tallest bar always fills at least 2/3 of the plot.
/// No hysteresis: the same data always draws the same scale (deterministic snapshots).
func niceMax(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 1 }
    let magnitude = pow(10, (log10(value)).rounded(.down))
    for step in [1.0, 1.5, 2, 3, 4, 5, 6, 8, 10] where step * magnitude >= value * (1 - 1e-9) { return step * magnitude }
    return 10 * magnitude
}

/// One path of fixed-slot bars on a linear scale: 0.6 of the slot wide, at least 2 × 2 pt, only the top corners
/// rounded (1 pt) so a 2 pt bar never reads as a "—" pill. Drawn as a plain `Path` (no macOS 14 shapes).
struct FlowBars: Shape {
    var values: [Int]
    var scale: Double
    var mask: [Bool]? = nil
    static let minHeight: CGFloat = 2
    static let minWidth: CGFloat = 2
    static let radius: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !values.isEmpty, scale > 0, rect.width > 0, rect.height > 0 else { return path }
        let slot = rect.width / CGFloat(values.count)
        let width = max(Self.minWidth, slot * 0.6)
        for (index, value) in values.enumerated() where value > 0 {
            if let mask, !(mask.indices.contains(index) && mask[index]) { continue }
            let height = min(rect.height, max(Self.minHeight, rect.height * CGFloat(Double(value) / scale)))
            let x = ((rect.minX + slot * CGFloat(index) + (slot - width) / 2) * 2).rounded() / 2
            let bar = CGRect(x: x, y: rect.maxY - height, width: width, height: height)
            let r = min(Self.radius, width / 2, height / 2)
            path.move(to: CGPoint(x: bar.minX, y: bar.maxY))
            path.addLine(to: CGPoint(x: bar.minX, y: bar.minY + r))
            path.addQuadCurve(to: CGPoint(x: bar.minX + r, y: bar.minY), control: CGPoint(x: bar.minX, y: bar.minY))
            path.addLine(to: CGPoint(x: bar.maxX - r, y: bar.minY))
            path.addQuadCurve(to: CGPoint(x: bar.maxX, y: bar.minY + r), control: CGPoint(x: bar.maxX, y: bar.minY))
            path.addLine(to: CGPoint(x: bar.maxX, y: bar.maxY))
            path.closeSubpath()
        }
        return path
    }
}
