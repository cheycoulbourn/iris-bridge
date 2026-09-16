# Changelog

## 0.2.0

- Your agent can send work to Iris. `iris-bridge mcp` is an MCP server for Claude Code with five tools:
  `iris_get_workspace_context`, `iris_submit_post`, `iris_submit_series`, `iris_list_submissions` and
  `iris_revise_submission`. Register it with
  `claude mcp add iris -- "$HOME/Library/Application Support/Iris Bridge/bin/iris-bridge" mcp`.
- A submission queue on the Mac (`inbox.json`), read and decided by the Iris app over the new `GET /inbox`,
  `POST /inbox/{id}/decision` and `PUT /context` endpoints. Nothing is saved into the planner until the
  creator approves it in Iris, and nothing is ever published to a platform.
- A workspace snapshot the app pushes and the agent reads, so plans use pillar, platform and format names
  that already exist rather than invented ones.
- `iris-bridge inbox` lists what is waiting, with how long it has been waiting; `iris-bridge inbox
  clear-decided` forgets decided submissions older than 30 days. The helper also prunes them at startup, so
  the file the app downloads does not grow forever.
- Arguments an agent got wrong are said out loud rather than dropped: an episode that is not a number, a
  scene that is not a scene, a revision carrying both a post and a series (which used to walk the series past
  the length cap). Listed titles and comments are flattened onto one line, escape sequences and all.
- The installer ends with the line that registers the tools in Claude Code.

The protocol version stays 2: every endpoint here is additive. The app's minimum helper version for Inbox
features is 0.2.0; older helpers still chat.

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
