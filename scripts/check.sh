#!/bin/bash
# The repo's check command: build everything and run the tests.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/package-index.sh --check
swift build -c release
swift test
