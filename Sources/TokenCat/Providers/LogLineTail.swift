import Foundation

/// A bounded JSONL tail for provider readers: the first read starts `tailLimit` bytes before the end (its partial first
/// line is dropped), later reads continue at the offset. A truncated or replaced file is read again from the top after
/// `reset`. Lines over 1 MB are skipped; an unterminated last line waits for its newline.
final class LogLineTail {
    let url: URL
    /// Whether the first read skipped the head of the file, so records before the tail were never seen.
    private(set) var skippedHead = false
    /// Modification time from the latest `read`.
    private(set) var modified: Date?
    private var offset: UInt64 = 0
    private var identity: String?
    private var pending = Data()
    private var dropping = false
    private let maximumLineBytes = 1_048_576

    init(url: URL) { self.url = url }

    /// Reads what was appended since the last call. `reset` runs before a replaced or truncated file is read again;
    /// `line` gets each complete new line without its newline. Returns false when the file is missing.
    @discardableResult
    func read(tailLimit: Int, reset: () -> Void, line: (Data) -> Void) -> Bool {
        // stat(2), not attributesOfItem: this runs for every tracked log on every tick.
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        let size = UInt64(info.st_size)
        let currentIdentity = "\(info.st_dev)-\(info.st_ino)"
        modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        if let identity, identity != currentIdentity || size < offset {
            self.identity = nil
            offset = 0
            skippedHead = false
            pending.removeAll(keepingCapacity: false)
            dropping = false
            reset()
        }
        if identity != nil && size == offset { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        if identity == nil {
            identity = currentIdentity
            if size > UInt64(max(128, tailLimit)) {
                offset = size - UInt64(max(128, tailLimit))
                skippedHead = true
                dropping = true
            }
        }
        // Bursts are caught up within one sample.
        var budget = 16_777_216 + tailLimit
        do {
            while offset < size, budget > 0 {
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: min(1_048_576, Int(min(size - offset, UInt64(Int.max))))) ?? Data()
                guard !data.isEmpty else { break }
                offset += UInt64(data.count)
                budget -= data.count
                autoreleasepool { consume(data, line: line) }
            }
        } catch { return true }
        return true
    }

    /// The file's first line when it is at most `limit` bytes: the session header a skipped head would lose.
    func firstLine(limit: Int = 65_536) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: limit), let newline = head.firstIndex(of: 10) else { return nil }
        return Data(head[head.startIndex..<newline])
    }

    private func consume(_ data: Data, line: (Data) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            if !dropping {
                if pending.count + data.distance(from: start, to: end) <= maximumLineBytes {
                    pending.append(contentsOf: data[start..<end])
                } else {
                    pending.removeAll(keepingCapacity: false)
                    dropping = true
                }
            }
            guard let newline else { break }
            if !dropping, !pending.isEmpty { line(pending) }
            // One long line must not pin up to 1 MB per reader for good.
            pending.removeAll(keepingCapacity: pending.count <= 65_536)
            dropping = false
            start = data.index(after: newline)
        }
    }
}

/// Field parsing shared by the provider readers. Values that do not parse are nil, never zero.
enum LogFields {
    /// An ISO 8601 string, with or without fractional seconds (the tracker's own fast path and formatters).
    static func date(_ value: Any?) -> Date? {
        value is String ? TokenLogParser.date(value) : nil
    }

    /// Epoch milliseconds.
    static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let ms = number.doubleValue
        guard ms.isFinite, ms > 0, ms < 253_370_764_800_000 else { return nil }
        return Date(timeIntervalSince1970: ms / 1_000)
    }

    /// A non-negative whole count; booleans, strings and fractions are not counts.
    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= Double(Int32.max), double.rounded() == double else { return nil }
        return Int(double)
    }

    /// A JSON object from one line or file.
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A non-empty string.
    static func text(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
