#!/bin/sh
# Live smoke test for an Iris Bridge release. Run it on the owner's Mac before every scripts/release.sh:
#
#   sh scripts/smoke.sh
#
# It builds this checkout and starts a SECOND helper on a random port with its own scratch folder. The
# installed helper on port 48731 keeps running and is never touched. It pairs a throwaway device, then checks:
#   1. /status without a token keeps the 0.2.4 shape;
#   2. /status with the device token adds paired, capabilities and health for both providers;
#   3. /status with a token that matches nothing is refused as deviceRevoked;
#   4. `iris-bridge status` prints health and the addresses this Mac answers on;
#   5. one Claude turn and 6. one Codex turn with a trivial prompt, each skipped when that provider is not
#      installed, is signed out or is at its usage limit;
#   7. the MCP server lists the Iris tools and reaches this helper;
#   8. with the helper stopped, an MCP tool says "not running".
# Prints PASS, FAIL or SKIP per step and exits 1 when any step fails. Each provider turn uses a little of the
# owner's plan, like any chat message. A clean run with at least one live turn records this code so
# scripts/release.sh will tag it. IRIS_BRIDGE_SMOKE_HOME=<dir> runs against stub CLIs linked in
# <dir>/.local/bin instead (Tests/smoke-test.sh) and records nothing.
set -eu
cd "$(dirname "$0")/.."

SCRATCH=/tmp/iris-bridge-build
ROOT=$(mktemp -d)
PORT=$(( 20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 20000 ))
BASE="https://127.0.0.1:$PORT"
FAILED=0
LIVE=0
PID=""
cleanup() { if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi; rm -rf "$ROOT"; }
trap cleanup EXIT

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
skip() { echo "SKIP  $1"; }
# One value from a JSON document on stdin, by dotted path ("health.claude.usage"). Prints nothing for a missing
# path or a body that is not JSON; booleans print as true/false, lists as a,b,c, objects as "present".
field() {
  python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for key in sys.argv[1].split("."):
    value = value.get(key) if isinstance(value, dict) else None
if value is None:
    sys.exit(0)
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, list):
    print(",".join(str(item) for item in value))
elif isinstance(value, dict):
    print("present")
else:
    print(value)
' "$1"
}

swift build --scratch-path "$SCRATCH" >/dev/null
BIN="$SCRATCH/debug/iris-bridge"
if [ -n "${IRIS_BRIDGE_SMOKE_HOME:-}" ]; then
  CFFIXED_USER_HOME="$IRIS_BRIDGE_SMOKE_HOME" "$BIN" serve --root "$ROOT" --port "$PORT" --no-bonjour >"$ROOT/serve.log" 2>&1 &
else
  "$BIN" serve --root "$ROOT" --port "$PORT" --no-bonjour >"$ROOT/serve.log" 2>&1 &
fi
PID=$!
for _ in $(seq 1 50); do curl -sk "$BASE/status" >/dev/null 2>&1 && break; sleep 0.2; done

ADMIN=$(cat "$ROOT/admin-token")
FP=$(openssl x509 -in "$ROOT/certificate.pem" -outform DER | openssl dgst -sha256 | awk '{print $NF}')
CODE=$(curl -sk -X POST -H "Authorization: Bearer $ADMIN" "$BASE/admin/pair-code" | field code)
PROOF=$(printf '%s' "$FP" | openssl dgst -sha256 -hmac "$CODE" | awk '{print $NF}')
TOKEN=$(curl -sk -X POST "$BASE/pair" -d "{\"deviceName\":\"Smoke test\",\"platform\":\"mac\",\"proof\":\"$PROOF\"}" | field token)
if [ -z "$TOKEN" ]; then echo "FAIL  pairing a throwaway device"; cat "$ROOT/serve.log"; exit 1; fi

# 1
PUBLIC=$(curl -sk "$BASE/status")
if [ "$(printf '%s' "$PUBLIC" | field version)" = 2 ] && [ -z "$(printf '%s' "$PUBLIC" | field health)" ] \
   && [ -z "$(printf '%s' "$PUBLIC" | field paired)" ]; then
  pass "status without a token keeps the 0.2.4 shape"
else fail "status without a token: $PUBLIC"; fi

# 2
STATUS=$(curl -sk -H "Authorization: Bearer $TOKEN" "$BASE/status")
if [ "$(printf '%s' "$STATUS" | field paired)" = true ] && printf '%s' "$STATUS" | field capabilities | grep -q health \
   && [ "$(printf '%s' "$STATUS" | field health.claude)" = present ] && [ "$(printf '%s' "$STATUS" | field health.codex)" = present ]; then
  pass "status with a device token adds paired, capabilities and health"
else fail "status with a device token: $STATUS"; fi
for P in claude codex; do
  echo "      $P: installed=$(printf '%s' "$STATUS" | field "health.$P.installed") signedIn=$(printf '%s' "$STATUS" | field "health.$P.signedIn") plan=$(printf '%s' "$STATUS" | field "health.$P.account") cli=$(printf '%s' "$STATUS" | field "health.$P.cliVersion") usage=$(printf '%s' "$STATUS" | field "health.$P.usage")"
done

# 3
REVOKED=$(curl -sk -w '\n%{http_code}' -H "Authorization: Bearer not-a-device" "$BASE/status")
if [ "$(printf '%s\n' "$REVOKED" | tail -1)" = 401 ] && [ "$(printf '%s\n' "$REVOKED" | sed '$d' | field cause)" = deviceRevoked ]; then
  pass "status with an unknown token is refused as deviceRevoked"
else fail "status with an unknown token: $REVOKED"; fi

# 4
REPORT=$("$BIN" status --root "$ROOT" --port "$PORT" 2>&1 || true)
if printf '%s' "$REPORT" | grep -q 'reach this Mac at' && printf '%s' "$REPORT" | grep -q 'CLI '; then
  pass "iris-bridge status prints health and addresses"
else fail "iris-bridge status: $REPORT"; fi

# 5, 6
turn() {
  P=$1
  if [ "$(printf '%s' "$STATUS" | field "health.$P.installed")" != true ]; then skip "$P turn: not installed on this Mac"; return; fi
  if [ "$(printf '%s' "$STATUS" | field "health.$P.signedIn")" != true ]; then skip "$P turn: signed out"; return; fi
  if [ "$(printf '%s' "$STATUS" | field "health.$P.usage")" = limited ]; then
    skip "$P turn: usage limit until $(printf '%s' "$STATUS" | field "health.$P.resetsAt")"; return
  fi
  REPLY=$(curl -sk --max-time 300 -w '\n%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" "$BASE/message" \
    -d "{\"id\":\"smoke-$P-$$\",\"provider\":\"$P\",\"message\":\"Reply with the single word ok.\",\"planMode\":true}")
  HTTP=$(printf '%s\n' "$REPLY" | tail -1)
  BODY=$(printf '%s\n' "$REPLY" | sed '$d')
  if [ "$HTTP" = 200 ] && [ -n "$(printf '%s' "$BODY" | field reply)" ]; then
    pass "$P turn answered with model $(printf '%s' "$BODY" | field model)"
    LIVE=$((LIVE + 1))
  elif [ "$(printf '%s' "$BODY" | field cause)" = usageLimit ]; then
    skip "$P turn: $(printf '%s' "$BODY" | field error)"
  else
    fail "$P turn: HTTP $HTTP, cause $(printf '%s' "$BODY" | field cause): $(printf '%s' "$BODY" | field error) | $(printf '%s' "$BODY" | field details)"
  fi
}
turn claude
turn codex

# 7
MCP=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>/dev/null <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"smoke","version":"1"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"iris_get_workspace_context","arguments":{}}}
JSONRPC
)
if printf '%s' "$MCP" | grep -q 'iris_propose_archive_posts' && printf '%s' "$MCP" | grep -q 'No workspace context yet'; then
  pass "MCP server lists the Iris tools and reaches this helper"
else fail "MCP server: $MCP"; fi

# 8
kill "$PID"; wait "$PID" 2>/dev/null || true; PID=""
DOWN=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>/dev/null <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_get_workspace_context","arguments":{}}}
JSONRPC
)
if printf '%s' "$DOWN" | grep -q 'Iris Bridge is not running.'; then pass "MCP says not running once the helper stops"
else fail "MCP with the helper stopped: $DOWN"; fi

if [ "$FAILED" != 0 ]; then
  cp "$ROOT/logs/bridge.log" /tmp/iris-bridge-smoke-bridge.log 2>/dev/null || true
  echo "smoke: FAILED (the scratch helper's log is at /tmp/iris-bridge-smoke-bridge.log)"
  exit 1
fi
if [ -n "${IRIS_BRIDGE_SMOKE_HOME:-}" ]; then echo "smoke: ok (stub CLIs)"; exit 0; fi
if [ "$LIVE" = 0 ]; then
  echo "smoke: ok, but no provider turn ran live. Sign in to Claude (claude auth login) or wait for a usage limit to reset, then run it again; scripts/release.sh will not tag this code until one turn passes."
  exit 0
fi
if [ -n "$(git status --porcelain -- Package.swift Sources)" ]; then
  echo "smoke: ok, but Package.swift or Sources has uncommitted changes, so nothing was recorded for scripts/release.sh."
  exit 0
fi
CODE_ID=$(git ls-tree -r HEAD -- Package.swift Sources | shasum -a 256 | awk '{print $1}')
mkdir -p /tmp/iris-bridge-smoke
git rev-parse HEAD > "/tmp/iris-bridge-smoke/$CODE_ID.ok"
echo "smoke: ok ($LIVE live turn(s); recorded code $CODE_ID for scripts/release.sh)"
