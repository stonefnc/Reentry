#!/usr/bin/env bash
# Tests prune and list on fake backup files. Needs no Docker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
export REENTRY_BACKUP_DIR="$dir"
fail=0

check() { # check <description> <condition command...>
  local what=$1; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fail=1; fi
}
present() { [ -f "$dir/$1" ] && [ -f "$dir/$1.sha256" ]; }
gone() { [ ! -e "$dir/$1" ] && [ ! -e "$dir/$1.sha256" ]; }

mk() { echo fake > "$dir/$1"; (cd "$dir" && sha256sum "$1" > "$1.sha256"); }
for s in 20261020T020000Z 20261020T010000Z 20261019T010000Z 20261018T010000Z 20261001T010000Z 20260915T010000Z; do
  mk "mysql_shop_$s.sql.gz"
done
mk postgres_shop_20250101T010000Z.sql.gz

export REENTRY_KEEP_DAILY=2 REENTRY_KEEP_WEEKLY=1 REENTRY_KEEP_MONTHLY=1

"$ROOT/reentry" prune --dry-run 2>/dev/null
check "dry run deletes nothing" present mysql_shop_20261018T010000Z.sql.gz

"$ROOT/reentry" prune 2>/dev/null
check "keeps newest of the newest day" present mysql_shop_20261020T020000Z.sql.gz
check "keeps second distinct day" present mysql_shop_20261019T010000Z.sql.gz
check "drops older backup from a kept day" gone mysql_shop_20261020T010000Z.sql.gz
check "drops third day" gone mysql_shop_20261018T010000Z.sql.gz
check "drops older month" gone mysql_shop_20261001T010000Z.sql.gz
check "drops oldest" gone mysql_shop_20260915T010000Z.sql.gz
check "other engine group untouched" present postgres_shop_20250101T010000Z.sql.gz

REENTRY_KEEP_DAILY=0 REENTRY_KEEP_WEEKLY=0 REENTRY_KEEP_MONTHLY=0 "$ROOT/reentry" prune 2>/dev/null
check "newest of a group survives all-zero limits" present mysql_shop_20261020T020000Z.sql.gz
check "all-zero limits prune the rest" gone mysql_shop_20261019T010000Z.sql.gz

set +e
REENTRY_KEEP_DAILY=abc "$ROOT/reentry" prune 2>/dev/null; rc=$?
set -e
check "non-numeric retention exits 2" [ "$rc" = 2 ]

check "list reports ok checksum" bash -c "'$ROOT/reentry' list | grep -q 'mysql_shop_20261020T020000Z.sql.gz.*ok'"
printf x >> "$dir/mysql_shop_20261020T020000Z.sql.gz"
check "list flags a corrupted file" bash -c "'$ROOT/reentry' list | grep -q CHECKSUM-MISMATCH"

exit "$fail"
