# Research: Cutting-edge directions for Elemental

## Context

Elemental's job is to turn a bare git repo into the experience that GitHub / GitLab / Linear / Jira / Confluence give you when stitched together — a readable stream of **changes and the decisions behind them** — but local, instant, offline, read-only, and powered by heuristics not LLMs. The constraints in `AGENTS.md` are absolute: no network in the core, no account, no inference cost, no mutation. Within those, this note collects directions that are genuinely cutting-edge in a desktop git client and aligned with the values.

The lens used to filter every idea below:
1. Works fully offline, including on an air-gapped client repo under NDA.
2. Strengthens *comprehension* of changes — not git operations, not editing.
3. Has a heuristic floor that stands alone (AI may layer on later).
4. SHA-keyed, immutable; survives squash/rebase under the user's CLI.

What's already shipped or in flight (don't re-litigate):
- 3-pane shell, Risk Mode, narrative commit summary header, `git notes` show for the selected commit, xfuncname hunk context, FSEvents-driven dirty banner.
- The git-native-context roadmap (commit notes + git-bug / git-appraise as offline "why" sources) is already an explicit direction.

The recommendations below extend that roadmap with the most impactful, on-brand cutting-edge moves.

---

## Tier 1 — The "GitHub-from-pure-git" wins (highest ROI, all heuristic)

These are the ideas that most directly cash the "no Jira/Confluence tab-switching" promise. All work today on any repo with no setup.

### 1. First-class trailer & Conventional Commits parsing
`git interpret-trailers --parse` already extracts `Signed-off-by`, `Reviewed-by`, `Co-authored-by`, `Fixes`, `Refs`, `Closes`, `BREAKING CHANGE`. Plus a tiny regex parses Conventional Commits headers (`feat(auth)!: …`).
- Render trailers as chips on the commit card (reviewers, co-authors, linked issues, breaking flag).
- Type/scope chips become **timeline filters and grouping keys** (group by scope = a per-subsystem activity stream — Linear-style without Linear).
- Across history, "all commits Reviewed-by Alice" or "all breaking changes since v2.1" become one-click filters.

### 2. Issue & PR reference detection (`#123`, `JIRA-456`, `GH-789`)
Pure regex on commit subjects, bodies, branch names, and notes. Build a local index `issueRef → [SHA]`. UI:
- Each detected ref becomes a clickable chip that opens an inline "issue page": every commit/note/PR-merge that touched that ref.
- The "issue page" *is* the offline Jira ticket for that work item — assembled from git alone.
- Zero network; the chip never resolves to a URL unless the user explicitly clicks "Open in browser."

### 3. Merge commits → synthetic Pull-Request view
Detect merge commits with two parents and a `Merge pull request #N` / GitHub-style / `into 'main' from 'feat/foo'` pattern (and the squash-merge subject conventions). Walk second-parent to the fork point to recover the topic-branch commits.
- One card per merge = a synthetic PR: title, description (merge body), commit list, file list, +/-, reviewers (from trailers), linked issues.
- This is the single biggest "feels like GitHub" win available from pure git.

### 4. Tag-delimited release chapters + auto release notes
Walk tags as chapter dividers in the timeline. Between any two adjacent semver tags, group commits by Conventional Commit type and render a real-looking release page: "v2.1 → v2.2: 8 features, 12 fixes, 1 breaking. 17 contributors. 4 reviewers."
- This is Changelog/Confluence-killer territory and falls out of #1 mechanically.

### 5. Read git-native tracker refs (the existing roadmap, productized)
The roadmap memo already names this. The cutting-edge framing: surface `refs/bugs/*` (git-bug), `refs/notes/devtools/discuss` (git-appraise), and arbitrary user-added notes refs as **siblings of the commit timeline** — an "Issues" tab and a "Reviews" tab populated entirely from git refs. This is something no cloud tool can structurally match because it requires no service.

---

## Tier 2 — Diff intelligence (cutting-edge reading experience)

### 6. Tree-sitter / AST-aware diffs (Difftastic-class, embedded)
Difftastic showed this is real and fast. Tree-sitter parsers are MIT, offline, and incremental. For supported languages (Swift, TS/JS, Go, Python, Rust, Ruby, Java, C/C++) render **structural diffs**:
- "Moved function `handleLogin` from `auth.ts` to `middleware/auth.ts`" instead of delete+add.
- Renamed identifier across hunk highlighted as a single rename, not 14 lines of churn.
- Pure-formatting changes auto-collapse with a "formatting only" chip.
This is the most genuinely cutting-edge feature on this list, and aligns perfectly with "noise reduction" in `ux.md`.

### 7. Hunk-level provenance (inline mini-blame on the read side)
For each removed/changed hunk, run `git blame` on the parent and surface "this hunk last touched 3 months ago by Bob in commit X: 'Fix rate limit bug.'" Hover or peek panel. Reading a deletion becomes "you're undoing *this past decision* — does that still hold?" This is profound for review and impossible to get from terminal git.

### 8. Pickaxe / reverse-blame as a right-click affordance
Select any string in the diff → "When was this introduced?" (`git log -S`) / "When was this removed?" (`git log -G`) / "All commits touching this line" (`git log -L`). Standard plumbing, but as a first-class diff-reading verb it transforms comprehension.

### 9. Word/token-level intra-line diff with identifier awareness
Standard Myers + identifier-aware tokenization (split on camelCase/snake_case boundaries) so `loadUserById` → `fetchUserById` underlines just `load`→`fetch`. Looks dramatically calmer than character-level highlights.

### 10. Function-scoped diff lens (`git log -L`)
Click a function name in the diff → side panel shows the full history of just that function across commits. xfuncname already gives us the enclosing-function header per hunk; -L gives us the history. Together they make "what is the story of *this function*" a one-click question — a feature nothing in the GitHub/GitLab world really nails.

### 11. Sticky enclosing-function header in the diff view
TextKit 2 sticky headers showing the enclosing function/class while scrolling a long diff. Tiny, native, calm.

---

## Tier 3 — Heuristic risk & ownership signals (extends Risk Mode)

### 12. Hotspot scoring (Tornhill-style code-as-a-crime-scene, but local)
Per file: `(changes in last 90 days) × (current size) × (number of distinct authors)`. Surface as a chip on the file pane: "🔥 hotspot — 12 changes in 90 days, 6 authors." Predicts bug-prone files famously well, requires zero AI.

### 13. Co-change graph ("files that move together")
Mine `git log --name-only` to compute "when X changes, Y changes 78% of the time." When the user opens `auth.go`, the file pane highlights peers and flags **missing peers** ("you usually change `session.go` with this — it's untouched"). Hidden architectural knowledge made visible.

### 14. "First-touch" warnings and bus-factor inlay
On the file pane, badges: "first contribution by this author to this file" / "only author who has ever touched this file" / "78% authored by Alice, last touched 14 months ago." Pure blame summary.

### 15. Change-shape classification chips
Each file change gets a classification chip from a small heuristic set: **rename-only**, **move-only**, **format-only**, **comment-only**, **test-only**, **generated**, **lockfile**, **config**, **schema/migration**, **mass-rename**, **dependency-bump**. Each chip drives auto-collapse + filter. These are the building blocks for Risk Mode v2 and for noise-reduction in `ux.md`.

### 16. Blast-radius score per commit
Composite: `files × distinct subsystems × public-API touches × hotspot files included`. Renders as a single calm number on each timeline card — the heuristic equivalent of "how nervous should I be about this commit."

---

## Tier 4 — Stream-of-decisions UX (the narrative direction)

### 17. Session/topic clustering
Group adjacent commits by `author + ≤2h gap + overlapping file set` into "sessions" — a stand-in for PRs in repos that don't use them. Show "Tuesday afternoon: Jason worked on auth, 4 commits, ended green." Combined with #3 (merge → synthetic PR), the entire timeline becomes a stream of meaningful units rather than raw commits.

### 18. Revert / fixup / squash-target pairing
Detect `Revert "X"` → link revert↔reverted as a paired narrative ("undone 6 days later"). Detect `fixup!`/`squash!` → fold into their target with a peek. Detect amends (same tree + same parent + different SHA) where possible. Turns historical noise into clean cards.

### 19. Stacked-diff awareness (Graphite / `jj` / sapling conventions)
Detect branch-naming and subject patterns (`[1/3]`, `Part 2:`, `user/feat/01-foo`) and render a stack as one expandable unit. The stacked-PR world is growing fast; supporting it natively is a clear differentiator.

### 20. Working copy framed as a "draft PR"
Repurpose the merge-commit synthetic-PR UI for the working tree: a draft PR view of staged + unstaged with Risk Mode applied and a diff lint pass (TODOs added, debug prints, focused tests `.only`/`fdescribe`, large file additions). No staging, no commit — pure preview. Closes the loop on "comprehension" for your own in-progress work.

### 21. CODEOWNERS / OWNERS / MAINTAINERS resolution
Parse the file, resolve each changed path → suggested reviewers, render as a chip on the commit card and on the synthetic-PR view. The reviewer-routing affordance from GitHub, with no GitHub.

---

## Tier 5 — Search and navigation

### 22. Local-first commit & symbol search
Tantivy-class index (or SQLite FTS5) built lazily on first open of a repo, persisted under `~/Library/Caches/`. Index: subject, body, trailers, file paths, symbol names extracted via tree-sitter, issue refs. Sub-50ms search across years of history.
- Heuristic floor obviously fine; semantic search (Tier 6) can layer on top of the same index.

### 23. First-parent toggle
PR-merged repos read dramatically better via `--first-parent`. One-keystroke toggle between "release narrative" and "every commit." This single toggle is more valuable than it sounds and trivial to ship.

### 24. Range / branch-compare view
`feat/foo..main` rendered as a synthetic PR (reusing #3): file list, diff, commit list, tabs. Replaces the GitHub "compare" page entirely.

---

## Tier 6 — Optional AI layer (must have heuristic floor; only after Tiers 1-3 land)

These are deliberately *last*, with the values constraint front-of-mind. None gates a feature; each only enriches existing heuristic output.

### 25. Apple Foundation Models for local commit TLDR (macOS 15.1+)
On-device, no key, no network, no cost. Generate a one-line "what does this commit do" *only* for commits whose subject is empty/uninformative (`wip`, `fix`, `.`, blank). Heuristic floor: just show the diff stat.

### 26. Local embeddings for semantic timeline search
NLEmbedding (built-in) or a small quantized sentence-transformer in CoreML. "Find commits about deadlock fixes." Heuristic floor: FTS keyword search (#22). Index lives in the same cache.

### 27. AI-drafted review questions per commit
For each diff, generate 3 reviewer prompts ("Does this rate-limit branch handle the existing per-tenant override?"). Heuristic floor: rule-based prompts ("new file with no test", "config touched without changelog entry").

The framing in all three: AI is a *progressive enhancement* of an already-good heuristic feature, never the feature itself.

---

## Recommended sequencing

If I had to pick a small set that compounds, in order:

1. **#1 trailers + Conventional Commits** — unlocks #2, #3, #4, #21 with shared parsing infra.
2. **#2 issue ref detection + local issue page** — first big "no more tab-switching" moment.
3. **#3 merge → synthetic PR** + **#23 first-parent toggle** — the GitHub-PR feel arrives.
4. **#15 change-shape chips** + **#12 hotspot score** — Risk Mode v2.
5. **#6 tree-sitter structural diff** — the headline "cutting-edge" feature; biggest single comprehension jump.
6. **#7 hunk-level provenance** + **#8 pickaxe affordances** — diff reading goes from "view" to "investigation."
7. **#4 tag chapters + release notes** + **#22 local search** — the app becomes the changelog and the search engine for the project.
8. **#5 git-bug / git-appraise tabs** — finishes the "everything offline" story.
9. AI layer only after the above are solid.

## What I am explicitly *not* recommending

- Anything that needs the network in the core path (live GitHub API, Jira API, Linear API). A `gh`/`glab` *opt-in* read of locally cached PR metadata could be debated later, but it must not be on the comprehension critical path.
- Any write feature (staging, commit, rebase, edit). Off-brand.
- Required cloud LLM calls. Off-brand.
- Any feature that hides files behind generated concepts (`ux.md` explicitly forbids this).
- A built-in editor, merge tool, or workflow manager.

## Verification approach (when any of these ship)

- Every new parser (trailers, Conventional Commits, issue refs, merge-PR detection) gets a `GitData` test against fixture repos covering messy real-world inputs (multi-line trailers, non-ASCII, mixed conventions, malformed headers). Tests must obey the `AGENTS.md` constraints: no timing dependence, parallel-safe, no network.
- Tree-sitter integration verified per-language with a fixture-repo diff test asserting structural equivalence for known move/rename/format-only cases.
- Manual end-to-end pass on the `TestRepositories/` corpus + at least one large public repo for performance feel.
