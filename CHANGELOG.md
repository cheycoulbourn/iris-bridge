# Changelog

## 0.1.1

- `GET /status` no longer tells the network who is signed in. An unauthenticated caller sees whether each
  provider is ready and nothing else; the account email, the auth method and the plan tier are returned only
  to a paired device or to this Mac's own subcommands over loopback.
- The first-run pairing code is printed only when a person is watching the terminal. Under launchd, where
  stdout is a log file, the helper prints how to get a code instead of printing one.
- Connections from the network are capped on their own so they cannot use up the slots `iris-bridge pair`,
  `status`, `devices` and `revoke` need over loopback.
- An empty, blank or truncated `admin-token` file is replaced on start instead of being accepted.
- A provider that ignores SIGTERM on timeout or cancellation is now killed, so a wedged CLI cannot hold the
  single-request lock.

The app's minimum helper version is unchanged at 0.1.0; 0.1.1 is a recommended update, not a required one.

## 0.1.0

- First release: `serve`, `pair`, `status`, `devices`, `revoke`, `install-agent`, `uninstall`; TLS with a
  self-signed certificate and fingerprint pinning, code-based pairing with per-device tokens, Bonjour
  discovery, and Claude Code / Codex subscription sign-in.
