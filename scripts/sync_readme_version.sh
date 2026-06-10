#!/usr/bin/env bash
# Keep README package dependency examples aligned with pubspec.yaml.
#
# Usage:
#   scripts/sync_readme_version.sh          # update README.md in place
#   scripts/sync_readme_version.sh --check  # verify README.md is already aligned

set -euo pipefail

PUBSPEC="pubspec.yaml"
README="README.md"
CHECK=false

for arg in "$@"; do
  case "$arg" in
    --check) CHECK=true ;;
    *)
      echo "error: unknown argument '$arg'" >&2
      echo "usage: $0 [--check]" >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$PUBSPEC" ]; then
  echo "error: missing $PUBSPEC" >&2
  exit 1
fi

if [ ! -f "$README" ]; then
  echo "error: missing $README" >&2
  exit 1
fi

VERSION=$(sed -n 's/^version:[[:space:]]*//p' "$PUBSPEC" | head -n 1)
if [ -z "$VERSION" ]; then
  echo "error: could not read package version from $PUBSPEC" >&2
  exit 1
fi

REF_PATTERN='oracledb: \^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?'

if [ "$CHECK" = true ]; then
  refs=$(grep -Eo "$REF_PATTERN" "$README" | sed 's/oracledb: \^//' | sort -u || true)
  if [ -z "$refs" ]; then
    echo "error: no README dependency references matching 'oracledb: ^<version>' found" >&2
    exit 1
  fi

  while IFS= read -r ref_version; do
    if [ "$ref_version" != "$VERSION" ]; then
      echo "error: README references oracledb ^$ref_version, but pubspec.yaml is $VERSION" >&2
      echo "Run scripts/sync_readme_version.sh to update README.md." >&2
      exit 1
    fi
  done <<EOF
$refs
EOF

  # Extract badge version: strip URL up to 'pub-v', then strip the trailing color
  # suffix (e.g. '-orange') which is always all-lowercase letters with no digits or dots.
  badge_version=$(grep -Eo 'img\.shields\.io/badge/pub-v[0-9][^)"#? ]*' "$README" \
    | sed 's/.*pub-v//' | sed 's/-[a-z][a-z]*$//' \
    | head -n 1 || true)
  if [ -z "$badge_version" ]; then
    echo "error: no pub badge matching 'img.shields.io/badge/pub-v<version>-<color>' found in README" >&2
    exit 1
  fi
  if [ "$badge_version" != "$VERSION" ]; then
    echo "error: README pub badge shows v$badge_version, but pubspec.yaml is $VERSION" >&2
    echo "Run scripts/sync_readme_version.sh to update README.md." >&2
    exit 1
  fi

  echo "README version references match pubspec.yaml: $VERSION"
  exit 0
fi

PACKAGE_VERSION="$VERSION" perl -0pi -e \
  's/oracledb: \^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?/oracledb: ^$ENV{PACKAGE_VERSION}/g' \
  "$README"

PACKAGE_VERSION="$VERSION" perl -0pi -e \
  's%(img\.shields\.io/badge/pub-v)\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?=-[a-z]+(?:[\s)"#?\]]|$))%${1}$ENV{PACKAGE_VERSION}%g' \
  "$README"

"$0" --check
