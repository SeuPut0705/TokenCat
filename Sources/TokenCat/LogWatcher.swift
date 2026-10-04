import CoreServices
import Foundation

/// Wakes token sampling as soon as Codex/Claude logs change. Only paths are delivered;
/// TokenTracker still reads the files. The 1 s timer remains the fallback.
final class LogWatcher {
    private let queue = DispatchQueue(label: "dev.seuput.TokenCat.logs", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let handler: ([String]) -> Void
    private var stream: FSEventStreamRef?

    init(handler: @escaping ([String]) -> Void) {
        self.handler = handler
        queue.setSpecific(key: queueKey, value: ())
    }
    deinit { stop() }

    /// Watches the existing directories; returns false when none could be watched.
    @discardableResult
    func start(directories: [URL]) -> Bool {
        stop()
        let paths = directories.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return false }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handler(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// Waits for an in-flight callback, so the handler never runs after this returns.
    func stop() {
        let release = { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { release() } else { queue.sync(execute: release) }
    }
}
