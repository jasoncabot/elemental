import Foundation

/// The production GitBackend: shells out to the user's own git binary using **plumbing** commands
/// (`rev-list`, `diff-tree`, `diff-index`, `diff-files`, `cat-file`, `rev-parse`, `for-each-ref`)
/// with machine-readable, config-stable output. Plumbing is the documented script-facing surface;
/// porcelain (`git diff`, `git show`, `git log`) is avoided because its output can be reshaped by
/// the user's config, aliases, pager, or external diff/textconv programs.
///
/// Two commands have no plumbing equivalent and are used with their documented stable machine
/// formats instead: `git worktree list --porcelain` and `git status --porcelain=v2 -z`.
///
/// All invocations are further hardened against the environment by `GitRunner` (see
/// `globalConfigArgs` / `hardenedEnvironment`).
public actor CLIGitBackend: GitBackend {
    /// Package-internal: exposed so `GitService` can reuse the already-discovered runner for
    /// streaming (avoiding a redundant PATH scan on every paginated log load).
    nonisolated let runner: GitRunner
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
        // `worktree` has no plumbing form; `--porcelain` is its documented stable machine format.
        let data = try await runner.runChecked(["worktree", "list", "--porcelain"], in: root)
        let text = String(decoding: data, as: UTF8.self)
        var result: [Worktree] = []
        var path: URL?
        var head: String?
        var branch: String?
        var bare = false
        var detached = false
        var locked = false
        var prunable = false
        func flush() {
            if let path {
                result.append(Worktree(path: path, head: head, branch: branch, isBare: bare,
                                       isDetached: detached, isLocked: locked, isPrunable: prunable))
            }
            path = nil; head = nil; branch = nil; bare = false
            detached = false; locked = false; prunable = false
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
            } else if line == "detached" {
                detached = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                prunable = true
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
                    let args = CommitLog.revListArgs(for: query)
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

    public func commitCount(_ query: CommitQuery) async throws -> Int {
        var args = ["rev-list", "--count"]
        switch query.scope {
        case .head:           args.append("HEAD")
        case .branch(let b):  args.append(b)
        case .ref(let r):     args.append(r)
        case .all:            args.append("--all")
        }
        if let since = query.since {
            args.append("--since=\(ISO8601DateFormatter.gitISO.string(from: since))")
        }
        let data = try await runner.runChecked(args, in: query.repo.rootURL)
        let str = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(str) ?? 0
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

    /// Formatting flags shared by every plumbing diff. They pin the output shape so the user's
    /// config can't perturb the parser, and refuse to run arbitrary user programs on the content:
    ///   - `--src-prefix`/`--dst-prefix`  force the `a/`,`b/` prefixes the parser strips.
    ///   - `--no-ext-diff`/`--no-textconv` never shell out to an external diff/textconv filter
    ///                                     (determinism, and never touch confidential content).
    ///   - `--no-color`                    never emit ANSI into the parser.
    ///   - `-M`/`-C`                       detect renames/copies.
    private static let diffFormatFlags = [
        "--patch", "-M", "-C",
        "--no-color", "--no-ext-diff", "--no-textconv",
        "--src-prefix=a/", "--dst-prefix=b/",
    ]

    public func diff(_ range: DiffRange, in repo: Repository) async throws -> [DiffFile] {
        var args: [String]
        switch range {
        case .workingUnstaged:
            // Worktree vs index. Plumbing equivalent of `git diff` (no args).
            args = ["diff-files"] + Self.diffFormatFlags
        case .workingStaged:
            // Index vs HEAD. Plumbing equivalent of `git diff --cached`. On an unborn branch
            // there is no HEAD, so compare against the (object-format-correct) empty tree.
            let base = try await stagedComparisonBase(in: repo)
            args = ["diff-index", "--cached"] + Self.diffFormatFlags + [base]
        case .workingUntracked(let path):
            // Untracked files are absent from the index, so no tree-diff sees them. `--no-index`
            // compares /dev/null against the worktree file to render the whole file as additions.
            // It exits 1 when the files differ (the normal case here), so this path can't use
            // `runChecked`; it's handled below with explicit exit-code tolerance.
            return try await untrackedDiff(path: path, in: repo)
        case .commit(let sha):
            // Commit vs parent. Plumbing equivalent of `git show`:
            //   --no-commit-id  suppress the leading `<sha>` line diff-tree prints.
            //   -r              recurse into subdirectories (diff-tree stops at top level otherwise).
            //   --root          show the initial commit as all-additions instead of an empty diff.
            //   -m --first-parent  render a merge as a plain diff against its first parent
            //                      (git show defaults to --cc, which the parser can't read and
            //                      which is empty for conflict-free merges).
            args = ["diff-tree", "--no-commit-id", "-r", "--root", "-m", "--first-parent"]
                + Self.diffFormatFlags + [sha]
        case .between(let a, let b):
            // Tree a vs tree b. Plumbing equivalent of `git diff a..b` (which diffs endpoints).
            args = ["diff-tree", "--no-commit-id", "-r"] + Self.diffFormatFlags + [a, b]
        }
        let data = try await runner.runChecked(args, in: repo.rootURL)
        // Single chokepoint: parse raw patch, then classify churn (whitespace/moves) for the UI.
        return DiffAnnotator.annotate(DiffParser.parse(data))
    }

    /// Render an untracked file's full contents as an all-additions diff via `git diff --no-index`.
    /// `--no-index` returns exit code 1 when the inputs differ — which is always the case here
    /// (empty vs file) — so a non-zero exit is expected; only treat ≥2 (git error) as failure.
    private func untrackedDiff(path: String, in repo: Repository) async throws -> [DiffFile] {
        let args = ["diff", "--no-index"] + Self.diffFormatFlags + ["--", "/dev/null", path]
        let result = try await runner.run(args, in: repo.rootURL)
        guard result.exitCode <= 1 else {
            throw GitError.commandFailed(command: "git " + args.joined(separator: " "),
                                         exitCode: result.exitCode, stderr: result.stderr)
        }
        // `--no-index` labels the new side `b/<path>` already (our forced dst-prefix); the parser
        // strips it. Mark the result as untracked so the UI can tint/group it as a new file.
        return DiffAnnotator.annotate(DiffParser.parse(result.stdout)).map { file in
            var f = file
            f.status = .untracked
            return f
        }
    }

    public func preparedCommitMessage(for repo: Repository) async throws -> String? {
        // Only files that mean a commit message is genuinely *in progress*: MERGE_MSG and
        // SQUASH_MSG exist during a merge/squash/cherry-pick. COMMIT_EDITMSG is deliberately
        // excluded — git leaves it behind after every `git commit`, so reading it would surface
        // the *last* commit's message as a phantom draft. Read-only; nothing is written.
        for name in ["MERGE_MSG", "SQUASH_MSG"] {
            let url = repo.gitDir.appendingPathComponent(name)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                   && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                continue   // file simply doesn't exist — no in-progress message for this name
            }
            // Any other read failure (permissions, disk error) propagates so the caller can surface it.
            guard let raw = String(data: data, encoding: .utf8) else { continue }
            // Drop git's comment lines (`# …`) and surrounding blank lines.
            let body = raw
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return body }
        }
        return nil
    }

    /// The tree `diff-index --cached` compares the index against: HEAD when it resolves, otherwise
    /// the empty tree (unborn branch — files staged before the first commit).
    private func stagedComparisonBase(in repo: Repository) async throws -> String {
        let result = try await runner.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: repo.rootURL)
        if result.exitCode == 0 {
            let sha = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        return try await emptyTreeOID(in: repo)
    }

    /// The empty-tree object id for this repository, computed read-only (no `-w`, nothing written)
    /// so it is correct for both sha1 and sha256 repositories.
    private func emptyTreeOID(in repo: Repository) async throws -> String {
        let data = try await runner.runChecked(
            ["hash-object", "-t", "tree", "/dev/null"], in: repo.rootURL)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func workingCopyStatus(for repo: Repository) async throws -> WorkingCopyStatus {
        // No plumbing command reports the combined index+worktree+untracked state; `--porcelain=v2`
        // is git's documented stable machine format and the intended interface for tools.
        let data = try await runner.runChecked(
            ["status", "--porcelain=v2", "-z", "--branch"], in: repo.rootURL)
        return StatusParser.parse(data)
    }

    public func blob(at path: String, rev: String, in repo: Repository) async throws -> Data {
        // `cat-file blob` is the plumbing read of raw object bytes (the equivalent `git show
        // <rev>:<path>` is porcelain). Returns content exactly as stored — no smudge/textconv.
        try await runner.runChecked(["cat-file", "blob", "\(rev):\(path)"], in: repo.rootURL)
    }

    public func note(for sha: String, in repo: Repository) async throws -> String? {
        // `git notes` has no plumbing form, and `rev-list`/`diff-tree` can't surface notes — so
        // notes are fetched on demand only for the commit being reviewed, via `notes show`'s
        // stable single-purpose output. A non-zero exit means "no note", not a failure.
        let result = try await runner.run(["notes", "show", sha], in: repo.rootURL)
        guard result.exitCode == 0 else { return nil }
        let text = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
