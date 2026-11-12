#!/bin/bash
# Regenerates apps/index.json: every package in apps/<id>/ with its version,
# reader API and each file's sha256. Run it after changing any package file.
#   scripts/package-index.sh          rewrite apps/index.json
#   scripts/package-index.sh --check  fail (exit 1) if apps/index.json is out of date
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp)
trap 'rm -f "$out"' EXIT
first=1
{
  printf '{\n  "packages" : [\n'
  for manifest in apps/*/manifest.json; do
    dir=$(dirname "$manifest"); id=$(basename "$dir")
    version=$(plutil -extract version raw -o - "$manifest")
    api=$(plutil -extract readerAPI raw -o - "$manifest")
    [ "$first" = 1 ] || printf ',\n'
    first=0
    printf '    {\n      "files" : [\n'
    sep=''
    for f in manifest.json reader.js; do
      [ -f "$dir/$f" ] || { echo "$dir/$f is missing" >&2; exit 1; }
      printf '%s        { "name" : "%s", "sha256" : "%s" }' "$sep" "$f" "$(shasum -a 256 "$dir/$f" | cut -d' ' -f1)"
      sep=$',\n'
    done
    printf '\n      ],\n      "id" : "%s",\n      "readerAPI" : %s,\n      "version" : "%s"\n    }' "$id" "$api" "$version"
  done
  printf '\n  ],\n  "version" : 1\n}\n'
} > "$out"
if [ "${1:-}" = "--check" ]; then
  if ! diff -q "$out" apps/index.json >/dev/null 2>&1; then
    echo "apps/index.json is out of date: run scripts/package-index.sh and commit it" >&2
    exit 1
  fi
  exit 0
fi
cp "$out" apps/index.json
echo "wrote apps/index.json"
