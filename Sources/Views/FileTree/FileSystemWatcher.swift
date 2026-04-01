import Foundation

/// Weak reference wrapper for safe FSEvents callback routing.
private final class FSEventsHelper: @unchecked Sendable {
    weak var watcher: FileSystemWatcher?
    init(watcher: FileSystemWatcher) { self.watcher = watcher }
}

/// Module-level C callback for FSEvents.
private let fileSystemWatcherCallback: FSEventStreamCallback = {
    (_, clientCallBackInfo, numEvents, eventPaths, _, _) in
    guard let clientCallBackInfo else { return }
    let helper = Unmanaged<FSEventsHelper>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    guard let watcher = helper.watcher else { return }

    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var paths: [String] = []
    for i in 0..<CFArrayGetCount(cfArray) {
        if let val = CFArrayGetValueAtIndex(cfArray, i) {
            paths.append(Unmanaged<CFString>.fromOpaque(val).takeUnretainedValue() as String)
        }
    }

    DispatchQueue.main.async {
        watcher.onChange?(paths)
    }
}

/// Manages an FSEvents stream for a directory, calling `onChange` when events fire.
@MainActor
final class FileSystemWatcher {
    /// Called on the main queue with the list of changed paths.
    var onChange: (([String]) -> Void)?

    private nonisolated(unsafe) var fsEventStreamRef: FSEventStreamRef?
    private nonisolated(unsafe) var fsEventsHelperRetained: Unmanaged<FSEventsHelper>?

    deinit {
        stop()
    }

    func start(path: String) {
        stop()
        let pathsToWatch = [path] as CFArray

        let helper = FSEventsHelper(watcher: self)
        let retained = Unmanaged.passRetained(helper)
        fsEventsHelperRetained = retained

        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            nil,
            fileSystemWatcherCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            retained.release()
            fsEventsHelperRetained = nil
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        fsEventStreamRef = stream
    }

    nonisolated func stop() {
        if let stream = fsEventStreamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStreamRef = nil
        }
        fsEventsHelperRetained?.release()
        fsEventsHelperRetained = nil
    }
}
