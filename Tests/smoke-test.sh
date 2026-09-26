#!/bin/sh
# Runs scripts/smoke.sh against the stub CLIs, so the smoke script itself is checked without a live sign-in.
set -eu
HOME_DIR=$(mktemp -d); trap 'rm -rf "$HOME_DIR"' EXIT
mkdir -p "$HOME_DIR/.local/bin"
ln -s "$(pwd)/Tests/stubs/claude" "$HOME_DIR/.local/bin/claude"
ln -s "$(pwd)/Tests/stubs/codex" "$HOME_DIR/.local/bin/codex"
OUT=$(IRIS_BRIDGE_SMOKE_HOME="$HOME_DIR" sh scripts/smoke.sh 2>&1) || { printf '%s\n' "$OUT"; echo "smoke-test: smoke.sh failed against the stubs"; exit 1; }
for step in "status without a token" "status with a device token" "status with an unknown token" "iris-bridge status prints" \
            "claude turn answered" "codex turn answered" "MCP server lists the v3 Iris tools" "v3 stream says hello" \
            "v3 Claude turn calls an Iris tool" "v3 approval round trip denies a connector write" \
            "v3 resume after a helper restart keeps the conversation" "v3 cancel stops the turn" \
            "v3 Codex turn calls an Iris tool and resumes" "MCP says not running"; do
  printf '%s' "$OUT" | grep -q "PASS  $step" || { printf '%s\n' "$OUT"; echo "smoke-test: no PASS for \"$step\""; exit 1; }
done
printf '%s' "$OUT" | grep -q '^smoke: ok (stub CLIs)$' || { printf '%s\n' "$OUT"; echo "smoke-test: missing the stub summary line"; exit 1; }
echo "smoke-test: ok"
