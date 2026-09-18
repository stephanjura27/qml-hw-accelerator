#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  One-command publish of this project to a new GitHub repository.
#  Run it ON YOUR MAC (this folder), with git installed and the GitHub CLI
#  logged in once:   gh auth login
#  Usage:            bash publish_to_github.sh   [repo-name]
# ---------------------------------------------------------------------------
set -e
cd "$(dirname "$0")"
REPO="${1:-qml-hw-accelerator}"

if [ ! -d .git ]; then
    git init -q
    git add -A
    git commit -q -m "QML hardware accelerator: RTL, verification, diagrams, on-chip classifier"
fi
git branch -M main 2>/dev/null || true

if command -v gh >/dev/null 2>&1; then
    gh repo create "$REPO" --public --source=. --remote=origin --push
    echo "Done — repo created and pushed."
else
    echo "GitHub CLI (gh) not found."
    echo "1) create an empty repo named '$REPO' on https://github.com/new"
    echo "2) then run:"
    echo "     git remote add origin https://github.com/<your-username>/$REPO.git"
    echo "     git push -u origin main"
fi
