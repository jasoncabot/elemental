# Golden fixtures

Checked-in inputs plus checked-in renderings of what the UI shows for them. They keep the
commit header and the note viewer stable across releases: any change to what a user would see
fails CI until someone deliberately re-records the golden, and the golden diff then shows the
change in review.

## How it fits together

```
Fixtures (TestSupport)          GitData tests                       Presenters tests
  Notes/<ref>--<case>.note  ──▶  round-trip through real git     ──▶  NotePresentation  ──▶ Goldens/Notes/<case>.golden
  Commits/<case>.commit     ──────────────────────────────────────▶  CommitHeaderPresentation ──▶ Goldens/Header/<case>.golden
```

- **Fixtures** live in `Packages/TestSupport/Sources/TestSupport/Fixtures/` and are loaded with
  `TextFixtures` (via `#filePath`, so they are read from the checkout, byte-exact).
  `.gitattributes` marks them `-text` so CRLF and trailing whitespace survive.
- **GitData** (`NoteFixtureRoundTripTests`) stores every note fixture under its ref with
  `git notes add -C <blob>` (verbatim bytes), then reads it back through `CLIGitBackend`. This pins
  what the app receives from git. It also checks the git-ai parser against the trickiest fixtures.
- **Presenters** (`GoldenFixtureTests`) turns each fixture into the presentation model the App
  renders (`NotePresentation`, `CommitHeaderPresentation.chips`) and compares a plain-text
  snapshot of it with `Packages/Presenters/Tests/PresentersTests/Goldens/<group>/<case>.golden`.

Goldens snapshot **presentation models, not pixels**. Test targets are headless and must not import
AppKit (see AGENTS.md), and pixel snapshots break with every macOS release. Everything a view shows
— strings, order, colour roles (`Swatch`), tooltips, what a chip does when clicked — is decided in
Presenters, so the snapshot covers it. Views only lay it out.

## Fixture naming

| Group | File | Meaning |
|---|---|---|
| Notes | `ai--v3-long-esoteric.note` | stored under `refs/notes/ai`; case `v3-long-esoteric` |
| Notes | `devtools~reviews--git-appraise.note` | `~` stands for `/`: `refs/notes/devtools/reviews` |
| Commits | `conventional-breaking-scope.commit` | full commit message: subject, blank line, body |

`ai--*` note fixtures must parse as git-ai logs unless the name contains `malformed`. The tests
enforce that, so an `ai--` fixture that falls back to plain text fails instead of passing quietly.

## Changing what the UI shows

1. Make the change.
2. Run `swift test --package-path Packages/Presenters`. The affected goldens fail, and each
   failure shows the first differing line and the full new snapshot.
3. If the change is intended, re-record:
   `ELEMENTAL_RECORD_GOLDENS=1 swift test --package-path Packages/Presenters`
   Recording still fails any golden it changed, so a recording run never passes silently by
   accident. Run again without the variable to confirm green.
4. Commit the `.golden` changes with the code. Reviewers read the golden diff as "what changed
   on screen".

Never hand-edit a golden to make a test pass. A golden is the reviewed record of intended output.

## Adding a fixture

Add a file to the right `Fixtures/<group>` folder. The next test run fails with
`Recorded new golden … — review it and commit it` and prints the snapshot. Read it, check it is
what a user should see, and commit both files. Deleting a fixture means deleting its golden too;
the orphan check fails otherwise.

Good fixtures are real-world-shaped and edge-heavy: long and esoteric git-ai logs (quoted,
escaped and unicode paths, several trace IDs for one session, keys missing from the metadata,
legacy prompts, CRLF line endings), human prose, front matter, other tools' formats (git-appraise
JSON lines), and whitespace and symbol noise.
