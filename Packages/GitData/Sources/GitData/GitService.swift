import Foundation

/// `GitService` is the actor that presenters and the coordinator depend on.
/// It wraps `CLIGitBackend` and adds:
///   - Per-repo request coalescing: duplicate in-flight requests (same repo + key) share one child process.
///   - Swift `Task` cancellation → child process termination for all calls.
///   - Incremental stdout streaming for `loadCommits` so a 100k-commit log is never held
///     in a single buffer.
///
/// It conforms to `GitBackend` so the rest of the app only ever depends on the protocol seam.
public actor GitService: GitBackend {

    private let backend: CLIGitBackend
    /// Cached once at init so `streamCommits` (nonisolated) never re-discovers git on each call.
    nonisolated private let runner: GitRunner

    // MARK: - In-flight coalescing

    /// A coalescing key for deduplicated async calls that return a single value.
    private enum CoalescingKey: Hashable, Sendable {
        case refs(URL)
        case workingCopyStatus(URL)
        /// `diffKey` encodes the DiffRange as a string so the key is Hashable without
        /// requiring DiffRange itself to conform (it is a frozen protocol type).
        case diff(URL, String)
    }

    /// Wraps a running `Task` whose result can be awaited by multiple callers.
    private struct SharedTask<T: Sendable>: Sendable {
        let task: Task<T, Error>
    }

    /// Active in-flight tasks keyed by `CoalescingKey`.  When a second caller asks for the
    /// same data while a request is already running, it awaits the same `Task` rather than
    /// spawning a new child process.
    private var inflight: [CoalescingKey: any Sendable] = [:]

    // MARK: - Init

    public init() throws {
        let r = try GitRunner.discover()
        self.runner = r
        self.backend = CLIGitBackend(runner: r)
    }

    /// Injectable for testing.
    init(backend: CLIGitBackend) {
        self.backend = backend
        self.runner = backend.runner
    }

    // MARK: - GitBackend conformance

    public func gitVersion() async throws -> String {
        try await backend.gitVersion()
    }

    public func openRepository(at url: URL) async throws -> Repository {
        try await backend.openRepository(at: url)
    }

    /// Returns a stream that delivers `Commit` values incrementally as `git log` produces them.
    /// Cancellation of the consuming `Task` terminates the child process immediately.
    public nonisolated func loadCommits(_ query: CommitQuery) -> AsyncThrowingStream<Commit, Error> {
        let runner = self.runner
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Stream incrementally — parse each commit record as bytes arrive so we never
                // buffer the entire log in memory.
                let stream = GitService.streamCommits(query: query, runner: runner)
                do {
                    for try await commit in stream {
                        if Task.isCancelled {
                            continuation.finish(throwing: GitError.cancelled)
                            return
                        }
                        continuation.yield(commit)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func commitCount(_ query: CommitQuery) async throws -> Int {
        try await backend.commitCount(query)
    }

    public func refs(for repo: Repository) async throws -> RefSnapshot {
        try await coalesced(.refs(repo.rootURL)) {
            try await self.backend.refs(for: repo)
        }
    }

    public func diff(_ range: DiffRange, in repo: Repository) async throws -> [DiffFile] {
        let rangeKey: String
        switch range {
        case .workingUnstaged: rangeKey = "unstaged"
        case .workingStaged:   rangeKey = "staged"
        case .workingUntracked(let path): rangeKey = "untracked:\(path)"
        case .commit(let sha): rangeKey = "commit:\(sha)"
        case .between(let a, let b): rangeKey = "between:\(a):\(b)"
        }
        return try await coalesced(.diff(repo.rootURL, rangeKey)) {
            try await self.backend.diff(range, in: repo)
        }
    }

    public func workingCopyStatus(for repo: Repository) async throws -> WorkingCopyStatus {
        try await coalesced(.workingCopyStatus(repo.rootURL)) {
            try await self.backend.workingCopyStatus(for: repo)
        }
    }

    public func blob(at path: String, rev: String, in repo: Repository) async throws -> Data {
        // blob fetches are already keyed by (path, rev) and are cheap; no coalescing needed.
        try await backend.blob(at: path, rev: rev, in: repo)
    }

    public func note(for sha: String, in repo: Repository) async throws -> String? {
        // Per-commit, on demand, and cheap — no coalescing needed.
        try await backend.note(for: sha, in: repo)
    }

    // MARK: - Coalescing helper

    /// Runs `work` once; if another call with the same `key` is already in flight, both callers
    /// await the same `Task` and share its result.  The entry is removed from `inflight` when the
    /// task completes so subsequent calls start fresh.
    private func coalesced<T: Sendable>(
        _ key: CoalescingKey,
        work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if let existing = inflight[key] as? SharedTask<T> {
            return try await existing.task.value
        }
        let task = Task<T, Error> { try await work() }
        let shared = SharedTask(task: task)
        inflight[key] = shared
        defer { inflight.removeValue(forKey: key) }
        return try await task.value
    }

    // MARK: - Incremental streaming for loadCommits

    /// Spawns `git log` and yields `Commit` values as they are parsed from the byte stream,
    /// record by record.  Never accumulates the full stdout in memory.  Cancellation terminates
    /// the child process via `GitRunner.stream`.
    private static func streamCommits(query: CommitQuery, runner: GitRunner) -> AsyncThrowingStream<Commit, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let args = CommitLog.revListArgs(for: query)
                    var buffer = Data()
                    let recordSep = LogFormat.record.data(using: .utf8)!
                    for try await chunk in runner.stream(args, in: query.repo.rootURL) {
                        guard !Task.isCancelled else { break }
                        buffer.append(contentsOf: chunk)
                        while let range = buffer.range(of: recordSep) {
                            let recordData = buffer[buffer.startIndex..<range.upperBound]
                            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                            for commit in CommitParser.parse(recordData) {
                                guard !Task.isCancelled else { break }
                                continuation.yield(commit)
                            }
                        }
                    }
                    // Flush any trailing bytes after EOF (no separator at very end).
                    if !buffer.isEmpty && !Task.isCancelled {
                        for commit in CommitParser.parse(buffer) { continuation.yield(commit) }
                    }
                    continuation.finish(throwing: Task.isCancelled ? GitError.cancelled : nil)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
