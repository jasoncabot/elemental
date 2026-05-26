# Feature: QA Tester (Test Strategy & Quality)

> A cross-cutting agent responsible for the **quality of the approach**, not for shipping features.
> It owns the test strategy and the shared fixtures every other layer tests against. See
> [ORCHESTRATOR.md](ORCHESTRATOR.md).

## Purpose

Ensure the **smallest possible test suite catches the most problems**. This agent continuously proposes
and maintains tests that run **along the seams** between layers (the contracts in the orchestrator),
favoring low-level, high-leverage techniques: shared **fixtures**, **snapshots**, **fuzzing**, and
**mutation testing**. It validates that the data-layer/presenter contracts hold under real and
adversarial git inputs.

## Explicitly out of scope

- **The GUI layer is not tested.** It's manually exercised by humans; correctness/"feel" is subjective.
  No view snapshot tests, no UI automation, no AppKit-layer assertions. (View-layer's own doc lists
  only manual checks — honor that.)
- No end-to-end "click" tests. Integration testing stops at the presenter boundary (fake views).

## Testing philosophy (in priority order)

1. **Seam tests over unit-of-implementation tests.** Test the published contracts (`GitBackend`
   methods, model shapes, presenter↔data-layer interaction) so internal refactors don't churn the
   suite. One test at a seam beats ten testing private helpers.
2. **Real git, real fixtures.** Exercise `CLIGitBackend` against actual repos built by the CLI — this
   is the only way to validate the "user's own git" promise and forward-compat. Don't mock git for the
   backend's own tests.
3. **Fakes only above the data layer.** Presenter tests use a fake `GitBackend` + fake `RepoWatcher`
   (in-memory) to drive state transitions deterministically.
4. **Snapshots for structured output.** Pin parsed results (commit lists, diff structures, ref
   snapshots, computed graph lane layouts) as serialized snapshots; diffs in output surface
   regressions cheaply.
5. **Fuzzing at the parsers.** The porcelain/`-z` parsers are the riskiest surface — fuzz them.
6. **Mutation testing to measure suite strength**, not line coverage.

## Owned assets

### Shared fixture library (`FixtureRepo`)
A reusable helper that programmatically builds temp repos via the CLI, so every layer tests the same
canonical shapes. Minimum catalog:
- linear history; branch + merge; **octopus merge**; rename + copy; binary file; empty repo;
  detached HEAD; **bare repo**; **worktree**; **submodule**; large-ish history (perf smoke);
  non-ASCII/emoji paths & messages; CRLF and mixed line endings; files with no trailing newline.
- A **mutating fixture**: applies a sequence of on-disk changes (extra commit, branch switch, squash,
  `git gc`) to validate the SHA-keyed resilience contract.

### Snapshot suite
Golden serializations of: parsed `[Commit]` for each fixture, `[DiffFile]` for representative diffs,
`RefSnapshot`, and **graph lane layouts** for known topologies (straight/branch/merge/octopus).

### Fuzz targets
- Diff/patch parser, `status --porcelain=v2 -z` parser, `for-each-ref` parser, `log --format` NUL
  parser. Feed malformed/truncated/adversarial bytes; assert **no crash, no hang** — either valid
  output or a typed error. Seed corpus from real git output captured across fixtures.

### Mutation testing
Run a Swift mutation tool (e.g. muter-style) over the **data layer + presenter** logic. Target a high
mutation score on parsers and the dirty/Refresh reconciliation. Track score in CI; treat surviving
mutants as test gaps to close (not just coverage %).

## Seam/integration tests it proposes per layer

- **Data layer:** every `FixtureRepo` → assert parsed models match snapshots; cancellation terminates
  the child process; mutating-fixture changes don't throw on reads of surviving SHAs;
  worktree/submodule/bare paths resolve.
- **Presenter↔data-layer (with fakes):** timeline paging/selection invariants; `DirtyEvent` flips
  `isDirty` without reload; Refresh preserves selection when SHA survives and falls back gracefully
  when it doesn't; per-SHA diff cache reused.
- **Graph algorithm:** lane layout snapshots for the topology fixtures (pure function — no view).

## Working agreement with other agents

- Owns `FixtureRepo` and the snapshot/fuzz/mutation harness; other agents **consume** these fixtures
  rather than inventing their own.
- When a contract in the orchestrator changes, QA updates fixtures/snapshots first and flags affected
  layers.
- Keeps the suite **small and fast**: prune redundant tests; prefer one parametrized seam test over
  many near-duplicates. A growing suite that isn't catching new mutants is a smell to cut.

## Verification (of the test strategy itself)

- CI runs: fixture/seam tests, snapshot tests, fuzz (bounded iterations), mutation score gate.
- Mutation score on parsers + reconciliation logic above an agreed threshold.
- Suite runtime stays within an agreed budget (fast feedback is a goal, not an afterthought).
