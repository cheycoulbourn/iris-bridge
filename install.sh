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
  if [ "${HAVE_PYTHON:-no}" = yes ]; then
    # 0 means signed in and 3 means not signed in. Any other status — python broke after all, or what the
    # CLI printed was not JSON — means this path cannot answer, so fall through to the text match below.
    _rc=0
    printf '%s' "$_json" | python3 -c 'import json, sys
try:
    a = json.load(sys.stdin)
except Exception:
    sys.exit(2)
ok = (a.get("loggedIn") is True
      and bool(a.get("subscriptionType"))
      and a.get("authMethod") not in ("api_key", "apiKey"))
sys.exit(0 if ok else 3)' 2>/dev/null || _rc=$?
    case "$_rc" in
      0) return 0;;
      3) return 1;;
    esac
  fi
  # No usable python3: match the same three conditions by text, but only against the JSON itself — from the
  # first line that starts with "{" to the brace that closes it. Anything the CLI printed around the JSON is
  # not JSON, and must not be able to satisfy a condition the helper would evaluate as false.
  _flat=$(printf '%s\n' "$_json" | awk '!f && /^\{/ { f = 1 }
f { printf "%s", $0; d += gsub(/\{/, "{") - gsub(/\}/, "}"); if (d <= 0) exit }')
  [ -n "$_flat" ] || return 1
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

# The terminal the person is sitting at, by its real name (/dev/ttys003), or nothing when there is none.
# Under `curl … | sh` stdin is the pipe, so an interactive CLI has to be handed the terminal explicitly — and
# it cannot be /dev/tty: Claude Code is a Bun binary, Bun watches stdin with kqueue, and kqueue refuses the
# /dev/tty alias ("EINVAL: invalid argument, kqueue") while accepting the device it stands for.
terminal_device() {
  _t=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
  case "$_t" in
    ""|"?"|"??"|-) return 1;;
  esac
  [ -c "/dev/$_t" ] || return 1
  printf '/dev/%s' "$_t"
}

# Runs a command that needs a person at the keyboard. Returns 75 without running it when nobody is.
run_interactive() {
  if [ -t 0 ]; then "$@"; return $?; fi
  _tty=$(terminal_device) || return 75
  "$@" <"$_tty"
}

# Sign-in is the one step the installer cannot do for anyone, so when it does not happen the installer stops
# with the one command to run, rather than carrying on to a helper the phone will report as "not signed in".
sign_in() {
  _name=$1; _check=$2; shift 2
  _rc=0; run_interactive "$@" || _rc=$?
  if "$_check" "$1"; then return 0; fi
  printf '\n'
  if [ "$_rc" -eq 75 ]; then note "Signing in to $_name needs a Terminal window, and this is not one."
  else note "You are not signed in to $_name yet."; fi
  note "Open Terminal, run this, and finish signing in in your browser:"
  note "  $*"
  note "Then run the install command again. It will pick up where it left off."
  exit 1
}

# Gives Claude Code the Iris tools in every folder. The default scope is "local", which means only the folder
# the command happened to run in: open Claude Code anywhere else and the tools are simply not there. An older
# entry is removed first so that running the installer again replaces it instead of failing on a duplicate.
register_mcp() {
  "$1" mcp remove iris -s user >/dev/null 2>&1 || true
  "$1" mcp add -s user iris -- "$BIN" mcp >/dev/null 2>&1
}

register_codex_mcp() {
  "$1" mcp add iris -- "$BIN" mcp >/dev/null 2>&1
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

  # On a Mac without the Command Line Tools, /usr/bin/python3 exists but only pops the install dialog and
  # fails, so "is python3 on the PATH" is the wrong question. Ask once whether it actually runs.
  HAVE_PYTHON=no
  if python3 -c 'pass' >/dev/null 2>&1; then HAVE_PYTHON=yes; fi

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
      CHOICE=1
      if _tty=$(terminal_device); then printf 'Which do you use? [1] Claude  [2] ChatGPT/Codex: '; read -r CHOICE <"$_tty"; fi
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
    if claude_signed_in "$CLI"; then note "Already signed in to Claude."; else sign_in Claude claude_signed_in "$CLI" auth login; fi
  else
    if [ -z "$CODEX_CLI" ]; then
      note "Installing Codex…"
      curl -fsSL https://chatgpt.com/codex/install.sh | sh
      CODEX_CLI=$(find_codex || true)
      [ -n "$CODEX_CLI" ] || { note "Codex was installed but is not on your PATH yet. Open a new Terminal window and run the install command again."; exit 1; }
    fi
    CLI="$CODEX_CLI"
    say "3/5 Signing in to ChatGPT"
    if codex_signed_in "$CLI"; then note "Already signed in to ChatGPT."; else sign_in ChatGPT codex_signed_in "$CLI" login; fi
  fi

  say "4/5 Starting Iris Bridge"
  "$BIN" install-agent --binary "$BIN"
  STARTED=no
  i=0
  # 80 x 0.25s = 20s. The helper itself waits up to 10s for its listener, so a poll that also stopped at 10s
  # would call a slow-but-healthy start a failure and bootout the agent.
  while [ "$i" -lt 80 ]; do
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
    # Leaving the agent loaded means launchd respawns the broken helper every few seconds, forever, and
    # leaving the plist behind brings it back at the next login. Take both away.
    launchctl bootout "gui/$(id -u)/$AGENT" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/LaunchAgents/$AGENT.plist"
    exit 1
  fi

  # Registered before the pairing code is shown, so the code and what to do with it are the last thing on
  # screen. Claude Code is looked for again here: someone who picked Codex for chat may still use it.
  MCP_READY=no
  CODEX_MCP_READY=no
  if [ -z "$CLAUDE_CLI" ]; then CLAUDE_CLI=$(find_claude || true); fi
  if [ -n "$CLAUDE_CLI" ] && register_mcp "$CLAUDE_CLI"; then MCP_READY=yes; fi

  if [ -z "$CODEX_CLI" ]; then CODEX_CLI=$(find_codex || true); fi
  if [ -n "$CODEX_CLI" ] && register_codex_mcp "$CODEX_CLI"; then CODEX_MCP_READY=yes; fi

  say "5/5 Ready to pair"
  "$BIN" pair
  if [ "$IRIS_BRIDGE_COMMAND" != "iris-bridge" ]; then
    note "  On this Mac that command is: $IRIS_BRIDGE_COMMAND pair"
    printf '\n'
  fi
  if [ "$CODEX_MCP_READY" = yes ]; then
    note "Codex is connected to the Iris tools. Open a new Codex session to use them."
  elif [ -n "$CODEX_CLI" ]; then
    note "Codex setup needs one more command:"
    note '  codex mcp add iris -- "$HOME/Library/Application Support/Iris Bridge/bin/iris-bridge" mcp'
  fi
  say "What to do next"
  note "  1. On your iPhone or Mac, open Iris, choose this Mac under \"Macs nearby\", and enter the code above."
  if [ "$MCP_READY" = yes ]; then
    note "  2. Claude Code now has the Iris tools in every folder. Start a NEW Claude Code session — one that"
    note "     was already open will not see them — and ask it, for example:"
    note "       \"Read brief.md and plan it as posts for Iris.\""
    note "  3. What it sends waits in the Inbox in Ask Iris. Nothing is saved until you approve it there."
  elif [ -n "$CLAUDE_CLI" ]; then
    # The literal $HOME is on purpose: this line is meant to be pasted into a shell, where it expands.
    note "  2. Claude Code could not be given the Iris tools automatically. Run this once:"
    note '       claude mcp add -s user iris -- "$HOME/Library/Application Support/Iris Bridge/bin/iris-bridge" mcp'
  fi
}

[ "${IRIS_BRIDGE_INSTALL_SOURCED:-}" = 1 ] || main "$@"
