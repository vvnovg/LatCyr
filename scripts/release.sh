#!/bin/bash
# Publishes the version in VERSION as a GitHub release.
#
# Usage: ./scripts/release.sh
#
# Refuses unless: the tree is clean, the branch is main and pushed, the tag
# v<VERSION> doesn't exist yet, and CHANGELOG.md has a "## [<VERSION>]"
# section. Then runs the tests, packages the app, zips it, tags the commit,
# pushes the tag and creates the release with that CHANGELOG section as notes.
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

swift test
./scripts/package-app.sh
rm -f dist/LatCyr.zip
ditto -c -k --keepParent dist/LatCyr.app dist/LatCyr.zip

NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<MD
## Установка
1. Скачай \`LatCyr.zip\`, распакуй, перемести \`LatCyr.app\` в «Программы».
2. Открой через правый клик → Open (ad-hoc подпись, Gatekeeper). Если Mac пишет «файл повреждён» — \`xattr -cr LatCyr.app\`.
3. Выдай разрешения **Accessibility** и **Input Monitoring** в System Settings → Privacy & Security. При обновлении сначала удали LatCyr из обоих списков и добавь заново: у новой сборки другая подпись.
4. Перезапусти приложение.
$NOTES
MD

git tag -a "$TAG" -m "LatCyr $VERSION"
git push origin "$TAG"
gh release create "$TAG" dist/LatCyr.zip --verify-tag --title "LatCyr $VERSION" --notes-file "$NOTES_FILE"
echo "Released $TAG"
