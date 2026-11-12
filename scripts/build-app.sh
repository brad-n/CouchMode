#!/bin/bash
# Builds dist/CouchMode.app from the current commit, signed with HTPC_SIGN_IDENTITY, or ad-hoc if unset.
set -euo pipefail
cd "$(dirname "$0")/.."
# Machine-specific settings (HTPC_HOST, HTPC_SIGN_IDENTITY) may live in
# scripts/local.env, which git ignores; see scripts/local.env.example.
if [ -f scripts/local.env ]; then . scripts/local.env; fi
swift build -c release --arch arm64
sha=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
app=dist/CouchMode.app
rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --show-bin-path)/CouchMode" "$app/Contents/MacOS/"
sed "s/__BUILD__/$sha/" packaging/Info.plist > "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources/art"
cp packaging/art/*.png "$app/Contents/Resources/art/" 2>/dev/null || true
# HTPC_SIGN_IDENTITY names a code-signing identity in your keychain (see
# `security find-identity -v -p codesigning`). A stable identity keeps macOS's
# keychain "Always Allow" and permission grants valid across rebuilds; without
# one the app is signed ad-hoc ("-"), which changes every build and re-prompts.
identity="${HTPC_SIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then
  echo "HTPC_SIGN_IDENTITY not set: signing ad-hoc" >&2
  codesign -s - --force "$app"
else
  codesign -s "$identity" --force --options runtime "$app"
fi
echo "built $app ($sha)"
