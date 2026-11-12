#!/bin/bash
# Copies dist/CouchMode.app to the media Mac and (re)launches it.
# Target host comes from HTPC_HOST (required), as an ssh destination such as
# user@mac-mini.local. Key-based ssh access to it must already work.
set -euo pipefail
cd "$(dirname "$0")/.."
# Machine-specific settings (HTPC_HOST, HTPC_SIGN_IDENTITY) may live in
# scripts/local.env, which git ignores; see scripts/local.env.example.
if [ -f scripts/local.env ]; then . scripts/local.env; fi
if [ -z "${HTPC_HOST:-}" ]; then
  echo "usage: HTPC_HOST=user@hostname scripts/deploy.sh" >&2
  echo "  HTPC_HOST is the ssh destination of the Mac that runs the shell." >&2
  exit 2
fi
host="$HTPC_HOST"
test -d dist/CouchMode.app || { echo "run scripts/build-app.sh first" >&2; exit 1; }
ditto -c -k --keepParent dist/CouchMode.app /tmp/CouchMode.zip
scp -q /tmp/CouchMode.zip "$host:/tmp/CouchMode.zip"
# The old shell is stopped before the new one starts, so a launch that fails
# (LaunchServices error -600 happens now and then) is retried rather than
# leaving the TV without a shell, and a shell that never starts fails loudly.
ssh "$host" 'set -e; pkill -x HTPCShell || true; pkill -x CouchMode || true; mkdir -p ~/Applications; cd ~/Applications; rm -rf CouchMode.app HTPCShell.app; ditto -x -k /tmp/CouchMode.zip .
for attempt in 1 2 3; do
  open ~/Applications/CouchMode.app || true
  sleep 3
  if pgrep -x CouchMode >/dev/null; then echo "running on $(hostname)"; exit 0; fi
done
echo "CouchMode did not start on $(hostname)" >&2; exit 1'
