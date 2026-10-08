# Local and QR pairing verification

Date: 2026-10-07. Source changes only; no installed helper, user data, release, or live app-group file was changed.

## Requirements and implementation

- Same-Mac connection pins the helper using a public descriptor in Iris's existing app group. Standard `serve` writes only `{version:1,fingerprint}` from the actual loaded certificate. Scratch `--root` instances never write the descriptor. Existing group/child paths must be directories owned by this user, with no symlink or group/other write access; writes use directory-relative no-follow operations and atomic replacement, child mode 0700 and file mode 0600.
- `/pair/local` requires loopback, no Origin, JSON, platform `mac`, and a 32-hex confirmation. A fixed AppleScript receives only the formatted first 12 hex characters through argv. The person compares that number in Iris and the macOS dialog. Cancel is the default, and the dialog/process deadline is 60 seconds. No production flag can approve it automatically.
- Only one confirmation can be pending. A ten-second cooldown and three prompts per minute apply globally. Approval creates only a 256-bit one-use approval token in memory, retaining its hash and original confirmation/name for 60 seconds. `/pair/local/complete` validates and atomically consumes it before saving a device. Denial, abandonment, mismatched completion, expired completion, and replay create no device.
- Loopback-admin `/admin/pair-qr` creates a ten-minute, 256-bit hex challenge in memory. `/pair/qr` validates the HMAC using UTF-8 hex-secret bytes and lowercase certificate fingerprint, accepts Mac/iPhone/iPad, and atomically consumes the challenge once. A new QR replaces the previous QR. iPad retains the existing store's `iphone` mobile-platform grouping. Legacy `/pair` and its independent manual code remain unchanged.
- `iris-bridge pair` prints a CoreImage terminal QR and manual code; `--code-only` preserves the fallback. The encoded content is `iris-pair:` plus base64url JSON. Fixed black/white ANSI cells include a four-module quiet zone. Too-small terminals receive a required-width message. Redirected default QR output is refused to keep credentials out of logs.

## Passed evidence

1. `swift test --scratch-path /tmp/iris-bridge-pairing-build`: 388 tests, zero failures, one existing opt-in live-provider catalog test skipped. Includes local request guards, deny/no-device, challenge validation, one pending prompt, cooldown/rate bounds, deferred persistence, completion mismatch/replay/expiry, QR mismatch/replay/expiry/replacement/rate bounds, and legacy compatibility.
2. `PairingFlowTests.testRealTLSQRPairingAndLegacyCLICompatibility`: temporary certificate/root, random-port listener, certificate-pinned URLSession, admin QR issuance, iPad QR pairing, Origin refusal, single-use proof, and manual pairing. QR URL reports the listener's actual port.
3. `PairingFlowTests.testQREncodingIsVersionedBase64URLAndTerminalHasQuietZone`: Apple Vision decodes a raster reconstructed from the exact terminal glyphs back to the complete original QR string.
4. `python3 Tests/pairing-cli-test.py /tmp/iris-bridge-pairing-build/debug/iris-bridge`: isolated stub-provider TLS helper verifies wide PTY QR output, narrow width guidance, manual fallback, headless refusal, no credentials in logs, and no scratch app-group write.
5. The fixed native AppleScript compiles with `/usr/bin/osacompile` without opening a dialog. `git diff --check` passes. The initial default `.build` location failed code signing because it carries FinderInfo/file-provider attributes; the documented scratch build passed.

## Remaining verification

The real native confirmation was not displayed or approved during automated checks. Physical iPhone/iPad camera scanning, Iris's app-group entitlement access, and the combined app/helper owner review remain unverified. The installed helper and its existing devices were not restarted or changed. These source changes do not authorize installation, deployment, distribution, or publishing.

## Internal app release follow-up

Owner confirmed a real iPhone QR connection against an isolated helper on port 48732, then requested Git and the internal app build. Re-ran 388 helper tests (one existing opt-in skip, zero failures) and the isolated TLS/PTY CLI regression successfully. Source push only: the public helper installer remains version 0.3.0 and this does not publish a new binary or replace the everyday helper.
