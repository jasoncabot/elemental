import Foundation

/// Parses unified diff / `git diff`-style patch text into structured DiffFiles.
/// Riskiest surface in the data layer — QA fuzzes this. Must never crash; on malformed
/// input it returns whatever it parsed so far.
enum DiffParser {
    static func parse(_ data: Data) -> [DiffFile] {
        let text = String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var current: Builder?
        func flush() {
            if let c = current { files.append(c.build()) }
            current = nil
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("diff --git ") {
                flush()
                current = Builder()
                current?.parseGitHeader(line)
            } else if line.hasPrefix("old mode ") || line.hasPrefix("new mode ") {
                // ignore
            } else if line.hasPrefix("new file mode") {
                current?.status = .added
            } else if line.hasPrefix("deleted file mode") {
                current?.status = .deleted
            } else if line.hasPrefix("rename from ") {
                current?.oldPath = String(line.dropFirst("rename from ".count)); current?.status = .renamed
            } else if line.hasPrefix("rename to ") {
                current?.newPath = String(line.dropFirst("rename to ".count)); current?.status = .renamed
            } else if line.hasPrefix("copy from ") {
                current?.oldPath = String(line.dropFirst("copy from ".count)); current?.status = .copied
            } else if line.hasPrefix("copy to ") {
                current?.newPath = String(line.dropFirst("copy to ".count)); current?.status = .copied
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.isBinary = true
            } else if line.hasPrefix("--- ") {
                current?.setOld(fromTripleDash: String(line.dropFirst(4)))
            } else if line.hasPrefix("+++ ") {
                current?.setNew(fromPlusPlus: String(line.dropFirst(4)))
            } else if line.hasPrefix("@@") {
                current?.startHunk(line)
            } else {
                current?.appendBodyLine(line)
            }
            i += 1
        }
        flush()
        return files
    }

    private final class Builder {
        var oldPath: String?
        var newPath: String?
        var status: DiffStatus = .modified
        var isBinary = false
        var hunks: [DiffHunk] = []
        var additions = 0
        var deletions = 0

        private var hunkOldStart = 0
        private var hunkNewStart = 0
        private var hunkOldCount = 0
        private var hunkNewCount = 0
        private var hunkHeader = ""
        private var hunkLines: [DiffLine] = []
        private var oldLine = 0
        private var newLine = 0
        private var inHunk = false

        func parseGitHeader(_ line: String) {
            // diff --git a/<old> b/<new>
            let rest = line.dropFirst("diff --git ".count)
            if let range = rest.range(of: " b/") {
                let a = String(rest[rest.startIndex..<range.lowerBound])
                let b = String(rest[range.upperBound...])
                oldPath = a.hasPrefix("a/") ? String(a.dropFirst(2)) : a
                newPath = b
            }
        }

        func setOld(fromTripleDash s: String) {
            if s == "/dev/null" { status = .added; oldPath = nil; return }
            oldPath = s.hasPrefix("a/") ? String(s.dropFirst(2)) : s
        }

        func setNew(fromPlusPlus s: String) {
            if s == "/dev/null" { status = .deleted; newPath = nil; return }
            newPath = s.hasPrefix("b/") ? String(s.dropFirst(2)) : s
        }

        func startHunk(_ line: String) {
            finishHunk()
            inHunk = true
            hunkHeader = line
            // @@ -oldStart,oldCount +newStart,newCount @@ optional
            let scanner = line
            if let atRange = scanner.range(of: "@@", options: .backwards) {
                _ = atRange
            }
            let core = line.components(separatedBy: "@@")
            if core.count >= 2 {
                let nums = core[1].trimmingCharacters(in: .whitespaces)
                for token in nums.split(separator: " ") {
                    if token.hasPrefix("-") {
                        let (start, count) = parseRange(String(token.dropFirst()))
                        hunkOldStart = start; hunkOldCount = count; oldLine = start
                    } else if token.hasPrefix("+") {
                        let (start, count) = parseRange(String(token.dropFirst()))
                        hunkNewStart = start; hunkNewCount = count; newLine = start
                    }
                }
            }
            hunkLines = []
        }

        private func parseRange(_ s: String) -> (Int, Int) {
            let parts = s.split(separator: ",")
            let start = Int(parts.first ?? "0") ?? 0
            let count = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
            return (start, count)
        }

        func appendBodyLine(_ line: String) {
            guard inHunk else { return }
            if line.hasPrefix("+") {
                hunkLines.append(DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: newLine, text: String(line.dropFirst())))
                newLine += 1; additions += 1
            } else if line.hasPrefix("-") {
                hunkLines.append(DiffLine(kind: .removed, oldLineNumber: oldLine, newLineNumber: nil, text: String(line.dropFirst())))
                oldLine += 1; deletions += 1
            } else if line.hasPrefix(" ") {
                hunkLines.append(DiffLine(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1; newLine += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" — ignore
            } else if line.isEmpty {
                hunkLines.append(DiffLine(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: ""))
                oldLine += 1; newLine += 1
            }
        }

        private func finishHunk() {
            guard inHunk else { return }
            hunks.append(DiffHunk(oldStart: hunkOldStart, oldCount: hunkOldCount,
                                  newStart: hunkNewStart, newCount: hunkNewCount,
                                  header: hunkHeader, lines: hunkLines))
            inHunk = false
        }

        func build() -> DiffFile {
            finishHunk()
            return DiffFile(oldPath: oldPath, newPath: newPath, status: status,
                            isBinary: isBinary, hunks: hunks,
                            additions: additions, deletions: deletions)
        }
    }
}
