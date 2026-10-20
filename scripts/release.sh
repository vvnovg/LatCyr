#!/bin/bash
# Publishes the version in VERSION as a GitHub release.
#
# Usage: ./scripts/release.sh
#
# Refuses unless: the tree is clean, the branch is main and pushed, the tag
# v<VERSION> doesn't exist yet, and CHANGELOG.md has a "## [<VERSION>]"
# section. Then runs the tests, packages the app (Developer ID signature is
# required), notarizes it and staples the ticket, zips it, tags the commit,
# pushes the tag and creates the release with that CHANGELOG section as notes.
#
# Notarization uses the keychain profile latcyr-notary (NOTARY_PROFILE
# overrides), created once with:
#   xcrun notarytool store-credentials latcyr-notary --apple-id <id> --team-id JHWW538CH9
#
# To release: bump VERSION, add the CHANGELOG section, commit, push, run this.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v${VERSION}"
fail() { echo "release: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION '$VERSION' is not X.Y.Z"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "working tree has uncommitted changes"
[[ "$(git branch --show-current)" == "main" ]] || fail "not on main"
git fetch --quiet origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not pushed (or is behind origin)"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG already exists"

# The section body: from "## [VERSION]" up to the next "## " heading.
NOTES="$(awk -v v="## [$VERSION]" 'index($0, v) == 1 {on=1; next} on && /^## / {exit} on {print}' CHANGELOG.md)"
[[ -n "${NOTES//[[:space:]]/}" ]] || fail "CHANGELOG.md has no section for $VERSION"

NOTARY_PROFILE="${NOTARY_PROFILE:-latcyr-notary}"

swift test
./scripts/package-app.sh
codesign -dvv dist/LatCyr.app 2>&1 | grep "^Authority=Developer ID Application" >/dev/null \
    || fail "dist/LatCyr.app is not signed with Developer ID (certificate missing from the keychain?)"

# notarytool takes a zip; the stapled ticket goes into the .app, so the zip
# that ships is made again afterwards.
rm -f dist/LatCyr.zip
ditto -c -k --keepParent dist/LatCyr.app dist/LatCyr.zip
NOTARY_OUT="$(xcrun notarytool submit dist/LatCyr.zip --keychain-profile "$NOTARY_PROFILE" --wait)"
echo "$NOTARY_OUT"
grep -q "status: Accepted" <<<"$NOTARY_OUT" \
    || fail "notarization was not accepted (details: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)"
xcrun stapler staple dist/LatCyr.app
spctl --assess --type execute dist/LatCyr.app || fail "Gatekeeper rejects the notarized app"
rm -f dist/LatCyr.zip
ditto -c -k --keepParent dist/LatCyr.app dist/LatCyr.zip

NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<MD
## Установка
1. Скачай \`LatCyr.zip\`, распакуй, перемести \`LatCyr.app\` в «Программы».
2. Открой LatCyr (сборка подписана Developer ID и нотаризована Apple).
3. Выдай разрешения **Accessibility** и **Input Monitoring** в System Settings → Privacy & Security и перезапусти приложение. При обновлении с версии, подписанной Developer ID, разрешения сохраняются; при обновлении с 0.3.1 и старше (ad-hoc подпись) удали LatCyr из обоих списков и добавь заново.
$NOTES
MD

git tag -a "$TAG" -m "LatCyr $VERSION"
git push origin "$TAG"
gh release create "$TAG" dist/LatCyr.zip --verify-tag --title "LatCyr $VERSION" --notes-file "$NOTES_FILE"
echo "Released $TAG"
