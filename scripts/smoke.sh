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
#   5. one Claude turn and 6. one Codex turn on the v2 /message endpoint, each skipped when that provider is not
#      installed, is signed out or is at its usage limit;
#   7. the MCP server lists the v3 Iris tools and reaches this helper;
#   9. the v3 stream answers hello with the v3 capability;
#  10. a v3 Claude turn calls an Iris tool (iris_list_posts, on a fictional snapshot this script pushes);
#  11. a v3 approval round trip: Claude is asked to create a Google Calendar event, the approval reaches this
#      script, which denies it, so nothing is created; skipped when Google Calendar is not connected in the
#      Claude account, needs authorizing again there, or Claude's settings pre-allow any MCP tool (a pre-allowed
#      tool never asks);
#  12. the helper restarts and the thread's next turn resumes the same Claude conversation;
#  13. turn.cancel stops a reply and the next turn still knows what was written;
#  14. a v3 Codex turn calls an Iris tool and the next turn resumes, skipped like 6;
#   8. with the helper stopped, an MCP tool says "not running".
# Prints PASS, FAIL or SKIP per step and exits 1 when any step fails. Each provider turn uses a little of the
# owner's plan, like any chat message. A clean run in which steps 10, 12 and 13 ran live records this code so
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
start_helper() {
  if [ -n "${IRIS_BRIDGE_SMOKE_HOME:-}" ]; then
    CFFIXED_USER_HOME="$IRIS_BRIDGE_SMOKE_HOME" "$BIN" serve --root "$ROOT" --port "$PORT" --no-bonjour >>"$ROOT/serve.log" 2>&1 &
  else
    "$BIN" serve --root "$ROOT" --port "$PORT" --no-bonjour >>"$ROOT/serve.log" 2>&1 &
  fi
  PID=$!
  for _ in $(seq 1 50); do curl -sk "$BASE/status" >/dev/null 2>&1 && break; sleep 0.2; done
}
start_helper

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
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"iris_workspace_summary","arguments":{}}}
JSONRPC
)
if printf '%s' "$MCP" | grep -q 'iris_create_post_draft' && printf '%s' "$MCP" | grep -q 'has not shared its workspace'; then
  pass "MCP server lists the v3 Iris tools and reaches this helper"
else fail "MCP server: $MCP"; fi

# 9-14: the v3 stream, as the app uses it.
CLIENT="python3 scripts/v3_smoke_client.py --port $PORT --fingerprint $FP --token $TOKEN"
V3LIVE=0
cat >"$ROOT/smoke-snapshot.json" <<'SNAPSHOT'
{"profileId":"5A0E0000-0000-4000-8000-000000000001","revision":"smoke-1","snapshot":{"schemaVersion":2,"capturedAt":"2026-10-01T09:00:00Z","timeZone":"UTC",
 "creatorName":"Smoke Test","profiles":[{"id":"5A0E0000-0000-4000-8000-000000000001","name":"Smoke Test","handle":"@smoketest","active":true}],
 "pillars":[{"id":"5A0E0000-0000-4000-8000-0000000000B1","name":"Testing","detail":"","isAnchor":true,"weekdays":[2]}],
 "platforms":[{"name":"Instagram","formats":["Reel"],"weeklyGoal":1}],
 "posts":[{"id":"5A0E0000-0000-4000-8000-0000000000A1","revision":"r1","title":"Smoke test post","stage":"drafted","pillar":"Testing",
           "platform":"Instagram","format":"Reel","date":"2030-01-01","archived":false,"hook":"","script":"","caption":"","cta":"","notes":"","scenes":[]}],
 "tasks":[],"ideas":[],"series":[],"focusThemes":[],"reviewItems":[]}}
SNAPSHOT

# 9
HELLO=$($CLIENT hello 2>&1 || true)
if printf '%s' "$HELLO" | field capabilities | grep -q 'v3'; then pass "v3 stream says hello with the v3 capability"
else fail "v3 hello: $HELLO"; fi
$CLIENT push-snapshot "$ROOT/smoke-snapshot.json" >/dev/null 2>&1 || fail "v3 snapshot push"

# 10-13 need Claude signed in and not at its usage limit.
ready() {
  P=$1
  if [ "$(printf '%s' "$STATUS" | field "health.$P.installed")" != true ]; then echo "not installed on this Mac"; return; fi
  if [ "$(printf '%s' "$STATUS" | field "health.$P.signedIn")" != true ]; then echo "signed out"; return; fi
  if [ "$(printf '%s' "$STATUS" | field "health.$P.usage")" = limited ]; then echo "usage limit until $(printf '%s' "$STATUS" | field "health.$P.resetsAt")"; fi
}
THREAD=$(uuidgen)
turn3() { $CLIENT turn --thread "$THREAD" --provider claude --model haiku "$@" 2>&1 || true; }
NOT_READY=$(ready claude)
if [ -n "$NOT_READY" ]; then
  for step in "v3 Claude turn calls an Iris tool" "v3 approval round trip" "v3 resume after a helper restart" "v3 cancel"; do skip "$step: Claude $NOT_READY"; done
else
  # 10
  TOOL=$(turn3 --text "Use the iris_list_posts tool once with no arguments, then reply with only the title of the first post it returns.")
  if [ "$(printf '%s' "$TOOL" | field end)" = turn.completed ] && printf '%s' "$TOOL" | field toolsOk | grep -q 'iris_list_posts' \
     && printf '%s' "$TOOL" | field text | grep -q 'Smoke test post'; then
    pass "v3 Claude turn calls an Iris tool"; V3LIVE=$((V3LIVE + 1))
  else fail "v3 Claude tool call: $TOOL"; fi

  # 11
  HEALTH=$($CLIENT hello 2>&1 || true)
  CONNECTED=$(printf '%s' "$HEALTH" | python3 -c 'import json, sys
try:
    claude = json.load(sys.stdin)["health"]["claude"]
except Exception:
    sys.exit(0)
print(",".join(c["name"] for c in claude.get("connectors", []) if c.get("status") == "connected"))')
  PREALLOWED=$(printf '%s' "$HEALTH" | field health.claude.preAllowedTools)
  if ! printf '%s' "$CONNECTED" | grep -q 'Google Calendar'; then skip "v3 approval round trip: Google Calendar is not connected in the Claude account"
  elif [ -n "$PREALLOWED" ]; then skip "v3 approval round trip: Claude's settings pre-allow MCP tools ($PREALLOWED), so a write might not ask"
  else
    APPROVAL=$(turn3 --text "Use the Google Calendar create_event tool to create an event titled 'Iris smoke test (deny me)' on 2030-01-02 at 09:00. If it is denied, reply with only the word DENIED.")
    if [ "$(printf '%s' "$APPROVAL" | field end)" = turn.completed ] && printf '%s' "$APPROVAL" | field approvalKinds | grep -q 'connectorWrite' \
       && ! printf '%s' "$APPROVAL" | field toolsOk | grep -q 'create_event'; then
      pass "v3 approval round trip denies a connector write"
    elif [ -z "$(printf '%s' "$APPROVAL" | field tools)" ] && printf '%s' "$APPROVAL" | field text | grep -qi 'needs to be authorized'; then
      # The account lists Google Calendar, but Claude reports it needs authorizing again before any tool runs, so
      # no write was attempted and there is nothing to approve: the same as not connected.
      skip "v3 approval round trip: Google Calendar needs authorizing again in the Claude account"
    else fail "v3 approval round trip: $APPROVAL"; fi
  fi

  # 12
  turn3 --text "Remember the code word PLUM-7. Reply with only OK." >/dev/null
  kill "$PID"; wait "$PID" 2>/dev/null || true
  start_helper
  RECALL=$(turn3 --text "What was the code word I asked you to remember? Reply with only the code word.")
  if printf '%s' "$RECALL" | field text | grep -q 'PLUM-7'; then pass "v3 resume after a helper restart keeps the conversation"; V3LIVE=$((V3LIVE + 1))
  else fail "v3 resume after a helper restart: $RECALL"; fi

  # 13
  COUNT=$(turn3 --cancel-after-first-delta --text "Count from 1 to 300, one number per line, nothing else.")
  LAST=$(turn3 --text "What was the last number you wrote in your previous reply? Reply with only that number, or NONE.")
  if [ "$(printf '%s' "$COUNT" | field cause)" = cancelled ] && printf '%s' "$LAST" | field text | grep -Eq '^[0-9]+'; then
    pass "v3 cancel stops the turn and keeps what was written"; V3LIVE=$((V3LIVE + 1))
  else fail "v3 cancel: $COUNT | $LAST"; fi
fi

# 14
NOT_READY=$(ready codex)
if [ -n "$NOT_READY" ]; then skip "v3 Codex turn: Codex $NOT_READY"
else
  CTHREAD=$(uuidgen)
  FIRST=$($CLIENT turn --thread "$CTHREAD" --provider codex --text "Use the iris_list_posts tool from the iris MCP server once, then reply with only the title of the first post it returns." 2>&1 || true)
  if [ "$(printf '%s' "$FIRST" | field cause)" = usageLimit ]; then skip "v3 Codex turn: $(printf '%s' "$FIRST" | field message)"
  else
    NEXT=$($CLIENT turn --thread "$CTHREAD" --provider codex --text "What did I ask you in my previous message? Reply in ten words or fewer." 2>&1 || true)
    if [ "$(printf '%s' "$FIRST" | field end)" = turn.completed ] && printf '%s' "$FIRST" | field toolsOk | grep -q 'iris_list_posts' \
       && [ "$(printf '%s' "$NEXT" | field end)" = turn.completed ]; then
      pass "v3 Codex turn calls an Iris tool and resumes"
    else fail "v3 Codex turn: $FIRST | $NEXT"; fi
  fi
fi

# 8
kill "$PID"; wait "$PID" 2>/dev/null || true; PID=""
DOWN=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>/dev/null <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_workspace_summary","arguments":{}}}
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
if [ "$LIVE" = 0 ] || [ "$V3LIVE" != 3 ]; then
  echo "smoke: ok, but the Claude turns did not all run live (v2 turns: $LIVE, v3 Claude steps: $V3LIVE of 3). Sign in to Claude (claude auth login) or wait for its usage limit to reset, then run it again; scripts/release.sh will not tag this code until they pass."
  exit 0
fi
if [ -n "$(git status --porcelain -- Package.swift Sources)" ]; then
  echo "smoke: ok, but Package.swift or Sources has uncommitted changes, so nothing was recorded for scripts/release.sh."
  exit 0
fi
CODE_ID=$(git ls-tree -r HEAD -- Package.swift Sources | shasum -a 256 | awk '{print $1}')
mkdir -p /tmp/iris-bridge-smoke
git rev-parse HEAD > "/tmp/iris-bridge-smoke/$CODE_ID.ok"
echo "smoke: ok ($LIVE live v2 turn(s), $V3LIVE live v3 Claude steps; recorded code $CODE_ID for scripts/release.sh)"
