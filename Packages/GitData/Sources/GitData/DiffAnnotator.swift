import Foundation

/// Heuristic, offline post-pass over parsed diffs. It classifies *changed* lines as formatting
/// churn (`.whitespace`) or relocated code (`.moved`), leaving genuine edits `.substantive`, so
/// the UI can let real changes stand out from the noise around them.
///
/// This is the single chokepoint where diff lines gain structural meaning — the one place an
/// optional, future refiner could sharpen these labels without the rest of the app changing.
/// No language parsing, no AST, no network: pure diff structure, derived from `git`'s own output.
enum DiffAnnotator {
    /// Minimum trimmed length for a line to be eligible as a `.moved` match. Short, ubiquitous
    /// lines (`}`, `return`, `break`) recur everywhere and would produce false matches, so they
    /// stay `.substantive`.
    static let minMovedSignificance = 4

    static func annotate(_ files: [DiffFile]) -> [DiffFile] {
        // Phase 1: whitespace-only changes, paired within each hunk.
        let whitespaced = files.map(annotateWhitespace(in:))
        // Phase 2: moved lines, matched across the whole diff (cross-file).
        return annotateMoves(in: whitespaced)
    }

    // MARK: - Phase 1: whitespace

    /// Within each hunk, pair a removed line with an added line whose content is identical after
    /// collapsing whitespace; if their raw text differs, both are whitespace-only churn. Pairing
    /// is 1:1 (a multiset queue) so duplicated lines aren't over-claimed.
    private static func annotateWhitespace(in file: DiffFile) -> DiffFile {
        var hunks = file.hunks
        for h in hunks.indices {
            var lines = hunks[h].lines
            var removedByNorm: [String: [Int]] = [:]
            for (idx, line) in lines.enumerated() where line.kind == .removed {
                removedByNorm[normalize(line.text), default: []].append(idx)
            }
            guard !removedByNorm.isEmpty else { continue }
            for (idx, line) in lines.enumerated() where line.kind == .added {
                let norm = normalize(line.text)
                guard var queue = removedByNorm[norm], let rIdx = queue.first else { continue }
                // A byte-identical pair is a move, not a whitespace change; leave it for phase 2.
                guard lines[rIdx].text != line.text else { continue }
                queue.removeFirst()
                removedByNorm[norm] = queue
                lines[idx] = lines[idx].with(.whitespace)
                lines[rIdx] = lines[rIdx].with(.whitespace)
            }
            hunks[h] = hunks[h].replacingLines(lines)
        }
        return file.replacingHunks(hunks)
    }

    // MARK: - Phase 2: moves

    private static func annotateMoves(in files: [DiffFile]) -> [DiffFile] {
        // Count significant trimmed contents on each side among lines still considered substantive.
        var removedCounts: [String: Int] = [:]
        var addedCounts: [String: Int] = [:]
        for file in files {
            for hunk in file.hunks {
                for line in hunk.lines where line.change == .substantive {
                    guard let key = movedKey(line) else { continue }
                    switch line.kind {
                    case .removed: removedCounts[key, default: 0] += 1
                    case .added:   addedCounts[key, default: 0] += 1
                    case .context: break
                    }
                }
            }
        }

        // A key is moved only if it appears on both sides; budget = min(occurrences), tracked per
        // side so we mark at most that many on each, leaving any surplus as genuine add/remove.
        var removedBudget: [String: Int] = [:]
        var addedBudget: [String: Int] = [:]
        for (key, removed) in removedCounts {
            guard let added = addedCounts[key] else { continue }
            let n = min(removed, added)
            removedBudget[key] = n
            addedBudget[key] = n
        }
        guard !removedBudget.isEmpty else { return files }

        return files.map { file in
            file.mapLines { line in
                guard line.change == .substantive, let key = movedKey(line) else { return line }
                switch line.kind {
                case .removed:
                    if let n = removedBudget[key], n > 0 { removedBudget[key] = n - 1; return line.with(.moved) }
                case .added:
                    if let n = addedBudget[key], n > 0 { addedBudget[key] = n - 1; return line.with(.moved) }
                case .context: break
                }
                return line
            }
        }
    }

    // MARK: - Keys

    /// Whitespace-insensitive key: trim, then collapse internal whitespace runs to a single space.
    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// Move key: the trimmed line, or `nil` if too short to be a meaningful match.
    private static func movedKey(_ line: DiffLine) -> String? {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= minMovedSignificance ? trimmed : nil
    }
}

// MARK: - Value-type rebuild helpers

private extension DiffLine {
    func with(_ change: DiffLineChange) -> DiffLine {
        DiffLine(kind: kind, oldLineNumber: oldLineNumber, newLineNumber: newLineNumber,
                 text: text, change: change)
    }
}

private extension DiffHunk {
    func replacingLines(_ lines: [DiffLine]) -> DiffHunk {
        DiffHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
                 header: header, lines: lines, context: context)
    }
}

private extension DiffFile {
    func replacingHunks(_ hunks: [DiffHunk]) -> DiffFile {
        DiffFile(oldPath: oldPath, newPath: newPath, status: status, isBinary: isBinary,
                 hunks: hunks, additions: additions, deletions: deletions)
    }

    func mapLines(_ transform: (DiffLine) -> DiffLine) -> DiffFile {
        replacingHunks(hunks.map { $0.replacingLines($0.lines.map(transform)) })
    }
}
