# Provider output fixtures

Each `.stdout`/`.stderr` fixture is what a provider CLI printed for one failed v2 turn: `<name>.stdout` (JSON
events, one per line) and/or `<name>.stderr`. `ProviderOutputTests` and `ProvidersTests` read them through
`Fixture.result`.

| Fixture | Provenance |
|---|---|
| `codex-usage-limit` | Recorded. Codex 0.155.0-alpha.9.2 on the owner's Mac, 2026-09-23 03:10 UTC: `thread.started` (real id), `turn.started`, `error`, `turn.failed`. The message is Codex's own, as it appears in the owner's `~/.codex` logs. A non-fatal `item.completed` warning line from that run is left out. |
| `codex-disconnected` | Message recorded in the owner's `~/.codex` logs; event framing as in `codex-usage-limit`. |
| `codex-signed-out` | Constructed. Codex's refresh-token message, not observed on this Mac. |
| `codex-no-events` | Constructed: a run that printed only to stderr. |
| `claude-session-limit` | Message and `error: "rate_limit"` recorded in the owner's Claude Code 2.1.227 transcripts. The `init` and `result` lines are constructed in the stream-json shape `ProviderService` parses. |
| `claude-oauth-expired` | Message and `error: "authentication_failed"` recorded (Claude Code 2.1.274); framing constructed. |
| `claude-token-revoked` | Message recorded (Claude Code 2.1.271). Result line only, so the cause is read from the text. |
| `claude-overloaded` | Message and `error: "server_error"` recorded (Claude Code 2.1.255); framing constructed. |
| `claude-offline` | Message recorded (Claude Code 2.1.255). Result line only. |
| `claude-usage-credits` | Message and `error: "rate_limit"` recorded; framing constructed. |
| `claude-no-output` | Constructed: a run that printed only to stderr. |

To re-record, run the CLI the way the helper does while the account is in that state, and redirect its
stdout and stderr to `<name>.stdout` and `<name>.stderr` here.

## v3 session transcripts (0.3.0)

Each `.jsonl` transcript is one provider session as `ScriptedLauncher` replays it: `{"dir":"in","obj":…}` is a
line the helper must write next (matched on `type`, and on `request.subtype` for control requests),
`{"dir":"out","obj":…}` a line the CLI printed, `{"dir":"exit","status":…,"stderr":…}` the CLI exiting. A
string `"@name.json"` stands for that fixture's JSON. Content is fictional throughout; no account data, email
or connector content from the owner's Mac is in any of them.

| Fixture | Provenance |
|---|---|
| `claude-mcp-status.json` | Shape recorded by spike run q2-f (`mcpServers` with `name`, `status`, `scope`, `source`, `config`, `tools` with Claude Code's `annotations`). Servers are fictional apart from connector and tool names that are public. Two Google Calendar tools are made up to test the approval rules against annotations: `createEventFromTemplate` (marked readOnly, as a real connector marks a tool that creates something) and `fetch_and_clear_reminders` (marked destructive, with a name that reads like a read). |
| `claude-session-turns` | Shapes recorded by the Iris Bridge v3 spike on Claude Code 2.1.274 (runs q3-a, q5-a and q2-h2: `initialize` and `mcp_status` control responses, `system init`, `rate_limit_event`, `stream_event` thinking and text deltas, full `assistant` messages with `tool_use`, `user` messages with `tool_result`, `result`). Text, ids and tool inputs replaced. |
| `claude-interrupt` | Shape recorded by spike run q5-d: `interrupt` answered `{still_queued: []}`, `[Request interrupted by user]`, `result` `error_during_execution` with no `result`, then the same process answers the next message. |
| `claude-turn-usage-limit` | The `claude-session-limit` message and `error: "rate_limit"` above, in the stream-json session shape. |
| `claude-api-key` | Constructed: a `system init` whose `apiKeySource` is not `none`. |
| `claude-exit-mid-turn` | Constructed: the process exits during a turn; stderr is the `claude-oauth-expired` message. |
| `codex-exec-usage-limit` | Recorded: spike run q4-a on Codex 0.155.0-alpha.9.2 (`thread.started`, `turn.started`, `error`, `turn.failed`, exit 1). |
| `codex-exec-tool-call` | Constructed from Codex's documented `exec --json` output (`item.started`/`item.completed` with `mcp_tool_call`, `reasoning`, `agent_message`; `turn.completed` with `usage`). **Unverified** until spike task S7 records a real run; replace it with the recorded lines then. |
| `codex-exec-resume` | Constructed like `codex-exec-tool-call`, for `codex exec resume`. **Unverified** until S7. |
| `codex-exec-hang` | Constructed: a run that never finishes, for cancel. |
| `snapshot-v2.json` | Constructed: a fictional workspace in snapshot schema 2 (contract §5). |
