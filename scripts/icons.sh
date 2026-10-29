#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
./scripts/upstream.sh
output="$repo_dir/apple/AppCore/Sources/AppCore/GeneratedIcons"
stamp="$( { cat UPSTREAM_REV scripts/icons.sh scripts/generate-icons.swift; git -C vendor/simple-icons rev-parse HEAD; } | shasum -a 256)"
if [[ -f "$output/catalog.json" && "$(cat "$output/.stamp" 2>/dev/null)" == "$stamp" ]]; then
    echo 'Icon catalog is current'
    exit 0
fi
mkdir -p "$repo_dir/.build"
temporary="$(mktemp -d "$repo_dir/.build/icons.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
swiftc -O scripts/generate-icons.swift -o "$temporary/generate-icons"
mkdir "$temporary/catalog"
"$temporary/generate-icons" "$repo_dir" "$temporary/catalog"
printf '%s\n' "$stamp" > "$temporary/catalog/.stamp"
rm -rf "$output"
mv "$temporary/catalog" "$output"
