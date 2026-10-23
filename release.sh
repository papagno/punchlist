#!/bin/zsh
# Builds, signs and notarizes Punchlist, publishes it as a GitHub release,
# and points the Homebrew cask at it.
#
# usage: ./release.sh 0.1.0
#
# Needs a "Developer ID Application" certificate in the keychain, notarytool credentials
# saved as a keychain profile, and gh signed in with push access to this repo and the tap.
# Optional environment: SIGN_IDENTITY, NOTARY_PROFILE (default "apps-notary").
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>, e.g. 0.1.0}"
TAG="v$VERSION"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-apps-notary}"
REPO="papagno/punchlist"
TAP="papagno/homebrew-tap"
APP="build/Punchlist.app"
ZIP="build/Punchlist-$VERSION.zip"

fail() { print -r -- "$1" >&2; exit 1; }

# Only release what's on GitHub: a clean main that matches origin, with no tag for this version yet.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "The version must look like 1.2.3."
[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first."
[[ "$(git branch --show-current)" == main ]] || fail "Release from main."
git fetch --quiet origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't in sync with origin/main."
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "$TAG already exists."

print "==> Building and signing $VERSION"
VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" ./bundle.sh

print "==> Notarizing (usually a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
# Zip again so the download carries the stapled ticket and opens without a network check.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
SHA256=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

print "==> Publishing $TAG"
git tag -a "$TAG" -m "Punchlist $VERSION"
git push --quiet origin "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Punchlist $VERSION" --notes "Install or update with Homebrew:

\`\`\`bash
brew install --cask papagno/tap/punchlist
\`\`\`

Requires macOS 27. Signed with a Developer ID and notarized by Apple."

print "==> Updating the Homebrew cask"
TAP_DIR=$(mktemp -d)
gh repo clone "$TAP" "$TAP_DIR" -- --quiet
CASK="$TAP_DIR/Casks/punchlist.rb"
sed -i '' -E "s/^  version \".*\"$/  version \"$VERSION\"/; s/^  sha256 \".*\"$/  sha256 \"$SHA256\"/" "$CASK"
git -C "$TAP_DIR" commit --quiet -am "punchlist $VERSION"
git -C "$TAP_DIR" push --quiet
rm -rf "$TAP_DIR"

print "Released $TAG. Install with: brew install --cask papagno/tap/punchlist"
