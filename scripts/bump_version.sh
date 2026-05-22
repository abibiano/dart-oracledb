#!/usr/bin/env bash
# Bump the package version, commit, tag, and push.
# The publish.yml workflow picks up the tag and publishes to pub.dev.
#
# Usage:
#   ./scripts/bump_version.sh              # alpha.N → alpha.N+1  (default)
#   ./scripts/bump_version.sh alpha        # same as default
#   ./scripts/bump_version.sh beta         # → beta.1 (resets number)
#   ./scripts/bump_version.sh rc           # → rc.1
#   ./scripts/bump_version.sh stable       # removes pre-release (0.1.0-alpha.X → 0.1.0)
#   ./scripts/bump_version.sh patch        # → next patch, alpha.1  (0.1.0 → 0.1.1-alpha.1)
#   ./scripts/bump_version.sh minor        # → next minor, alpha.1  (0.1.0 → 0.2.0-alpha.1)
#   ./scripts/bump_version.sh major        # → next major, alpha.1  (0.1.0 → 1.0.0-alpha.1)
#   ./scripts/bump_version.sh --dry-run    # print new version without changing anything

set -euo pipefail

PUBSPEC="pubspec.yaml"
DRY_RUN=false
ACTION="alpha"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) ACTION="$arg" ;;
  esac
done

# ── Read current version ──────────────────────────────────────────────────────
CURRENT=$(grep '^version:' "$PUBSPEC" | sed 's/version: *//')
echo "Current version: $CURRENT"

# ── Parse semver ─────────────────────────────────────────────────────────────
# Supports: MAJOR.MINOR.PATCH  or  MAJOR.MINOR.PATCH-TYPE.NUM
SEMVER_RE='^([0-9]+)\.([0-9]+)\.([0-9]+)(-([a-zA-Z]+)\.([0-9]+))?$'

if [[ ! "$CURRENT" =~ $SEMVER_RE ]]; then
  echo "error: cannot parse version '$CURRENT'" >&2
  exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"
PRE_TYPE="${BASH_REMATCH[5]:-}"   # e.g. alpha, beta, rc  (empty if stable)
PRE_NUM="${BASH_REMATCH[6]:-0}"   # e.g. 1

# ── Compute new version ───────────────────────────────────────────────────────
case "$ACTION" in
  alpha|beta|rc)
    if [ "$ACTION" = "$PRE_TYPE" ]; then
      # Same pre-release type: just bump the number
      NEW_PRE_NUM=$(( PRE_NUM + 1 ))
      NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}-${ACTION}.${NEW_PRE_NUM}"
    else
      # Changing pre-release type: reset to .1
      NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}-${ACTION}.1"
    fi
    ;;
  stable)
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
    ;;
  patch)
    NEW_PATCH=$(( PATCH + 1 ))
    NEW_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}-alpha.1"
    ;;
  minor)
    NEW_MINOR=$(( MINOR + 1 ))
    NEW_VERSION="${MAJOR}.${NEW_MINOR}.0-alpha.1"
    ;;
  major)
    NEW_MAJOR=$(( MAJOR + 1 ))
    NEW_VERSION="${NEW_MAJOR}.0.0-alpha.1"
    ;;
  *)
    echo "error: unknown action '$ACTION'" >&2
    echo "usage: $0 [alpha|beta|rc|stable|patch|minor|major|--dry-run]" >&2
    exit 1
    ;;
esac

echo "New version:     $NEW_VERSION"

if [ "$DRY_RUN" = true ]; then
  echo "(dry run — no changes made)"
  exit 0
fi

# ── Require clean working tree ────────────────────────────────────────────────
if ! git diff --quiet HEAD; then
  echo "error: working tree is dirty. Commit or stash changes first." >&2
  exit 1
fi

# ── Update pubspec.yaml ───────────────────────────────────────────────────────
sed -i.bak "s/^version: .*/version: $NEW_VERSION/" "$PUBSPEC"
rm -f "${PUBSPEC}.bak"

# ── Commit, tag, push ─────────────────────────────────────────────────────────
TAG="v${NEW_VERSION}"

git add "$PUBSPEC"
git commit -m "chore: bump version to $NEW_VERSION"
git tag "$TAG"
git push origin HEAD
git push origin "$TAG"

echo ""
echo "Released $TAG — publish.yml will pick it up and push to pub.dev."
