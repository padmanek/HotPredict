#!/usr/bin/env bash
# Publishes the version in the .toc as a GitHub release that WowUp can install and update:
#   <Name>-v<version>.zip  - the addon folder, only the files the game needs
#   release.json           - tells WowUp which zip is for which game flavor ("forever" = WoW Forever)
# Usage: ./release.sh ["release notes"]   (needs git, the GitHub CLI signed in, and Windows' tar.exe)
set -euo pipefail
cd "$(dirname "$0")"

NAME=$(basename "$(pwd)")
TOC="$NAME.toc"
VERSION=$(sed -n 's/^## Version: *//p' "$TOC" | tr -d '\r')
INTERFACE=$(sed -n 's/^## Interface: *//p' "$TOC" | tr -d '\r' | cut -d, -f1 | tr -d ' ')
TAG="v$VERSION"
ZIP="$NAME-$TAG.zip"
NOTES=${1:-"$NAME $TAG"}

if [ -n "$(git status --porcelain)" ]; then echo "Commit your changes first." >&2; exit 1; fi
if git rev-parse "$TAG" >/dev/null 2>&1; then echo "$TAG already exists: raise ## Version in $TOC." >&2; exit 1; fi

rm -rf dist
mkdir -p "dist/$NAME"
# Everything tracked except the repo's own files
git ls-files | grep -v -E '^(README\.md|LICENSE|release\.sh|\.gitignore|\.gitattributes)$' | while read -r f; do
  mkdir -p "dist/$NAME/$(dirname "$f")"
  cp "$f" "dist/$NAME/$f"
done
cp LICENSE "dist/$NAME/LICENSE"
# Windows' own tar writes real zips with forward slashes (Compress-Archive in PowerShell 5 does not)
(cd dist && /c/Windows/System32/tar.exe -a -c -f "$ZIP" "$NAME")

cat > dist/release.json <<EOF
{
  "releases": [
    {
      "name": "$NAME",
      "version": "$TAG",
      "filename": "$ZIP",
      "nolib": false,
      "metadata": [ { "flavor": "forever", "interface": $INTERFACE } ]
    }
  ]
}
EOF

git tag "$TAG"
git push origin HEAD "$TAG"
gh release create "$TAG" "dist/$ZIP" dist/release.json --title "$NAME $TAG" --notes "$NOTES"
echo "Released $NAME $TAG"
