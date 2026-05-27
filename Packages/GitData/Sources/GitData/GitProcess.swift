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

        let command = "git " + arguments.joined(separator: " ")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitProcessResult, Error>) in
                let outData = LockedData()
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        outData.append(chunk)
                    }
                }
                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    let remaining = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remaining.isEmpty { outData.append(remaining) }
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(decoding: errData, as: UTF8.self)
                    continuation.resume(returning: GitProcessResult(
                        stdout: outData.snapshot(), stderr: stderr, exitCode: proc.terminationStatus
                    ))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: GitError.commandFailed(
                        command: command, exitCode: -1, stderr: "\(error)"
                    ))
                }
            }
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

/// Minimal thread-safe data accumulator for the readability handler.
final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
