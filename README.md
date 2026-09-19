# Iris Bridge

The Mac helper that lets Iris use the Claude Code or Codex subscription already signed in on your Mac.

Install (in Terminal on your Mac):

    curl -fsSL https://raw.githubusercontent.com/cheycoulbourn/iris-bridge/main/install.sh | sh

Then open Iris, choose this Mac under "Macs nearby", and enter the code shown in Terminal.

Commands: `iris-bridge pair`, `iris-bridge status`, `iris-bridge devices`, `iris-bridge revoke <id>`, `iris-bridge inbox`, `iris-bridge uninstall`.

## Model and reasoning choices (0.2.3)

In a compatible Iris app, open the model dropdown beside Send. It shows models and reasoning choices reported by the provider connected to this Mac. Codex and Claude maintain their own lists; changing models clears an effort the new model does not support. Automatic uses the provider default. If the Mac cannot provide its list, Automatic remains available and the app can refresh later.

Catalog discovery does not send a chat prompt. The authenticated protocol, bounded discovery, cache behavior and test evidence are recorded in [model-catalog-verification.md](docs/model-catalog-verification.md). Install the latest helper using the public install command above.

## Send work to Iris from Claude Code or Codex

Iris Bridge also hands Claude Code and Codex a set of tools for sending finished work to your Iris Inbox. The
installer registers the tools automatically for the signed-in provider. Claude Code gets a user-scoped
registration in every folder; Codex gets its global MCP registration. **Start a new Claude Code or Codex
session after installing** — a session that was already open will not see newly registered tools.

Then ask for work the way you would ask a person:

> Plan a 4-episode series for my anchor pillar and send it to Iris.

> Read brief.md and plan it as posts for Iris.

The tool instructions tell the agent to call `iris_get_workspace_context` first, use the existing pillar,
platform and format names, and copy imported creator writing exactly. It must preserve punctuation, spacing,
line breaks and facts rather than paraphrasing or shortening them. When a field, date, owner or merge target
is ambiguous, it asks a clarification question before importing. For requested changes, it reads existing
submissions and uses `iris_revise_submission` with the original id; it does not create a new submission.

If the tools are missing (`claude mcp list` does not show `iris`), register them by hand. The `-s user` matters:
without it Claude Code only adds them to the one folder you ran the command in.

    claude mcp add -s user iris -- "$HOME/Library/Application Support/Iris Bridge/bin/iris-bridge" mcp

The tools Claude Code gets:

- `iris_get_workspace_context` — your pillars, platforms, formats, weekly goals and series, so it plans with
  the names you actually use. It is told to call this first.
- `iris_submit_post` — sends one planned post for review.
- `iris_submit_series` — sends a series, one post per episode.
- `iris_list_submissions` — what it has already sent, with your decisions and comments.
- `iris_revise_submission` — a replacement for something you asked it to change. The original stays as history.
- `iris_list_posts` — read saved planner posts for the active account, with search, archived-post filtering and explicit pagination. It returns the snapshot revision and capture time and never changes a post.
- `iris_get_post` — read one saved post in full, including exact creator text, linked-task and linked-idea metadata, and attachment identity/name/type/size metadata. Binary media is never sent through the bridge.
- `iris_find_duplicate_posts` — compare active posts by normalized title, platform and format. Its groups are candidates for review, never proof that posts should be merged or removed.
- `iris_propose_archive_posts` — send up to 100 id-and-revision targets with an account ID, operation ID and reason to Iris for explicit review. The helper requires a matching planner snapshot captured within five minutes, rejects changed or archived targets, and treats an identical operation retry as the same request even after its decision.

**Nothing is saved until you approve it.** Everything the agent sends waits in the Inbox in Ask Iris, where
you review, edit, approve, deny or request changes. Nothing is ever published to a platform; approving only
writes the post into your planner.

On the Mac, a new submission notifies you as soon as it arrives. On iPhone, notifications arrive when the
phone next checks in — in the foreground straight away, in the background every so often. A phone that has
been locked for hours will not be woken: that needs push through Apple's servers, which is a later build.

Planner cleanup needs a compatible Iris app that refreshes its optional planner snapshot. In Iris, compare
candidate records, then review each archive proposal individually; approval archives the matching current
records in the app. The MCP helper has no delete tool, does not merge posts, and cannot approve its own
proposal. Update the app and rerun the Iris Bridge installer before using these tools with an older helper.

To see what is waiting from Terminal:

    iris-bridge inbox                 # id, kind, title and how long it has been waiting
    iris-bridge inbox clear-decided   # forget decided submissions older than 30 days

Inbox features need helper 0.2.0 or newer. Older helpers still chat with Iris.
