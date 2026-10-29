#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
team="${DEVELOPMENT_TEAM:-$(git config --get entemenubar.team || true)}"
if [ -z "$team" ]; then
    echo "Set DEVELOPMENT_TEAM, or save your team ID once: git config entemenubar.team <team ID>" >&2
    exit 1
fi
./scripts/bindings.sh release
./scripts/brand.sh
./scripts/icons.sh
/opt/homebrew/bin/xcodegen generate --spec apple/App/project.yml
xcodebuild -project apple/App/EnteMenubar.xcodeproj -scheme EnteMenubar \
    -allowProvisioningUpdates -configuration Debug -derivedDataPath "$repo_dir/.build/app" \
    DEVELOPMENT_TEAM="$team" build
printf '%s\n' "$repo_dir/.build/app/Build/Products/Debug/EnteMenubar.app"
