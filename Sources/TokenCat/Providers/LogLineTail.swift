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
    private var lines = LogLineAssembler()

    init(url: URL) { self.url = url }

    /// Reads what was appended since the last call. `reset` runs before a replaced or truncated file is read again;
    /// `header` gets the first line (within 64 KB) before the tail when the first read skips the head (session metadata
    /// only); `line` gets each complete new line without its newline. Returns false when the file is missing.
    @discardableResult
    func read(tailLimit: Int, reset: () -> Void, header: ((Data) -> Void)? = nil, line: (Data) -> Void) -> Bool {
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
            lines.reset()
            reset()
        }
        if identity != nil && size == offset { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        if identity == nil {
            identity = currentIdentity
            if size > UInt64(max(128, tailLimit)) {
                if let header, let head = try? handle.read(upToCount: 65_536), let newline = head.firstIndex(of: 10) {
                    header(Data(head[head.startIndex..<newline]))
                }
                offset = size - UInt64(max(128, tailLimit))
                skippedHead = true
                lines.dropping = true
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
                autoreleasepool { lines.consume(data, line: line) }
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

}

/// Splits appended bytes into complete lines (without the newline) for every JSONL reader: a line still being written waits
/// in `pending`, a line over `maximumLineBytes` is skipped, and a line that ran long releases its buffer afterwards.
struct LogLineAssembler {
    static let maximumLineBytes = 1_048_576
    /// Lines up to this size keep the buffer's capacity for the next one; a longer one must not pin up to 1 MB per reader.
    static let retainedCapacity = 65_536
    private(set) var pending = Data()
    /// True while the rest of a skipped line (an oversized one, or the partial first line of a tail) is passing.
    var dropping = false

    mutating func reset() {
        pending = Data()
        dropping = false
    }

    /// `oversized` gets the first 16 KB of a line that passes the limit, once (an oversized tool result still names the
    /// call it completes near its start).
    mutating func consume(_ data: Data, oversized: ((Data) -> Void)? = nil, line: (Data) -> Void) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var start = 0
            while start < buffer.count {
                let found = memchr(base + start, 10, buffer.count - start)
                let end = found.map { UnsafeRawPointer(base).distance(to: UnsafeRawPointer($0)) } ?? buffer.count
                if !dropping {
                    if pending.count + (end - start) <= Self.maximumLineBytes {
                        pending.append(base + start, count: end - start)
                    } else {
                        if let oversized {
                            var head = pending.prefix(16_384)
                            head.append(base + start, count: min(end - start, 16_384 - head.count))
                            oversized(Data(head))
                        }
                        pending.removeAll(keepingCapacity: false)
                        dropping = true
                    }
                }
                guard found != nil else { break }
                if !dropping, !pending.isEmpty { line(pending) }
                pending.removeAll(keepingCapacity: pending.count <= Self.retainedCapacity)
                dropping = false
                start = end + 1
            }
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

/// Ids a reader remembers to count each record once, up to `limit`: past it the oldest is forgotten first. Clearing
/// everything at the cap would let every replayed record count again.
struct RecentKeys<Value> {
    let limit: Int
    private var values: [String: Value] = [:]
    private var order: [String] = []
    private var head = 0

    init(limit: Int) { self.limit = limit }

    var count: Int { values.count }
    subscript(key: String) -> Value? { values[key] }
    func contains(_ key: String) -> Bool { values[key] != nil }

    mutating func set(_ key: String, _ value: Value) {
        guard values.updateValue(value, forKey: key) == nil else { return }
        order.append(key)
        guard values.count > limit else { return }
        values[order[head]] = nil
        head += 1
        // The forgotten prefix of `order` is dropped in one move once it is as long as the kept part.
        if head >= limit {
            order.removeFirst(head)
            head = 0
        }
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        head = 0
    }
}

extension RecentKeys where Value == Void {
    /// True when `key` was not remembered yet.
    mutating func insert(_ key: String) -> Bool {
        guard !contains(key) else { return false }
        set(key, ())
        return true
    }
}
