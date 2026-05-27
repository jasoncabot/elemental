#!/usr/bin/env zsh
# Sets up the GitHub Actions secrets needed for signed + notarized releases.
# Requirements: gh (GitHub CLI), jq, Xcode command line tools.
# Run from the root of the repo.

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

info()    { echo -e "${BOLD}$*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
fatal()   { echo -e "${RED}✗ $*${RESET}"; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────

command -v gh  >/dev/null 2>&1 || fatal "'gh' not found. Install with: brew install gh"
command -v jq  >/dev/null 2>&1 || fatal "'jq' not found. Install with: brew install jq"

gh auth status >/dev/null 2>&1 || fatal "Not logged in to GitHub CLI. Run: gh auth login"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
  || fatal "Could not detect GitHub repo. Make sure you're inside the repo directory."

echo ""
info "Setting up release secrets for: $REPO"
echo ""

# ── Step 1: Developer ID Application certificate ────────────────────────────

info "Step 1 of 3 — Developer ID Application certificate"
echo ""
echo "Looking for Developer ID Application certificates in your keychain..."
echo ""

# List matching certs with their SHA-1 fingerprints (zsh 1-based arrays)
CERTS=("${(@f)$(security find-identity -v -p codesigning \
    | grep 'Developer ID Application' \
    | sed -E 's/^[[:space:]]+[0-9]+\) ([A-F0-9]+) "(.+)"$/\1|\2/')}")

if [ ${#CERTS} -eq 0 ]; then
  fatal "No 'Developer ID Application' certificate found in your keychain.
  Download it from: https://developer.apple.com/account/resources/certificates/list"
fi

if [ ${#CERTS} -eq 1 ]; then
  CERT_FINGERPRINT="${CERTS[1]%%|*}"
  CERT_NAME="${CERTS[1]##*|}"
  echo "Found: $CERT_NAME"
else
  echo "Multiple certificates found. Choose one:"
  for i in {1..${#CERTS}}; do
    echo "  $i) ${CERTS[$i]##*|}"
  done
  read -rp "Enter number: " CERT_CHOICE
  CERT_FINGERPRINT="${CERTS[$CERT_CHOICE]%%|*}"
  CERT_NAME="${CERTS[$CERT_CHOICE]##*|}"
fi

echo ""
echo "Exporting certificate: $CERT_NAME"
read -rsp "Enter a password to protect the exported .p12 file: " CERT_PASSWORD
echo ""
read -rsp "Confirm password: " CERT_PASSWORD_CONFIRM
echo ""
[ "$CERT_PASSWORD" = "$CERT_PASSWORD_CONFIRM" ] || fatal "Passwords do not match."

P12_FILE=$(mktemp /tmp/elemental-cert-XXXX.p12)
security export \
  -k login.keychain-db \
  -t identities \
  -f pkcs12 \
  -P "$CERT_PASSWORD" \
  -o "$P12_FILE" \
  2>/dev/null \
  || security export \
       -k ~/Library/Keychains/login.keychain-db \
       -t identities \
       -f pkcs12 \
       -P "$CERT_PASSWORD" \
       -o "$P12_FILE"

CERT_B64=$(base64 -i "$P12_FILE")
rm -f "$P12_FILE"

# Extract the team ID from the certificate CN (format: "Name (TEAMID)")
TEAM_ID=$(echo "$CERT_NAME" | grep -oE '\([A-Z0-9]{10}\)$' | tr -d '()')
[ -n "$TEAM_ID" ] || { read -rp "Could not detect Team ID automatically. Enter it manually: " TEAM_ID; }

gh secret set APPLE_CERTIFICATE        --repo "$REPO" --body "$CERT_B64"
gh secret set APPLE_CERTIFICATE_PASSWORD --repo "$REPO" --body "$CERT_PASSWORD"
gh secret set APPLE_TEAM_ID            --repo "$REPO" --body "$TEAM_ID"

success "Certificate secrets set (Team ID: $TEAM_ID)"
echo ""

# ── Step 2: App Store Connect API key ────────────────────────────────────────

info "Step 2 of 3 — App Store Connect API key (for notarization)"
echo ""
echo "You need an API key from App Store Connect:"
echo "  1. Go to https://appstoreconnect.apple.com/access/integrations/api"
echo "  2. Create a new key with 'Developer' role"
echo "  3. Download the .p8 file (only available once)"
echo "  4. Note the Key ID and Issuer ID shown on that page"
echo ""

read -rp "Path to the .p8 file (drag it here): " P8_PATH
P8_PATH="${P8_PATH//\'/}"   # strip quotes from drag-and-drop
P8_PATH="${P8_PATH## }"
P8_PATH="${P8_PATH%% }"
[ -f "$P8_PATH" ] || fatal "File not found: $P8_PATH"

read -rp "Key ID (e.g. ABCD123456): " NOTARY_KEY_ID
read -rp "Issuer ID (e.g. 12345678-1234-...): " NOTARY_ISSUER_ID

NOTARY_KEY=$(cat "$P8_PATH")

gh secret set APPLE_NOTARY_KEY       --repo "$REPO" --body "$NOTARY_KEY"
gh secret set APPLE_NOTARY_KEY_ID    --repo "$REPO" --body "$NOTARY_KEY_ID"
gh secret set APPLE_NOTARY_ISSUER_ID --repo "$REPO" --body "$NOTARY_ISSUER_ID"

success "Notarization secrets set"
echo ""

# ── Step 3: Verify ───────────────────────────────────────────────────────────

info "Step 3 of 3 — Verifying secrets"
echo ""

SECRETS=$(gh secret list --repo "$REPO" --json name -q '.[].name')
REQUIRED=(APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_TEAM_ID APPLE_NOTARY_KEY APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID)
ALL_OK=true

for SECRET in "${REQUIRED[@]}"; do
  if echo "$SECRETS" | grep -q "^${SECRET}$"; then
    success "$SECRET"
  else
    warn "MISSING: $SECRET"
    ALL_OK=false
  fi
done

echo ""
if $ALL_OK; then
  success "All secrets configured. To cut a release:"
  echo ""
  echo "  git tag v0.1.0 && git push origin v0.1.0"
  echo ""
else
  warn "Some secrets are missing. Re-run this script to retry."
fi
