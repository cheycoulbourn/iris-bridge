# Iris Bridge

The Mac helper that lets Iris use the Claude Code or Codex subscription already signed in on your Mac.

Install (in Terminal on your Mac):

    curl -fsSL https://raw.githubusercontent.com/cheycoulbourn/iris-bridge/main/install.sh | sh

Then open Iris, choose this Mac under "Macs nearby", and enter the code shown in Terminal.

Commands: `iris-bridge pair`, `iris-bridge status`, `iris-bridge devices`, `iris-bridge revoke <id>`, `iris-bridge inbox`, `iris-bridge uninstall`.

## Send work to Iris from Claude Code

Iris Bridge also hands Claude Code a set of tools for sending finished work to your Iris Inbox. The
installer registers them for you, in every folder. **Start a new Claude Code session after installing** — a
session that was already open will not see them.

Then ask for work the way you would ask a person:

> Plan a 4-episode series for my anchor pillar and send it to Iris.

> Read brief.md and plan it as posts for Iris.

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

**Nothing is saved until you approve it.** Everything the agent sends waits in the Inbox in Ask Iris, where
you review, edit, approve, deny or request changes. Nothing is ever published to a platform; approving only
writes the post into your planner.

On the Mac, a new submission notifies you as soon as it arrives. On iPhone, notifications arrive when the
phone next checks in — in the foreground straight away, in the background every so often. A phone that has
been locked for hours will not be woken: that needs push through Apple's servers, which is a later build.

To see what is waiting from Terminal:

    iris-bridge inbox                 # id, kind, title and how long it has been waiting
    iris-bridge inbox clear-decided   # forget decided submissions older than 30 days

Inbox features need helper 0.2.0 or newer. Older helpers still chat with Iris.
