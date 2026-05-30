import AppKit

/// Central design system for Elemental.
///
/// The product brief calls for a calm, native, typography-led experience that is
/// deliberately *not* a terminal-style diff tool. Every color here resolves through
/// the system appearance so light/dark both feel native, and tints are kept low so
/// the diff reads as calm rather than noisy.
enum Theme {

    // MARK: - Metrics

    enum Metric {
        /// Standard content inset used across panes.
        static let pad: CGFloat = 14
        static let padTight: CGFloat = 8
        static let cornerRadius: CGFloat = 6
        static let pillRadius: CGFloat = 4

        static let timelineRowHeight: CGFloat = 56
        static let fileRowHeight: CGFloat = 26
        static let groupRowHeight: CGFloat = 24
        static var diffLineHeight: CGFloat { ceil(Font.diffFontSize * 1.5) }
        static let hunkHeaderHeight: CGFloat = 26
    }

    // MARK: - Typography

    enum Font {
        static func subject(_ weight: NSFont.Weight = .semibold) -> NSFont {
            .systemFont(ofSize: 13, weight: weight)
        }
        static let secondary = NSFont.systemFont(ofSize: 11, weight: .regular)
        static let caption = NSFont.systemFont(ofSize: 10, weight: .medium)
        static let pill = NSFont.systemFont(ofSize: 10, weight: .semibold)
        static let sectionHeader = NSFont.systemFont(ofSize: 11, weight: .semibold)

        static let file = NSFont.systemFont(ofSize: 12, weight: .regular)
        static let fileGroup = NSFont.systemFont(ofSize: 12, weight: .semibold)

        static let defaultDiffSize: CGFloat = 11
        static let minDiffSize: CGFloat = 9
        static let maxDiffSize: CGFloat = 18

        static var diffFontSize: CGFloat {
            get {
                let v = UserDefaults.standard.double(forKey: "diffFontSize")
                return v > 0 ? CGFloat(v) : defaultDiffSize
            }
            set {
                let clamped = max(minDiffSize, min(maxDiffSize, newValue))
                UserDefaults.standard.set(Double(clamped), forKey: "diffFontSize")
                NotificationCenter.default.post(name: .diffFontSizeDidChange, object: nil)
            }
        }

        static func code() -> NSFont { .monospacedSystemFont(ofSize: diffFontSize, weight: .regular) }
        static var codeGutter: NSFont { .monospacedSystemFont(ofSize: max(8, diffFontSize - 2), weight: .regular) }
        static var codeMeta: NSFont { .monospacedSystemFont(ofSize: max(8, diffFontSize - 1.5), weight: .medium) }
    }

    // MARK: - Color

    enum Color {
        // Diff line backgrounds — intentionally soft so large diffs stay calm.
        static let addedBackground = NSColor.systemGreen.withAlphaComponent(0.10)
        static let removedBackground = NSColor.systemRed.withAlphaComponent(0.10)
        static let addedGutter = NSColor.systemGreen.withAlphaComponent(0.16)
        static let removedGutter = NSColor.systemRed.withAlphaComponent(0.16)

        static let addedText = blend(.systemGreen, into: .labelColor, amount: 0.35)
        static let removedText = blend(.systemRed, into: .labelColor, amount: 0.35)

        static let addStat = NSColor.systemGreen
        static let delStat = NSColor.systemRed

        // Hunk separators / structural lines.
        static let hunkBackground = NSColor.separatorColor.withAlphaComponent(0.10)

        // Risk accents.
        static let riskHigh = NSColor.systemRed
        static let riskMedium = NSColor.systemOrange
        static let riskLow = NSColor.systemBlue

        static func statusColor(_ status: DiffStatusKind) -> NSColor {
            switch status {
            case .added:   return .systemGreen
            case .deleted: return .systemRed
            case .renamed, .copied: return .systemPurple
            case .modified, .typeChanged: return .systemOrange
            case .other:   return .secondaryLabelColor
            }
        }

        /// A calm, typography-friendly status tint for filename text — the status color blended
        /// toward the label color so a list of modified files reads as text, not a warning.
        static func statusText(_ status: DiffStatusKind) -> NSColor {
            blend(statusColor(status), into: .labelColor, amount: 0.55)
        }

        private static func blend(_ a: NSColor, into b: NSColor, amount: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let resolvedA = a.resolvedColor(for: appearance)
                let resolvedB = b.resolvedColor(for: appearance)
                return resolvedB.blended(withFraction: amount, of: resolvedA) ?? resolvedB
            }
        }
    }
}

// MARK: - Constraint builder helpers

extension NSLayoutConstraint {
    /// Sets a human-readable identifier so the constraint appears by name in the debugger
    /// and Xcode's constraint-conflict log instead of as an opaque memory address.
    @discardableResult func id(_ name: String) -> NSLayoutConstraint {
        identifier = name; return self
    }
    /// Drops priority to `.defaultHigh` so an autoresizing-mask constraint imposed by
    /// NSSplitView at startup can win without triggering unsatisfiable-constraint logs.
    @discardableResult func h() -> NSLayoutConstraint {
        priority = .defaultHigh; return self
    }
}

extension Notification.Name {
    static let diffFontSizeDidChange = Notification.Name("elemental.diffFontSizeDidChange")
}

/// Appearance-aware resolution helper for NSColor (used by custom-drawn cells).
extension NSColor {
    func resolvedColor(for appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance {
            result = self.usingColorSpace(.sRGB) ?? self
        }
        return result
    }
}

/// View-local mirror of GitData.DiffStatus so the design layer carries no git dependency.
enum DiffStatusKind {
    case added, deleted, modified, renamed, copied, typeChanged, other
}
