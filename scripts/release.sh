#!/bin/sh
# Manual semantic release: bump version.txt + the release-please manifest, tag,
# push and create the GitHub Release. The tag push makes ci.yml publish:
#
#   ghcr.io/<owner>/<repo>:X.Y.Z, :X.Y, :X, :latest, :sha-<commit>
#
# Usage: scripts/release.sh 1.2.3
set -eu

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: scripts/release.sh X.Y.Z" >&2
  exit 1
fi

case "$VERSION" in
  *[!0-9.]* | .* | *..* | *.)
    echo "not a semantic version: $VERSION" >&2
    exit 1
    ;;
esac

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is not clean; commit or stash first" >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "tag v$VERSION already exists" >&2
  exit 1
fi

printf '%s\n' "$VERSION" >version.txt
printf '{".": "%s"}\n' "$VERSION" >.release-please-manifest.json

git add version.txt .release-please-manifest.json
if ! git diff --cached --quiet; then
  git commit -m "chore: release $VERSION"
fi

git tag -a "v$VERSION" -m "v$VERSION"
git push origin HEAD
git push origin "v$VERSION"

if command -v gh >/dev/null 2>&1; then
  gh release create "v$VERSION" --generate-notes --title "v$VERSION"
fi

echo "==> released v$VERSION"
