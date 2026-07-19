import Foundation
import CoreServices

/// Watches a single directory for file changes via FSEvents (file-level).
/// Fires `onChange` on the main queue whenever any file in the tree changes.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }

    /// Point the watcher at `path` (restarting if already watching elsewhere).
    func watch(_ path: String) {
        guard path != watchedPath else { return }
        stop()
        watchedPath = path

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,                      // coalesce bursts within 0.2s
            flags) else { return }

        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        watchedPath = nil
    }

    deinit { stop() }
}
