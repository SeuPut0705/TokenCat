import CoreServices
import Foundation

/// Wakes token sampling as soon as a read client's log changes. Paths and lost-event signals are delivered;
/// TokenTracker still reads the files. The adaptive sampling timer remains the fallback.
final class LogWatcher {
    private let queue = DispatchQueue(label: "dev.seuput.TokenCat.logs", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let handler: ([String], Bool) -> Void
    private var stream: FSEventStreamRef?

    init(handler: @escaping ([String], Bool) -> Void) {
        self.handler = handler
        queue.setSpecific(key: queueKey, value: ())
    }
    deinit { stop() }

    static func requiresRediscovery(_ flags: FSEventStreamEventFlags) -> Bool {
        let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        return flags & lost != 0
    }

    /// Watches the existing directories; returns false when none could be watched.
    @discardableResult
    func start(directories: [URL]) -> Bool {
        stop()
        let paths = directories.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return false }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
            let rediscover = UnsafeBufferPointer(start: eventFlags, count: count).contains(where: LogWatcher.requiresRediscovery)
            watcher.handler(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [], rediscover)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
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
