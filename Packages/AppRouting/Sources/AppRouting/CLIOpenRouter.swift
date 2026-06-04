import Foundation

/// Pure decision logic for "what should happen when the CLI (or Finder) hands the app one or
/// more URLs to open?". Mirrors the contract VSCode's `code <path>` follows:
///
///   • If a window already shows a repo that contains `<path>`, focus that window.
///   • Otherwise open one new window holding any unmatched URLs.
///   • If the app isn't ready yet (cold launch, backend not constructed), defer the URLs so
///     the caller can drain them once setup completes.
///
/// Path matching is symlink-aware so `/tmp/repo` matches the canonical `/private/tmp/repo`
/// the bookmark store records — a real failure mode on macOS.
public enum CLIOpenRouter {

    /// A single live window's view of which repos it knows about. The id is opaque — the
    /// caller picks any stable handle (an `ObjectIdentifier`, an index, etc.) and pattern-matches
    /// it back to its concrete window.
    public struct WindowSnapshot: Equatable {
        public let id: Int
        /// Repository root paths this window has opened. Canonicalization happens inside the
        /// router, so callers can pass raw `URL.path` values.
        public let repoRoots: [String]
        public init(id: Int, repoRoots: [String]) {
            self.id = id
            self.repoRoots = repoRoots
        }
    }

    public struct FocusInstruction: Equatable {
        public let windowID: Int
        /// The original input URL — the path the user typed.
        public let url: URL
        /// The repo root (as supplied in the matched `WindowSnapshot.repoRoots`) that the
        /// router decided contains `url`. Callers should look up this exact string in their
        /// own repo list to avoid having to repeat the router's symlink canonicalization.
        public let matchedRoot: String
    }

    public enum Decision: Equatable {
        /// Backend not yet constructed — caller should hold the URLs until ready and re-route.
        case deferUntilReady([URL])
        /// Concrete instructions. `focus` brings existing windows forward; `openInNewWindow` is
        /// the (possibly empty) list of paths that should land in one fresh window.
        case route(focus: [FocusInstruction], openInNewWindow: [URL])
    }

    public static func route(
        urls: [URL],
        windows: [WindowSnapshot],
        isReady: Bool
    ) -> Decision {
        guard !urls.isEmpty else {
            return .route(focus: [], openInNewWindow: [])
        }
        guard isReady else {
            return .deferUntilReady(urls)
        }

        // Pre-canonicalize each window's repo roots once, keeping the original strings so
        // we can hand the matched root back to the caller verbatim.
        let canonicalWindows: [(id: Int, roots: [(canonical: String, original: String)])]
            = windows.map { snap in
                (snap.id, snap.repoRoots.map { (canonicalize($0), $0) })
            }

        var focus: [FocusInstruction] = []
        var unmatched: [URL] = []
        for url in urls {
            let target = canonicalize(url.path)
            var matched: (id: Int, root: String)?
            for entry in canonicalWindows {
                if let hit = entry.roots.first(where: {
                    isSameOrAncestor(parent: $0.canonical, child: target)
                }) {
                    matched = (entry.id, hit.original)
                    break
                }
            }
            if let matched {
                focus.append(FocusInstruction(windowID: matched.id, url: url,
                                              matchedRoot: matched.root))
            } else {
                unmatched.append(url)
            }
        }
        return .route(focus: focus, openInNewWindow: unmatched)
    }

    // MARK: - Helpers

    /// Resolve symlinks and strip any trailing slash so `/tmp/r/` and `/private/tmp/r` compare
    /// equal. Falls back to the input on failure rather than throwing — routing should be
    /// best-effort, never blocking.
    static func canonicalize(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved.count > 1, resolved.hasSuffix("/") {
            return String(resolved.dropLast())
        }
        return resolved
    }

    /// True when `child` is `parent` itself or lives inside `parent`. Uses a trailing `/` guard
    /// so `/foo/bar` does not falsely match `/foo/barbaz`.
    static func isSameOrAncestor(parent: String, child: String) -> Bool {
        if parent == child { return true }
        return child.hasPrefix(parent + "/")
    }
}
