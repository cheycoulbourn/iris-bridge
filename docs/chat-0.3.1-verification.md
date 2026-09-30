# Iris Bridge 0.3.1 chat verification

Verified 2026-09-30. Implementation commits: `fbf51ed`, `b4b417e`, `fcadeac`.
This is a verified local activation, not a public release.

## Permission and reply evidence

The installed Codex 0.159.0 CLI was tested against a synthetic local MCP server using `gpt-6.1-sol`, low
effort, a read-only sandbox and ignored user configuration. No creator records or real Iris mutations
were used. The workspace read succeeded, but the draft mutation was rejected before reaching the MCP
server with `MCP tool call requires approval, but approval policy is never`.

The fix lists all 25 existing Iris tools from IrisToolCatalog and applies individual
`mcp_servers.iris.tools.<tool>.approval_mode="approve"` overrides on both fresh and resumed runs. The
same synthetic read and draft call then reached the server and returned its fictional Inbox receipt on
both runs. This trusts only the named Iris tools. Other servers, the Claude-only approval tool and unknown
tools receive no override. Shell, apps, browser, hooks and plugins remain disabled; connector approval
and the app's Inbox review boundary remain intact. Recorded transcripts and provenance are in
[Fixtures/README.md](../Tests/IrisBridgeCoreTests/Fixtures/README.md).

Run UUID checks prevent late Codex output or process exit from contaminating or failing a successor reply
or deleting its attachments. Regression tests also verify cancellation of that successor.

## Post references and final tests

Successful `iris_get_post` reads for either provider carry internal metadata from the exact snapshot
returned. Active-turn checks and per-turn deduplication publish only canonical post/profile UUIDs. The
wire uses existing `type: "thinking"` plus `postReference: {postID, profileID}` so older apps consume its
sequence normally. Failed, missing, invalid and terminal reads do not produce cards. See the
[reference contract](post-reference-contract.md).

The final compatible source passed `swift test` using an external scratch directory: **380 tests,
one skipped, zero failures** (28.54 seconds). The skip is the optional installed-CLI catalog-discovery
test, gated by `IRIS_BRIDGE_LIVE_CATALOG=1`. The affected compatibility suite separately passed 30 tests.
App card resolution, profile validation, rendering and draft Inbox policy belong to the companion app
change; this report does not claim physical-device UI verification.

## Local activation

The owner explicitly authorized an idle restart and confirmed Iris was closed. Immediately before
activation there was no macOS Iris process and no process descended from the resident bridge. A simulator
test process was identified separately and left untouched. The prior executable was backed up outside
the repository, the signed executable was replaced atomically, and `install-agent` restarted the helper.

Resident status changed from 0.3.0 to **0.3.1**, with a new process id and reachable status. Pairing count
remained **4 before / 4 after**. The audit checked 14 protected path entries; existing certificate, key,
admin/device, context, action, session, Inbox, snapshot and event files retained their hashes. No support
root replacement, pairing reset or data migration occurred.

The activated binary is universal arm64/x86_64, targets macOS 15, and passed strict Developer ID team
verification with hardened runtime and timestamp. Its SHA-256 is:

`85240d2f47e59b21029a219f8cd1a1ff6d749b47c0a5df48000e663aadc214ea`

## Routing and public release gate

The parent supplied the live Jev permission/lifecycle route: confidence 0.43 was below its threshold and
the recommended Terra execution model was unavailable. The parent explicitly selected fallback
`gpt-6.1-sol` at high effort. A later reference-specific live route recommended Sol medium at confidence
0.91; the existing stronger integration agent was retained. No duplicate paid route or extra subagent
was created. These are routing decisions, not correctness evidence.

No merge to main, public tag, notarization or public release was performed. The local signed fix is
active. Public release remains gated by the README checks and `scripts/release.sh`, including a fresh
live smoke record for this source with the required Claude v2/v3 steps. That release gate has not passed
in this work.
