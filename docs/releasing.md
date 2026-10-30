# Releasing

Releases are cut by pushing a version tag. `.github/workflows/release.yml` builds, signs,
notarizes and publishes everything; nothing is built by hand.

## Cutting a release

1. Make sure CI is green on the commit (`main`).
2. Tag it and push the tag:
   ```bash
   git tag v0.1.12 <commit> && git push origin v0.1.12
   ```
   Tags are lightweight and must match `vX.Y.Z`. Bump the patch number for each release. A tag with a
   suffix (`v0.2.0-beta.1`) becomes a **prerelease**: it is never marked latest, so updaters never see it.
3. Watch the **Release** workflow. It:
   - fails fast if update signing isn't set up (see below);
   - archives the app with `MARKETING_VERSION` = the tag and `CURRENT_PROJECT_VERSION` (CFBundleVersion)
     = its numeric part;
   - re-signs Sparkle's nested helpers and the app with the Developer ID certificate (hardened runtime);
   - builds the DMG, notarizes and staples it;
   - writes a changelog from the commits since the previous stable tag;
   - EdDSA-signs the DMG for Sparkle and writes `appcast.xml`;
   - publishes the GitHub release with the DMG and `appcast.xml` attached.

If notarization fails with *"A required agreement is missing or has expired"*, accept the pending
agreement on developer.apple.com / App Store Connect (as the Account Holder) and re-run the workflow.
You don't need a new tag.

## In-app updates (Sparkle)

Elemental updates itself with [Sparkle](https://sparkle-project.org) 2.10.1, pinned exactly in the Xcode
project. `scripts/setup-sparkle-keys.sh` and the release workflow read the same version.

**Manual only by default.** `Config/Info.plist` sets `SUEnableAutomaticChecks` to `NO`, so Elemental
never checks in the background and never shows Sparkle's "check automatically?" prompt. A check
happens only when the user chooses **Elemental → Check for Updates…**, or after they turn on
**Automatically check for updates** in **Settings… (⌘,)**. There, they can also allow automatic
download and install. Sparkle stores these choices in the app's user defaults. CI fails the build if
the built app's `SUEnableAutomaticChecks` isn't `false`.

**How an update is found.** `SUFeedURL` is
`https://github.com/jasoncabot/elemental/releases/latest/download/appcast.xml`. GitHub serves that from
the newest non-prerelease release, so the feed holds only the latest version. Sparkle compares
its `sparkle:version` (CFBundleVersion, e.g. `0.1.12`) with the running app's, downloads the DMG,
checks its EdDSA signature against `SUPublicEDKey`, and installs it.

**Releases up to v0.1.11 have no updater.** People on those versions need to download one release
by hand. After that, updates come through the app.

### One-time setup: signing keys

On your Mac, from the repo root, with the GitHub CLI logged in:

```bash
scripts/setup-sparkle-keys.sh
git add Config/Info.plist && git commit -m "Add Sparkle public key" && git push
```

The script generates (or reuses) Sparkle's EdDSA key pair in your login Keychain and stores the
private key as the `SPARKLE_ED_PRIVATE_KEY` Actions secret. It deletes the exported file straight
away and writes the public key into `Config/Info.plist` as `SUPublicEDKey`. Until both exist, the
release workflow stops at its first check, so the app can't ship with an updater that couldn't
verify updates.

**Back up the private key** (Keychain Access → *Private key for signing Sparkle updates*). If it's
lost, installed copies can never verify another update. You would have to ship a new key and
everyone would need to download that release by hand.

### Changing Sparkle's version

Change `version` in the `XCRemoteSwiftPackageReference "Sparkle"` block of
`Elemental.xcodeproj/project.pbxproj` and `SPARKLE_VERSION` in `scripts/setup-sparkle-keys.sh`. The
release workflow reads the project's pin to download the matching `sign_update`.

## Release secrets

| Secret | Set by | Used for |
|---|---|---|
| `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID` | `scripts/setup-release-secrets.sh` | Developer ID signing |
| `APPLE_NOTARY_KEY`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID` | `scripts/setup-release-secrets.sh` | Notarization |
| `SPARKLE_ED_PRIVATE_KEY` | `scripts/setup-sparkle-keys.sh` | Signing updates for Sparkle |

## Build info in the About window

The Version line shows the git revision after the version number: `Version 0.1.12 (v0.1.12, a1b2c3d)` for a
release build, `Version 0.1.0 (a1b2c3d, dirty)` for a local build with uncommitted changes to tracked files.
The "Stamp build info" build phase runs `scripts/stamp-build-info.sh`, which writes `ElementalBuildInfo` into the
built Info.plist. Release builds need the tag in the checkout, which `release.yml` already fetches.
