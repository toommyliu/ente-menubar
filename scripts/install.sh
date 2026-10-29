#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
app_path="$(./scripts/app.sh | tail -1)"
pkill -f '/Applications/EnteMenubar.app/Contents/MacOS/EnteMenubar' || true
rm -rf /Applications/EnteMenubar.app
cp -R "$app_path" /Applications/
open /Applications/EnteMenubar.app
echo "Installed and opened /Applications/EnteMenubar.app"
