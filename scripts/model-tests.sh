#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
./scripts/bindings.sh
cargo build --locked --manifest-path rust/Cargo.toml -p ente-devserver
cd apple/AppCore
swift test
