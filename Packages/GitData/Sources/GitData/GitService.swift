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
        self.backend = try CLIGitBackend()
    }

    /// Injectable for testing.
    init(backend: CLIGitBackend) {
        self.backend = backend
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
        AsyncThrowingStream { continuation in
            let task = Task {
                // Stream incrementally — parse each commit record as bytes arrive so we never
                // buffer the entire log in memory.
                let stream = GitService.streamCommits(query: query)
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
    /// the child process via `withTaskCancellationHandler`.
    private static func streamCommits(
        query: CommitQuery
    ) -> AsyncThrowingStream<Commit, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let runner = try GitRunner.discover()
                    var args = ["log", "--parents", "--format=\(LogFormat.pretty)"]
                    switch query.scope {
                    case .head: break
                    case .branch(let b): args.append(b)
                    case .ref(let r): args.append(r)
                    case .all: args.append("--all")
                    }
                    if let maxCount = query.maxCount { args.append("--max-count=\(maxCount)") }
                    if let skip = query.skip { args.append("--skip=\(skip)") }
                    if let since = query.since {
                        args.append("--since=\(ISO8601DateFormatter.gitISO.string(from: since))")
                    }

                    let process = Process()
                    process.executableURL = runner.gitURL
                    process.arguments = args
                    process.currentDirectoryURL = query.repo.rootURL

                    var env = ProcessInfo.processInfo.environment
                    env["GIT_OPTIONAL_LOCKS"] = "0"
                    env["GIT_TERMINAL_PROMPT"] = "0"
                    env["GIT_PAGER"] = "cat"
                    process.environment = env

                    let outPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = FileHandle.nullDevice

                    try await withTaskCancellationHandler {
                        try process.run()

                        // Buffer for the current (possibly partial) commit record.
                        var buffer = Data()
                        let recordSep = LogFormat.record.data(using: .utf8)!

                        // Read stdout in chunks; parse and yield complete records immediately.
                        let byteChunks = AsyncChunksSequence(
                            base: outPipe.fileHandleForReading.bytes, chunkSize: 4096)
                        for try await chunk in byteChunks {
                            if Task.isCancelled { break }
                            buffer.append(contentsOf: chunk)
                            // Yield every complete record we have so far.
                            while let range = buffer.range(of: recordSep) {
                                let recordData = buffer[buffer.startIndex..<range.upperBound]
                                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                                for commit in CommitParser.parse(recordData) {
                                    if Task.isCancelled { break }
                                    continuation.yield(commit)
                                }
                            }
                        }

                        // Flush any trailing bytes after EOF (no separator at very end).
                        if !buffer.isEmpty && !Task.isCancelled {
                            for commit in CommitParser.parse(buffer) {
                                continuation.yield(commit)
                            }
                        }

                        process.waitUntilExit()
                        let code = process.terminationStatus
                        if code != 0 && !Task.isCancelled {
                            throw GitError.commandFailed(
                                command: "git " + args.joined(separator: " "),
                                exitCode: code, stderr: "")
                        }
                        if Task.isCancelled {
                            continuation.finish(throwing: GitError.cancelled)
                        } else {
                            continuation.finish()
                        }
                    } onCancel: {
                        if process.isRunning { process.terminate() }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - AsyncSequence chunking helper

/// An `AsyncSequence` that groups `UInt8` elements from `Base` into `[UInt8]` arrays of up to
/// `chunkSize` elements.  Used to batch single-byte reads from `FileHandle.AsyncBytes` so we
/// pass fewer, larger `Data` chunks to the parser.
private struct AsyncChunksSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable
    where Base.Element == UInt8
{
    typealias Element = [UInt8]

    let base: Base
    let chunkSize: Int

    struct AsyncIterator: AsyncIteratorProtocol {
        var inner: Base.AsyncIterator
        let chunkSize: Int

        mutating func next() async throws -> [UInt8]? {
            var chunk: [UInt8] = []
            chunk.reserveCapacity(chunkSize)
            while chunk.count < chunkSize {
                guard let byte = try await inner.next() else {
                    return chunk.isEmpty ? nil : chunk
                }
                chunk.append(byte)
            }
            return chunk
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(inner: base.makeAsyncIterator(), chunkSize: chunkSize)
    }
}
