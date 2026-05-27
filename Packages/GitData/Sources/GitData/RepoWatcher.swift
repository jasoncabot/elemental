import Foundation

/// Emitted when something under a repository's git dir changes on disk.
public struct DirtyEvent: Sendable {
    public var repo: Repository
    public var changedPaths: [String]
    public init(repo: Repository, changedPaths: [String]) {
        self.repo = repo
        self.changedPaths = changedPaths
    }
}

/// Signals on-disk changes. The UI never auto-reloads on these; it surfaces a Refresh affordance.
public protocol RepoWatcher: Sendable {
    func events(for repo: Repository) -> AsyncStream<DirtyEvent>
}

/// FSEvents-backed watcher over a repository's common git dir. Debounces bursts.
public final class FSEventsRepoWatcher: RepoWatcher, @unchecked Sendable {
    private let debounce: Duration

    public init(debounce: Duration = .milliseconds(300)) {
        self.debounce = debounce
    }

    public func events(for repo: Repository) -> AsyncStream<DirtyEvent> {
        let path = repo.commonDir.path
        let debounce = self.debounce
        return AsyncStream { continuation in
            let stream = FSEventStreamSession(path: path, debounce: debounce) { paths in
                continuation.yield(DirtyEvent(repo: repo, changedPaths: paths))
            }
            stream.start()
            continuation.onTermination = { _ in stream.stop() }
        }
    }
}

/// Thin wrapper around the FSEvents C API with debouncing.
private final class FSEventStreamSession {
    private let path: String
    private let debounce: Duration
    private let onChange: ([String]) -> Void
    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.jasoncabot.elemental.fsevents")
    private var pending: [String] = []
    private var debounceWorkItem: DispatchWorkItem?

    init(path: String, debounce: Duration, onChange: @escaping ([String]) -> Void) {
        self.path = path
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let session = Unmanaged<FSEventStreamSession>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            var paths: [String] = []
            for i in 0..<count {
                if let p = (cfPaths as? [String])?[i] { paths.append(p) }
            }
            session.enqueue(paths)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let ref = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, flags
        ) else { return }
        streamRef = ref
        FSEventStreamSetDispatchQueue(ref, queue)
        FSEventStreamStart(ref)
    }

    func stop() {
        guard let ref = streamRef else { return }
        FSEventStreamStop(ref)
        FSEventStreamInvalidate(ref)
        FSEventStreamRelease(ref)
        streamRef = nil
        // Drain the queue: ensures any in-flight C callback has finished
        // dereferencing the unretained `self` pointer before we return,
        // and cancels any pending debounce that would fire after teardown.
        queue.sync {
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
        }
    }

    private func enqueue(_ paths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.append(contentsOf: paths)
            self.debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let batch = self.pending
                self.pending.removeAll()
                if !batch.isEmpty { self.onChange(batch) }
            }
            self.debounceWorkItem = work
            self.queue.asyncAfter(
                deadline: .now() + .milliseconds(Int(self.debounce.components.seconds * 1000)
                    + Int(self.debounce.components.attoseconds / 1_000_000_000_000_000)),
                execute: work
            )
        }
    }
}
