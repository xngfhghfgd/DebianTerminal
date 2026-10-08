#!/usr/bin/env bash
#
# package-ipa.sh — Build, sign and export the DebianTerminal iOS app as an .ipa.
#
# MUST run on macOS with Xcode + xcodegen + an Apple signing identity. This
# cannot run on the Linux POC host (compiling iOS needs the macOS SDK).
#
# Prerequisites (run these first, also on the Mac):
#   brew install xcodegen
#   ./Scripts/build-qemu.sh      # -> Resources/qemu-system-aarch64 (iOS arm64)
#   ./Scripts/build-debian.sh    # -> Resources/Image, initrd.img, debian12.img
#   # or copy the artifacts produced on the Linux host into ./Resources/
#
# Signing: the app is built with the JIT entitlements
#   (com.apple.security.cs.allow-unsigned-executable-memory / allow-jit /
#    get-task-allow). These dev entitlements are only honored when the app is
#   signed with a DEVELOPMENT certificate (your personal team) and installed on
#   a device with Developer Mode enabled. A Distribution/App Store build will
#   NOT be granted JIT. So this script exports with method=development.
#
# Usage (from the repo root):
#   DEVELOPMENT_TEAM=ABCDE12345 ./Scripts/package-ipa.sh
#   DEVELOPMENT_TEAM=ABCDE12345 UDID=00008110-... ./Scripts/package-ipa.sh
#
# Output: build/ipa/DebianTerminal.ipa
#
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

SCHEME="DebianTerminal"
TEAM="${DEVELOPMENT_TEAM:-}"
UDID="${UDID:-}"           # optional: an iOS device UDID to pre-register

if [ -z "$TEAM" ]; then
  echo "ERROR: set DEVELOPMENT_TEAM to your Apple Team ID (Xcode > Signing)"; exit 1
fi

# --- sanity: runtime artifacts ------------------------------------------
for f in qemu-system-aarch64 Image initrd.img debian12.img; do
  if [ ! -f "Resources/$f" ]; then
    echo "WARN: Resources/$f missing. Build with build-qemu.sh / build-debian.sh before packaging."
  fi
done

# --- regenerate the Xcode project ---------------------------------------
command -v xcodegen >/dev/null 2>&1 || { echo "ERROR: xcodegen not found (brew install xcodegen)"; exit 1; }
xcodegen generate

# --- archive ------------------------------------------------------------
rm -rf build
# Pre-register a device so automatic signing can include it (personal team).
EXTRA=()
if [ -n "$UDID" ]; then
  EXTRA=("TARGETED_DEVICE_FAMILY=1,2" "PROVISIONING_PROFILE_SPECIFIER=")
fi

xcodebuild \
  -project DebianTerminal.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/DebianTerminal.xcarchive \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  "${EXTRA[@]}" \
  archive

# --- sign for development & export an .ipa ------------------------------
# Method is 'development' (JIT entitlements require a dev-signed app). For a
# hardened/ad-hoc variant change ExportOptions.plist accordingly (JIT won't work).
# ExportOptions.plist ships with a placeholder teamID; substitute the real one.
plutil -replace teamID -string "$TEAM" ExportOptions.plist
xcodebuild \
  -exportArchive \
  -archivePath build/DebianTerminal.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/ipa \
  -allowProvisioningUpdates

echo
echo "Done. IPA: build/ipa/DebianTerminal.ipa"
echo "Install it with your device in Developer Mode (Settings > Privacy & Security > Developer Mode),"
echo "or via SideStore/AltStore. Log in as root / ${ROOT_PASSWORD:-debian}."
