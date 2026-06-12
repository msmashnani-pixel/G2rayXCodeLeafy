#!/usr/bin/env bash
#
# publish-to-github.sh
#
# Log in to GitHub and publish THIS folder to a repository on YOUR account.
# Login uses the official GitHub CLI (gh) device/browser flow, so no token is
# ever written into the project. Safe to run again: it commits whatever has
# changed locally, creates the repo if needed, and pushes so GitHub matches
# your local folder exactly.
#
# Use this version inside a Codespace, on Linux, or on macOS:
#     bash ./publish-to-github.sh
#
set -euo pipefail
cd "$(dirname "$0")"

command -v git >/dev/null 2>&1 || { echo "git is not installed."; exit 1; }
command -v gh  >/dev/null 2>&1 || { echo "GitHub CLI (gh) is not installed: https://cli.github.com"; exit 1; }

[ -d .git ] || { git init >/dev/null; git branch -M main; }

# --- Log in to GitHub ---
# Probe with an API call, not `gh auth status`: status returns nonzero when any
# stored account has an expired token, even if the active account is fine.
user=$(gh api user --jq .login 2>/dev/null || true)
if [ -z "$user" ]; then
    echo "Opening GitHub login..."
    gh auth login
    user=$(gh api user --jq .login 2>/dev/null || true)
    [ -n "$user" ] || { echo "Could not read your GitHub username."; exit 1; }
fi
echo "Logged in as: $user"
read -rp "Publish to this account? Press Enter to accept, or type 'switch' to use another account: " ans
if [ "$ans" = "switch" ]; then
    gh auth login
    user=$(gh api user --jq .login)
    echo "Now logged in as: $user"
fi
gh auth setup-git >/dev/null 2>&1 || true

# --- Repository name and visibility ---
default=$(basename "$PWD")
read -rp "Repository name [$default]: " repo; repo=${repo:-$default}
read -rp "Visibility - type 'private' or 'public' [private]: " vis; [ "$vis" = "public" ] || vis=private
slug="$user/$repo"

# --- Commit pending local changes so GitHub matches local exactly ---
git add -A
if ! git diff --cached --quiet; then
    read -rp "Commit message [Update G2rayXCodeLeafy]: " msg; msg=${msg:-Update G2rayXCodeLeafy}
    git commit -m "$msg" >/dev/null
    echo "Committed local changes."
else
    echo "Nothing new to commit; the working folder already matches the last commit."
fi

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "HEAD" ] && { git branch -M main; branch=main; }

# --- Create the repo on your account if it does not exist yet ---
if ! gh repo view "$slug" >/dev/null 2>&1; then
    echo "Creating $vis repository $slug ..."
    gh repo create "$slug" "--$vis"
fi

# --- Point a dedicated remote at it and push ---
url="https://github.com/$slug.git"
if git remote | grep -qx mine; then git remote set-url mine "$url"; else git remote add mine "$url"; fi
echo "Pushing $branch to $slug ..."
git push -u mine "$branch"

echo ""
echo "  Done. Your project is live at: https://github.com/$slug"
