import Foundation
import GitData

/// In-memory GitBackend for deterministic presenter tests. No real git involved above the data layer.
///
/// Thread-safe: mutable counters and stubs are protected by a lock so tests can run in parallel.
final class FakeBackend: GitBackend, @unchecked Sendable {
    private let lock = NSLock()

    private var _commitsByScopeAll: [Commit] = []
    var commitsByScopeAll: [Commit] {
        get { lock.lock(); defer { lock.unlock() }; return _commitsByScopeAll }
        set { lock.lock(); _commitsByScopeAll = newValue; lock.unlock() }
    }

    var diffsBySHA: [String: [DiffFile]] = [:]
    var stagedDiffs:   [DiffFile] = []
    var unstagedDiffs: [DiffFile] = []
    var stubbedRefs: RefSnapshot?
    var stubbedStatus: WorkingCopyStatus?

    private var _diffCallCount = 0
    private(set) var diffCallCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _diffCallCount }
        set { lock.lock(); _diffCallCount = newValue; lock.unlock() }
    }

    private var _loadCallCount = 0
    private(set) var loadCallCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _loadCallCount }
        set { lock.lock(); _loadCallCount = newValue; lock.unlock() }
    }

    func gitVersion() async throws -> String { "git version fake" }

    func openRepository(at url: URL) async throws -> Repository {
        Repository(rootURL: url, gitDir: url, commonDir: url, isBare: false)
    }

    func loadCommits(_ query: CommitQuery) -> AsyncThrowingStream<Commit, Error> {
        lock.lock()
        _loadCallCount += 1
        let snapshot = _commitsByScopeAll
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for c in snapshot { continuation.yield(c) }
            continuation.finish()
        }
    }

    func commitCount(_ query: CommitQuery) async throws -> Int { commitsByScopeAll.count }

    func refs(for repo: Repository) async throws -> RefSnapshot {
        if let s = stubbedRefs { return s }
        return RefSnapshot(head: .detached(sha: commitsByScopeAll.first?.sha ?? ""),
                           branches: [], remotes: [], tags: [])
    }

    func diff(_ range: DiffRange, in repo: Repository) async throws -> [DiffFile] {
        lock.lock()
        _diffCallCount += 1
        lock.unlock()
        switch range {
        case .commit(let sha):     return diffsBySHA[sha] ?? []
        case .workingStaged:       return stagedDiffs
        case .workingUnstaged:     return unstagedDiffs
        case .between:             return []
        }
    }

    func workingCopyStatus(for repo: Repository) async throws -> WorkingCopyStatus {
        if let s = stubbedStatus { return s }
        return WorkingCopyStatus(branch: nil, ahead: nil, behind: nil,
                                 staged: [], unstaged: [], untracked: [], conflicts: [])
    }

    func blob(at path: String, rev: String, in repo: Repository) async throws -> Data { Data() }
}

/// Controllable RepoWatcher: tests push DirtyEvents on demand.
///
/// Thread-safe and supports multiple concurrent subscribers (e.g. when two presenters
/// each call `events(for:)` on the same watcher). Events are only delivered to subscribers
/// that registered for the matching repository, mirroring production behavior.
final class FakeWatcher: RepoWatcher, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [(id: UUID, repoURL: URL, continuation: AsyncStream<DirtyEvent>.Continuation)] = []

    func events(for repo: Repository) -> AsyncStream<DirtyEvent> {
        let id = UUID()
        let repoURL = repo.rootURL
        return AsyncStream { continuation in
            self.lock.lock()
            self.continuations.append((id: id, repoURL: repoURL, continuation: continuation))
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeAll { $0.id == id }
                self.lock.unlock()
            }
        }
    }

    func fire(_ event: DirtyEvent) {
        lock.lock()
        let snapshot = continuations
        lock.unlock()
        for entry in snapshot where entry.repoURL == event.repo.rootURL {
            entry.continuation.yield(event)
        }
    }
}

func makeCommit(_ sha: String, parents: [String] = [], subject: String = "msg") -> Commit {
    Commit(sha: sha, parents: parents,
           author: Signature(name: "A", email: "a@x"),
           committer: Signature(name: "A", email: "a@x"),
           authorDate: Date(timeIntervalSince1970: 0),
           commitDate: Date(timeIntervalSince1970: 0),
           subject: subject, body: "", refNames: [])
}
