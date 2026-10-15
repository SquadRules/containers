#!/usr/bin/env bash
# sync-wiki.sh - Sync .qoder/repowiki/en/content/ to the GitHub Wiki repository.
#
# Single source of truth for wiki publishing, used by both CI and local runs.
#
# Usage:
#   # Local: clone the wiki to /tmp, sync, commit, and push.
#   bash scripts/sync-wiki.sh
#
#   # CI: reuse an already-checked-out wiki working copy (with push creds).
#   WIKI_WORKDIR=wiki bash scripts/sync-wiki.sh
#
# Environment / arguments:
#   SOURCE_DIR    Source content dir (default: .qoder/repowiki/en/content).
#   WIKI_WORKDIR  Existing wiki checkout to reuse. When unset, the script
#                 clones the wiki repo into /tmp.
#   REPO_OWNER    GitHub org / user (default: SquadRules).
#   REPO_NAME     Repository name  (default: containers).
#
# Prerequisites (local runs only):
#   - Wiki repository already initialized (visit the /wiki tab once).
#   - Push access via the credential helper (gh) or SSH.

set -euo pipefail

REPO_OWNER="${REPO_OWNER:-SquadRules}"
REPO_NAME="${REPO_NAME:-containers}"
SOURCE_DIR="${SOURCE_DIR:-.qoder/repowiki/en/content}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}GitHub Wiki Sync${NC}"
echo "=================="

# Resolve the source directory to an absolute path BEFORE any cd, then validate.
if [ ! -d "$SOURCE_DIR" ]; then
  echo -e "${RED}Error: source directory '${SOURCE_DIR}' not found${NC}" >&2
  echo "Run Qoder Repo Wiki generation first, or check your working directory." >&2
  exit 1
fi
SOURCE_ABS="$(cd "$SOURCE_DIR" && pwd)"
if [ -z "$(ls -A "$SOURCE_ABS")" ]; then
  echo -e "${RED}Error: source directory '${SOURCE_DIR}' is empty${NC}" >&2
  exit 1
fi
echo "Source: ${SOURCE_ABS}"

# Capture the repo root so we can read the source commit after we cd away.
REPO_ROOT="$(pwd)"

# Resolve the wiki working copy: reuse WIKI_WORKDIR (CI) or clone to /tmp (local).
CLONED_TEMP=""
if [ -n "${WIKI_WORKDIR:-}" ]; then
  if [ ! -d "$WIKI_WORKDIR/.git" ]; then
    echo -e "${RED}Error: WIKI_WORKDIR='${WIKI_WORKDIR}' is not a git checkout${NC}" >&2
    exit 1
  fi
  WIKI_ABS="$(cd "$WIKI_WORKDIR" && pwd)"
  echo -e "${YELLOW}Using existing wiki checkout: ${WIKI_ABS}${NC}"
else
  CLONED_TEMP="/tmp/${REPO_NAME}.wiki"
  if [ -d "$CLONED_TEMP/.git" ]; then
    echo -e "${YELLOW}Updating existing wiki clone...${NC}"
    git -C "$CLONED_TEMP" fetch origin
    git -C "$CLONED_TEMP" reset --hard "origin/$(git -C "$CLONED_TEMP" symbolic-ref --short HEAD)"
  else
    echo -e "${YELLOW}Cloning wiki repository...${NC}"
    rm -rf "$CLONED_TEMP"
    git clone "https://github.com/${REPO_OWNER}/${REPO_NAME}.wiki.git" "$CLONED_TEMP"
  fi
  WIKI_ABS="$CLONED_TEMP"
fi

# Build a flat, navigable GitHub Wiki from the nested Qoder source tree, then
# one-way sync the built pages into the wiki working copy. GitHub Wiki is a flat
# namespace, so the raw nested tree cannot be mirrored verbatim without losing
# navigation and colliding duplicate page titles; scripts/build-wiki.mjs handles
# the transform (flatten + Home + _Sidebar + source-link rewrite).
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
echo "Building wiki pages from ${SOURCE_ABS}/ ..."
SOURCE_DIR="$SOURCE_ABS" \
REPO_OWNER="$REPO_OWNER" \
REPO_NAME="$REPO_NAME" \
  node "$REPO_ROOT/scripts/build-wiki.mjs" "$BUILD_DIR"

echo "Running rsync from ${BUILD_DIR}/ ..."
rsync -a --delete --exclude ".git" "${BUILD_DIR}/" "${WIKI_ABS}/"

# Commit and push only if there is a change (no empty commits).
if [ -z "$(git -C "$WIKI_ABS" status --porcelain)" ]; then
  echo -e "${GREEN}Wiki is already up to date${NC}"
  exit 0
fi

echo -e "${YELLOW}Changes detected. Committing...${NC}"
git -C "$WIKI_ABS" config user.name "github-actions[bot]"
git -C "$WIKI_ABS" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$WIKI_ABS" add -A

SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
git -C "$WIKI_ABS" commit -m "docs: sync Qoder Repo Wiki content

Source commit: ${SOURCE_COMMIT}
Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

echo "Pushing to GitHub Wiki..."
git -C "$WIKI_ABS" push origin "HEAD:$(git -C "$WIKI_ABS" symbolic-ref --short HEAD)"

echo -e "${GREEN}Wiki updated successfully!${NC}"
echo "View at: https://github.com/${REPO_OWNER}/${REPO_NAME}/wiki"
