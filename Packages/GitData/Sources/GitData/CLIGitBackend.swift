import Foundation

/// The production GitBackend: shells out to the user's own git binary using plumbing/porcelain
/// with machine-readable output. This is what gives forward-compatibility with whatever git
/// features the user's git version supports.
public actor CLIGitBackend: GitBackend {
    private let runner: GitRunner
    private var cachedVersion: String?

    public init() throws {
        self.runner = try GitRunner.discover()
    }

    init(runner: GitRunner) {
        self.runner = runner
    }

    public func gitVersion() async throws -> String {
        if let cachedVersion { return cachedVersion }
        let data = try await runner.runChecked(["--version"], in: nil)
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        cachedVersion = version
        return version
    }

    public func openRepository(at url: URL) async throws -> Repository {
        let args = ["-C", url.path, "rev-parse",
                    "--show-toplevel", "--absolute-git-dir",
                    "--path-format=absolute", "--git-common-dir", "--is-bare-repository"]
        let result = try await runner.run(args, in: url)
        guard result.exitCode == 0 else { throw GitError.notARepository(url) }
        let lines = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard lines.count >= 4 else { throw GitError.notARepository(url) }
        let root = URL(fileURLWithPath: lines[0])
        let gitDir = URL(fileURLWithPath: lines[1])
        var common = URL(fileURLWithPath: lines[2])
        if !lines[2].hasPrefix("/") {
            common = gitDir.appendingPathComponent(lines[2])
        }
        let isBare = lines[3] == "true"
        let worktrees = (try? await loadWorktrees(in: root)) ?? []
        return Repository(rootURL: root, gitDir: gitDir, commonDir: common,
                          isBare: isBare, worktrees: worktrees)
    }

    private func loadWorktrees(in root: URL) async throws -> [Worktree] {
        let data = try await runner.runChecked(["worktree", "list", "--porcelain"], in: root)
        let text = String(decoding: data, as: UTF8.self)
        var result: [Worktree] = []
        var path: URL?
        var head: String?
        var branch: String?
        var bare = false
        func flush() {
            if let path { result.append(Worktree(path: path, head: head, branch: branch, isBare: bare)) }
            path = nil; head = nil; branch = nil; bare = false
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                flush(); path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count))
            } else if line == "bare" {
                bare = true
            } else if line.isEmpty {
                flush()
            }
        }
        flush()
        return result
    }

    public nonisolated func loadCommits(_ query: CommitQuery) -> AsyncThrowingStream<Commit, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
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
                    let data = try await runner.runChecked(args, in: query.repo.rootURL)
                    if Task.isCancelled { continuation.finish(throwing: GitError.cancelled); return }
                    for commit in CommitParser.parse(data) {
                        if Task.isCancelled { continuation.finish(throwing: GitError.cancelled); return }
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
        async let branchData = runner.runChecked(
            ["for-each-ref", "--format=\(RefParser.format)", "refs/heads", "refs/remotes", "refs/tags"],
            in: repo.rootURL)
        let head = try await readHead(in: repo)
        let all = RefParser.parse(try await branchData)
        return RefSnapshot(
            head: head,
            branches: all.filter { $0.kind == .branch },
            remotes: all.filter { $0.kind == .remote },
            tags: all.filter { $0.kind == .tag }
        )
    }

    private func readHead(in repo: Repository) async throws -> HeadState {
        let symbolic = try await runner.run(["symbolic-ref", "--short", "-q", "HEAD"], in: repo.rootURL)
        let shaData = try? await runner.runChecked(["rev-parse", "HEAD"], in: repo.rootURL)
        let sha = shaData.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        if symbolic.exitCode == 0 {
            let branch = String(decoding: symbolic.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let sha, !sha.isEmpty, sha != "HEAD" { return .attached(branch: branch, sha: sha) }
            return .unborn(branch: branch)
        }
        return .detached(sha: sha ?? "")
    }

    public func diff(_ range: DiffRange, in repo: Repository) async throws -> [DiffFile] {
        var args: [String]
        switch range {
        case .workingUnstaged:
            args = ["diff", "--patch", "-M", "-C"]
        case .workingStaged:
            args = ["diff", "--cached", "--patch", "-M", "-C"]
        case .commit(let sha):
            args = ["show", sha, "--patch", "-M", "-C", "--format="]
        case .between(let a, let b):
            args = ["diff", "--patch", "-M", "-C", "\(a)..\(b)"]
        }
        let data = try await runner.runChecked(args, in: repo.rootURL)
        return DiffParser.parse(data)
    }

    public func workingCopyStatus(for repo: Repository) async throws -> WorkingCopyStatus {
        let data = try await runner.runChecked(
            ["status", "--porcelain=v2", "-z", "--branch"], in: repo.rootURL)
        return StatusParser.parse(data)
    }

    public func blob(at path: String, rev: String, in repo: Repository) async throws -> Data {
        try await runner.runChecked(["show", "\(rev):\(path)"], in: repo.rootURL)
    }
}
