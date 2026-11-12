#!/bin/bash
# Builds dist/CouchMode.app from the current commit, signed with HTPC_SIGN_IDENTITY, or ad-hoc if unset.
# Version: $COUCHMODE_VERSION, else packaging/VERSION. Build number: commit count (always increases).
# COUCHMODE_RELEASE=1 (set by release.sh) adds a secure timestamp to every signature, which notarization requires.
set -euo pipefail
cd "$(dirname "$0")/.."
# Machine-specific settings (HTPC_HOST, HTPC_SIGN_IDENTITY) may live in
# scripts/local.env, which git ignores; see scripts/local.env.example.
if [ -f scripts/local.env ]; then . scripts/local.env; fi
swift build -c release --arch arm64
sha=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
count=$(git rev-list --count HEAD 2>/dev/null || echo 0)
version="${COUCHMODE_VERSION:-$(tr -d '[:space:]' < packaging/VERSION)}"
case "$version" in *[!0-9A-Za-z.-]*|"") echo "bad version: $version" >&2; exit 2;; esac
app=dist/CouchMode.app
bin=$(swift build -c release --arch arm64 --show-bin-path)
rm -rf "$app" && mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp "$bin/CouchMode" "$app/Contents/MacOS/"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$count/" -e "s/__SHA__/$sha/" packaging/Info.plist > "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources/art"
cp packaging/art/*.png "$app/Contents/Resources/art/" 2>/dev/null || true
# Sparkle.framework (from SwiftPM's binary artifact) goes in Contents/Frameworks, found through an rpath.
fw=$(find .build/artifacts -type d -path '*macos-arm64*/Sparkle.framework' -maxdepth 6 | head -1)
test -d "$fw" || { echo "Sparkle.framework not found; run swift package resolve" >&2; exit 1; }
ditto "$fw" "$app/Contents/Frameworks/Sparkle.framework"
otool -l "$app/Contents/MacOS/CouchMode" | grep -q '@executable_path/../Frameworks' \
  || install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/CouchMode"
# HTPC_SIGN_IDENTITY names a code-signing identity in your keychain (see
# `security find-identity -v -p codesigning`). A stable identity keeps macOS's
# keychain "Always Allow" and permission grants valid across rebuilds; without
# one the app is signed ad-hoc ("-"), which changes every build and re-prompts.
identity="${HTPC_SIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then
  echo "HTPC_SIGN_IDENTITY not set: signing ad-hoc" >&2
  codesign -s - --force --deep "$app"
else
  ts=(); [ "${COUCHMODE_RELEASE:-}" = 1 ] && ts=(--timestamp)
  sign() { codesign -s "$identity" --force --options runtime ${ts[@]+"${ts[@]}"} "$@"; }
  # Sparkle's helpers, innermost first, then the framework, then the app. No --deep: each piece is signed
  # on its own with the hardened runtime, as Sparkle's documentation requires.
  sv="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  for x in "$sv"/XPCServices/*.xpc; do [ -e "$x" ] && sign --preserve-metadata=entitlements "$x"; done
  sign "$sv/Autoupdate"
  sign "$sv/Updater.app"
  sign "$app/Contents/Frameworks/Sparkle.framework"
  sign "$app"
fi
echo "built $app ($version, build $count, $sha)"
