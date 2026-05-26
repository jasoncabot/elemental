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

    public func tag(_ name: String) throws {
        try run(["tag", name])
    }

    public func revParse(_ ref: String) throws -> String {
        try output(["rev-parse", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
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
