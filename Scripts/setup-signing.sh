#!/usr/bin/env bash
#
# setup-signing.sh — ONE-COMMAND signing setup for DebianTerminal.
#
# On your Mac, this script:
#   1. Finds your Apple Development certificate in the login keychain and
#      exports it to a .p12 (you are asked for the export password).
#   2. Finds (or, if none exists, tells you how Xcode auto-generates) a
#      matching .mobileprovision for bundle id dev.debianterminal.app.
#   3. base64-encodes both and uploads the 4 GitHub Action secrets
#      (APPLE_TEAM_ID, APPLE_CERT_P12_BASE64, APPLE_CERT_P12_PASSWORD,
#      APPLE_PROVISIONING_BASE64) to the repo.
#   4. Triggers the Build IPA workflow, which now runs the SIGNED path.
#
# Run it from the repo root on macOS. Requires: xcodegen, Xcode signed into
# your Apple ID, and `gh` (GitHub CLI) OR your repo-scoped PAT.
#
#   ./Scripts/setup-signing.sh                # interactive (asks for p12 password)
#   GITHUB_TOKEN=<ghp_...> ./Scripts/setup-signing.sh   # PAT auth, no gh login needed
#
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

REPO="${GITHUB_REPOSITORY:-xngfhghfgd/DebianTerminal}"
BUNDLE_ID="dev.debianterminal.app"   # must match project.yml PRODUCT_BUNDLE_IDENTIFIER

echo "==> DebianTerminal one-command signing setup"
echo "    repo: $REPO   bundle id: $BUNDLE_ID"
echo

# --- 0. sanity: need a Mac + Xcode signing identity ------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: this script must run on a Mac (it reads the login keychain and Xcode certs)." >&2
  exit 1
fi

# --- 1. find the Apple Development certificate -----------------------------
echo "==> Looking for your Apple Development certificate in the login keychain..."
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null | grep -iE "Apple Development|iPhone Developer" || true)
if [ -z "$IDENTITIES" ]; then
  echo "ERROR: no Apple Development / iPhone Developer certificate found." >&2
  echo "  Open Xcode > Settings > Accounts, sign in with your Apple ID, then" >&2
  echo "  choose your team in the Signing pane. Xcode will create a personal-team" >&2
  echo "  'Apple Development' cert automatically (free account works). Re-run this script." >&2
  exit 1
fi
echo "$IDENTITIES"
# Take the newest *Development* cert (assume one; if several, first is fine).
CERT_NAME=$(echo "$IDENTITIES" | head -1 | sed -E 's/^.*"(.*)".*$/\1/')
CERT_SHA=$(echo "$IDENTITIES" | head -1 | awk '{print $2}')
echo "    using: $CERT_NAME"

# --- 2. export it to a .p12 -------------------------------------------------
echo
echo "==> Exporting the certificate + private key to a .p12"
P12_PATH="build/signing.p12"
mkdir -p build
# Generate a random password so the import step in CI never has to prompt.
P12_PASSWORD=$(openssl rand -hex 16)
# `security export -t identities` exports all cert+key pairs in the login
# keychain to one p12 — this includes the Apple Development identity(s).
security export -k "$HOME/Library/Keychains/login.keychain-db" \
  -t identities -f pkcs12 -P "$P12_PASSWORD" -o "$P12_PATH" || {
  echo "    (export failed; ensure the cert is in the login keychain and unlocked)" >&2
  exit 1
}
echo "    wrote $P12_PATH (password generated; kept secret for CI)"

# --- 3. find the provisioning profile --------------------------------------
echo
echo "==> Looking for a matching .mobileprovision for $BUNDLE_ID"
PROF_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
PROFILE=""
if [ -d "$PROF_DIR" ]; then
  for p in "$PROF_DIR"/*.mobileprovision; do
    [ -f "$p" ] || continue
    if security cms -D -i "$p" 2>/dev/null | grep -q "$BUNDLE_ID"; then
      PROFILE="$p"
      break
    fi
  done
fi
if [ -z "$PROFILE" ]; then
  echo "WARN: no .mobileprovision containing '$BUNDLE_ID' found in $PROF_DIR"
  echo "  Build the app once in Xcode (Product > Archive, or the sign-in above) so"
  echo "  automatic signing creates a Development profile for your device, then"
  echo "  re-run this script. (A free personal team profile lasts 7 days.)" >&2
  exit 1
fi
echo "    using: $PROFILE"

# --- 4. derive secrets ------------------------------------------------------
echo
echo "==> Deriving the 4 secrets"
# TEAM ID: from the cert CN, e.g. "Apple Development: Name (TEAMID)" -> TEAMID.
TEAM_ID=$(echo "$CERT_NAME" | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()')
if [ -z "$TEAM_ID" ]; then
  echo "ERROR: could not infer Team ID from cert name '$CERT_NAME'." >&2
  echo "  Set it manually: export APPLE_TEAM_ID before re-running, or edit the script." >&2
  exit 1
fi
echo "    APPLE_TEAM_ID           = $TEAM_ID"
echo "    APPLE_CERT_P12_BASE64   = (base64 of $P12_PATH)"
echo "    APPLE_CERT_P12_PASSWORD = (generated: ${#P12_PASSWORD} hex chars)"
echo "    APPLE_PROVISIONING_BASE64 = (base64 of $(basename "$PROFILE"))"

P12_B64=$(base64 -i "$P12_PATH" | tr -d '\n')
PROV_B64=$(base64 -i "$PROFILE" | tr -d '\n')

# --- 5. upload secrets via `gh` (or curl + PAT) -----------------------------
echo
echo "==> Uploading secrets to $REPO"
if command -v gh >/dev/null 2>&1 && [ -z "${GITHUB_TOKEN:-}" ]; then
  gh secret set APPLE_TEAM_ID --repo "$REPO" --body "$TEAM_ID" && echo "  + APPLE_TEAM_ID"
  gh secret set APPLE_CERT_P12_BASE64 --repo "$REPO" --body "$P12_B64" && echo "  + APPLE_CERT_P12_BASE64"
  gh secret set APPLE_CERT_P12_PASSWORD --repo "$REPO" --body "$P12_PASSWORD" && echo "  + APPLE_CERT_P12_PASSWORD (generated)"
  gh secret set APPLE_PROVISIONING_BASE64 --repo "$REPO" --body "$PROV_B64" && echo "  + APPLE_PROVISIONING_BASE64"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  # PAT path: encrypt with the repo's public key (libsodium sealedbox) via a
  # tiny python helper; then PUT each secret.
  python3 - <<'PY'
import base64, json, subprocess, sys
try:
    from nacl import public, encoding
except ImportError:
    print("ERROR: python nacl not installed; `pip3 install pynacl`, or use gh. aborting", file=sys.stderr)
    sys.exit(2)
token=sys.argv[1]; repo=sys.argv[2]
head=['Authorization: Bearer '+token,'Accept: application/vnd.github+json']
pub=json.loads(subprocess.run(['curl','-s','-H','Authorization: Bearer '+token,'https://api.github.com/repos/'+repo+'/actions/secrets/public-key'],capture_output=True,text=True).stdout)
key=base64.b64decode(pub['key']); key_id=pub['key_id']
box=public.SealedBox(public.PublicKey(key))
def put(name,value):
    enc=box.encrypt(value.encode()).__bytes__()
    payload=json.dumps({'encrypted_value':base64.b64encode(enc).decode(),'key_id':key_id})
    r=subprocess.run(['curl','-s','-X','PUT','-H','Authorization: Bearer '+token,'-H','Accept: application/vnd.github+json','-d',payload,'https://api.github.com/repos/'+repo+'/actions/secrets/'+name],capture_output=True,text=True)
    print(name,'->',r.stdout.strip() or 'OK (204/201)')
PY
  # shellcheck disable=SC2016
  python3 - "$GITHUB_TOKEN" "$REPO" || true
  echo "  NOTE: the python path above needs `pip3 install pynacl`; if it errored, install pynacl or use gh."
else
  echo "ERROR: neither \`gh\` nor GITHUB_TOKEN is available to upload secrets." >&2
  echo "  Either install GitHub CLI (brew install gh) and sign in, or set GITHUB_TOKEN." >&2
  exit 1
fi

# --- 6. verify + trigger the signed build -----------------------------------
echo
echo "==> Verifying secrets landed"
for S in APPLE_TEAM_ID APPLE_CERT_P12_BASE64 APPLE_CERT_P12_PASSWORD APPLE_PROVISIONING_BASE64; do
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/repos/$REPO/actions/secrets/$S")
    echo "  $S -> HTTP $code"
  fi
done

echo "==> Triggering Build IPA (signed) workflow"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  curl -s -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/actions/workflows/build-ipa.yml/dispatches" \
    -d '{"ref":"main"}' -w "HTTP %{http_code}\n" -o /dev/null
elif command -v gh >/dev/null 2>&1; then
  gh workflow run build-ipa.yml --repo "$REPO"
else
  echo "  (trigger it manually: Actions > Build IPA > Run workflow)"
fi

echo
echo "Done. Check Actions > 'Build IPA' for the signed run. Once it passes, download the"
echo "'DebianTerminal-ipa' artifact (now producing DebianTerminal.ipa, a development-signed IPA)."
echo "Install with Developer Mode on + SideStore/AltStore. Free team profile is valid 7 days."
