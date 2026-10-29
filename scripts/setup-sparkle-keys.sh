#!/usr/bin/env zsh
# One-time setup for signed Sparkle updates. Run on your Mac from the root of the repo.
#
# 1. Generates (or reuses) Sparkle's EdDSA key pair. The private key lives in your login
#    Keychain, as Sparkle's own tools expect.
# 2. Stores the private key as the SPARKLE_ED_PRIVATE_KEY GitHub Actions secret, so the release
#    workflow can sign each DMG. The exported key file is deleted straight away.
# 3. Writes the public key into Config/Info.plist (SUPublicEDKey) for you to commit.
#
# Keep a backup of the private key (Keychain Access → "Private key for signing Sparkle updates").
# Losing it means existing installs can never verify another update.
# Requirements: gh (GitHub CLI), logged in. See docs/releasing.md.

set -euo pipefail

SPARKLE_VERSION="2.10.1"   # keep in step with the package pin in Elemental.xcodeproj
PLIST="Config/Info.plist"

BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
info()    { echo -e "${BOLD}$*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
fatal()   { echo -e "${RED}✗ $*${RESET}"; exit 1; }

[ -f "$PLIST" ] || fatal "Run this from the root of the elemental repo."
command -v gh >/dev/null 2>&1 || fatal "'gh' not found. Install with: brew install gh"
gh auth status >/dev/null 2>&1 || fatal "Not logged in to GitHub CLI. Run: gh auth login"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) || fatal "Could not detect the GitHub repo."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

info "Downloading Sparkle ${SPARKLE_VERSION} tools…"
curl -fsSL -o "$WORK/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
tar -xJf "$WORK/sparkle.tar.xz" -C "$WORK" ./bin/generate_keys
GENERATE_KEYS="$WORK/bin/generate_keys"

info "Generating or reusing the EdDSA key in your login Keychain (macOS may ask for access)…"
"$GENERATE_KEYS" >/dev/null
PUBLIC_KEY=$("$GENERATE_KEYS" -p | tr -d '[:space:]')
[ -n "$PUBLIC_KEY" ] || fatal "generate_keys did not return a public key."
success "Public key: $PUBLIC_KEY"

info "Storing the private key as the SPARKLE_ED_PRIVATE_KEY secret on $REPO…"
"$GENERATE_KEYS" -x "$WORK/private.key" >/dev/null
gh secret set SPARKLE_ED_PRIVATE_KEY --repo "$REPO" < "$WORK/private.key"
rm -f "$WORK/private.key"
success "Secret set (exported key file deleted)."

info "Writing SUPublicEDKey to $PLIST…"
# A targeted edit (not PlistBuddy, which rewrites the file and drops its comments).
PUBLIC_KEY="$PUBLIC_KEY" perl -0pi -e '
  s{\n\t<key>SUPublicEDKey</key>\n\t<string>[^<]*</string>}{};
  s{(\n</dict>\s*</plist>)}{\n\t<key>SUPublicEDKey</key>\n\t<string>$ENV{PUBLIC_KEY}</string>$1};
' "$PLIST"
plutil -lint "$PLIST" >/dev/null || fatal "$PLIST is no longer a valid plist."
success "Done. Commit $PLIST and push before tagging the next release:"
echo "  git add $PLIST && git commit -m 'Add Sparkle public key' && git push"
