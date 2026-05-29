import Foundation

/// Builds disposable git repositories on disk for tests. Shells out to the real git binary so
/// tests exercise the same "user's own git" path the app uses. Other layers consume these
/// fixtures rather than inventing their own.
public final class FixtureRepo {
    public let url: URL
    private let git: String

    public init(git: String = FixtureRepo.discoverGit()) throws {
        self.git = git
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("elemental-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base
        try run(["init", "-q", "-b", "main"])
        try run(["config", "user.name", "Fixture Tester"])
        try run(["config", "user.email", "fixture@example.com"])
        try run(["config", "commit.gpgsign", "false"])
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    public static func discoverGit() -> String {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/git"
    }

    // MARK: - Building history

    @discardableResult
    public func writeFile(_ path: String, _ contents: String) throws -> URL {
        let fileURL = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    public func writeBinary(_ path: String, _ bytes: [UInt8]) throws {
        let fileURL = url.appendingPathComponent(path)
        try Data(bytes).write(to: fileURL)
    }

    /// Write raw bytes (Data) to a file — used for CRLF, mixed endings, binary, etc.
    public func writeData(_ path: String, _ data: Data) throws {
        let fileURL = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
    }

    @discardableResult
    public func commit(_ message: String, addAll: Bool = true) throws -> String {
        if addAll { try run(["add", "-A"]) }
        try run(["commit", "-q", "-m", message, "--allow-empty"])
        return try revParse("HEAD")
    }

    public func checkoutNewBranch(_ name: String) throws {
        try run(["checkout", "-q", "-b", name])
    }

    public func checkout(_ ref: String) throws {
        try run(["checkout", "-q", ref])
    }

    public func merge(_ branch: String, message: String) throws {
        try run(["merge", "--no-ff", "-q", "-m", message, branch])
    }

    /// Perform an octopus merge of multiple branches in a single commit.
    public func octopusMerge(_ branches: [String], message: String) throws {
        try run(["merge", "--no-ff", "-q", "-m", message] + branches)
    }

    public func tag(_ name: String) throws {
        try run(["tag", name])
    }

    public func revParse(_ ref: String) throws -> String {
        try output(["rev-parse", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Catalog factory methods

    /// Build an empty repo (no commits at all) and return its URL.
    public static func makeEmpty() throws -> FixtureRepo {
        // Default init already produces an empty repo; no commits added.
        return try FixtureRepo()
    }

    /// Build a bare clone of self into a sibling directory; caller is responsible for cleanup.
    public func makeBareClone() throws -> URL {
        let bareURL = url.deletingLastPathComponent()
            .appendingPathComponent("bare-\(UUID().uuidString).git")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["clone", "--bare", "-q", url.path, bareURL.path]
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return bareURL
    }

    /// Add a linked worktree checked out to `branch`. Returns the worktree URL.
    public func addWorktree(branch: String) throws -> URL {
        let wtURL = url.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)")
        try run(["worktree", "add", "-q", "-b", branch, wtURL.path])
        return wtURL
    }

    /// Add a linked worktree with a detached HEAD at the given ref. Returns the worktree URL.
    public func addDetachedWorktree(at ref: String) throws -> URL {
        let wtURL = url.deletingLastPathComponent()
            .appendingPathComponent("wt-detached-\(UUID().uuidString)")
        try run(["worktree", "add", "--detach", "-q", wtURL.path, ref])
        return wtURL
    }

    /// Add an orphan worktree (unborn branch, empty index). Returns the worktree URL.
    public func addOrphanWorktree(branch: String) throws -> URL {
        let wtURL = url.deletingLastPathComponent()
            .appendingPathComponent("wt-orphan-\(UUID().uuidString)")
        try run(["worktree", "add", "--orphan", "-b", branch, "-q", wtURL.path])
        return wtURL
    }

    /// Lock a linked worktree by its path.
    public func lockWorktree(at path: URL, reason: String? = nil) throws {
        var args = ["worktree", "lock"]
        if let reason { args += ["--reason", reason] }
        args.append(path.path)
        try run(args)
    }

    /// Stash the current working copy changes.
    @discardableResult
    public func stash(message: String? = nil) throws -> Int32 {
        var args = ["stash", "push"]
        if let message { args += ["-m", message] }
        return try run(args)
    }

    /// Pop the most recent stash entry.
    @discardableResult
    public func stashPop() throws -> Int32 {
        try run(["stash", "pop"])
    }

    /// Create a shallow clone of this repo at the given depth. Returns the clone's URL.
    public func makeShallowClone(depth: Int = 1) throws -> URL {
        let shallowURL = url.deletingLastPathComponent()
            .appendingPathComponent("shallow-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["clone", "--depth", "\(depth)", "-q", url.path, shallowURL.path]
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return shallowURL
    }

    /// Switch to an existing branch using `git switch`.
    @discardableResult
    public func switchBranch(_ name: String) throws -> Int32 {
        try run(["switch", "-q", name])
    }

    /// Start an interactive rebase (non-interactive via GIT_SEQUENCE_EDITOR) to squash last N commits.
    @discardableResult
    public func rebaseSquash(last n: Int) throws -> Int32 {
        // Use a sequence editor that replaces "pick" with "squash" for all but the first line.
        let editor = "sed -i '2,$s/^pick/squash/' \"$1\""
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SEQUENCE_EDITOR"] = editor
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", url.path, "rebase", "-i", "HEAD~\(n)"]
        p.environment = env
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Add a submodule from another FixtureRepo. `subPath` is the in-repo path.
    public func addSubmodule(_ sub: FixtureRepo, at subPath: String) throws {
        try run(["submodule", "add", "-q", sub.url.path, subPath])
    }

    // MARK: - Raw git

    @discardableResult
    public func run(_ args: [String]) throws -> Int32 {
        let p = process(args)
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    public func output(_ args: [String]) throws -> String {
        let p = process(args)
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", url.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        p.standardError = FileHandle.nullDevice
        return p
    }
}
