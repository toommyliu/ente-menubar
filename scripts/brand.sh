#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
./scripts/upstream.sh >/dev/null
assets="$repo_dir/vendor/ente/mobile/apps/auth"
catalog="$repo_dir/apple/App/Generated/Assets.xcassets"
rm -rf "$catalog"
mkdir -p "$catalog/MenuBarIcon.imageset"
printf '{"info":{"author":"xcode","version":1}}\n' >"$catalog/Contents.json"
cp -R "$assets/macos/Runner/Assets.xcassets/AppIcon.appiconset" "$catalog/"
sips -z 18 18 "$assets/assets/icons/auth-icon-monochrome-padded.png" --out "$catalog/MenuBarIcon.imageset/menubar.png" >/dev/null
sips -z 36 36 "$assets/assets/icons/auth-icon-monochrome-padded.png" --out "$catalog/MenuBarIcon.imageset/menubar@2x.png" >/dev/null
cat >"$catalog/MenuBarIcon.imageset/Contents.json" <<'JSON'
{
  "images": [
    { "filename": "menubar.png", "idiom": "mac", "scale": "1x" },
    { "filename": "menubar@2x.png", "idiom": "mac", "scale": "2x" }
  ],
  "info": { "author": "xcode", "version": 1 },
  "properties": { "template-rendering-intent": "template" }
}
JSON
echo "brand assets ready"
