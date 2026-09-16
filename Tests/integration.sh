#!/bin/sh
# Starts the real binary on a random port with stub CLIs, then walks pair → status → message → cancel → revoke.
set -eu
ROOT=$(mktemp -d)
PORT=$(( 20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 20000 ))
STUBS="$(pwd)/Tests/stubs"
export PATH="$STUBS:$PATH"
# ProviderService.findExecutable looks in ~/.local/bin and /Applications before PATH, so the stubs are
# also linked into the scratch home that CFFIXED_USER_HOME points at below. Without this a real Codex
# or Claude Code installed on the machine would answer instead of the stubs.
mkdir -p "$ROOT/.local/bin"
ln -s "$STUBS/claude" "$ROOT/.local/bin/claude"
ln -s "$STUBS/codex" "$ROOT/.local/bin/codex"
swift build --scratch-path /tmp/iris-bridge-build >/dev/null
BIN=/tmp/iris-bridge-build/debug/iris-bridge
# CFFIXED_USER_HOME points FileManager.homeDirectoryForCurrentUser at the scratch root.
CFFIXED_USER_HOME="$ROOT" "$BIN" serve --root "$ROOT" --port "$PORT" --no-bonjour >"$ROOT/serve.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
for i in $(seq 1 50); do curl -sk "https://127.0.0.1:$PORT/status" >/dev/null 2>&1 && break; sleep 0.2; done
FP=$(openssl x509 -in "$ROOT/certificate.pem" -outform DER | openssl dgst -sha256 | awk '{print $NF}')
ADMIN=$(cat "$ROOT/admin-token")
CODE=$(curl -sk -X POST -H "Authorization: Bearer $ADMIN" "https://127.0.0.1:$PORT/admin/pair-code" | python3 -c 'import json,sys;print(json.load(sys.stdin)["code"])')
# A pairing code is as good as a pairing until it expires, and the admin and device tokens are as good as
# the helper itself. None of the three may ever reach a file somebody else can read.
# Written as `if grep …; then exit 1; fi` rather than `! grep …`: a pipeline beginning with `!` is exempt
# from `set -e`, so every negated assertion in this file used to be a no-op that reported nothing.
if grep -qF -- "$CODE" "$ROOT/serve.log"; then echo "LEAK: pairing code found in serve.log"; exit 1; fi
if grep -qF -- "$CODE" "$ROOT/logs/bridge.log"; then echo "LEAK: pairing code found in logs/bridge.log"; exit 1; fi
if grep -qF -- "$ADMIN" "$ROOT/serve.log"; then echo "LEAK: admin token found in serve.log"; exit 1; fi
if grep -qF -- "$ADMIN" "$ROOT/logs/bridge.log"; then echo "LEAK: admin token found in logs/bridge.log"; exit 1; fi
# An unauthenticated caller learns the protocol version and whether a provider is ready, and no more: no
# account email, no plan.
PUBLIC=$(curl -sk "https://127.0.0.1:$PORT/status")
printf '%s' "$PUBLIC" | grep -q '"version":2'
if printf '%s' "$PUBLIC" | grep -qF -- 'stub@example.com'; then echo "LEAK: account email found in unauthenticated /status"; exit 1; fi
PROOF=$(printf '%s' "$FP" | openssl dgst -sha256 -hmac "$CODE" | awk '{print $NF}')
TOKEN=$(curl -sk -X POST "https://127.0.0.1:$PORT/pair" -d "{\"deviceName\":\"CI\",\"platform\":\"mac\",\"proof\":\"$PROOF\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
test -n "$TOKEN"
if grep -qF -- "$TOKEN" "$ROOT/serve.log"; then echo "LEAK: device token found in serve.log"; exit 1; fi
if grep -qF -- "$TOKEN" "$ROOT/logs/bridge.log"; then echo "LEAK: device token found in logs/bridge.log"; exit 1; fi
# Asserted before any /message call: if the stubs are not the ones answering, the account email will not be
# the stub's, and the run stops before a prompt reaches a real Claude Code or Codex. The email is in the
# authenticated answer only, which is also what proves the paired device still gets the full picture.
STATUS=$(curl -sk -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/status")
printf '%s' "$STATUS" | grep -q '"version":2'
printf '%s' "$STATUS" | grep -q 'stub@example.com'
curl -sk -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/message" -d '{"id":"m1","provider":"claude","message":"hello"}' | grep -q 'Stub reply.'
curl -sk -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/message" -d '{"id":"m2","provider":"codex","message":"hello"}' | grep -q 'Codex stub.'
curl -sk -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/message" -d '{"id":"m3","provider":"claude","message":"FAIL-PLEASE"}' | grep -q '502'
curl -sk -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/cancel" -d '{"id":"m9"}' | grep -q '"canceled":true'
curl -sk -o /dev/null -w '%{http_code}' -H "Origin: https://evil.example" "https://127.0.0.1:$PORT/status" | grep -q '403'
# Before the app has ever pushed a snapshot, the context tool says so rather than inventing a workspace for
# the agent to plan against.
NO_CONTEXT=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>"$ROOT/mcp.err" <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_get_workspace_context","arguments":{}}}
JSONRPC
)
printf '%s' "$NO_CONTEXT" | grep -q 'No workspace context yet. Open Iris on a paired device.'
printf '%s' "$NO_CONTEXT" | grep -q '"isError":true'
curl -sk -X PUT -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/context" \
  -d '{"creatorName":"Chey","pillars":[{"name":"Craft","detail":"How it is made","isAnchor":true,"weekdays":[2,4]}],"platforms":[{"name":"Instagram","formats":["Reel","Carousel"],"weeklyGoal":3}],"series":[],"creatorContext":"Speaks plainly.","updatedAt":"2026-09-16T10:00:00Z"}' | grep -q '"saved":true'
CONTEXT=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>>"$ROOT/mcp.err" <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_get_workspace_context","arguments":{}}}
JSONRPC
)
printf '%s' "$CONTEXT" | grep -q 'Craft'
printf '%s' "$CONTEXT" | grep -q 'anchor'
printf '%s' "$CONTEXT" | grep -q 'Carousel'
printf '%s' "$CONTEXT" | grep -q 'Speaks plainly.'

# The MCP server, driven the way Claude Code drives it: newline-delimited JSON-RPC on stdin, one answer per
# request on stdout, nothing for the notification, and logs kept off stdout entirely.
MCP_OUT=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>"$ROOT/mcp.err" <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"iris_submit_post","arguments":{"title":"Three shots","pillar":"Craft","platform":"Instagram","format":"Reel","hook":"Do this once","note":"Ready for you."}}}
JSONRPC
)
printf '%s' "$MCP_OUT" | grep -q '"protocolVersion":"2025-06-18"'
printf '%s' "$MCP_OUT" | grep -q 'iris_submit_series'
printf '%s' "$MCP_OUT" | grep -q 'Sent to Iris for review.'
LINES=$(printf '%s\n' "$MCP_OUT" | wc -l | tr -d ' ')
[ "$LINES" = 3 ] || { echo "MCP: expected 3 replies (the notification gets none), got $LINES"; exit 1; }
# A single stray print on stdout breaks the JSON-RPC stream for the whole session, so every line is checked
# to be a JSON object rather than the assertions above merely finding what they looked for somewhere in it.
if printf '%s\n' "$MCP_OUT" | grep -qv '^{'; then echo "MCP: something that is not JSON was written to stdout"; exit 1; fi
# Submitted over loopback, and visible to this Mac's own admin endpoint straight away.
ADMIN_INBOX=$(curl -sk -H "Authorization: Bearer $ADMIN" "https://127.0.0.1:$PORT/admin/inbox")
SUB=$(printf '%s' "$ADMIN_INBOX" | python3 -c 'import json,sys;a=json.load(sys.stdin);print(a[0]["id"] if a else "")')
test -n "$SUB"
printf '%s' "$ADMIN_INBOX" | grep -q '"title":"Three shots"'
# The agent name comes from the MCP client that connected, not from a hard-coded string.
printf '%s' "$ADMIN_INBOX" | grep -q '"agent":"claude-code"'
INBOX_CLI=$("$BIN" inbox --root "$ROOT" --port "$PORT")
printf '%s' "$INBOX_CLI" | grep -q "$SUB"
printf '%s' "$INBOX_CLI" | grep -q 'Three shots'
# A revision of something the helper has never seen is refused before it is submitted, so a typo cannot
# leave a submission in the Inbox pointing at nothing.
REVISE=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>>"$ROOT/mcp.err" <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_revise_submission","arguments":{"id":"sub_zzzzzzzzzzzz","post":{"title":"x","pillar":"Craft","platform":"Instagram","format":"Reel"}}}}
JSONRPC
)
printf '%s' "$REVISE" | grep -q 'That submission was not found.'
printf '%s' "$REVISE" | grep -q '"isError":true'
"$BIN" inbox clear-decided --root "$ROOT" --port "$PORT" | grep -q 'Removed 0 decided submissions older than 30 days.'
test "$(curl -sk -H "Authorization: Bearer $ADMIN" "https://127.0.0.1:$PORT/admin/inbox" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" = 1
ID=$(curl -sk -H "Authorization: Bearer $ADMIN" "https://127.0.0.1:$PORT/admin/devices" | python3 -c 'import json,sys;print(json.load(sys.stdin)["devices"][0]["id"])')
curl -sk -X DELETE -H "Authorization: Bearer $ADMIN" "https://127.0.0.1:$PORT/admin/devices/$ID" | grep -q revoked
curl -sk -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/message" -d '{"provider":"claude","message":"x"}' | grep -q '401'
grep -q "paired device" "$ROOT/logs/bridge.log"
if grep -qF -- "hello" "$ROOT/logs/bridge.log"; then echo "LEAK: prompt text found in logs/bridge.log"; exit 1; fi
if grep -qF -- "hello" "$ROOT/serve.log"; then echo "LEAK: prompt text found in serve.log"; exit 1; fi
echo "integration: ok"
