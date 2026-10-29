#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
profile="${1:-debug}"
case "$profile" in
    debug) cargo_profile=dev ;;
    release) cargo_profile=release ;;
    *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac
./scripts/upstream.sh
cargo build --locked --manifest-path rust/Cargo.toml -p ente-bridge --target aarch64-apple-darwin --profile "$cargo_profile"
cargo build --locked --manifest-path rust/Cargo.toml -p uniffi-bindgen
binding_dir="$repo_dir/.build/bindings"
header_dir="$binding_dir/headers"
mkdir -p "$header_dir" apple/EnteBridge/Frameworks apple/EnteBridge/Sources/EnteBridge
(
    cd rust
    target/debug/uniffi-bindgen generate \
        "target/aarch64-apple-darwin/$profile/libente_bridge.dylib" \
        --language swift --out-dir "$binding_dir"
)
swift_out=apple/EnteBridge/Sources/EnteBridge/EnteBridge.swift
cmp -s "$binding_dir/EnteBridge.swift" "$swift_out" || cp "$binding_dir/EnteBridge.swift" "$swift_out"
cp "$binding_dir/EnteBridgeFFI.h" "$header_dir/EnteBridgeFFI.h"
cp "$binding_dir/EnteBridgeFFI.modulemap" "$header_dir/module.modulemap"
library="$repo_dir/rust/target/aarch64-apple-darwin/$profile/libente_bridge.a"
framework_dir="$repo_dir/apple/EnteBridge/Frameworks/EnteBridgeFFI.xcframework"
stamp="$(cat "$library" "$header_dir/EnteBridgeFFI.h" "$header_dir/module.modulemap" | shasum)"
if [[ -d "$framework_dir" && "$(cat "$binding_dir/xcframework.stamp" 2>/dev/null)" == "$stamp" ]]; then
    exit 0
fi
rm -rf "$framework_dir"
xcodebuild -create-xcframework -library "$library" -headers "$header_dir" -output "$framework_dir"
printf '%s\n' "$stamp" >"$binding_dir/xcframework.stamp"
