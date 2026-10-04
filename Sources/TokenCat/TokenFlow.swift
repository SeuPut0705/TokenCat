import Foundation
import SwiftUI

/// Log-recorded output volume in 5 s wall-clock buckets. Counts only, never a rate:
/// `at` is when a client wrote the usage record, not when tokens streamed.
/// Rebuilt from scratch on every update; there is no incremental state.
struct FlowSeries: Equatable {
    struct Row: Equatable {
        var buckets: [Int]
        var fresh: [Bool]
        var peak: Int { buckets.max() ?? 0 }
    }

    static let bucketSeconds: TimeInterval = 5
    static let heroCount = 60
    static let rowCount = 24
    static let freshSeconds: TimeInterval = 5
    /// Writers' clocks may run slightly ahead; such records land in the newest bucket.
    static let futureTolerance: TimeInterval = 5

    /// Start of the newest bucket: `floor(now / 5) * 5`.
    var newest: Date
    /// Oldest → newest.
    var hero: [Int]
    var fresh: [Bool]
    var rows: [String: Row]
    var byProvider: [TokenSource: Int]
    var last: TokenOutputEvent?

    var total: Int { hero.reduce(0, +) }
    var peak: Int { hero.max() ?? 0 }

    static let empty = FlowSeries(newest: .distantPast, hero: Array(repeating: 0, count: heroCount),
                                  fresh: Array(repeating: false, count: heroCount), rows: [:], byProvider: [:], last: nil)

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
                                fresh: Array(repeating: false, count: heroCount), rows: [:], byProvider: [:], last: nil)
        for reading in readings where !reading.id.hasPrefix("telemetry:") {
            var row = Row(buckets: Array(repeating: 0, count: rowCount), fresh: Array(repeating: false, count: rowCount))
            var rowHasRecord = false
            for event in reading.recentOutputs where event.tokens > 0 {
                let isFresh = now.timeIntervalSince(event.at) <= freshSeconds
                if let offset = offset(of: event.at, now: now, newest: newest, count: heroCount) {
                    series.hero[heroCount - 1 - offset] += event.tokens
                    if isFresh { series.fresh[heroCount - 1 - offset] = true }
                    series.byProvider[reading.source, default: 0] += event.tokens
                    if let last = series.last, last.at >= event.at {
                        if last.at == event.at { series.last?.tokens += event.tokens }
                    } else {
                        series.last = event
                    }
                }
                if let offset = offset(of: event.at, now: now, newest: newest, count: rowCount) {
                    row.buckets[rowCount - 1 - offset] += event.tokens
                    if isFresh { row.fresh[rowCount - 1 - offset] = true }
                    rowHasRecord = true
                }
            }
            if rowHasRecord { series.rows[reading.id] = row }
        }
        return series
    }
}

/// Rounds up to 1, 2 or 5 × 10ⁿ.
func niceMax(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 1 }
    let magnitude = pow(10, (log10(value)).rounded(.down))
    for step in [1.0, 2, 5, 10] where step * magnitude >= value * (1 - 1e-9) { return step * magnitude }
    return 10 * magnitude
}

/// One path of fixed-slot bars. A linear scale with a minimum height keeps small records visible.
struct FlowBars: Shape {
    var values: [Int]
    var scale: Double
    var mask: [Bool]? = nil
    /// Narrow strips raise these so a single record reads as a bar rather than a speck.
    var minHeight: CGFloat = 2
    var minWidth: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !values.isEmpty, scale > 0, rect.width > 0, rect.height > 0 else { return path }
        let slot = rect.width / CGFloat(values.count)
        let width = max(minWidth, slot * 0.68)
        for (index, value) in values.enumerated() where value > 0 {
            if let mask, !(mask.indices.contains(index) && mask[index]) { continue }
            let height = min(rect.height, max(minHeight, rect.height * CGFloat(Double(value) / scale)))
            let x = ((rect.minX + slot * CGFloat(index) + (slot - width) / 2) * 2).rounded() / 2
            path.addRoundedRect(in: CGRect(x: x, y: rect.maxY - height, width: width, height: height),
                                cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }
}
