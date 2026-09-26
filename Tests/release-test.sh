#!/bin/sh
# Runs scripts/release.sh's preflight on scratch repositories and checks each refusal it must make before it
# builds, signs or publishes anything. Nothing here reaches the network, the keychain or GitHub: origin is a local
# bare repository, and gh, xcrun, swift, codesign, lipo and ditto are stubs that fail the test if they ever run.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
VERSION=9.9.9
export GIT_AUTHOR_NAME=release-test GIT_AUTHOR_EMAIL=release-test@example.invalid
export GIT_COMMITTER_NAME=release-test GIT_COMMITTER_EMAIL=release-test@example.invalid

mkdir -p "$WORK/bin"
for tool in gh xcrun swift codesign lipo ditto; do
  printf '#!/bin/sh\necho "STUB-RAN: %s" >&2\nexit 97\n' "$tool" >"$WORK/bin/$tool"
  chmod +x "$WORK/bin/$tool"
done

commit() { git -C "$1" add -A && git -C "$1" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "$2"; }

# A tree release.sh would accept up to its smoke check, on main, pushed to its own bare origin. Package.swift
# names the scratch folder, so no smoke marker in /tmp/iris-bridge-smoke can match its code.
make_repo() {
  R="$WORK/$1"
  git init -q --bare "$R.origin.git"
  git init -q -b main "$R"
  mkdir -p "$R/scripts" "$R/Sources/IrisBridgeCore" "$R/Tests/IrisBridgeCoreTests/Providers"
  cp "$HERE/scripts/release.sh" "$R/scripts/release.sh"
  printf '// swift-tools-version: 6.0\n// %s\n' "$R" >"$R/Package.swift"
  printf 'public enum BridgeVersion {\n    public static let current = "%s"\n}\n' "$VERSION" >"$R/Sources/IrisBridgeCore/Version.swift"
  printf '# Changelog\n\n## %s\n\n- This release.\n\n## 9.9.8\n\n- The one before.\n' "$VERSION" >"$R/CHANGELOG.md"
  printf 'import XCTest\n' >"$R/Tests/IrisBridgeCoreTests/Providers/SignInCheckTests.swift"
  commit "$R" "releasable"
  git -C "$R" remote add origin "$R.origin.git"
  git -C "$R" push -q origin main
}

# release.sh's output. It must refuse (exit non-zero) without running any stub. Called as OUT=$(preflight …), so
# its own complaints go to stderr, where they are not swallowed with the output it returns.
preflight() {
  if OUT=$(cd "$WORK/$1" && PATH="$WORK/bin:$PATH" sh scripts/release.sh "$VERSION" 2>&1); then
    printf '%s\n' "$OUT" >&2; echo "release-test: $1: release.sh went all the way through" >&2; exit 1
  fi
  if printf '%s' "$OUT" | grep -q 'STUB-RAN'; then
    printf '%s\n' "$OUT" >&2; echo "release-test: $1: preflight ran a build, signing or publishing tool" >&2; exit 1
  fi
  printf '%s' "$OUT"
}

expect() {
  printf '%s' "$2" | grep -qF -- "$3" || { printf '%s\n' "$2"; echo "release-test: $1: expected \"$3\""; exit 1; }
}

# --- 1. A releasable main, one commit ahead of origin, passes every check up to the smoke run ---------------------
make_repo good
printf '\n- One more note.\n' >>"$WORK/good/CHANGELOG.md"; commit "$WORK/good" "ahead of origin"
OUT=$(preflight good)
expect good "$OUT" "Run sh scripts/smoke.sh on this code first."

# --- 2. A release branch is not released; it says how to get onto main -----------------------------------------------
make_repo branch
git -C "$WORK/branch" switch -q -c "release/$VERSION"
OUT=$(preflight branch)
expect branch "$OUT" "Release from main. Merge release/$VERSION into main first (on main: git merge --ff-only release/$VERSION)"

# --- 3. origin/main moved on: refused before anything is tagged, not at `git push origin main` after it -----------
make_repo behind
git clone -q "$WORK/behind.origin.git" "$WORK/elsewhere"
printf 'x\n' >"$WORK/elsewhere/NOTES"; commit "$WORK/elsewhere" "pushed from elsewhere"
git -C "$WORK/elsewhere" push -q origin main
OUT=$(preflight behind)
expect behind "$OUT" "origin/main has commits this main does not."
# The same once those commits are fetched but not merged: fetching is not enough, main must contain them.
git -C "$WORK/behind" fetch -q origin
OUT=$(preflight behind)
expect behind-fetched "$OUT" "origin/main has commits this main does not."

# --- 4. A merge that resolved CHANGELOG.md to main's side and lost this version's entry --------------------------
make_repo changelog
printf '# Changelog\n\n## 9.9.8\n\n- The one before.\n' >"$WORK/changelog/CHANGELOG.md"; commit "$WORK/changelog" "lost the entry"
OUT=$(preflight changelog)
expect changelog "$OUT" "CHANGELOG.md has no \"## $VERSION\" entry."

# --- 5. A merge that brought a moved test file back at its old path ---------------------------------------------
make_repo duplicate
printf 'import XCTest\n' >"$WORK/duplicate/Tests/IrisBridgeCoreTests/SignInCheckTests.swift"; commit "$WORK/duplicate" "old path back"
OUT=$(preflight duplicate)
expect duplicate "$OUT" "Two test files share a name"
expect duplicate "$OUT" "    Tests/IrisBridgeCoreTests/Providers/SignInCheckTests.swift"
expect duplicate "$OUT" "    Tests/IrisBridgeCoreTests/SignInCheckTests.swift"

echo "release-test: ok"
