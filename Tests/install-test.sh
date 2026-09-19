#!/bin/sh
# Exercises install.sh's own functions without installing anything: the script is sourced with
# IRIS_BRIDGE_INSTALL_SOURCED=1, which defines the functions and skips main.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# --- 1. Interactive sign-in under `curl … | sh` ------------------------------------------------------------
# Claude Code is a Bun binary, and Bun cannot watch /dev/tty with kqueue: `claude auth login </dev/tty` dies
# with "EINVAL: invalid argument, kqueue" on every Mac. The named device behind it (/dev/ttys003) is fine. So
# the installer must hand an interactive CLI the named device, never /dev/tty. The stub below fails the same
# way Bun does — by refusing a stdin that is the /dev/tty alias — and the whole thing runs under a fresh pty
# with stdin as a pipe, which is the shape `curl | sh` gives the script.
cat >"$WORK/cli" <<'STUB'
#!/bin/sh
# /dev/tty is character device major 2 on macOS; a real pty slave is not.
MAJOR=$(stat -f '%Hr' /dev/stdin 2>/dev/null || echo "?")
TTY_MAJOR=$(stat -f '%Hr' /dev/tty)
if [ "$MAJOR" = "$TTY_MAJOR" ]; then echo "EINVAL: invalid argument, kqueue"; exit 1; fi
if [ -t 0 ]; then echo "STUB-INTERACTIVE-OK"; exit 0; fi
echo "STUB-NOT-A-TERMINAL"; exit 1
STUB
chmod +x "$WORK/cli"
cat >"$WORK/piped.sh" <<PIPED
IRIS_BRIDGE_INSTALL_SOURCED=1 . "$HERE/install.sh"
run_interactive "$WORK/cli"
PIPED
OUT=$(python3 - "$WORK/piped.sh" <<'PY'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("sh", ["sh", "-c", "cat '%s' | sh" % sys.argv[1]])
out = b""; deadline = time.time() + 15
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if fd in r:
        try: chunk = os.read(fd, 4096)
        except OSError: break
        if not chunk: break
        out += chunk
sys.stdout.write(out.decode(errors="replace"))
PY
)
printf '%s' "$OUT" | grep -q 'STUB-INTERACTIVE-OK' || { echo "run_interactive: the CLI did not get a usable terminal. Output was:"; printf '%s\n' "$OUT"; exit 1; }

# --- 2. With no terminal at all, say what to run instead of crashing --------------------------------------
cat >"$WORK/headless.sh" <<HEADLESS
IRIS_BRIDGE_INSTALL_SOURCED=1 . "$HERE/install.sh"
if run_interactive "$WORK/cli"; then echo RAN; else echo "REFUSED:\$?"; fi
HEADLESS
# setsid-less way to lose the controlling terminal portably: python's os.setsid in a child.
HEADLESS_OUT=$(python3 - "$WORK/headless.sh" <<'PY'
import os, subprocess, sys
print(subprocess.run(["sh", sys.argv[1]], stdin=subprocess.DEVNULL, capture_output=True, text=True, preexec_fn=os.setsid).stdout)
PY
)
printf '%s' "$HEADLESS_OUT" | grep -q 'REFUSED:' || { echo "run_interactive: expected a refusal with no terminal, got: $HEADLESS_OUT"; exit 1; }

# --- 3. The tools are registered for every folder, and re-running replaces rather than duplicates ---------
cat >"$WORK/claude" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK/claude.calls"
exit 0
STUB
chmod +x "$WORK/claude"
( IRIS_BRIDGE_INSTALL_SOURCED=1 . "$HERE/install.sh"; BIN="/x/iris-bridge"; register_mcp "$WORK/claude" ) >/dev/null
grep -q '^mcp remove iris -s user$' "$WORK/claude.calls" || { echo "register_mcp: did not clear an older user-scope entry first"; cat "$WORK/claude.calls"; exit 1; }
grep -q '^mcp add -s user iris -- /x/iris-bridge mcp$' "$WORK/claude.calls" || { echo "register_mcp: did not add at user scope"; cat "$WORK/claude.calls"; exit 1; }

cp "$WORK/claude" "$WORK/codex"
( IRIS_BRIDGE_INSTALL_SOURCED=1 . "$HERE/install.sh"; BIN="/x/iris-bridge"; register_codex_mcp "$WORK/codex" ) >/dev/null
grep -q '^mcp add iris -- /x/iris-bridge mcp$' "$WORK/claude.calls"
echo "install-test: ok"
