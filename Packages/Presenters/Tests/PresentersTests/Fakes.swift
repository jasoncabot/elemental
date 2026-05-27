import Foundation
import GitData

/// In-memory GitBackend for deterministic presenter tests. No real git involved above the data layer.
final class FakeBackend: GitBackend, @unchecked Sendable {
    var commitsByScopeAll: [Commit] = []
    var diffsBySHA: [String: [DiffFile]] = [:]
    var stagedDiffs:   [DiffFile] = []
    var unstagedDiffs: [DiffFile] = []
    var stubbedRefs: RefSnapshot?
    var stubbedStatus: WorkingCopyStatus?
    private(set) var diffCallCount = 0
    private(set) var loadCallCount = 0

    func gitVersion() async throws -> String { "git version fake" }

    func openRepository(at url: URL) async throws -> Repository {
        Repository(rootURL: url, gitDir: url, commonDir: url, isBare: false)
    }

    func loadCommits(_ query: CommitQuery) -> AsyncThrowingStream<Commit, Error> {
        loadCallCount += 1
        let snapshot = commitsByScopeAll
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
        diffCallCount += 1
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
final class FakeWatcher: RepoWatcher, @unchecked Sendable {
    private var continuation: AsyncStream<DirtyEvent>.Continuation?

    func events(for repo: Repository) -> AsyncStream<DirtyEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func fire(_ event: DirtyEvent) { continuation?.yield(event) }
}

func makeCommit(_ sha: String, parents: [String] = [], subject: String = "msg") -> Commit {
    Commit(sha: sha, parents: parents,
           author: Signature(name: "A", email: "a@x"),
           committer: Signature(name: "A", email: "a@x"),
           authorDate: Date(timeIntervalSince1970: 0),
           commitDate: Date(timeIntervalSince1970: 0),
           subject: subject, body: "", refNames: [])
}
