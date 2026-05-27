import AppKit
import GitData

/// Heuristic, AI-free analysis of a changed file.
///
/// The brief is emphatic: the core experience must be fast and fully functional
/// with no LLM inference — powered only by git metadata, paths, and diff structure.
/// These heuristics drive file signals (badges + icons), risk classification, and
/// the Risk-mode review ordering that mirrors how engineers already triage a PR.
enum FileSignal: Hashable {
    case config
    case dependency
    case lockfile
    case generated
    case docs
    case test
    case security
    case infra
    case schema
    case largeRewrite
    case largeDeletion

    var label: String {
        switch self {
        case .config:        return "config"
        case .dependency:    return "deps"
        case .lockfile:      return "lockfile"
        case .generated:     return "generated"
        case .docs:          return "docs"
        case .test:          return "test"
        case .security:      return "security"
        case .infra:         return "infra"
        case .schema:        return "schema"
        case .largeRewrite:  return "large rewrite"
        case .largeDeletion: return "large deletion"
        }
    }

    var tint: NSColor {
        switch self {
        case .security, .largeDeletion: return .systemRed
        case .infra, .schema, .config:  return .systemOrange
        case .dependency, .lockfile:    return .systemPurple
        case .generated:                return .secondaryLabelColor
        case .docs:                     return .systemTeal
        case .test:                     return .systemGreen
        case .largeRewrite:             return .systemOrange
        }
    }
}

enum RiskLevel: Int, Comparable {
    case low = 0, medium = 1, high = 2
    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var tint: NSColor {
        switch self {
        case .high:   return Theme.Color.riskHigh
        case .medium: return Theme.Color.riskMedium
        case .low:    return Theme.Color.riskLow
        }
    }
}

/// Cognitive review modes from the brief. These are *not* AI modes — they reorder and
/// regroup the same heuristic data to match a reviewer's intent.
enum ReviewMode: Int, CaseIterable {
    case narrative   // "What happened?" — grouped by subsystem, noise collapsed
    case file        // ground-truth, path-ordered precision
    case risk        // dangerous changes first

    var title: String {
        switch self {
        case .narrative: return "Narrative"
        case .file:      return "Files"
        case .risk:      return "Risk"
        }
    }
}

/// Everything the file/diff UI needs to know about one changed file, derived once.
struct FileAnalysis {
    let file: DiffFile
    let signals: [FileSignal]
    let risk: RiskLevel
    /// Whether this file is low-signal noise that should collapse by default.
    let isNoise: Bool

    var displayPath: String { file.displayPath }
    var fileName: String { (file.displayPath as NSString).lastPathComponent }
    var directory: String {
        let dir = (file.displayPath as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
    var statusKind: DiffStatusKind { Self.statusKind(file.status) }

    // MARK: - Derivation

    static func analyze(_ file: DiffFile) -> FileAnalysis {
        let path = file.displayPath.lowercased()
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension

        var signals: [FileSignal] = []
        var risk: RiskLevel = .low

        // Lockfiles & dependency manifests.
        if lockfileNames.contains(name) {
            signals.append(.lockfile)
        } else if dependencyNames.contains(name) {
            signals.append(.dependency)
            risk = max(risk, .medium)
        }

        // Generated / vendored.
        if generatedHints.contains(where: { path.contains($0) }) || generatedExtensions.contains(ext) {
            signals.append(.generated)
        }

        // Docs.
        if docExtensions.contains(ext) || name == "readme" {
            signals.append(.docs)
        }

        // Tests.
        if path.contains("test") || path.contains("spec") || name.hasPrefix("test_") {
            signals.append(.test)
        }

        // Config.
        if configExtensions.contains(ext) || configNames.contains(name) {
            signals.append(.config)
            risk = max(risk, .medium)
        }

        // Security-sensitive.
        if securityHints.contains(where: { path.contains($0) }) {
            signals.append(.security)
            risk = max(risk, .high)
        }

        // Infra / deploy.
        if infraHints.contains(where: { path.contains($0) }) || infraNames.contains(name) {
            signals.append(.infra)
            risk = max(risk, .high)
        }

        // Schema / migrations.
        if path.contains("migration") || path.contains("schema") || ext == "sql" {
            signals.append(.schema)
            risk = max(risk, .high)
        }

        // Magnitude-based signals.
        if file.status == .deleted || (file.deletions >= 60 && file.additions == 0) {
            signals.append(.largeDeletion)
            risk = max(risk, .medium)
        } else if file.additions + file.deletions >= 200 {
            signals.append(.largeRewrite)
            risk = max(risk, .medium)
        }

        let isNoise = signals.contains(.lockfile)
            || signals.contains(.generated)
            || (signals.contains(.dependency) && !signals.contains(.security))

        return FileAnalysis(file: file, signals: signals, risk: risk, isNoise: isNoise)
    }

    static func statusKind(_ status: DiffStatus) -> DiffStatusKind {
        switch status {
        case .added, .untracked: return .added
        case .deleted:           return .deleted
        case .renamed:           return .renamed
        case .copied:            return .copied
        case .modified:          return .modified
        case .typeChanged:       return .typeChanged
        default:                 return .other
        }
    }

    /// SF Symbol name approximating the file's type — kept lightweight and path-driven.
    var iconName: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if signals.contains(.lockfile) { return "lock.fill" }
        if signals.contains(.docs) { return "doc.text" }
        if signals.contains(.config) { return "gearshape" }
        if signals.contains(.infra) { return "shippingbox" }
        if signals.contains(.schema) { return "cylinder.split.1x2" }
        switch ext {
        case "swift": return "swift"
        case "json", "yaml", "yml", "toml", "plist": return "curlybraces"
        case "md", "markdown", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "pdf", "icns": return "photo"
        case "sh", "bash", "zsh": return "terminal"
        case "h", "hpp", "c", "cpp", "m", "mm": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    // MARK: - Lexicons

    private static let lockfileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "package.resolved",
        "cargo.lock", "gemfile.lock", "poetry.lock", "composer.lock", "podfile.lock",
        "flake.lock", "go.sum",
    ]
    private static let dependencyNames: Set<String> = [
        "package.json", "cargo.toml", "gemfile", "podfile", "go.mod",
        "requirements.txt", "pyproject.toml", "build.gradle", "pom.xml", "package.swift",
    ]
    private static let configExtensions: Set<String> = [
        "yaml", "yml", "toml", "ini", "conf", "cfg", "env", "plist", "xcconfig", "editorconfig",
    ]
    private static let configNames: Set<String> = [
        ".gitignore", ".gitattributes", ".dockerignore", "makefile", "justfile",
    ]
    private static let docExtensions: Set<String> = ["md", "markdown", "rst", "adoc"]
    private static let generatedExtensions: Set<String> = ["pbxproj", "xcworkspacedata", "lock"]
    private static let generatedHints = ["generated", "node_modules", "vendor/", ".pb.", "dist/", "build/"]
    private static let securityHints = ["auth", "token", "secret", "credential", "password", "oauth", "jwt", "crypto", "permission"]
    private static let infraHints = [".github/", "docker", "kubernetes", "k8s", "terraform", "helm", "ansible", "deploy", "ci/"]
    private static let infraNames: Set<String> = ["dockerfile", "docker-compose.yml", "docker-compose.yaml", ".gitlab-ci.yml"]
}

/// A subsystem grouping of analyzed files, used by the files pane's outline view.
struct Subsystem {
    let name: String          // e.g. "auth", "ui", or "" for root
    let files: [FileAnalysis]

    var additions: Int { files.reduce(0) { $0 + $1.file.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.file.deletions } }
    var risk: RiskLevel { files.map(\.risk).max() ?? .low }
    var displayName: String { name.isEmpty ? "/" : name }
}

enum FileOrganizer {
    /// Group + order analyzed files for a given review mode.
    static func organize(_ files: [DiffFile], mode: ReviewMode) -> [Subsystem] {
        let analyzed = files.map(FileAnalysis.analyze)
        switch mode {
        case .file:
            // Flat, path-sorted ground truth — one synthetic group so the outline stays uniform.
            let sorted = analyzed.sorted { $0.displayPath < $1.displayPath }
            return groupByTopLevel(sorted)
        case .narrative:
            // Subsystem grouping, noise sinks to the bottom of each group.
            let groups = groupByTopLevel(analyzed)
            return groups.map { group in
                let ordered = group.files.sorted { a, b in
                    if a.isNoise != b.isNoise { return !a.isNoise }
                    return a.displayPath < b.displayPath
                }
                return Subsystem(name: group.name, files: ordered)
            }
        case .risk:
            // Highest-risk files first, regardless of location; one flat risk-ordered group.
            let ordered = analyzed.sorted { a, b in
                if a.risk != b.risk { return a.risk > b.risk }
                let aMag = a.file.additions + a.file.deletions
                let bMag = b.file.additions + b.file.deletions
                if aMag != bMag { return aMag > bMag }
                return a.displayPath < b.displayPath
            }
            return [Subsystem(name: "", files: ordered)]
        }
    }

    private static func groupByTopLevel(_ files: [FileAnalysis]) -> [Subsystem] {
        var order: [String] = []
        var buckets: [String: [FileAnalysis]] = [:]
        for f in files {
            let dir = f.directory
            let key = dir.isEmpty ? "" : (dir.components(separatedBy: "/").first ?? dir)
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(f)
        }
        return order.map { Subsystem(name: $0, files: buckets[$0] ?? []) }
    }
}
