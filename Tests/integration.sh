#!/bin/sh
# Starts the real binary on a random port with stub CLIs, then walks pair → status → message → cancel → revoke.
set -eu
ROOT=$(mktemp -d)
PORT=$(( 20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 20000 ))
# Nothing in 0.3.0 creates v2 submissions; the v2 Inbox serves what 0.2.x saved. Two of those, one with a title
# an agent wrote with a newline and a colour escape in it, are on disk before the helper starts.
cat >"$ROOT/inbox.json" <<'INBOX'
[{"agent":"claude-code","createdAt":"2026-09-16T10:00:00Z","id":"sub_aaaaaaaaaaaa","kind":"post","note":"Ready for you.","post":{"format":"Reel","hook":"Do this once","pillar":"Craft","platform":"Instagram","title":"Three shots"},"status":"pending"},
 {"agent":"claude-code","createdAt":"2026-09-16T10:05:00Z","id":"sub_bbbbbbbbbbbb","kind":"post","post":{"format":"Reel","pillar":"Craft","platform":"Instagram","title":"Two\nlines\u001b[31m here"},"status":"pending"}]
INBOX
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
# 0.2.5: the paired device's /status also says it is paired, what this helper can do and how each provider is,
# and none of that reaches a caller without a token. A token that matches nothing is refused (contract §2).
printf '%s' "$STATUS" | grep -q '"paired":true'
printf '%s' "$STATUS" | grep -q '"authStatus"'
printf '%s' "$STATUS" | grep -q '"cliVersion":"9.9.9"'
if printf '%s' "$PUBLIC" | grep -qF -- '"health"'; then echo "LEAK: health in unauthenticated /status"; exit 1; fi
curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer not-a-token" "https://127.0.0.1:$PORT/status" | grep -q '401'
curl -sk -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/message" -d '{"id":"m1","provider":"claude","message":"hello"}' | grep -q 'Stub reply.'
curl -sk -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/message" -d '{"id":"m2","provider":"codex","message":"hello"}' | grep -q 'Codex stub.'
# A failed turn keeps its 502 and now says why, in the provider's own words (I1).
FAILED=$(curl -sk -w '\n%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/message" -d '{"id":"m3","provider":"claude","message":"FAIL-PLEASE"}')
printf '%s\n' "$FAILED" | tail -1 | grep -q '^502$'
printf '%s' "$FAILED" | grep -q '"cause":"usageLimit"'
printf '%s' "$FAILED" | grep -q '"provider":"claude"'
printf '%s' "$FAILED" | grep -q 'session limit'
curl -sk -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/cancel" -d '{"id":"m9"}' | grep -q '"canceled":true'
curl -sk -o /dev/null -w '%{http_code}' -H "Origin: https://evil.example" "https://127.0.0.1:$PORT/status" | grep -q '403'
# Before the app has ever pushed anything, the read tools say so rather than inventing a workspace for the
# agent to plan against.
NO_CONTEXT=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>"$ROOT/mcp.err" <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_workspace_summary","arguments":{}}}
JSONRPC
)
printf '%s' "$NO_CONTEXT" | grep -q 'Iris has not shared its workspace with this Mac yet.'
printf '%s' "$NO_CONTEXT" | grep -q '"isError":true'
# An app older than the v3 chat pushes its v2 context; the read tools answer from it.
curl -sk -X PUT -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/context" \
  -d '{"creatorName":"Chey","pillars":[{"name":"Craft","detail":"How it is made","isAnchor":true,"weekdays":[2,4]}],"platforms":[{"name":"Instagram","formats":["Reel","Carousel"],"weeklyGoal":3}],"series":[],"creatorContext":"Speaks plainly.","updatedAt":"2026-09-16T10:00:00Z"}' | grep -q '"saved":true'
CONTEXT=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>>"$ROOT/mcp.err" <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_workspace_summary","arguments":{}}}
JSONRPC
)
printf '%s' "$CONTEXT" | grep -q 'Craft'
printf '%s' "$CONTEXT" | grep -q 'anchor'
printf '%s' "$CONTEXT" | grep -q 'Carousel'
printf '%s' "$CONTEXT" | grep -q 'Speaks plainly.'

# The MCP server, driven the way Claude Code drives it: newline-delimited JSON-RPC on stdin, one answer per
# request on stdout, nothing for the notification, and logs kept off stdout entirely. With no app connected, a
# change waits on this Mac.
MCP_OUT=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>"$ROOT/mcp.err" <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"iris_create_task","arguments":{"title":"Film the intro"}}}
JSONRPC
)
printf '%s' "$MCP_OUT" | grep -q '"protocolVersion":"2025-06-18"'
printf '%s' "$MCP_OUT" | grep -q 'iris_create_post_draft'
if printf '%s' "$MCP_OUT" | grep -q 'iris_submit_post'; then echo "MCP: a v0.2.x tool name is still listed"; exit 1; fi
if printf '%s' "$MCP_OUT" | grep -q '"name":"approval"'; then echo "MCP: a terminal agent was offered the approval tool"; exit 1; fi
printf '%s' "$MCP_OUT" | grep -q 'queued_until_iris_connects'
LINES=$(printf '%s\n' "$MCP_OUT" | wc -l | tr -d ' ')
[ "$LINES" = 3 ] || { echo "MCP: expected 3 replies (the notification gets none), got $LINES"; exit 1; }
# A single stray print on stdout breaks the JSON-RPC stream for the whole session, so every line is checked
# to be a JSON object rather than the assertions above merely finding what they looked for somewhere in it.
if printf '%s\n' "$MCP_OUT" | grep -qv '^{'; then echo "MCP: something that is not JSON was written to stdout"; exit 1; fi
# The change waits in actions.json, attributed to the agent that connected.
grep -q '"name":"iris_create_task"' "$ROOT/actions.json"
grep -q '"agent":"claude"' "$ROOT/actions.json"
# A chat session's MCP server (started with --thread) also lists the approval tool; a bad thread id is refused.
"$BIN" mcp --root "$ROOT" --port "$PORT" --thread 8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77 2>/dev/null <<'JSONRPC' | grep -q '"name":"approval"'
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
JSONRPC
if "$BIN" mcp --root "$ROOT" --port "$PORT" --thread ../x </dev/null >/dev/null 2>&1; then echo "mcp accepted a bad --thread"; exit 1; fi
# The saved v2 Inbox is still listed, one line per submission whatever an agent put in its title.
INBOX_CLI=$("$BIN" inbox --root "$ROOT" --port "$PORT")
printf '%s' "$INBOX_CLI" | grep -q 'sub_aaaaaaaaaaaa'
printf '%s' "$INBOX_CLI" | grep -q 'Three shots'
printf '%s' "$INBOX_CLI" | grep -q 'Two lines here'
INBOX_LINES=$(printf '%s\n' "$INBOX_CLI" | wc -l | tr -d ' ')
[ "$INBOX_LINES" = 2 ] || { echo "inbox: expected one line per submission, got $INBOX_LINES"; exit 1; }
"$BIN" inbox clear-decided --root "$ROOT" --port "$PORT" | grep -q 'Removed 0 decided submissions older than 30 days.'
test "$(curl -sk -H "Authorization: Bearer $ADMIN" "https://127.0.0.1:$PORT/admin/inbox" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" = 2
ID=$(curl -sk -H "Authorization: Bearer $ADMIN" "https://127.0.0.1:$PORT/admin/devices" | python3 -c 'import json,sys;print(json.load(sys.stdin)["devices"][0]["id"])')
curl -sk -X DELETE -H "Authorization: Bearer $ADMIN" "https://127.0.0.1:$PORT/admin/devices/$ID" | grep -q revoked
curl -sk -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/message" -d '{"provider":"claude","message":"x"}' | grep -q '401'
grep -q "paired device" "$ROOT/logs/bridge.log"
if grep -qF -- "hello" "$ROOT/logs/bridge.log"; then echo "LEAK: prompt text found in logs/bridge.log"; exit 1; fi
if grep -qF -- "hello" "$ROOT/serve.log"; then echo "LEAK: prompt text found in serve.log"; exit 1; fi
# I7: the agent hears "not set up" for a folder nothing was ever installed in, and "not running" once the helper
# has stopped, rather than one sentence for both.
EMPTY=$(mktemp -d)
NOT_SET_UP=$("$BIN" mcp --root "$EMPTY" --port "$PORT" 2>/dev/null <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_workspace_summary","arguments":{}}}
JSONRPC
)
printf '%s' "$NOT_SET_UP" | grep -q 'not set up on this Mac'
kill "$PID"; wait "$PID" 2>/dev/null || true
NOT_RUNNING=$("$BIN" mcp --root "$ROOT" --port "$PORT" 2>/dev/null <<'JSONRPC'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_workspace_summary","arguments":{}}}
JSONRPC
)
printf '%s' "$NOT_RUNNING" | grep -q 'Iris Bridge is not running.'
echo "integration: ok"
