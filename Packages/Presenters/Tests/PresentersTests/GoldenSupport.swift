import Foundation
import XCTest
import GitData
@testable import Presenters

/// Golden-snapshot assertions. A golden is the checked-in, human-readable rendering of a
/// presentation model for one fixture; any change to what the UI would show fails the test until
/// the golden is deliberately re-recorded and reviewed in the diff. See docs/golden-fixtures.md.
enum Golden {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Goldens", isDirectory: true)

    /// Set `ELEMENTAL_RECORD_GOLDENS=1` to rewrite goldens from the current output.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["ELEMENTAL_RECORD_GOLDENS"] == "1"
    }

    static func url(group: String, name: String) -> URL {
        directory.appendingPathComponent(group, isDirectory: true)
            .appendingPathComponent(name + ".golden")
    }

    static func assertMatches(_ actual: String, group: String, name: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let url = url(group: group, name: name)
        let expected = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }

        if isRecording || expected == nil {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(actual.utf8).write(to: url)
            } catch {
                XCTFail("Could not write golden \(group)/\(name): \(error)", file: file, line: line)
            }
            // A new golden must be reviewed before it can pass; recording never silently passes a change.
            if expected == nil {
                XCTFail("""
                    Recorded new golden \(group)/\(name).golden — review it and commit it.
                    ----- BEGIN GOLDEN \(group)/\(name) -----
                    \(actual)----- END GOLDEN -----
                    """, file: file, line: line)
            } else if expected != actual {
                XCTFail("Re-recorded changed golden \(group)/\(name).golden — review the diff and commit it.",
                        file: file, line: line)
            }
            return
        }

        guard let expected, expected != actual else { return }
        XCTFail("""
            \(group)/\(name) no longer matches its golden.
            \(firstDifference(expected: expected, actual: actual))
            If this change is intended, re-run with ELEMENTAL_RECORD_GOLDENS=1 and commit the updated golden.
            ----- BEGIN GOLDEN \(group)/\(name) -----
            \(actual)----- END GOLDEN -----
            """, file: file, line: line)
    }

    /// Goldens with no fixture left behind — a deleted fixture must take its golden with it.
    static func orphans(group: String, expected names: Set<String>) -> [String] {
        let dir = directory.appendingPathComponent(group, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".golden") }
            .map { String($0.dropLast(".golden".count)) }
            .filter { !names.contains($0) }
            .sorted()
    }

    private static func firstDifference(expected: String, actual: String) -> String {
        let e = expected.components(separatedBy: "\n")
        let a = actual.components(separatedBy: "\n")
        for i in 0..<max(e.count, a.count) {
            let el = i < e.count ? e[i] : "<missing>"
            let al = i < a.count ? a[i] : "<missing>"
            if el != al { return "First difference at line \(i + 1):\n  golden: \(el)\n  actual: \(al)" }
        }
        return "Contents differ."
    }
}

/// Stable, diff-friendly text renderings of presentation models. Every field the App shows is
/// listed, so a golden diff reads as "what changed on screen".
enum Snapshot {
    static func swatch(_ s: Swatch) -> String {
        switch s {
        case .commitType(let t): return "type:\(t)"
        case .neutral:           return "neutral"
        case .danger:            return "danger"
        case .issue:             return "issue"
        case .ai:                return "ai"
        case .note:              return "note"
        case .agent(let i):      return "agent\(i)"
        case .human(let i):      return "human\(i)"
        case .unknown:           return "unknown"
        }
    }

    /// Tooltips can hold newlines; keep each field on one line.
    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: " | ")
    }

    static func note(_ p: NotePresentation) -> String {
        var out: [String] = []
        out.append("title: \(p.title)")
        out.append("caption: \(p.caption)")
        out.append("pill: \(p.pillText)")
        out.append("pill tooltip: \(p.pillTooltip)")
        out.append("raw style: \(p.rawStyle == .monospaced ? "monospaced" : "prose")")
        let rawLines = p.rawText.components(separatedBy: "\n").count
        out.append("raw: \(rawLines) line\(rawLines == 1 ? "" : "s"), \(p.rawText.unicodeScalars.count) scalars, "
                   + "CR \(p.rawText.unicodeScalars.filter { $0 == "\r" }.count)")
        guard let s = p.summary else {
            out.append("summary: none")
            return out.joined(separator: "\n") + "\n"
        }
        out.append("summary:")
        out.append("  overview: \(s.overview)")
        out.append("  shares: " + (s.shares.isEmpty ? "none" : s.shares
            .map { "\(swatch($0.swatch)) \(String(format: "%.1f%%", $0.fraction * 100))" }
            .joined(separator: " · ")))
        out.append("  agents: " + (s.agentNames.isEmpty ? "none" : s.agentNames.joined(separator: ", ")))
        out.append("  contributors:")
        for c in s.contributors {
            out.append("    [\(swatch(c.swatch))] \(c.name) — \(c.countText)")
            for d in c.details { out.append("      \(d)") }
            out.append("      tooltip: \(oneLine(c.tooltip))")
        }
        out.append("  files:" + (s.files.isEmpty ? " none" : ""))
        for f in s.files {
            out.append("    \(oneLine(f.path)) — \(f.countText)")
            for a in f.attributions {
                out.append("      [\(swatch(a.swatch))] \(a.name) · \(a.rangesText) · \(a.countText)")
            }
        }
        out.append("  footer: \(s.footer)")
        out.append("  footer tooltip: \(s.footerTooltip ?? "none")")
        return out.joined(separator: "\n") + "\n"
    }

    static func chips(_ chips: [HeaderChip]) -> String {
        guard !chips.isEmpty else { return "chips: none\n" }
        var out = ["chips:"]
        for c in chips {
            var line = "  [\(swatch(c.swatch))\(c.filled ? " filled" : "")] \(c.text)"
            if case .openNote(let i) = c.action { line += " → opens note \(i)" }
            if let t = c.tooltip { line += " (tooltip: \(oneLine(t)))" }
            out.append(line)
        }
        return out.joined(separator: "\n") + "\n"
    }
}
