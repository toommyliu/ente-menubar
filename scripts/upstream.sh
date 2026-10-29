#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
rev=$(cat "$root/UPSTREAM_REV")
dir="$root/vendor/ente"
if [ ! -d "$dir/.git" ]; then
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin https://github.com/ente-io/ente.git
fi
git -C "$dir" sparse-checkout set --no-cone '/rust/' '/server/' '/mobile/apps/auth/assets/custom-icons/' '/mobile/apps/auth/assets/icons/' '/mobile/apps/auth/macos/Runner/Assets.xcassets/AppIcon.appiconset/'
if [ "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null)" != "$rev" ]; then
  git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$rev"
  git -C "$dir" checkout -q --detach FETCH_HEAD
fi
echo "vendor/ente at $(git -C "$dir" rev-parse HEAD)"
rev=$(git -C "$dir" ls-tree HEAD mobile/apps/auth/assets/simple-icons | awk '{print $3}')
test -n "$rev"
dir="$root/vendor/simple-icons"
if [ ! -d "$dir/.git" ]; then
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin https://github.com/simple-icons/simple-icons.git
fi
git -C "$dir" sparse-checkout set --no-cone '/icons/' '/_data/simple-icons.json'
if [ "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null)" != "$rev" ]; then
  git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$rev"
  git -C "$dir" checkout -q --detach FETCH_HEAD
fi
echo "vendor/simple-icons at $(git -C "$dir" rev-parse HEAD)"
