#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
./scripts/icons.sh
swift run --package-path apple/AppCore snapshots "$repo_dir/.build/snapshots"
