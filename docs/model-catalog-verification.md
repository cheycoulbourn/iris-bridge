# Connected-provider model catalog verification

This record covers the unreleased 0.2.3 bridge model-catalog capability.

## HTTP contract

An already-paired device calls `GET /models?provider=codex` or
`GET /models?provider=claude` with its bearer token. A successful reply is:

```json
{
  "provider": "codex",
  "models": [{"id": "…", "name": "…", "efforts": ["…"], "defaultEffort": "…"}],
  "source": "live-codex-app-server",
  "notice": null,
  "defaultModelID": "…"
}
```

`provider`, `models`, and `source` are always present. `notice` and
`defaultModelID` are optional. Missing or unsupported provider returns 400;
missing or invalid bearer token returns 401. A provider that is not ready or
cannot be enumerated returns HTTP 200 with `models: []`, `source:
"unavailable"`, and a notice that preserves Automatic. A 60-second in-memory
result is returned as `source: "cached-…"` with an explicit cache notice.
The catalog is availability information, not an entitlement promise.

## Live, read-only protocol evidence

These commands sent no user prompt and did not run inference. Their raw output
was intentionally not saved because it can contain account metadata.

- `codex app-server --help` documented `--stdio`. `codex app-server
generate-json-schema` documented the v2 `initialize` then `model/list`
sequence. `ModelListResponse` provides `data[].model`, `displayName`,
`hidden`, `isDefault`, `defaultReasoningEffort`,
`supportedReasoningEfforts[].reasoningEffort`, and `nextCursor`. The live
probe did not require an initialized notification before `model/list`.
- Claude Code 2.1.274 accepted a stream-json `control_request` whose request
is `{ "subtype": "initialize" }`, using `-p --safe-mode --tools ''
--permission-mode dontAsk --disable-slash-commands --strict-mcp-config
--mcp-config '{"mcpServers":{}}' --no-session-persistence`. Its successful
control response exposed subscription-scoped `models`,
`supportsEffort`, and `supportedEffortLevels`. The bridge uses those values
directly; it has no static Claude alias fallback and never assumes an effort
for a model.

The Claude Agent SDK type surface exposes initialization and supported-model
information in the [SDK declarations](https://app.unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.211/files/sdk.d.ts).
Claude's [CLI reference](https://docs.anthropic.com/en/docs/claude-code/cli-usage)
documents model and effort controls.

## Runtime limits and forwarding

Codex asks for `includeHidden: false`, follows at most ten pages, and has a
12-second total discovery deadline. Both catalog subprocesses cap stdout at
256 KiB, drain stderr, and terminate/reap on exit or timeout. The parser
handles line chunks plus Codex JSON-RPC `id` and Claude nested
`response.request_id` correlation.

Automatic is represented by an omitted `effort`: it skips catalog discovery
and sends neither `--effort` nor `model_reasoning_effort`. A supplied effort
must be a bounded lowercase token and appear in the current selected model's
catalog entry. Claude receives `--effort VALUE`; Codex receives
`-c model_reasoning_effort="VALUE"`. No CLI permission mode is weakened.

## Test record

On 2026-09-19, `swift test` compiled all source and tests but Xcode codesign
rejected Finder/provenance extended attributes on the generated
`.build/out/Products/Debug/IrisBridgeCoreTests.xctest` bundle. Only that
build product was cleared and ad-hoc-signed before the normal XCTest runner:

```sh
swift test > /tmp/iris-bridge-swift-test.log 2>&1
find .build/out/Products/Debug/IrisBridgeCoreTests.xctest -type f -exec xattr -c {} +
find .build/out/Products/Debug/IrisBridgeCoreTests.xctest -type d -exec xattr -c {} +
codesign --force --sign - --timestamp=none .build/out/Products/Debug/IrisBridgeCoreTests.xctest
xcrun xctest .build/out/Products/Debug/IrisBridgeCoreTests.xctest
```

The direct XCTest run passed 185 tests with zero failures; the one opt-in live
catalog test is skipped unless explicitly enabled. The suite includes
HTTP authentication/provider tests, empty-effort rejection, cached-source
labeling, server-advertised Codex capability mapping, Claude initialize
capability mapping, safe argv forwarding, unavailable-catalog rejection, and
a chunked fake-executable transport test for both provider protocols.

For a local, read-only end-to-end parser check against the installed signed-in
CLIs, run:

```sh
IRIS_BRIDGE_LIVE_CATALOG=1 xcrun xctest -XCTest ProvidersTests/testLiveCatalogDiscoveryUsesShippingParserWhenExplicitlyRequested .build/out/Products/Debug/IrisBridgeCoreTests.xctest
```

This test asserts only provider identity, nonempty catalog, and unique IDs; it
does not print models, account data, credentials, prompts, or responses.

## Release record

Iris Bridge 0.2.3 was released on 2026-09-19. Tag `v0.2.3` resolves to
commit `137e00574c902ae3bae8537ec2ecb8777bce59ed`. The universal macOS
binary was signed with Developer ID Application: Cheyenne Coulbourn
(`2S27MSM8G8`) and Apple notarization submission
`62fad1d0-34ab-4786-9d6f-a877803ae4b8` completed with status Accepted.

The published `iris-bridge-0.2.3-macos.tar.gz` and its uploaded checksum file
both verify SHA-256 `61e5f3fa5456ec94d85ea8ea1d3f15dc44905448b5c4acf9e09e9d87b7c370f7`.
