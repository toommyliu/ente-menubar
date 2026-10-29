#!/bin/bash
set -euo pipefail
: "${DEVELOPMENT_TEAM:?set it to your Apple developer team ID}"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
./scripts/bindings.sh release
./scripts/brand.sh
./scripts/icons.sh
/opt/homebrew/bin/xcodegen generate --spec apple/App/project.yml
xcodebuild -project apple/App/EnteMenubar.xcodeproj -scheme EnteMenubar \
    -allowProvisioningUpdates -configuration Debug -derivedDataPath "$repo_dir/.build/app" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" build
printf '%s\n' "$repo_dir/.build/app/Build/Products/Debug/EnteMenubar.app"
