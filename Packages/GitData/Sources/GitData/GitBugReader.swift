import Foundation

/// Reads `refs/bugs/*` (git-bug format) from a repository and reconstructs issue snapshots.
///
/// git-bug stores each issue as a linked-list of commits under `refs/bugs/<64-char-id>`.
/// Each commit's tree contains an `ops` blob — a JSON object carrying an array of typed
/// operations that are applied in chronological order to build the issue snapshot.
///
/// Operation types (from git-bug source):
///   1 = CreateOp    { title, message, files }
///   2 = SetTitleOp  { was, title }
///   3 = AddCommentOp{ message, files }
///   4 = SetStatusOp { status }  (1=open, 2=closed)
///   5 = LabelChangeOp { added, removed }
///   6 = EditCommentOp { target, message, files }
///
/// Performance: uses `git cat-file --batch` with `<sha>:ops` extended SHA syntax to read all
/// ops blobs in a single subprocess call, and `withTaskGroup` to parallelise the per-bug
/// `git rev-list` calls. Reduces ~5000 sequential subprocess calls to ~460 (parallel).
enum GitBugReader {

    // MARK: - Public entry point

    /// Load all git-bug issues in `repo`. Returns empty when `refs/bugs/` doesn't exist.
    static func load(runner: GitRunner, repo: Repository) async throws -> [GitIssue] {
        // 1. List all bug refs (tip SHA + bug ID).
        let refData = try await runner.runChecked(
            ["for-each-ref", "--format=%(objectname) %(refname:lstrip=2)", "refs/bugs/"],
            in: repo.rootURL)
        let refLines = String(decoding: refData, as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !refLines.isEmpty else { return [] }

        var bugs: [(index: Int, bugID: String, tipSHA: String)] = []
        for (i, line) in refLines.enumerated() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            bugs.append((i, String(parts[1].dropFirst("bugs/".count)), parts[0]))
        }

        // 2. Parallel rev-list: get the commit chain for each bug concurrently.
        //    Results come back out-of-order, so we index by position.
        var bugCommits: [(bugID: String, commitSHAs: [String])] =
            Array(repeating: ("", []), count: bugs.count)

        await withTaskGroup(of: (Int, [String]).self) { group in
            for bug in bugs {
                let (idx, bugID, tipSHA) = (bug.index, bug.bugID, bug.tipSHA)
                let root = repo.rootURL
                group.addTask {
                    let data = try? await runner.runChecked(["rev-list", tipSHA], in: root)
                    let shas: [String] = data.map {
                        String(decoding: $0, as: UTF8.self)
                            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                            .reversed()  // oldest-first for correct op application
                    } ?? []
                    return (idx, shas)
                }
            }
            for await (idx, shas) in group {
                bugCommits[idx] = (bugs[idx].bugID, shas)
            }
        }

        // 3. Build a flat ordered list of all commit SHAs (per-bug, oldest-first) and a reverse map.
        var orderedCommits: [String] = []
        var commitToBug: [String: String] = [:]
        for (bugID, shas) in bugCommits {
            for sha in shas {
                if commitToBug[sha] == nil {  // guard against shared ancestry (rare)
                    commitToBug[sha] = bugID
                    orderedCommits.append(sha)
                }
            }
        }
        guard !orderedCommits.isEmpty else { return [] }

        // 4. Single batch cat-file call: `<sha>:ops` resolves directly to the ops blob content.
        //    git outputs one response per input line, in order — positional alignment is stable.
        let batchInput = Data(orderedCommits.map { "\($0):ops" }.joined(separator: "\n")
                                .appending("\n").utf8)
        guard let batchData = try? await runner.runWithInput(
            ["cat-file", "--batch"], input: batchInput, in: repo.rootURL) else { return [] }

        // 5. Parse batch output positionally, accumulate ops per bug in chronological order.
        var bugStates: [String: IssueState] = Dictionary(
            uniqueKeysWithValues: bugs.map { ($0.bugID, IssueState(bugID: $0.bugID)) })
        let opsBlobs = parseBatchOutput(batchData)
        for (sha, opsData) in zip(orderedCommits, opsBlobs) {
            guard let opsData, let bugID = commitToBug[sha] else { continue }
            parseOps(opsData, into: &bugStates[bugID]!)
        }

        // 6. Convert states to issues.
        return bugStates.values.compactMap { state -> GitIssue? in
            guard let title = state.title, let createdAt = state.createdAt else { return nil }
            return GitIssue(
                id: String(state.bugID.prefix(7)),
                bugID: state.bugID,
                title: title,
                body: state.body ?? "",
                status: state.status,
                createdAt: createdAt,
                updatedAt: state.updatedAt ?? createdAt,
                labels: Array(state.labels).sorted(),
                commentCount: state.commentCount
            )
        }
    }

    // MARK: - Batch output parser

    /// Parse `git cat-file --batch` output into an array of `Data?` values, one per input line.
    /// `nil` entries correspond to "missing" objects (e.g. a commit with no `ops` blob).
    /// The output and input are in the same order, so callers can zip with the input array.
    private static func parseBatchOutput(_ data: Data) -> [Data?] {
        var results: [Data?] = []
        var i = data.startIndex

        while i < data.endIndex {
            // Each entry starts with a header line terminated by LF.
            guard let nlIdx = data[i...].firstIndex(of: 0x0A) else { break }
            let header = String(data: Data(data[i..<nlIdx]), encoding: .utf8) ?? ""
            i = data.index(after: nlIdx)

            let parts = header.split(separator: " ").map(String.init)
            // Missing object: "<key> missing"
            if parts.last == "missing" {
                results.append(nil)
                continue
            }
            // Normal object: "<sha> <type> <size>"
            guard parts.count >= 3, let size = Int(parts[2]), size >= 0 else { continue }
            let contentEnd = data.index(i, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            results.append(Data(data[i..<contentEnd]))
            // Advance past content + the trailing LF separator.
            i = data.index(contentEnd, offsetBy: 1, limitedBy: data.endIndex) ?? data.endIndex
        }
        return results
    }

    // MARK: - Op parsing

    private struct IssueState {
        var bugID: String
        var title: String?
        var body: String?
        var status: GitIssue.Status = .open
        var createdAt: Date?
        var updatedAt: Date?
        var labels: Set<String> = []
        var commentCount: Int = 0
    }

    private static func parseOps(_ data: Data, into state: inout IssueState) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ops = root["ops"] as? [[String: Any]] else { return }
        for op in ops {
            guard let type = op["type"] as? Int,
                  let ts = op["timestamp"] as? TimeInterval else { continue }
            let date = Date(timeIntervalSince1970: ts)
            state.updatedAt = max(state.updatedAt ?? .distantPast, date)

            switch type {
            case 1: // CreateOp
                state.title = op["title"] as? String
                state.body = op["message"] as? String
                state.createdAt = date
            case 2: // SetTitleOp
                if let t = op["title"] as? String { state.title = t }
            case 3: // AddCommentOp
                state.commentCount += 1
            case 4: // SetStatusOp — 1=open, 2=closed
                state.status = (op["status"] as? Int) == 2 ? .closed : .open
            case 5: // LabelChangeOp
                if let added = op["added"] as? [String] { state.labels.formUnion(added) }
                if let removed = op["removed"] as? [String] { state.labels.subtract(removed) }
            default: break
            }
        }
    }
}
