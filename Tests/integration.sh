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
ID=$(curl -sk -H "Authorization: Bearer $ADMIN" "https://127.0.0.1:$PORT/admin/devices" | python3 -c 'import json,sys;print(json.load(sys.stdin)["devices"][0]["id"])')
curl -sk -X DELETE -H "Authorization: Bearer $ADMIN" "https://127.0.0.1:$PORT/admin/devices/$ID" | grep -q revoked
curl -sk -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/message" -d '{"provider":"claude","message":"x"}' | grep -q '401'
grep -q "paired device" "$ROOT/logs/bridge.log"
if grep -qF -- "hello" "$ROOT/logs/bridge.log"; then echo "LEAK: prompt text found in logs/bridge.log"; exit 1; fi
if grep -qF -- "hello" "$ROOT/serve.log"; then echo "LEAK: prompt text found in serve.log"; exit 1; fi
echo "integration: ok"
