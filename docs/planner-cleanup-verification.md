# Planner cleanup, version 0.2.4

September 19, 2026. Companion app: Iris build 114.

Four additive MCP tools read saved planner posts, retrieve exact details, identify possible duplicate groups, and propose an archive for in-app review. No MCP tool permanently deletes, merges, approves, or rewrites existing posts. Both app and helper validate account identity and record revisions. New proposals require a snapshot no older than five minutes. An identical operation-ID retry returns the original submission even if it was already approved and the snapshot is now stale.

The app sends all selected-profile posts with attachment metadata, not attachment bodies. A 16 MiB transport cap fails explicitly instead of truncating creator writing. Older apps continue to use their existing context contract. App build 114 gates planner transport on helper 0.2.4.

Validation: `swift test --parallel` completed successfully with 192 XCTest tests. Focused regression covers an approved request retried against an archived target and stale snapshot. Existing loopback/admin authentication, paired-client authorization, and pending-capacity boundaries remain covered. `git diff --check` passed.

The app retains archive and bridge-import undo receipts. Workspace import rollback is local to the device that imported the file. Old imports without an exact rollback receipt cannot safely gain automatic undo retrospectively. Live partner devices and installed helpers are not changed by publishing this release; update the helper through the documented install command.
