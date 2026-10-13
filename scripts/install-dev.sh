#!/bin/bash
# Copies dist/Lidless.app into /Applications and opens it. Run scripts/bundle.sh first.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_app="$root/dist/Lidless.app"
target_app="/Applications/Lidless.app"

[ -d "$source_app" ] || { echo "install-dev.sh: $source_app is missing; run scripts/bundle.sh first" >&2; exit 1; }

# Quit a running copy so it restores the sleep setting before being replaced.
if pgrep -xq Lidless; then
    osascript -e 'tell application id "com.benabens.lidless" to quit' 2>/dev/null || pkill -x Lidless || true
    while pgrep -xq Lidless; do sleep 0.2; done
fi

rm -rf "$target_app"
ditto "$source_app" "$target_app"
open "$target_app"
echo "Installed $target_app"
