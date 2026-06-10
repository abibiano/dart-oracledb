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

# ── Check / generate CHANGELOG entry ─────────────────────────────────────────
CHANGELOG="CHANGELOG.md"

if grep -q "^## ${NEW_VERSION}" "$CHANGELOG" 2>/dev/null; then
  echo "Changelog entry for $NEW_VERSION already exists."
else
  echo "No changelog entry for $NEW_VERSION — generating with Claude..."

  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
  if [ -n "$LAST_TAG" ]; then
    GIT_LOG=$(git log "${LAST_TAG}..HEAD" --oneline --no-merges)
  else
    GIT_LOG=$(git log --oneline --no-merges)
  fi

  PROMPT="Generate a CHANGELOG.md entry for version ${NEW_VERSION} of the dart-oracledb Dart package.

Use this exact markdown format:
## ${NEW_VERSION}

[one-sentence summary]

### Features
- ...

### Bug Fixes
- ...

### Breaking Changes
- ...

Omit sections that have no items.
Base the entry on these git commits since the last release:
${GIT_LOG}

Respond with ONLY the markdown — no explanation, no code fences."

  # Capture stderr and check the exit code explicitly (Story 7.9 AC12):
  # under `set -e` a failing command substitution would abort the script
  # with no context, and the old `2>/dev/null` discarded the actual error.
  CLAUDE_STDERR=$(mktemp)
  set +e
  NEW_ENTRY=$(claude -p "$PROMPT" 2>"$CLAUDE_STDERR")
  CLAUDE_STATUS=$?
  set -e
  if [ "$CLAUDE_STATUS" -ne 0 ]; then
    echo "error: 'claude -p' exited with status ${CLAUDE_STATUS}." >&2
    if [ -s "$CLAUDE_STDERR" ]; then
      echo "──── claude stderr ────" >&2
      cat "$CLAUDE_STDERR" >&2
      echo "───────────────────────" >&2
    fi
    rm -f "$CLAUDE_STDERR"
    echo "Add an entry for ## ${NEW_VERSION} to $CHANGELOG manually, then re-run." >&2
    exit 1
  fi
  rm -f "$CLAUDE_STDERR"

  # Secondary guard: a zero exit with empty output is still unusable.
  if [ -z "$NEW_ENTRY" ]; then
    echo "error: Claude did not return a changelog entry." >&2
    echo "Add an entry for ## ${NEW_VERSION} to $CHANGELOG manually, then re-run." >&2
    exit 1
  fi

  echo ""
  echo "──── Generated changelog entry ────────────────────────────────────────"
  echo "$NEW_ENTRY"
  echo "────────────────────────────────────────────────────────────────────────"
  echo ""

  # Insert the new entry after the first line (# Changelog header)
  TMPFILE=$(mktemp)
  head -1 "$CHANGELOG" > "$TMPFILE"
  printf '\n%s\n' "$NEW_ENTRY" >> "$TMPFILE"
  tail -n +2 "$CHANGELOG" >> "$TMPFILE"
  mv "$TMPFILE" "$CHANGELOG"

  echo "CHANGELOG.md updated."
fi

# ── Update pubspec.yaml ───────────────────────────────────────────────────────
sed -i.bak "s/^version: .*/version: $NEW_VERSION/" "$PUBSPEC"
rm -f "${PUBSPEC}.bak"

# ── Commit, tag, push ─────────────────────────────────────────────────────────
TAG="v${NEW_VERSION}"

git add "$PUBSPEC" "$CHANGELOG"
git commit -m "chore: bump version to $NEW_VERSION"
git tag "$TAG"
git push origin HEAD
git push origin "$TAG"

echo ""
echo "Released $TAG — publish.yml will pick it up and push to pub.dev."
