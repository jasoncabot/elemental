import Foundation

/// Reads git-ai line-level authorship data from `refs/ai/authorship/<sha>` (SHA-keyed blobs).
///
/// The git-ai project (https://github.com/git-ai-project/git-ai) records per-commit authorship
/// at the line level for both human and AI contributors. Each ref is a blob (not a commit) whose
/// name encodes the commit SHA it annotates.
///
/// Blob format (schema_version "authorship/0.0.1"):
/// ```json
/// {
///   "files": {
///     "path/to/file.swift": {
///       "file": "path/to/file.swift",
///       "authors": [
///         { "author": "Claude Code", "lines": [1, [5,10], 22], "agent_metadata": null }
///       ]
///     }
///   },
///   "schema_version": "authorship/0.0.1"
/// }
/// ```
/// `lines` is a mixed array of integers (single line) and 2-element arrays (inclusive ranges).
enum GitAIAuthorshipReader {

    static func load(sha: String, runner: GitRunner, root: URL) async throws -> AIAuthorshipRecord? {
        let result = try await runner.run(
            ["cat-file", "blob", "refs/ai/authorship/\(sha)"], in: root, optionalLocks: true)
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return parse(result.stdout)
    }

    private static func parse(_ data: Data) -> AIAuthorshipRecord? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filesMap = root["files"] as? [String: Any] else { return nil }

        let schemaVersion = root["schema_version"] as? String ?? ""
        var fileRecords: [AIAuthorshipRecord.FileRecord] = []

        for (path, value) in filesMap {
            guard let fileInfo = value as? [String: Any],
                  let authorsJSON = fileInfo["authors"] as? [[String: Any]] else { continue }

            var authorRecords: [AIAuthorshipRecord.FileRecord.Author] = []
            for authorInfo in authorsJSON {
                guard let name = authorInfo["author"] as? String,
                      let linesJSON = authorInfo["lines"] as? [Any] else { continue }
                let lineCount = countLines(linesJSON)
                if lineCount > 0 {
                    authorRecords.append(.init(name: name, lineCount: lineCount))
                }
            }
            if !authorRecords.isEmpty {
                fileRecords.append(.init(path: path, authors: authorRecords))
            }
        }
        return fileRecords.isEmpty ? nil : AIAuthorshipRecord(files: fileRecords, schemaVersion: schemaVersion)
    }

    /// Count lines from the mixed-type lines array: integers are single lines, [start, end] pairs
    /// are inclusive ranges.
    private static func countLines(_ lines: [Any]) -> Int {
        lines.reduce(0) { total, item in
            if item is Int {
                return total + 1
            } else if let range = item as? [Int], range.count == 2 {
                return total + max(0, range[1] - range[0] + 1)
            }
            return total
        }
    }
}
