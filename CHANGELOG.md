# Changelog

## 0.3.0

Run the install command again to pick this up. Pairs with Iris build 142, the first with the new chat. The
port, certificate and pairing are the same, so no device re-pairs.

What an Iris build without the new chat (builds 139 to 141, and older) gets from 0.3.0:

- Unchanged: chat on `/message` and `/cancel`, the model list on `/models`, `/status` (protocol `version: 2`
  and the same fields), listing and deciding what Iris Bridge 0.2 already collected in the Inbox (`/inbox` and
  `/inbox/<id>/decision`), and `PUT /context`, which the new read tools still fall back to while no build with
  the new chat has sent this Mac its workspace.
- `/status` for a paired device now also lists `v3` and `effort` in `capabilities`. These builds ignore names
  they do not know and still check `version: 2`, so nothing they show changes.
- New agent work no longer reaches them. The 0.2 agent tools are replaced by the v3 Iris tools the README
  lists: `iris_submit_post`, `iris_submit_series`, `iris_propose_archive_posts`, `iris_revise_submission`,
  `iris_list_submissions` and `iris_get_workspace_context` are gone, and so are `POST /admin/inbox` and
  `GET /admin/context`, the routes they saved and read through. A change made with the v3 tools is queued on
  this Mac for a device that says hello on `/v3/stream`, which only a build with the new chat does, and one
  still waiting after a week is dropped. A build without the new chat never sees it in its Inbox, even while
  it is open.
- A Claude Code or Codex session that was already open keeps the 0.2 tools, and they fail until the session is
  restarted, because this helper no longer serves their routes. A new session gets the v3 tools.

What 0.3.0 adds:

- Iris chat: an Iris app with the new chat holds one secure connection open to this Mac
  (`wss://<this Mac>:48731/v3/stream`) while it is in the foreground. Each thread gets its own Claude Code or
  Codex session here, started when the thread is opened and picked up again later, so replies stream as they
  are written and the conversation is remembered; up to three chats can answer at once, a reply keeps going if
  the phone locks, and the app catches up when it reconnects.
- In chat, Claude can use the Iris tools and the connectors in the owner's Claude account (Gmail, Google
  Calendar, Notion and the rest connected at claude.ai). It reads a connector only when the message mentions it
  with `@` or the chosen `/` command allows it, and anything that would send, create or change something
  outside Iris asks the owner first in the app; no answer within ten minutes reads as no. It cannot read or
  change files on this Mac, run commands or browse the web. Codex gets the Iris tools but no connectors.
- A connector tool that a Claude Code setting already pre-allows (`permissions.allow` in
  `~/.claude/settings.json`) never asks; Iris's Settings shows any such rule. The helper reads that file again
  every time it builds its health report, at each hello and at each check (once a minute), so a rule added or
  removed shows up within a minute without restarting anything.
- `thread.send` can carry a reasoning-effort choice (`low`, `medium`, `high`, `xhigh`, `max`; omitted is
  Automatic, the provider's own default), offered in the app's composer only when this helper reports the
  `effort` capability. Claude receives it as `--effort`; Codex receives it as `model_reasoning_effort`, with
  `xhigh` and `max` folded into Codex's own highest documented level. Changing it mid-reply takes effect after
  that turn: the session restarts with `--resume` so nothing already written is lost.
- Every 0.2.6 fix, carried on both the v2 `/message` path and the new v3 sessions: a busy Mac answering
  `claude auth status` slowly is no longer read as signed out (20 seconds and one retry, not 0.2.5's 8); a
  message is tried when the sign-in check itself could not finish, provided an earlier check since the helper
  started found a subscription sign-in, and refused as `providerUnavailable` (not `signedOut`) when none has;
  a check that could not finish is never kept, and `/status` never shows a Mac it could not check as signed
  out; both providers' sign-in checks (and CLI versions) start as the helper itself starts, so the first poll
  after an install, a login or a restart already has an answer instead of waiting on a cold check.
- The v3 provider runner no longer waits forever for its process's stdout and stderr to reach end of file once
  the process itself has exited: something a long chat session started can leave either pipe's write end open
  long after the CLI is gone, which used to stall that session's `exit` report indefinitely (piling up the
  reader threads it never released, and the turn or session it never reported the end of) the same way a
  blocking `readDataToEndOfFile()` could hang the v2 path before 0.2.6's `PipeReader`. It now reads both pipes
  incrementally on their own threads, exactly as before, but waits for them only up to the same 2-second grace
  0.2.6 gave the v2 runner once the process has exited, then reports `exit` regardless; a reader still going
  past that point keeps delivering whatever it later reads, it just no longer holds up the report that the
  process ended. The read loop itself also moved off `FileHandle.availableData` onto the same raw, fixed-size
  `read()` `PipeReader` uses, so a pipe closed out from under a blocked read cannot raise the uncatchable
  Objective-C exception `FileHandle` risks and take the helper down with it.

## 0.2.6

Run the install command again to pick this up. Older Iris apps keep working unchanged.

- A busy Mac is no longer mistaken for a signed-out one. On a heavily loaded Mac, `claude auth status` could take
  longer than the 8 seconds 0.2.5 allowed; the helper then answered "not signed in", kept that answer for a
  minute, and refused every message in that minute with `signedOut` ("after 0s" in the log). The sign-in check now
  gets 20 seconds and one quick retry. Only a check that finishes and says so (`loggedIn: false`, an API-key
  sign-in, Codex's "Not logged in") counts as signed out; a timeout, a CLI that will not start or an answer the
  helper cannot read is "couldn't check".
- A message is tried when the sign-in could not be checked, provided a check since the helper started found a
  subscription sign-in. If the Mac really is signed out, the turn itself says so and the reply carries
  `cause: signedOut` with the provider's own words, as before. Without such a check nothing has ruled out an API
  key (Codex bills a key saved with `codex login --with-api-key` whatever the environment says), so no turn runs:
  the reply is "Couldn't check Claude's sign-in just now — the Mac may be busy. Try again in a moment." with
  `cause: providerUnavailable`, not `signedOut`, which Iris shows as "Claude couldn't answer on your Mac" with
  Retry. A check that could not finish never replaces the last one that did.
- A check that could not finish is never kept. A sign-in is kept for a minute, as before; a sign-out for ten
  seconds, so signing in on the Mac shows up at once.
- `/status` answers within the app's poll timeout and never shows a Mac it could not check as signed out: every
  Iris app shows `ready: false` as "not signed in" with the sign-in command, which fixes nothing on a busy Mac. A
  sign-in check that is still running is answered with the last real answer, or with `ready: true` and "Couldn't
  check Claude's sign-in just now — the Mac may be busy. Try again in a moment." when there is none, and finishes
  in the background. A check that could not finish is `ready: true` too, with "… Trying anyway." when a turn is
  still tried and "… Try again in a moment." when it is not. For a paired device, health says `signedIn: true`
  and adds `signInChecked: false` in both cases; nothing else in the reply changes, and a finished check sends
  exactly the 0.2.5 shape. `iris-bridge status` prints "sign-in unknown" for it.
- Both sign-in checks start as the helper starts, so the app's first poll after an install, a login or a restart
  finds a finished answer instead of waiting on a cold check, which can outlast that poll. Both CLI versions are
  read then too.
- A sign-in check that never finishes holds nothing up. A message waits for one at most 50 seconds from when it
  started (both tries, and the kill of a CLI that ignores the stop signal), then is answered as a check that could
  not finish while the check carries on; the next message, model list or poll does not wait on it again, and the
  helper takes the next message instead of answering "still answering another message". A CLI that answers and
  exits but leaves something running with its output open no longer keeps its sign-in check, or a chat turn,
  going: the helper stops reading two seconds after the CLI exits.
- `/status` waits at most 0.75 seconds in all, for both providers' sign-in checks and CLI versions together, where
  it waited 0.75 seconds for each check and then as long as `--version` took.
- A CLI version read that times out is asked again next time, instead of showing no version until the CLI changes.
- `/models` waits at most 10 seconds for a sign-in check, well inside the app's 30. When the check is still
  running it starts no CLI and answers with the model list this Mac gave last, if a subscription sign-in was
  confirmed, or with "Couldn't check Claude's sign-in just now — the Mac may be busy. Try again in a moment."

## 0.2.5

Run the install command again to pick this up. Older Iris apps keep working unchanged.

- Errors say why. Every error reply keeps its `error` sentence and adds `cause`: `signedOut`, `usageLimit`,
  `providerUnavailable`, `modelUnavailable`, `timeout`, `cancelled`, `busy`, `deviceRevoked`, `badRequest` or
  `internal`. Provider failures also carry `provider`, the provider's own message in `details` (up to 2,000
  characters) and, for a usage limit, `resetsAt`. Claude Code's `result` and assistant `error` events, Codex's
  `turn.failed` and `error` events, and both tools' stderr are read instead of thrown away, so "Codex could not
  finish" becomes "ChatGPT's usage limit is reached until Sep 26, 8:41 AM." HTTP status codes are unchanged.
- `/status` with a device token adds `paired`, a `capabilities` list and per-provider `health`: installed,
  signed in, plan, CLI version, usage state and reset time, and the last failure's cause. A token that matches
  nothing gets `401 device-revoked` at once, so a revoked device stops showing "Connected". Without a token,
  `/status` is exactly what 0.2.4 sent.
- A usage limit is remembered until the provider's reset time, or for six hours when it gives none, and is
  cleared by the next successful turn.
- Claude Code is no longer updated inside a chat turn. The hourly `claude install latest` that could fail a
  message is gone; health reports the CLI version instead.
- A phone that locks or changes network mid-request is logged at INFO, not ERROR.
- The Iris tools tell an agent which problem it is: Iris Bridge not set up, not running, not answering in
  time, or serving a different certificate.
- `iris-bridge status` prints provider health and the names and addresses this Mac answers on.
- `scripts/smoke.sh` checks a release against the real Claude Code and Codex, and `scripts/release.sh` requires
  a clean run of the code it tags.

## 0.2.4

- Added read-only MCP planner cleanup tools for listing and searching saved posts, getting full post details,
  and finding candidate duplicate groups. Read replies carry the planner snapshot revision and capture time;
  attachment metadata is available but binary media is never sent.
- Added `iris_propose_archive_posts`, which queues a revision-checked archive proposal for explicit Iris
  review. It has no direct delete or merge path, requires a planner snapshot no older than five minutes, and
  safely returns the same submission for an identical operation-ID retry even after a decision.
- Workspace context now carries an optional versioned planner snapshot. The helper accepts snapshots up to
  16 MiB at both its HTTP parser and context boundary, while legacy context-only updates retain their 256 KiB
  limit.

## 0.2.3

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
