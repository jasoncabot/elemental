import Foundation

/// Result of running a git invocation.
struct GitProcessResult: Sendable {
    var stdout: Data
    var stderr: String
    var exitCode: Int32
}

/// Locates and runs the user's own git binary. Read-only callers should pass optionalLocks: false.
struct GitRunner: Sendable {
    let gitURL: URL

    /// Discover git by scanning PATH directly — no subprocess, never blocks the main thread.
    static func discover() throws -> GitRunner {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("git").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return GitRunner(gitURL: URL(fileURLWithPath: candidate))
            }
        }
        for fallback in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: fallback) {
                return GitRunner(gitURL: URL(fileURLWithPath: fallback))
            }
        }
        throw GitError.gitNotFound
    }

    /// Run git in `directory` and return raw output. Honors task cancellation by terminating the child.
    func run(_ arguments: [String], in directory: URL?, optionalLocks: Bool = false) async throws -> GitProcessResult {
        let process = Process()
        process.executableURL = gitURL
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }

        var env = ProcessInfo.processInfo.environment
        if !optionalLocks { env["GIT_OPTIONAL_LOCKS"] = "0" }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withTaskCancellationHandler {
            try process.run()
            // Close the parent's write ends: once the child exits, both ends are closed
            // and the concurrent reads below receive EOF instead of blocking forever.
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()

            async let exitCode: Int32 = withCheckedContinuation { cont in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            }
            async let outData: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(returning: outPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            async let errData: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(returning: errPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }

            return GitProcessResult(
                stdout: await outData,
                stderr: String(decoding: await errData, as: UTF8.self),
                exitCode: await exitCode
            )
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Run and throw on non-zero exit; returns stdout.
    func runChecked(_ arguments: [String], in directory: URL?, optionalLocks: Bool = false) async throws -> Data {
        let result = try await run(arguments, in: directory, optionalLocks: optionalLocks)
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(
                command: "git " + arguments.joined(separator: " "),
                exitCode: result.exitCode, stderr: result.stderr
            )
        }
        return result.stdout
    }
}
