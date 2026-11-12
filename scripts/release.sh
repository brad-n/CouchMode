#!/bin/bash
# Builds, notarizes and drafts a CouchMode release. See agents/release.md.
#
#   scripts/release.sh <version> [--notes FILE]
#
# Produces in dist/release/<version>/: a signed, notarized, stapled CouchMode.app (inside the zip and DMG),
# CouchMode-<version>.dmg (signed, notarized, stapled) and appcast.xml (Sparkle, EdDSA-signed), then creates a
# DRAFT GitHub release v<version> with the DMG and appcast attached. It never publishes, never pushes a
# tag or commits. Publishing the draft is a separate, deliberate step.
#
# Needs in scripts/local.env: HTPC_SIGN_IDENTITY (Developer ID Application), NOTARY_KEYCHAIN_KEY_SERVICE,
# NOTARY_KEYCHAIN_ISSUER_SERVICE, NOTARY_KEY_ID. Secrets are read from the Keychain at run time, written
# only to a mode-600 temp file that is deleted on exit, and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: scripts/release.sh <version> [--notes FILE]   (version like 0.2.0 or 0.2.0-rc1)" >&2; exit 2; }
version=""; notes=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) [ $# -ge 2 ] || usage; notes="$2"; shift 2;;
    -*) usage;;
    *) [ -z "$version" ] || usage; version="$1"; shift;;
  esac
done
[ -n "$version" ] || usage
# Same rule as AppVersion.isValidRelease (Core, unit-tested): 1-3 dotted numbers, optional -prerelease tag.
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]] || { echo "bad version: $version" >&2; usage; }
if [ -n "$notes" ] && [ ! -f "$notes" ]; then echo "notes file not found: $notes" >&2; exit 2; fi

[ -f scripts/local.env ] && . scripts/local.env
for v in HTPC_SIGN_IDENTITY NOTARY_KEYCHAIN_KEY_SERVICE NOTARY_KEYCHAIN_ISSUER_SERVICE NOTARY_KEY_ID; do
  [ -n "${!v:-}" ] || { echo "$v is not set in scripts/local.env (see scripts/local.env.example)" >&2; exit 2; }
done
case "$HTPC_SIGN_IDENTITY" in "Developer ID Application:"*) ;; *) echo "HTPC_SIGN_IDENTITY must be a Developer ID Application identity" >&2; exit 2;; esac

# Preflight: everything that can fail cheaply fails before the slow build.
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "working tree has uncommitted changes; commit first" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in" >&2; exit 1; }
tag="v$version"
if gh release view "$tag" >/dev/null 2>&1; then echo "GitHub release $tag already exists" >&2; exit 1; fi
sign_update=$(find .build/artifacts -type f -name sign_update -path '*Sparkle*' 2>/dev/null | head -1 || true)
if [ -z "$sign_update" ]; then swift package resolve >/dev/null; sign_update=$(find .build/artifacts -type f -name sign_update | head -1); fi
[ -x "$sign_update" ] || { echo "Sparkle sign_update not found" >&2; exit 1; }
generate_keys="$(dirname "$sign_update")/generate_keys"
pub=$("$generate_keys" -p 2>/dev/null) || { echo "no Sparkle signing key in the login Keychain (see agents/release.md)" >&2; exit 1; }
plist_pub=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' packaging/Info.plist)
[ "$pub" = "$plist_pub" ] || { echo "Sparkle key in Keychain does not match SUPublicEDKey in packaging/Info.plist" >&2; exit 1; }

# Credentials: a temp dir only we can read, removed on any exit.
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
key=$(security find-generic-password -s "$NOTARY_KEYCHAIN_KEY_SERVICE" -w) || { echo "notary key not in Keychain" >&2; exit 1; }
issuer=$(security find-generic-password -s "$NOTARY_KEYCHAIN_ISSUER_SERVICE" -w) || { echo "notary issuer not in Keychain" >&2; exit 1; }
case "$key" in -----BEGIN*) printf '%s\n' "$key" > "$tmp/key.p8";; *) printf '%s' "$key" | base64 -d > "$tmp/key.p8";; esac
unset key
chmod 600 "$tmp/key.p8"
notarize() {   # notarize <file>: submit, wait, and stop with the log if not Accepted
  local out status id
  out=$(xcrun notarytool submit "$1" --key "$tmp/key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$issuer" --wait --timeout 30m --output-format json) \
    || { echo "notarytool failed for $1: $out" >&2; return 1; }
  status=$(printf '%s' "$out" | plutil -extract status raw -o - - 2>/dev/null || echo unknown)
  id=$(printf '%s' "$out" | plutil -extract id raw -o - - 2>/dev/null || echo unknown)
  echo "notarization $id: $status"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --key "$tmp/key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$issuer" >&2 || true
    return 1
  fi
}

out="dist/release/$version"
rm -rf "$out" && mkdir -p "$out"
sha=$(git rev-parse --short HEAD); full=$(git rev-parse HEAD)

echo "== build"
COUCHMODE_RELEASE=1 COUCHMODE_VERSION="$version" scripts/build-app.sh
app=dist/CouchMode.app
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
codesign --verify --strict --deep "$app"

echo "== notarize app"
ditto -c -k --keepParent "$app" "$tmp/app.zip"
notarize "$tmp/app.zip"
xcrun stapler staple "$app" >/dev/null
xcrun stapler validate "$app" >/dev/null
spctl --assess --type execute "$app"

echo "== dmg"
dmg="$out/CouchMode-$version.dmg"
stage="$tmp/dmg"; mkdir -p "$stage"
ditto "$app" "$stage/CouchMode.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "CouchMode $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
codesign -s "$HTPC_SIGN_IDENTITY" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg" >/dev/null
xcrun stapler validate "$dmg" >/dev/null
spctl --assess --type open --context context:primary-signature "$dmg"

echo "== appcast"
# sign_update prints: sparkle:edSignature="..." length="..." (the private key stays in the Keychain).
sig=$("$sign_update" "$dmg")
[[ "$sig" =~ ^sparkle:edSignature=\"[A-Za-z0-9+/=]+\"\ length=\"[0-9]+\"$ ]] || { echo "unexpected sign_update output" >&2; exit 1; }
if [ -n "$notes" ]; then
  # An .html notes file is used as is; anything else is shown as plain text.
  case "$notes" in *.html) body=$(cat "$notes");; *) body="<pre style=\"font-family: -apple-system, sans-serif; white-space: pre-wrap\">$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$notes")</pre>";; esac
else
  body="<p>CouchMode $version</p>"
fi
[[ "$body" != *"]]>"* ]] || { echo "notes must not contain ]]>" >&2; exit 1; }
url="https://github.com/brad-n/CouchMode/releases/download/$tag/$(basename "$dmg")"
cat > "$out/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>CouchMode</title>
    <item>
      <title>Version $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$body]]></description>
      <enclosure url="$url" type="application/x-apple-diskimage" $sig/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$out/appcast.xml"

echo "== github draft"
# The draft targets this commit when origin already has it, otherwise main; no tag is pushed (publishing creates it).
target=main
if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then target="$full"; else echo "note: $sha is not on origin/main; draft targets main" >&2; fi
flags=(--draft --target "$target" --title "CouchMode $version")
[[ "$version" == *-* ]] && flags+=(--prerelease)
if [ -n "$notes" ]; then flags+=(--notes-file "$notes"); else flags+=(--notes "CouchMode $version (build $build, $sha)"); fi
url=$(gh release create "$tag" "${flags[@]}" "$dmg" "$out/appcast.xml")
echo "draft release: $url"
echo "(not published; review it, then publish with: gh release edit $tag --draft=false)"
