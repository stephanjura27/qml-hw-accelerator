#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Push the latest changes to GitHub in one step.
#  Run it ON YOUR MAC, inside this folder, AFTER the repo already exists on
#  GitHub (i.e. after you ran publish_to_github.sh once).
#
#  Usage:   bash update_github.sh "short message about what changed"
#  Example: bash update_github.sh "added component diagram"
# ---------------------------------------------------------------------------
set -e
cd "$(dirname "$0")"
MSG="${1:-update}"

git add -A
if git diff --cached --quiet; then
    echo "Nothing changed — GitHub is already up to date."
    exit 0
fi
git commit -m "$MSG"
git push
echo "✓ GitHub updated."
