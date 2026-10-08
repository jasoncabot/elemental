import AppKit
import Presenters

/// The one place colour roles chosen by presenters become system colours.
extension Swatch {
    var color: NSColor {
        switch self {
        case .commitType(let type):
            switch type {
            case "feat":     return .systemBlue
            case "fix":      return .systemOrange
            case "docs":     return .systemTeal
            case "test":     return .systemGreen
            case "perf":     return .systemPurple
            case "refactor": return .systemIndigo
            default:         return .systemGray
            }
        case .neutral: return .systemGray
        case .danger:  return .systemRed
        case .issue:   return .systemBlue
        case .ai:      return .systemPurple
        case .note:    return .systemYellow
        case .agent(let i):
            let palette: [NSColor] = [.systemPurple, .systemIndigo, .systemPink, .systemTeal, .systemOrange]
            return palette[i % palette.count]
        case .human(let i):
            let palette: [NSColor] = [.systemBlue, .systemGreen, .systemBrown]
            return palette[i % palette.count]
        case .unknown: return .systemGray
        }
    }
}
