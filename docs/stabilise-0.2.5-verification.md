# Stabilising release, version 0.2.5

September 23, 2026. Code a5430c55c8c7, commit a724ac9. Companion: the Iris phase 0 build.

Every error reply keeps its 0.2.4 `error` text and status code and adds `cause`; provider failures add `provider`, `details` and, for a usage limit, `resetsAt`. Authenticated `/status` adds `paired`, `capabilities` and per-provider `health`, and refuses an unknown token with 401. The in-turn Claude Code update is gone. Provider failure parsing is tested against the fixtures in `Tests/IrisBridgeCoreTests/Fixtures`; their provenance is in its README.

Validation, stub CLIs: `swift test`: 	 Executed 249 tests, with 1 test skipped and 0 failures (0 unexpected) in 5.909 (5.924) seconds. integration: ok. install-test: ok. smoke-test: ok.

Live smoke test against this Mac's Claude Code and Codex (`sh scripts/smoke.sh`):

    PASS  status without a token keeps the 0.2.4 shape
    PASS  status with a device token adds paired, capabilities and health
          claude: installed=true signedIn=true plan=Max cli=2.1.274 usage=unknown
          codex: installed=true signedIn=true plan= cli=0.155.0-alpha.9.2 usage=unknown
    PASS  status with an unknown token is refused as deviceRevoked
    PASS  iris-bridge status prints health and addresses
    PASS  claude turn answered with model claude-opus-5[1m]
    SKIP  codex turn: ChatGPT's usage limit is reached until Sep 26, 8:41 AM.
    PASS  MCP server lists the Iris tools and reaches this helper
    PASS  MCP says not running once the helper stops
    smoke: ok (1 live turn(s); recorded code a5430c55c8c71e313d2f402fd67734d6f678d7cd3cb06f9ed2c878b68157e6b9 for scripts/release.sh)

Publishing this release does not change installed helpers; each Mac updates through the documented install command.
