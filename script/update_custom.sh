#!/usr/bin/env bash
# Reapplies this fork's custom providers (OpenCode + Command Code) onto the
# latest upstream Usagebar, tests, rebuilds, and reinstalls the app.
#
# Usage: ./script/update_custom.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="feat/opencode-commandcode"
APP_PATH="${TMPDIR:-/tmp/}UsagebarDerivedData/Build/Products/Release/Usagebar.app"

cd "$ROOT_DIR"
git checkout "$BRANCH"
git fetch origin

echo "Replaying the provider commit onto origin/main..."
if ! git rebase origin/main; then
  git rebase --abort
  echo "Rebase conflict: upstream changed the same lines. Resolve by hand:" >&2
  echo "  cd $ROOT_DIR && git rebase origin/main" >&2
  exit 1
fi

echo "Running tests..."
./script/test_performance.sh

echo "Building release..."
make release

echo "Installing to /Applications..."
pkill -x Usagebar >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Usagebar.app
cp -R "$APP_PATH" /Applications/Usagebar.app
open -a Usagebar
sleep 2
pgrep -x Usagebar >/dev/null && echo "Usagebar updated and running with custom providers." || {
  echo "Usagebar did not stay running" >&2
  exit 1
}
