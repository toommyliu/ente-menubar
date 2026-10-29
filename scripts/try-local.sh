#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
app_path="$(./scripts/app.sh | tail -1)"
cargo build --locked --manifest-path rust/Cargo.toml -p ente-devserver
work="$(mktemp -d)"
rust/target/debug/ente-devserver >"$work/server.json" &
server=$!
cleanup() {
    [[ -n "${app:-}" ]] && kill "$app" 2>/dev/null
    kill "$server" 2>/dev/null
    security delete-generic-password -s dev.entemenubar.EnteMenubar.local -a session >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Application Support/EnteMenubar/local" "$work"
}
trap cleanup EXIT
until grep -q endpoint "$work/server.json" 2>/dev/null; do sleep 1; done
endpoint="$(python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).readline()); print(d["endpoint"]); print("Email:    " + d["email"], file=sys.stderr); print("Password: " + d["password"], file=sys.stderr)' "$work/server.json")"
ENTE_MENUBAR_API_ORIGIN="$endpoint" ENTE_MENUBAR_PROFILE=local "$app_path/Contents/MacOS/EnteMenubar" &
app=$!
echo "The app is in the menu bar, pointed at a local server with its own Keychain item. Press Ctrl-C to stop."
wait "$app"
