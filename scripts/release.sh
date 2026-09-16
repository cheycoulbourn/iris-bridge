#!/bin/sh
# Usage: scripts/release.sh 0.1.0   (requires: Developer ID cert in login keychain, a notarytool keychain profile, gh CLI signed in)
set -eu
VERSION="$1"
IDENTITY="Developer ID Application: Cheyenne Coulbourn (2S27MSM8G8)"
# The Apple ID credentials notarization needs are already stored on this Mac under the profile name below,
# from the agent.cy release that shipped before this one. Set NOTARY_PROFILE to use a different one; create
# one with: xcrun notarytool store-credentials <name> --apple-id <apple id> --team-id 2S27MSM8G8
NOTARY_PROFILE="${NOTARY_PROFILE:-agentcy-notary}"
# This checkout lives in iCloud Drive, where SwiftPM's in-tree .build races the sync daemon and fails
# mid-build. Every build goes to a scratch path outside the synced folder instead.
SCRATCH="/tmp/iris-bridge-build"
grep -q "current = \"$VERSION\"" Sources/IrisBridgeCore/Version.swift || { echo "Set BridgeVersion.current to $VERSION first."; exit 1; }
rm -rf dist && mkdir -p dist
swift build -c release --scratch-path "$SCRATCH" --arch arm64 --arch x86_64
# Ask the toolchain where the universal product landed rather than hardcoding a layout: the path moved
# between SwiftPM's old build system and Swift Build, and a stale guess would ship the wrong binary.
BIN_PATH=$(swift build -c release --scratch-path "$SCRATCH" --arch arm64 --arch x86_64 --show-bin-path)
cp "$BIN_PATH/iris-bridge" dist/iris-bridge
lipo -info dist/iris-bridge
codesign --force --sign "$IDENTITY" --options runtime --timestamp dist/iris-bridge
codesign --verify --strict dist/iris-bridge
# The installer refuses any download that does not meet this requirement, so a release that fails it here
# would install nowhere. Check it before the tag exists, not after.
codesign --verify -R '=anchor apple generic and certificate leaf[subject.OU]="2S27MSM8G8"' dist/iris-bridge
ditto -c -k --keepParent dist/iris-bridge dist/notarize.zip
xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
TARBALL="dist/iris-bridge-$VERSION-macos.tar.gz"
tar -czf "$TARBALL" -C dist iris-bridge
(cd dist && shasum -a 256 "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256")
git tag -a "v$VERSION" -m "Iris Bridge $VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" "$TARBALL" "$TARBALL.sha256" --title "Iris Bridge $VERSION" --notes "Signed and notarized Mac helper for Iris."
echo "Released v$VERSION"
