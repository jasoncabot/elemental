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
///
/// The C callback context holds a **retained** reference to a small ref-counted box rather than
/// an unretained pointer to `self`. This prevents a dangling-pointer crash when the stream is
/// deallocated while a C callback is still in flight on the dispatch queue (commonly triggered
/// by rapid branch switches that cause a burst of FSEvents).
private final class FSEventStreamSession {
    private let path: String
    private let debounce: Duration
    private let onChange: ([String]) -> Void
    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.jasoncabot.elemental.fsevents")
    private var pending: [String] = []
    private var debounceWorkItem: DispatchWorkItem?
    private var stopped = false

    /// A ref-counted box that the C callback retains. Even if `FSEventStreamSession` is
    /// deallocated, the box survives until the FSEvents framework releases it, preventing
    /// a use-after-free in the callback.
    private final class CallbackBox {
        weak var session: FSEventStreamSession?
        init(_ session: FSEventStreamSession) { self.session = session }
    }
    private var callbackBox: CallbackBox?

    init(path: String, debounce: Duration, onChange: @escaping ([String]) -> Void) {
        self.path = path
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        let box = CallbackBox(self)
        self.callbackBox = box

        let retainCB: CFAllocatorRetainCallBack = { info in
            guard let info else { return nil }
            _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
            return UnsafeRawPointer(info)
        }
        let releaseCB: CFAllocatorReleaseCallBack = { info in
            guard let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).release()
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: retainCB, release: releaseCB, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            guard let session = box.session else { return }
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
        ) else {
            return
        }
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
        // Mark stopped so any in-flight enqueue/debounce callbacks become no-ops.
        // Drain the queue to ensure all pending work items have finished before returning.
        queue.sync {
            self.stopped = true
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
        }
        // Sever the weak reference so the box's callback becomes a no-op even if the
        // FSEvents framework hasn't released the context info pointer yet.
        callbackBox?.session = nil
        callbackBox = nil
    }

    private func enqueue(_ paths: [String]) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.pending.append(contentsOf: paths)
            self.debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
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
