#!/bin/bash
# Publishes docs/ (the website and its screenshots) to https://maclister.github.io, which is served from the
# repository MacLister/maclister.github.io. Run it after changing docs/ or after Tools/make_screenshots.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
SITE_REPO="MacLister/maclister.github.io"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone -q "https://github.com/$SITE_REPO.git" "$WORK/site"
# mirror docs/ into the repository root (the page's own files, assets and screenshots)
rsync -a --delete --exclude '.git' --exclude '.DS_Store' docs/ "$WORK/site/"
cd "$WORK/site"
touch .nojekyll
git add -A
if git diff --cached --quiet; then echo "The site is already up to date."; exit 0; fi
git commit -q -m "Update the site from the MacLister repository" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git push -q origin HEAD:main
echo "Published: https://maclister.github.io/"
