#!/bin/sh
# Iris Bridge installer. Usage: curl -fsSL https://raw.githubusercontent.com/cheycoulbourn/iris-bridge/main/install.sh | sh -s -- [--claude|--codex]
set -eu
REPO="cheycoulbourn/iris-bridge"
SUPPORT="$HOME/Library/Application Support/Iris Bridge"
BIN_DIR="$SUPPORT/bin"
BIN="$BIN_DIR/iris-bridge"
LOG_DIR="$HOME/Library/Logs/Iris Bridge"
AGENT="com.agentcy.iris-bridge"
# Releases are signed by the Agent.cy team; a downloaded binary that is not is not ours.
TEAM_ID="2S27MSM8G8"

say() { printf '\033[1m%s\033[0m\n' "$1"; }
note() { printf '%s\n' "$1"; }
usage() { printf '%s\n' "Usage: sh install.sh [--claude|--codex]"; }

# Where each CLI lives, in the same order the helper looks: the helper must find the same binary the
# installer signed the user in to, or the phone sees "not signed in" right after a successful install.
find_claude() {
  if [ -x "$HOME/.local/bin/claude" ]; then printf '%s' "$HOME/.local/bin/claude"; return 0; fi
  _p=$(command -v claude 2>/dev/null || true)
  if [ -n "$_p" ]; then printf '%s' "$_p"; return 0; fi
  return 1
}

find_codex() {
  for _c in "$HOME/.local/bin/codex" "/Applications/ChatGPT.app/Contents/Resources/codex" "/Applications/Codex.app/Contents/Resources/codex"; do
    if [ -x "$_c" ]; then printf '%s' "$_c"; return 0; fi
  done
  _p=$(command -v codex 2>/dev/null || true)
  if [ -n "$_p" ]; then printf '%s' "$_p"; return 0; fi
  return 1
}

# The same predicate the helper applies in ProviderService.checkStatus. Anything looser lets the installer
# finish "signed in" on a Mac the helper will report as not signed in — an API key, or a logged-in account
# with no subscription.
claude_signed_in() {
  _json=$("$1" auth status --json 2>/dev/null) || return 1
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$_json" | python3 -c 'import json, sys
try:
    a = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ok = (a.get("loggedIn") is True
      and bool(a.get("subscriptionType"))
      and a.get("authMethod") not in ("api_key", "apiKey"))
sys.exit(0 if ok else 1)'; then return 0; else return 1; fi
  fi
  # No python3: flatten the JSON to one line and match the same three conditions.
  _flat=$(printf '%s' "$_json" | tr -d '\n\r')
  printf '%s' "$_flat" | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true' || return 1
  printf '%s' "$_flat" | grep -Eq '"subscriptionType"[[:space:]]*:[[:space:]]*"[^"]+"' || return 1
  if printf '%s' "$_flat" | grep -Eq '"authMethod"[[:space:]]*:[[:space:]]*"(api_key|apiKey)"'; then return 1; fi
  return 0
}

codex_signed_in() {
  _out=$("$1" login status 2>&1) || return 1
  case "$(printf '%s' "$_out" | tr '[:upper:]' '[:lower:]')" in
    *chatgpt*) return 0;;
    *) return 1;;
  esac
}

main() {
  PROVIDER=""
  for arg in "$@"; do
    case "$arg" in
      --claude) PROVIDER=claude;;
      --codex) PROVIDER=codex;;
      -h|--help) usage; exit 0;;
      *) note "I do not know the option $arg."; usage; exit 2;;
    esac
  done

  if [ "$(id -u)" -eq 0 ]; then note "Run this as your normal user, not with sudo."; exit 1; fi
  if [ "$(uname -s)" != "Darwin" ]; then note "Iris Bridge runs on macOS only."; exit 1; fi
  ARCH=$(uname -m); case "$ARCH" in arm64|x86_64) ;; *) note "Unsupported Mac: $ARCH"; exit 1;; esac

  say "1/5 Downloading Iris Bridge"
  mkdir -p "$BIN_DIR"; chmod 700 "$SUPPORT"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  if [ -n "${IRIS_BRIDGE_LOCAL_TARBALL:-}" ]; then
    cp "$IRIS_BRIDGE_LOCAL_TARBALL" "$TMP/bridge.tar.gz"; cp "$IRIS_BRIDGE_LOCAL_TARBALL.sha256" "$TMP/bridge.tar.gz.sha256"
  else
    TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$TAG" ] || { note "Could not find the latest Iris Bridge release."; exit 1; }
    URL="https://github.com/$REPO/releases/download/$TAG/iris-bridge-${TAG#v}-macos.tar.gz"
    curl -fsSL "$URL" -o "$TMP/bridge.tar.gz"; curl -fsSL "$URL.sha256" -o "$TMP/bridge.tar.gz.sha256"
  fi
  EXPECTED=$(awk '{print $1}' "$TMP/bridge.tar.gz.sha256"); ACTUAL=$(shasum -a 256 "$TMP/bridge.tar.gz" | awk '{print $1}')
  [ "$EXPECTED" = "$ACTUAL" ] || { note "Download did not verify. Try again."; exit 1; }
  tar -xzf "$TMP/bridge.tar.gz" -C "$TMP"
  # The checksum only proves the download matches the file next to it; the signature proves who built it.
  # A local tarball built for testing is unsigned by design, so only released ones are checked.
  if [ -z "${IRIS_BRIDGE_LOCAL_TARBALL:-}" ]; then
    if ! codesign --verify -R "=anchor apple generic and certificate leaf[subject.OU]=\"$TEAM_ID\"" "$TMP/iris-bridge" >/dev/null 2>&1; then
      note "This download is not signed by Agent.cy. Nothing was installed."
      exit 1
    fi
  fi
  install -m 755 "$TMP/iris-bridge" "$BIN"

  # The short name is a convenience, not a requirement: if the link or the PATH is missing, say so once and
  # spell the full path out at the end instead of printing a command the user cannot run.
  IRIS_BRIDGE_COMMAND="\"$BIN\""
  if mkdir -p "$HOME/.local/bin" 2>/dev/null && ln -sf "$BIN" "$HOME/.local/bin/iris-bridge" 2>/dev/null; then
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) IRIS_BRIDGE_COMMAND="iris-bridge";;
      *) note "Note: ~/.local/bin is not in your PATH, so the short \`iris-bridge\` command will not work yet.";;
    esac
  else
    note "Note: could not create the ~/.local/bin/iris-bridge shortcut; use the full path below instead."
  fi
  export IRIS_BRIDGE_COMMAND

  say "2/5 Checking your AI"
  CLAUDE_CLI=""; CODEX_CLI=""
  if _p=$(find_claude); then CLAUDE_CLI="$_p"; fi
  if _p=$(find_codex); then CODEX_CLI="$_p"; fi
  if [ -z "$PROVIDER" ]; then
    if [ -n "$CLAUDE_CLI" ] && [ -z "$CODEX_CLI" ]; then PROVIDER=claude
    elif [ -z "$CLAUDE_CLI" ] && [ -n "$CODEX_CLI" ]; then PROVIDER=codex
    elif [ -n "$CLAUDE_CLI" ] && [ -n "$CODEX_CLI" ]; then
      # Both installed: the one already signed in is the one that will work, so pick it rather than
      # a coin toss that sends the user through a sign-in they did not need.
      CLAUDE_OK=no; CODEX_OK=no
      if claude_signed_in "$CLAUDE_CLI"; then CLAUDE_OK=yes; fi
      if codex_signed_in "$CODEX_CLI"; then CODEX_OK=yes; fi
      if [ "$CLAUDE_OK" = no ] && [ "$CODEX_OK" = yes ]; then PROVIDER=codex; else PROVIDER=claude; fi
    else
      printf 'Which do you use? [1] Claude  [2] ChatGPT/Codex: '; read -r CHOICE </dev/tty
      [ "$CHOICE" = "2" ] && PROVIDER=codex || PROVIDER=claude
    fi
  fi

  if [ "$PROVIDER" = claude ]; then
    if [ -z "$CLAUDE_CLI" ]; then
      note "Installing Claude Code…"
      curl -fsSL https://claude.ai/install.sh | bash
      CLAUDE_CLI=$(find_claude || true)
      [ -n "$CLAUDE_CLI" ] || { note "Claude Code was installed but is not on your PATH yet. Open a new Terminal window and run the install command again."; exit 1; }
    fi
    CLI="$CLAUDE_CLI"
    say "3/5 Signing in to Claude"
    if claude_signed_in "$CLI"; then note "Already signed in to Claude."; else "$CLI" auth login </dev/tty; fi
  else
    if [ -z "$CODEX_CLI" ]; then
      note "Installing Codex…"
      curl -fsSL https://chatgpt.com/codex/install.sh | sh
      CODEX_CLI=$(find_codex || true)
      [ -n "$CODEX_CLI" ] || { note "Codex was installed but is not on your PATH yet. Open a new Terminal window and run the install command again."; exit 1; }
    fi
    CLI="$CODEX_CLI"
    say "3/5 Signing in to ChatGPT"
    if codex_signed_in "$CLI"; then note "Already signed in to ChatGPT."; else "$CLI" login </dev/tty; fi
  fi

  say "4/5 Starting Iris Bridge"
  "$BIN" install-agent --binary "$BIN"
  STARTED=no
  i=0
  while [ "$i" -lt 40 ]; do
    if "$BIN" status >/dev/null 2>&1; then STARTED=yes; break; fi
    i=$((i + 1)); sleep 0.25
  done
  if [ "$STARTED" = no ]; then
    note "Iris Bridge did not start."
    for f in launchd.log bridge.log; do
      if [ -f "$LOG_DIR/$f" ]; then printf '\nLast lines of %s:\n' "$f"; tail -n 3 "$LOG_DIR/$f"; fi
    done
    printf '\n'
    note "If another copy of Iris Bridge or the old Python helper is running, stop it and run this command again."
    # Leaving the agent loaded means launchd respawns the broken helper every few seconds, forever.
    launchctl bootout "gui/$(id -u)/$AGENT" >/dev/null 2>&1 || true
    exit 1
  fi

  say "5/5 Ready to pair"
  "$BIN" pair
  if [ "$IRIS_BRIDGE_COMMAND" != "iris-bridge" ]; then
    note "On this Mac that command is: $IRIS_BRIDGE_COMMAND pair"
  fi
}

main "$@"
