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

    /// Config overrides forced onto *every* invocation so output is stable regardless of the
    /// user's `~/.gitconfig` or system config. Command-line `-c` has the highest precedence in
    /// git, so these win over any on-disk setting without mutating anything.
    ///   - `core.quotepath=false`         emit raw UTF-8 paths, never octal-escaped (`\303\251…`).
    ///   - `i18n.logOutputEncoding=UTF-8` force UTF-8 so commit text decodes predictably.
    ///   - `log.showSignature=false`      never inject GPG verification lines into output.
    ///   - `color.ui=false`               never inject ANSI escapes (with `--no-color` on diffs).
    static let globalConfigArgs = [
        "-c", "core.quotepath=false",
        "-c", "i18n.logOutputEncoding=UTF-8",
        "-c", "log.showSignature=false",
        "-c", "color.ui=false",
    ]

    /// Environment hardening shared by every git invocation — including the bespoke streaming
    /// process in `GitService`, which is why this is exposed rather than inlined in `run`.
    /// Read-only, non-interactive, and isolated from system config.
    static func hardenedEnvironment(optionalLocks: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if !optionalLocks { env["GIT_OPTIONAL_LOCKS"] = "0" }  // don't take locks for reads
        env["GIT_TERMINAL_PROMPT"] = "0"   // never prompt for credentials
        env["GIT_PAGER"] = "cat"           // never invoke a pager
        env["GIT_CONFIG_NOSYSTEM"] = "1"   // ignore /etc/gitconfig for determinism
        return env
    }

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
        process.arguments = GitRunner.globalConfigArgs + arguments
        if let directory { process.currentDirectoryURL = directory }
        process.environment = GitRunner.hardenedEnvironment(optionalLocks: optionalLocks)

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

    /// Streams stdout from a git invocation as `[UInt8]` chunks. Cancellation terminates the child.
    func stream(_ arguments: [String], in directory: URL?, optionalLocks: Bool = false) -> AsyncThrowingStream<[UInt8], Error> {
        let gitURL = self.gitURL
        let allArgs = GitRunner.globalConfigArgs + arguments
        let env = GitRunner.hardenedEnvironment(optionalLocks: optionalLocks)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let process = Process()
                    process.executableURL = gitURL
                    process.arguments = allArgs
                    if let directory { process.currentDirectoryURL = directory }
                    process.environment = env
                    let outPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = FileHandle.nullDevice
                    try await withTaskCancellationHandler {
                        try process.run()
                        for try await chunk in ByteChunks(base: outPipe.fileHandleForReading.bytes) {
                            guard !Task.isCancelled else { break }
                            continuation.yield(chunk)
                        }
                        process.waitUntilExit()
                        if process.terminationStatus != 0 && !Task.isCancelled {
                            throw GitError.commandFailed(
                                command: "git " + allArgs.joined(separator: " "),
                                exitCode: process.terminationStatus, stderr: "")
                        }
                        continuation.finish(throwing: Task.isCancelled ? GitError.cancelled : nil)
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

/// Batches single-byte `AsyncBytes` reads into `[UInt8]` chunks to reduce per-byte overhead.
struct ByteChunks<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element == UInt8 {
    typealias Element = [UInt8]
    let base: Base
    var chunkSize: Int = 4096

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
