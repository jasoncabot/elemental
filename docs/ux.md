# Elemental UX Direction

> Diffs for humans.

---

# Overview

Elemental is a native macOS application focused on one thing:

> helping humans understand code changes quickly and confidently.

It is intentionally **read-focused**.

The goal is not to replace Git workflows, IDEs, or developer tooling.

The goal is to create the best possible environment for reviewing:

* commits
* staged changes
* unstaged changes
* file diffs
* subsystem changes
* architectural changes

Especially in a world where AI-assisted development dramatically increases the amount of code humans must review.

---

# Product Philosophy

## Elemental Is Not a Git Client

Elemental is not attempting to compete with:

* IDEs
* SourceTree
* GitKraken
* Tower
* GitHub Desktop

Those tools primarily optimize for:

* Git operations
* workflow management
* rebasing
* stashing
* branching
* editing

Elemental optimizes for:

* understanding
* scanning
* review velocity
* trust
* cognitive clarity
* low-fatigue inspection

Git operations are secondary.

Review quality is primary.

---

# Core Product Insight

Traditional diff tools are optimized around:

* files
* patches
* source control mechanics

Humans actually review changes in layers:

1. “What changed?”
2. “Which systems are affected?”
3. “What looks risky?”
4. “Which files matter?”
5. “What exactly changed?”

Most existing Git tools start at layer 5.

Elemental should start at layer 1.

---

# Design Principles

## 1. Git-Native, Not Git-Hiding

Elemental should improve Git UX without abstracting Git away.

Users should still feel grounded in familiar concepts:

* commits
* files
* branches
* diffs
* hunks
* paths

The goal is:

* better organization
* better prioritization
* better readability
* better navigation

Not:

* replacing Git concepts
* inventing entirely new abstractions
* hiding implementation details

Experienced engineers should feel comfortable immediately.

---

## 2. Files Remain First-Class

Files are still the most trustworthy navigation primitive.

Even when reviewing conceptually, humans still orient around:

* folders
* services
* modules
* files
* code locality

Elemental should not hide files behind AI-generated concepts.

Instead:

* files remain visible
* structure remains clear
* navigation remains direct

The improvement comes from:

* hierarchy
* presentation
* prioritization
* scanning ergonomics

---

## 3. Progressive Disclosure

The UI should progressively reveal detail.

The flow should be:

```text
What changed?
→ Which systems changed?
→ Which files changed?
→ Which functions changed?
→ Which lines changed?
```

Traditional Git tools immediately expose low-level patch noise.

Elemental should prioritize high-level understanding first.

---

## 4. Fast By Default

The application must work extremely well without AI.

No mandatory:

* LLM inference
* embeddings
* semantic indexing
* generated summaries

The core UX should be powered entirely by:

* Git metadata
* file paths
* diff structure
* heuristics
* syntax awareness

Reasons:

* responsiveness
* simplicity
* offline support
* scalability
* trust
* cost

AI may augment later.

It should never become a dependency for the core experience.

---

# UX Structure

## High-Level Layout

```text
┌──────────────────────────────────────────────────────────────┐
│ Repo Selector • Branch • Search • Mode • Filters           │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│ Commit Timeline │ File/Subsystem View │ Immersive Diff View │
│                 │                     │                      │
│                 │                     │                      │
│                 │                     │                      │
└──────────────────────────────────────────────────────────────┘
```

This preserves Git familiarity while improving readability and review flow.

---

# Top Bar

The top bar contains context.

Not content.

## Responsibilities

* repository selection
* worktree switching
* branch switching
* search
* review mode selection
* filters

Projects should not permanently occupy sidebar space.

Repositories are contextual state, not primary navigation.

---

## Repository Selection

Repositories/worktrees should be:

* quickly switchable
* searchable
* drag-and-drop friendly

Recent repositories should be easily accessible.

---

## Branch Switching

Branch switching should remain lightweight.

Initial versions do not need:

* advanced branch management
* rebasing UIs
* stash workflows
* merge tooling

The first priority is:

> showing the current repository state exceptionally well.

---

# Commit Timeline

The left column becomes the primary navigation structure.

Not a table.

Not a raw Git log.

A readable review timeline.

---

## Commit Presentation

The commit subject is the primary information.

Metadata becomes secondary.

Example:

```text
Improve websocket reconnect handling
2h ago • 7 files • +124 −42

Refactor sidebar rendering
Yesterday • 3 files • +91 −12

Remove deprecated auth middleware
Yesterday • 5 files • +22 −118
```

Humans naturally scan:

* intent
* meaning
* scope

Before:

* SHA
* author
* exact timestamps

The UI should optimize for rapid skim reading.

---

## Timeline Interaction

### Single Click

Select commit.

### Keyboard Navigation

Fast review flow is critical.

### Hover

Reveal:

* SHA
* author
* exact timestamp
* branch/tag references

### Expanded Metadata

Available on demand.

Never dominant.

---

# File / Subsystem View

The middle column provides structural context.

This is not just a flat file list.

It is a lightweight architectural view.

---

# Structural Grouping

Files should be grouped naturally by:

* folders
* modules
* services
* subsystems

Example:

```text
auth/
  middleware.ts
  token_store.ts

sync/
  scheduler.go
  websocket.go

ui/
  sidebar.swift
  colors.swift
```

This provides:

* architectural context
* spatial understanding
* quick scanning
* subsystem awareness

Without requiring AI.

---

# File Signals

Files may include lightweight indicators such as:

* additions/removals
* change magnitude
* rename indicators
* deletion markers
* file type icons
* “large rewrite”
* “config change”
* “dependency update”

These should be heuristic-driven.

Not AI-generated.

---

# Smart Review Ordering

One of Elemental’s strongest opportunities is helping humans prioritize review attention.

Experienced engineers already review changes in roughly this order:

1. infrastructure/config
2. auth/security
3. database/schema
4. dependency changes
5. CI/deployment
6. public APIs
7. subsystem behavior
8. implementation details

Elemental should support this workflow directly.

Without adding complexity.

---

# Diff View

The right pane is the core reading experience.

Most Git tools waste their largest canvas area.

Elemental should optimize heavily for:

* readability
* typography
* spacing
* scanning
* cognitive flow
* stable scrolling
* visual calmness

---

# Diff Philosophy

Diffs should feel:

* readable
* trustworthy
* inspectable
* calm
* low-noise

Not:

* terminal-like
* visually dense
* patch-stream oriented
* overloaded with chrome

---

# Noise Reduction

Noise should be aggressively collapsible.

Examples:

* import reorderings
* formatting-only changes
* generated files
* lockfiles
* whitespace changes

These should collapse automatically while remaining instantly expandable.

The goal is:

> maximize signal density without overwhelming the user.

---

# Review Modes

Review modes are cognitive modes.

Not AI modes.

---

# 1. Narrative Mode

Optimized for:

* skim review
* large commits
* AI-generated changes
* understanding intent

Focuses on:

* commit-level understanding
* grouped presentation
* reduced noise
* progressive disclosure

Primary question:

> “What happened?”

---

# 2. File Mode

Traditional precision review mode.

Optimized for:

* exact inspection
* locality
* verification
* implementation detail

This is the “ground truth” mode.

Critical for trust.

---

# 3. Risk Mode

Risk Mode prioritizes potentially dangerous changes.

Examples:

* auth
* infra
* database
* config
* dependency updates
* Docker/Kubernetes
* secrets
* public APIs
* large deletions

This mirrors how experienced engineers already review pull requests.

Importantly:

* no AI is required
* heuristic classification is sufficient

---

# Search

Search is extremely important.

Eventually:

* file names
* paths
* commit subjects
* symbols
* changed functions

Potentially semantic later.

But not required initially.

---

# Keyboard-First Navigation

Keyboard flow is critical.

Core actions should include:

* next commit
* previous commit
* next file
* next hunk
* expand/collapse
* quick search
* filter toggles

Review velocity matters.

The application should feel excellent without touching the mouse.

---

# Native macOS Feel

Elemental should feel unapologetically native.

Avoid:

* Electron aesthetics
* web dashboard patterns
* IDE chrome overload

Lean into:

* typography
* native materials
* restrained animation
* smooth scrolling
* stable layouts
* tactile interactions

The app should feel:

* premium
* focused
* calm
* fast

---

# Important Constraints

Elemental should avoid becoming:

* an IDE
* a merge tool
* an AI assistant
* a Git workflow manager
* a code generation platform

The product focus is extremely important:

> understanding code changes better.

Anything that does not improve:

* comprehension
* review speed
* confidence
* navigation
* scanning
* trust

Should be considered carefully before inclusion.

---

# Long-Term Direction

Elemental exists because AI-assisted development changes the economics of software review.

AI increases:

* code volume
* commit size
* change frequency

Humans remain responsible for:

* correctness
* architecture
* security
* maintainability
* intent validation

Review quality therefore becomes more important than code generation itself.

Elemental aims to become:

> the best possible human interface for understanding code changes.
