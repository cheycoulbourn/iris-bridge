# Provider output fixtures

Each fixture is what a provider CLI printed for one failed turn: `<name>.stdout` (JSON events, one per line)
and/or `<name>.stderr`. `ProviderOutputTests` and `ProvidersTests` read them through `Fixture.result`.

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
