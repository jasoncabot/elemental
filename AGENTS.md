# Agent Instructions

Guidelines for AI agents (Claude, Copilot, etc.) working in this repository.

## What Elemental Is Not

What Elemental *is* will evolve. What it refuses to become is fixed, and matters more.
These are hard constraints — treat them as failing conditions, not preferences. A change
that improves a feature while breaking one of these is a regression.

- **No account. No sign-in. No backend.** There is no server to talk to, ever. Don't add
  one, don't assume one, don't gate anything behind identity.
- **No upload. No network for the core.** Code never leaves the machine. The entire review
  experience must work fully offline — on a plane, on an air-gapped box, on a client's
  confidential codebase under NDA. Network access is not "degraded mode"; it is *no part of*
  the core path. Don't phone home, don't fetch, don't telemeter.
- **No inference cost. No latency tax.** Opening a diff is instant. The core must be 100%
  functional and fast with **zero LLM inference** — driven only by git metadata, file paths,
  diff structure, syntax/heuristics. Performance is a feature.
- **We don't sell AI.** Elemental sells *comprehension*. AI is an optional augmentation layer
  that may make a good experience better — it must **never** gate a feature, become a
  dependency, slow the core, or require a key/account to get value. If a feature only works
  with AI, it's built wrong. Every AI-powered capability needs a heuristic floor that stands
  on its own.
- **Read-only.** Elemental never mutates the repo. No commits, no staging, no checkout, no
  config writes. It observes; it does not touch.

When in doubt, optimize for: works offline, works instantly, works on code you're not allowed
to send anywhere.

## AppKit Conventions

### NSLayoutConstraint identifiers

Every `NSLayoutConstraint` **must** have a human-readable `.identifier` set via the `.id(_:)` helper
defined in `Theme.swift`. This makes constraint-conflict logs in Xcode's debugger and the runtime
unsatisfiable-constraint output readable without decoding opaque memory addresses.

```swift
// good
view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8)
    .id("MyView.label.leading")

// bad — anonymous constraint, invisible in conflict logs
view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8)
```

Use the format `TypeName.subviewRole.edge` (e.g. `DiffHeader.pathLabel.trailing`). Activate the
constraint in the same expression or immediately after — never split the `.id()` call onto a
separate line from the constraint that owns it.

### NSView subclass names

Every custom `NSView` subclass **must** carry an `@objc(Name)` annotation so the class name in
constraint-conflict logs is readable instead of Swift-mangled (e.g. `DiffHeaderView` instead of
`_TtC9ElementalP33_…DiffHeaderView`).

```swift
// good
@objc(DiffHeaderView)
private final class DiffHeaderView: NSView { … }

// bad — mangled name appears in constraint logs
private final class DiffHeaderView: NSView { … }
```

The `@objc(Name)` annotation affects only the Objective-C runtime name; Swift access control
(`private`, `internal`) is unchanged.

See [ux.md](ux.md) for broader UI/UX guidance.

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
