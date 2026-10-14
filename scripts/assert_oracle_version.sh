#!/usr/bin/env bash
# Assert the release reached through a running Oracle container's FREEPDB1.
# Usage: assert_oracle_version.sh CONTAINER EXPECTED_PREFIX [DOCKER_CONTEXT]
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 CONTAINER EXPECTED_PREFIX [DOCKER_CONTEXT]" >&2
  exit 2
fi

docker_args=()
if [ "$#" -eq 3 ]; then
  docker_args=(--context "$3")
fi

version="$(docker "${docker_args[@]}" exec -i "$1" \
  sqlplus -L -S system/testpassword@//localhost:1521/FREEPDB1 <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT VERSION_FULL FROM V$INSTANCE;
EXIT
SQL
)"
version="$(echo "$version" | tr -d '[:space:]')"
if [[ "$version" != "$2"* ]]; then
  echo "Expected Oracle version beginning $2, got ${version:-no version}" >&2
  exit 1
fi
echo "Oracle version verified: $version"
