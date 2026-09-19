# Changelog

## Unreleased (0.2.3)

- Connected apps can discover the signed-in provider's models and supported reasoning efforts through an authenticated catalog endpoint. Codex uses its app-server catalog; Claude uses its SDK initialization response. No hardcoded account model list or invented effort capabilities.
- Optional model/effort choices are validated and passed as separate CLI arguments. Automatic leaves both at provider defaults. Catalog subprocesses have time/output bounds and no chat prompt is sent.
- Mac discovery advertises the actual network hostname separately from its display name.
- Installer registers Iris MCP with Codex as well as Claude; imported creator text preserves whitespace and line breaks; revision retries preserve lineage, reject conflicting duplicates and roll back failed persistence.

- The MCP revision response now reports the existing decision status when an idempotent retry returns a
  revision that was already approved, denied or marked for changes, instead of saying it is still waiting.
- Claude Code and Codex registration, new-session requirements, verbatim import handling, clarification
  questions and explicit revision behavior are documented in the README.

## 0.2.2

Run the install command again to pick all of this up.

- On a Mac no device has paired with yet, the Iris tools now tell the agent exactly that, and what the person
  has to do (`iris-bridge pair`, then enter the code in Iris), instead of "No workspace context yet."

- Signing in to Claude no longer crashes the installer with `EINVAL: invalid argument, kqueue`. The installer
  handed Claude Code the terminal as `/dev/tty`, which Claude Code's runtime cannot watch; it is now handed
  the terminal by its real name. This stopped every first-time install on a Mac that was not already signed in.
- If sign-in does not finish, the installer stops and prints the one command to run, instead of carrying on.
- The Iris tools are registered in Claude Code automatically, for every folder. The old printed command
  registered them only for the folder it was run in, so Claude Code opened anywhere else had no Iris tools.
- The install ends with numbered next steps: pair, start a new Claude Code session, review in the Inbox.

## 0.2.1

- `iris-bridge mcp` now answers Claude Code. 0.2.0 waited for 64 KB of input or end of input before reading
  its first message, and Claude Code keeps stdin open for the whole session, so every connection timed out
  after 30 seconds. The server now reads whatever has arrived. Nothing else changed; run the install
  command again to pick it up.

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
