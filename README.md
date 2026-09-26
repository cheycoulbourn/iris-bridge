# Iris Bridge

The Mac helper that lets Iris use the Claude Code or Codex subscription already signed in on your Mac.

Install (in Terminal on your Mac):

    curl -fsSL https://raw.githubusercontent.com/cheycoulbourn/iris-bridge/main/install.sh | sh

Then open Iris, choose this Mac under "Macs nearby", and enter the code shown in Terminal.

Commands: `iris-bridge pair`, `iris-bridge status`, `iris-bridge devices`, `iris-bridge revoke <id>`, `iris-bridge inbox`, `iris-bridge uninstall`.

## Iris chat on this Mac (0.3.0)

An Iris app with the new chat keeps one secure connection open to this Mac while it is in the foreground
(`wss://<this Mac>:48731/v3/stream`, the same port, certificate and pairing as before; no device re-pairs).
Each chat thread has its own Claude Code or Codex session here, started when you open the thread and picked
up again later, so replies stream as they are written and remember the conversation. Up to three chats can
answer at once. A reply keeps going if your phone locks, and the app catches up when it reconnects.

In chat, Claude can use the Iris tools and the connectors in your Claude account (Gmail, Google Calendar,
Notion and the others you have connected at claude.ai). It reads a connector only when your message mentions
it with `@` or the command you chose allows it, and anything that would send, create or change something
outside Iris asks you first in the app; no answer within ten minutes means no. It cannot read or change files
on this Mac, run commands or browse the web. ChatGPT (Codex) gets the Iris tools but no connectors.

If Claude Code's own settings pre-allow a connector tool (`permissions.allow` in `~/.claude/settings.json`),
that tool never asks. Iris's Settings shows any such rule.

A chat message can also carry a reasoning-effort choice (`thread.send.effort`, one of `low`, `medium`,
`high`, `xhigh` or `max`; omitted is Automatic, the provider's own default). Claude receives it as `--effort`;
Codex receives it as `model_reasoning_effort`, with `xhigh` and `max` folded into Codex's own highest
documented level. Changing it while a chat is answering takes effect after that turn: the session restarts
with `--resume` so the conversation is kept and nothing is cut off. The composer offers this choice only when
the helper reports the `effort` capability.

## How it is built

One Swift helper, `Sources/IrisBridgeCore`, in the parts of the Iris Bridge v3 design (§4):

- `Connection/` the TLS listener, the v2 HTTP endpoints, the `/v3/stream` WebSocket and its messages, and the
  runtime that wires the parts together.
- `Pairing/` pairing codes and device tokens.
- `Sessions/` one provider session per chat thread, and each thread's event log for replay.
- `Providers/` the provider sessions behind one interface: `Claude/` (`claude -p` stream-json, long-lived)
  and `Codex/` (`codex exec --json`, one run per message); failure causes; the v2 chat turn.
- `Tools/` the Iris tools (`iris-bridge mcp`), the snapshot they read, and the queue that carries changes to
  the app, which is the only thing that ever writes your Iris data.
- `Approvals/` the permission check chat sessions ask before every tool use.
- `Health/` sign-in, plan, versions, usage and connectors, as the app shows them.

## When something goes wrong (0.2.5)

Every error Iris Bridge sends back keeps its plain sentence and also says why, so the app can label it:
signed out, usage limit (with the reset time when the provider gives one), provider unavailable, model
unavailable, timeout, cancelled, busy, device revoked, bad request or internal. The provider's own message
comes with it, so a usage limit reads as a usage limit, not as "check your connection".

`iris-bridge status` shows each provider's sign-in, plan and command-line tool version, what the last chat
turn said about usage, and the names and addresses you can type into Iris to reach this Mac.

A Mac that is too busy to answer the sign-in check in time is not treated as signed out (0.2.6). Once the helper
has seen your subscription sign-in, it reports "Couldn't check Claude's sign-in just now — the Mac may be busy.
Trying anyway." and still sends the message; if Claude or ChatGPT really is signed out, the reply says so. Until
it has seen one, it asks you to try again in a moment instead, so a message is never billed to an API key the
check would have caught. Either way Iris shows the Mac as connected, not signed out. Signing in on the Mac shows
up within about ten seconds. A sign-in check that never finishes holds nothing up: a message waits for it at most
50 seconds, the model list at most 10, and the connection status under a second.

Iris Bridge no longer updates Claude Code for you in the middle of a chat. Update it yourself with
`claude update`; the app shows the version the helper sees.

## Model and reasoning choices (0.2.3)

In a compatible Iris app, open the model dropdown beside Send. It shows models and reasoning choices reported by the provider connected to this Mac. Codex and Claude maintain their own lists; changing models clears an effort the new model does not support. Automatic uses the provider default. If the Mac cannot provide its list, Automatic remains available and the app can refresh later.

Catalog discovery does not send a chat prompt. The authenticated protocol, bounded discovery, cache behavior and test evidence are recorded in [model-catalog-verification.md](docs/model-catalog-verification.md). Install the latest helper using the public install command above.

## Iris tools for Claude Code and Codex

Iris Bridge gives Claude Code and Codex the same Iris tools the chat uses. The installer registers them for
the signed-in provider: Claude Code gets a user-scoped registration in every folder, Codex its global MCP
registration. **Start a new Claude Code or Codex session after installing**; one that was already open will not
see new tools.

Then ask for work the way you would ask a person:

> Plan a 4-episode series for my anchor pillar.

> Read brief.md and plan it as posts for Iris.

Reading, from the workspace your Iris app last shared with this Mac (every answer says how old that is):
`iris_workspace_summary` (call it first), `iris_list_posts`, `iris_get_post`, `iris_list_tasks`,
`iris_list_ideas`, `iris_list_series`, `iris_list_pillars`, `iris_get_schedule`, `iris_search`,
`iris_find_duplicate_posts` and `iris_list_review_items`.

Changing, always through the Iris app: `iris_create_task`, `iris_update_task`, `iris_complete_task`,
`iris_create_idea`, `iris_update_idea`, `iris_create_post_draft`, `iris_update_post_draft` and
`iris_attach_to_post` apply as soon as Iris receives them, with Undo in Activity; `iris_schedule_post`,
`iris_set_stage` past editing, `iris_mark_posted`, `iris_archive` and `iris_create_series` wait in the Inbox for
your approval, and so does anything for a profile other than the one open in Iris. `iris_revise_review_item`
replaces an Inbox item you asked to be changed. Nothing is ever deleted and nothing is published to a platform.

A change reaches Iris only through an Iris build with the new chat, open on a paired iPhone or Mac. Older Iris
builds do not receive agent changes, even while they are open. Until a build with the new chat connects, each
change waits on this Mac for up to a week; one still waiting after that is dropped. The tools from Iris Bridge
0.2 (`iris_submit_post` and the rest) are gone, and with them the way older Iris builds received agent work in
their Inbox; an agent picks up the new tools in its next session.

If the tools are missing (`claude mcp list` does not show `iris`), register them by hand. The `-s user` matters:
without it Claude Code only adds them to the one folder you ran the command in.

    claude mcp add -s user iris -- "$HOME/Library/Application Support/Iris Bridge/bin/iris-bridge" mcp

`iris-bridge inbox` still lists what Iris Bridge 0.2 collected and not yet decided, and
`iris-bridge inbox clear-decided` forgets decisions older than 30 days.

## Releasing (maintainers)

Every release is checked against the real Claude Code and Codex before it ships:

    swift test --scratch-path /tmp/iris-bridge-build
    sh Tests/integration.sh
    sh Tests/install-test.sh
    sh Tests/smoke-test.sh      # the smoke script itself, against the stub CLIs
    sh Tests/release-test.sh    # release.sh's preflight refusals, on scratch repositories
    sh scripts/smoke.sh         # live: a second helper on a random port, v2 turns and a v3 session per provider
    scripts/release.sh <version>

Releases are made from `main`: `scripts/release.sh` tags and pushes `main`, and the install command serves
`install.sh` from `main`. Work on a release branch reaches `main` by fast-forward. Merge `main` into the branch
first, keep every CHANGELOG entry, and `git rm` any test file the merge brings back at a path the branch moved
it from. Then on `main` run `git merge --ff-only release/<version>`. A smoke run records Package.swift and
Sources, so it stays valid across that merge when the merge leaves them as the branch had them.
`scripts/release.sh` refuses to start off `main`, on a `main` missing commits from `origin/main`, without a
`## <version>` CHANGELOG entry, or with two test files of the same name, before it builds or tags anything.

`scripts/smoke.sh` never touches the installed helper on port 48731. It skips a provider that is not
installed, is signed out or is at its usage limit. Its v3 session makes one Iris tool call, one approval round
trip (a Google Calendar event it denies, so nothing is created), a resume after restarting the helper and a
cancel. `scripts/release.sh` refuses to tag code that has no clean smoke run in which the v2 turn and the three
Claude v3 steps ran live.
