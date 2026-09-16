#!/bin/sh
# Usage: scripts/release.sh 0.1.0   (requires: Developer ID cert in login keychain, a notarytool keychain profile, gh CLI signed in)
#
# Runs in this order so that nothing outside this machine is mutated until every artifact exists and has
# been verified:
#
#   preflight (tag/branch/tree/tooling) -> build -> sign -> notarize -> tarball -> git tag -> git push -> gh release create
#
# Recovery, by the point at which it failed:
#
#   * Any failure BEFORE `git tag` (preflight, build, sign, notarize, tarball): nothing outside this Mac was
#     touched and nothing was published. Fix the problem and re-run the script. `dist/` is wiped and rebuilt
#     on every run.
#   * `git push` failed after `git tag` succeeded: the tag exists only locally. Either re-run the script
#     after deleting it (`git tag -d v$VERSION`) or push it yourself (`git push origin main v$VERSION`)
#     and continue with `gh release create` by hand.
#   * `gh release create` failed after `git push` succeeded: the tag is on origin with no release behind
#     it. Do NOT re-run the script (it will stop at the tag guard). Either publish from the artifacts still
#     sitting in `dist/`:
#         gh release create "v$VERSION" "dist/iris-bridge-$VERSION-macos.tar.gz" \
#             "dist/iris-bridge-$VERSION-macos.tar.gz.sha256" --title "Iris Bridge $VERSION" \
#             --notes "Signed and notarized Mac helper for Iris."
#     or unwind the tag and start over:
#         git tag -d "v$VERSION"; git push origin ":refs/tags/v$VERSION"
#   * Notarization rejected: the submission log says why. The script prints the exact
#     `xcrun notarytool log <id>` command; `dist/notary.log` keeps the submission output.
set -eu

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "Usage: scripts/release.sh <version>   (e.g. scripts/release.sh 0.1.0)"; exit 1; }

IDENTITY="Developer ID Application: Cheyenne Coulbourn (2S27MSM8G8)"
# The Apple ID credentials notarization needs are already stored on this Mac under the profile name below,
# from the agent.cy release that shipped before this one. Set NOTARY_PROFILE to use a different one; create
# one with: xcrun notarytool store-credentials <name> --apple-id <apple id> --team-id 2S27MSM8G8
NOTARY_PROFILE="${NOTARY_PROFILE:-agentcy-notary}"
# This checkout lives in iCloud Drive, where SwiftPM's in-tree .build races the sync daemon and fails
# mid-build. Every build goes to a scratch path outside the synced folder instead.
SCRATCH="/tmp/iris-bridge-build"

# --- Preflight: everything that can be known before a single byte is built. ------------------------------
# The tag is checked first and in both places it can exist. Re-running a release that already shipped would
# otherwise burn a notarization round trip only to die at `git tag`.
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "v$VERSION already tagged locally; bump the version or delete the tag: git tag -d v$VERSION"
    exit 1
fi
# Fails closed: an unreachable origin is not proof that the tag is free, and guessing wrong here is how a
# released version gets rebuilt under the same tag.
if ! REMOTE_TAG=$(git ls-remote --tags origin "v$VERSION"); then
    echo "Cannot reach origin to check whether v$VERSION is already tagged. Fix the network or the remote, then try again."
    exit 1
fi
if [ -n "$REMOTE_TAG" ]; then
    echo "v$VERSION already tagged on origin; bump the version or delete the tag: git tag -d v$VERSION; git push origin :refs/tags/v$VERSION"
    exit 1
fi

[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Release from main."; exit 1; }

# A dirty tree means the tag would not describe what was built. Untracked files count: a source file nobody
# committed still compiles into the binary this tag names.
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first (untracked files count; see git status)."; exit 1; }

grep -qF "current = \"$VERSION\"" Sources/IrisBridgeCore/Version.swift || { echo "Set BridgeVersion.current to $VERSION first."; exit 1; }

# Both of these fail slowly and late otherwise: gh at the very last step, notarytool after a full build.
gh auth status >/dev/null 2>&1 || { echo "gh is not signed in. Run: gh auth login"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "notarytool cannot use keychain profile '$NOTARY_PROFILE'."
    echo "Create it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id 2S27MSM8G8"
    echo "Or set NOTARY_PROFILE to an existing profile name."
    exit 1
}

# --- Build ----------------------------------------------------------------------------------------------
rm -rf dist && mkdir -p dist
swift build -c release --scratch-path "$SCRATCH" --arch arm64 --arch x86_64
# Ask the toolchain where the universal product landed rather than hardcoding a layout: the path moved
# between SwiftPM's old build system and Swift Build, and a stale guess would ship the wrong binary.
# Warnings can precede the path on stdout, so take the last line.
BIN_PATH=$(swift build -c release --scratch-path "$SCRATCH" --arch arm64 --arch x86_64 --show-bin-path | tail -1)
[ -x "$BIN_PATH/iris-bridge" ] || { echo "No executable at $BIN_PATH/iris-bridge after a successful build."; exit 1; }
cp "$BIN_PATH/iris-bridge" dist/iris-bridge

# A single-slice binary builds and signs and notarizes just fine; it simply does not run on half the Macs
# the installer offers it to. Assert both slices rather than eyeballing lipo's output.
LIPO_INFO=$(lipo -info dist/iris-bridge)
echo "$LIPO_INFO"
echo "$LIPO_INFO" | grep -qw x86_64 && echo "$LIPO_INFO" | grep -qw arm64 || {
    echo "Not a universal binary: need both x86_64 and arm64 slices."
    exit 1
}

# --- Sign -----------------------------------------------------------------------------------------------
codesign --force --sign "$IDENTITY" --options runtime --timestamp dist/iris-bridge
codesign --verify --strict dist/iris-bridge
# The installer refuses any download that does not meet this requirement, so a release that fails it here
# would install nowhere. Check it before the tag exists, not after.
codesign --verify -R '=anchor apple generic and certificate leaf[subject.OU]="2S27MSM8G8"' dist/iris-bridge

# --- Notarize -------------------------------------------------------------------------------------------
ditto -c -k --keepParent dist/iris-bridge dist/notarize.zip
# notarytool exits 0 for a submission that completed but was *rejected*, so the accepted status is asserted
# from the log rather than inferred from the exit code.
xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee dist/notary.log || true
# Anchored: notarytool's own output indents the status, and an unanchored match would also accept the string
# appearing inside a message or a path.
if ! grep -q '^ *status: Accepted' dist/notary.log; then
    SUBMISSION_ID=$(sed -n 's/^ *id: *//p' dist/notary.log | head -1)
    echo "Notarization was not accepted. Nothing has been tagged or published."
    echo "Submission id: ${SUBMISSION_ID:-<none found; see dist/notary.log>}"
    if [ -n "$SUBMISSION_ID" ]; then
        echo "Details: xcrun notarytool log $SUBMISSION_ID --keychain-profile \"$NOTARY_PROFILE\""
    fi
    exit 1
fi

# --- Package --------------------------------------------------------------------------------------------
TARBALL="dist/iris-bridge-$VERSION-macos.tar.gz"
tar -czf "$TARBALL" -C dist iris-bridge
(cd dist && shasum -a 256 "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256")

# --- Publish: first step that touches anything outside this machine. -------------------------------------
git tag -a "v$VERSION" -m "Iris Bridge $VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" "$TARBALL" "$TARBALL.sha256" --title "Iris Bridge $VERSION" --notes "Signed and notarized Mac helper for Iris."
echo "Released v$VERSION"
