#!/bin/sh
# Iris Bridge installer. Usage: curl -fsSL https://raw.githubusercontent.com/cheycoulbourn/iris-bridge/main/install.sh | sh -s -- [--claude|--codex]
set -eu
REPO="cheycoulbourn/iris-bridge"
SUPPORT="$HOME/Library/Application Support/Iris Bridge"
BIN_DIR="$SUPPORT/bin"
BIN="$BIN_DIR/iris-bridge"
PROVIDER=""
for arg in "$@"; do case "$arg" in --claude) PROVIDER=claude;; --codex) PROVIDER=codex;; esac; done
say() { printf '\033[1m%s\033[0m\n' "$1"; }
[ "$(id -u)" -eq 0 ] && { echo "Run this as your normal user, not with sudo."; exit 1; }
[ "$(uname -s)" = "Darwin" ] || { echo "Iris Bridge runs on macOS only."; exit 1; }
ARCH=$(uname -m); case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported Mac: $ARCH"; exit 1;; esac

say "1/5 Downloading Iris Bridge"
mkdir -p "$BIN_DIR"; chmod 700 "$SUPPORT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [ -n "${IRIS_BRIDGE_LOCAL_TARBALL:-}" ]; then
  cp "$IRIS_BRIDGE_LOCAL_TARBALL" "$TMP/bridge.tar.gz"; cp "$IRIS_BRIDGE_LOCAL_TARBALL.sha256" "$TMP/bridge.tar.gz.sha256"
else
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$TAG" ] || { echo "Could not find the latest Iris Bridge release."; exit 1; }
  URL="https://github.com/$REPO/releases/download/$TAG/iris-bridge-${TAG#v}-macos.tar.gz"
  curl -fsSL "$URL" -o "$TMP/bridge.tar.gz"; curl -fsSL "$URL.sha256" -o "$TMP/bridge.tar.gz.sha256"
fi
EXPECTED=$(awk '{print $1}' "$TMP/bridge.tar.gz.sha256"); ACTUAL=$(shasum -a 256 "$TMP/bridge.tar.gz" | awk '{print $1}')
[ "$EXPECTED" = "$ACTUAL" ] || { echo "Download did not verify. Try again."; exit 1; }
tar -xzf "$TMP/bridge.tar.gz" -C "$TMP"; install -m 755 "$TMP/iris-bridge" "$BIN"
mkdir -p "$HOME/.local/bin" 2>/dev/null && ln -sf "$BIN" "$HOME/.local/bin/iris-bridge" || true

say "2/5 Checking your AI"
has() { [ -x "$HOME/.local/bin/$1" ] || command -v "$1" >/dev/null 2>&1; }
if [ -z "$PROVIDER" ]; then
  if has claude && ! has codex; then PROVIDER=claude
  elif has codex && ! has claude; then PROVIDER=codex
  elif has claude && has codex; then PROVIDER=claude
  else
    printf 'Which do you use? [1] Claude  [2] ChatGPT/Codex: '; read -r CHOICE </dev/tty
    [ "$CHOICE" = "2" ] && PROVIDER=codex || PROVIDER=claude
  fi
fi
if [ "$PROVIDER" = claude ]; then
  has claude || { echo "Installing Claude Code…"; curl -fsSL https://claude.ai/install.sh | bash; }
  CLI="$HOME/.local/bin/claude"; [ -x "$CLI" ] || CLI=$(command -v claude)
  say "3/5 Signing in to Claude"
  if ! "$CLI" auth status --json 2>/dev/null | grep -q '"loggedIn": *true'; then "$CLI" auth login </dev/tty; fi
else
  has codex || { echo "Installing Codex…"; curl -fsSL https://chatgpt.com/codex/install.sh | sh; }
  CLI="$HOME/.local/bin/codex"; [ -x "$CLI" ] || CLI=$(command -v codex)
  say "3/5 Signing in to ChatGPT"
  if ! "$CLI" login status 2>&1 | grep -qi chatgpt; then "$CLI" login </dev/tty; fi
fi

say "4/5 Starting Iris Bridge"
"$BIN" install-agent --binary "$BIN"
for i in $(seq 1 40); do "$BIN" status >/dev/null 2>&1 && break; sleep 0.25; done
"$BIN" status >/dev/null 2>&1 || { echo "Iris Bridge did not start. See ~/Library/Logs/Iris Bridge/launchd.log"; exit 1; }

say "5/5 Ready to pair"
"$BIN" pair
