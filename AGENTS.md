# Agent Instructions

Guidelines for AI agents (Claude, Copilot, etc.) working in this repository.

## Testing the Git Backend

The `GitData` package tests exercise the real git binary against disposable fixture repositories.
These tests **must** obey the following constraints:

### No timing dependence

Tests must **never** rely on wall-clock timing, `sleep`, `Task.sleep`, fixed delays, or
timeouts-as-assertions. A timeout may be used as a safety net to prevent hangs (e.g.
`withTimeout` for cancellation tests) but the **pass/fail logic** must not depend on how
long something takes. Flaky tests that pass only because a race was won are unacceptable.

### Headless execution

All tests must run in a headless CI environment with no display server, no user interaction,
no keychain prompts, and no GUI. Never import AppKit or use `NSApplication` in test targets.
Git operations must disable credential prompts (`GIT_TERMINAL_PROMPT=0`).

### Concurrency and parallel safety

Tests must be safe to execute **concurrently and in parallel** — both within a single test
process (Swift's concurrent test runner) and across multiple processes on the same machine:

- Each test creates its own isolated `FixtureRepo` in a uniquely-named temp directory.
- Never share mutable state (files, environment variables, global singletons) between tests.
- Never assume a particular working directory or that the repo under test is the only repo
  being exercised at that moment.
- Never rely on ordering between test methods.
- Use `GIT_CONFIG_NOSYSTEM=1` to isolate from the host's global git configuration.

### Fixture hygiene

- Fixtures must be fully self-contained and cleaned up in `deinit` or `defer`.
- Use `--allow-empty` only when explicitly testing empty commits; prefer real file changes.
- Avoid network access in tests (no `git fetch`, no `git clone` from remote URLs).
