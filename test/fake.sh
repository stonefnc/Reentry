#!/usr/bin/env bash
# Tests backup, verify and their failure paths against a fake docker command (test/fake-docker).
# This proves the script logic. It does not prove real dumps and restores, see test/e2e.sh for that.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export PATH="$ROOT/test/fake-docker:$PATH" FAKE_LOG="$tmp/docker.log"
fail=0

check() { # check <description> <command...>
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $what"; else echo "FAIL $what"; fail=1; fi
}
fresh() { export REENTRY_BACKUP_DIR="$tmp/$1"; rm -rf "$REENTRY_BACKUP_DIR"; : > "$FAKE_LOG"; }
run() { "$ROOT/reentry" "$@" >"$tmp/out" 2>&1; rc=$?; }
has() { grep -q -- "$1" "$tmp/out"; }
files() { ls "$REENTRY_BACKUP_DIR" | grep -c "$1"; }

fresh a
run backup
check "backup exits 0" [ "$rc" = 0 ]
check "two dumps written" [ "$(files '\.sql\.gz$')" = 2 ]
check "each dump has a sidecar and a counts manifest" [ "$(files '\.sha256$')$(files '\.counts$')" = 22 ]
check "no .partial left behind" [ "$(files partial)" = 0 ]

run verify
check "verify passes" [ "$rc" = 0 ]
check "verify reports PASS for both engines" [ "$(grep -c PASS "$tmp/out")" = 2 ]
check "throwaway containers are removed on success" [ "$(grep -c '^rm .*reentry-verify-' "$FAKE_LOG")" = 2 ]

FAKE_DRIFT=1 run verify
check "writes after the backup do not fail verify (manifest used)" [ "$rc" = 0 ]

FAKE_DROP_ROW=1 run verify
check "a restored table missing a row fails verify" [ "$rc" = 1 ]
check "the mismatch is named" has "row counts differ"

printf x >> "$REENTRY_BACKUP_DIR/$(ls "$REENTRY_BACKUP_DIR" | grep '^mysql.*\.sql\.gz$')"
run verify
check "a corrupted backup fails verify on the checksum" [ "$rc" = 1 ]
check "the checksum failure is named" has "SHA-256 mismatch"

FAKE_DOWN=reentry-mysql run verify
check "a missing container exits 3" [ "$rc" = 3 ]

fresh b
FAKE_FAIL_DUMP=1 run backup
check "a failing dump exits 1" [ "$rc" = 1 ]
check "no files are left after failed dumps" [ "$(ls -A "$REENTRY_BACKUP_DIR" | grep -vc '^\.reentry\.lock$')" = 0 ]

fresh c
FAKE_TRUNCATE=1 run backup
check "a cut-off dump is rejected" [ "$rc" = 1 ]
check "the cut-off dump is named" has "looks incomplete"
check "a rejected dump leaves no backup" [ "$(files '\.sql\.gz$')" = 0 ]

fresh d
FAKE_DOWN=reentry-mysql run backup
check "one engine down still backs up the other" [ "$(files '^postgres.*\.sql\.gz$')" = 1 ]
check "and the run exits 3" [ "$rc" = 3 ]

# off-host copy
fresh f
run backup
check "off-host copy is skipped with a log line when no destination is set" has "off-host copy skipped"
check "and the backup still exits 0" [ "$rc" = 0 ]

fresh g; off="$tmp/off-g"; mkdir -p "$off"
REENTRY_OFFHOST_DEST="$off" run backup
check "a folder destination: backup exits 0" [ "$rc" = 0 ]
check "dump, sidecar and counts of both engines are copied" [ "$(ls "$off" | wc -l)" = 6 ]
check "the copies pass their SHA-256 check at the destination" bash -c "cd '$off' && for s in *.sha256; do sha256sum -c --status \"\$s\" || exit 1; done"
check "the copy is logged as verified" has "off-host copy of .* verified"
check "no temporary copy files are left" [ -z "$(ls -A "$off" | grep '^\.')" ]

fresh h
REENTRY_OFFHOST_DEST="$tmp/not-mounted" run backup
check "a missing destination folder fails the backup with exit 1" [ "$rc" = 1 ]
check "the failure says the local backup is kept" has "local backup .* is kept"
check "both local backups survive" [ "$(files '\.sql\.gz$')" = 2 ]
check "the missing folder is not created" [ ! -e "$tmp/not-mounted" ]

fresh i; off="$tmp/off-i"; mkdir -p "$off"
REENTRY_OFFHOST_DEST="fakehost:$off" run backup
check "a remote destination (rsync and ssh): backup exits 0" [ "$rc" = 0 ]
check "the remote copy is verified" [ "$(ls "$off" | wc -l)" = 6 ]

fresh j; off="$tmp/off-j"; mkdir -p "$off"
REENTRY_OFFHOST_DEST="fakehost:$off" FAKE_RSYNC_CORRUPT=1 run backup
check "a damaged remote copy fails the backup" [ "$rc" = 1 ]
check "the damaged copy is named" has "fails its SHA-256 check"
check "the damaged copy is removed from the destination" [ "$(ls "$off" | wc -l)" = 0 ]
check "the good local backups are kept" [ "$(files '\.sql\.gz$')" = 2 ]

fresh k; off="$tmp/off-k"; mkdir -p "$off"
REENTRY_OFFHOST_DEST="fakehost:$off" FAKE_RSYNC_FAIL=1 run backup
check "a failing rsync exits 1" [ "$rc" = 1 ]
check "the local backups survive an rsync failure" [ "$(files '\.sql\.gz$')" = 2 ]

fresh l
REENTRY_OFFHOST_DEST='bad dest;rm' run backup
check "an unsafe destination is a usage error (exit 2)" [ "$rc" = 2 ]
check "and nothing is written" [ ! -e "$REENTRY_BACKUP_DIR" ]
REENTRY_OFFHOST_DEST="$REENTRY_BACKUP_DIR" run backup
check "the backup folder as destination is a usage error (exit 2)" [ "$rc" = 2 ]

# restore
fresh m
run backup
latest_my="$(ls "$REENTRY_BACKUP_DIR" | grep '^mysql.*\.sql\.gz$')"
: > "$FAKE_LOG"
run restore mysql --target reentry-empty-my --yes
check "restore with --yes into a new database exits 0" [ "$rc" = 0 ]
check "the database is created first" grep -qx "create reentry-empty-my" "$FAKE_LOG"
check "the dump is loaded into the target" grep -qx "load reentry-empty-my" "$FAKE_LOG"
check "row counts are compared with the manifest" has "row counts match"
check "the latest backup is the default" has "using $latest_my"

run restore mysql
check "restore without --yes and without a terminal exits 2" [ "$rc" = 2 ]
check "the guard tells the user to pass --yes" has "pass --yes"
check "nothing was loaded by the refused restore" bash -c "! grep -q 'load reentry-mysql' '$FAKE_LOG'"

: > "$FAKE_LOG"
run restore mysql --yes
check "restore into the default container with --yes exits 0" [ "$rc" = 0 ]
check "the default target is the source container" grep -qx "load reentry-mysql" "$FAKE_LOG"

: > "$FAKE_LOG"
run restore mysql --target reentry-verify-9
check "a throwaway verify container needs no confirmation" [ "$rc" = 0 ]
check "and says so" has "throwaway verify container"

: > "$FAKE_LOG"
run restore mysql --backup "$latest_my" --target reentry-empty-named --database other_db --yes
check "a named backup and database restore" [ "$rc" = 0 ]
check "the restore names the chosen database" has "database other_db"

if command -v script >/dev/null 2>&1; then
  : > "$FAKE_LOG"
  printf 'no\n' | script -qec "'$ROOT/reentry' restore mysql --target reentry-empty-ask" /dev/null >"$tmp/out" 2>&1; rc=$?
  check "answering no at the prompt aborts with exit 1" [ "$rc" = 1 ]
  check "and loads nothing" bash -c "! grep -q '^load' '$FAKE_LOG'"
  printf 'yes\n' | script -qec "'$ROOT/reentry' restore mysql --target reentry-empty-ask" /dev/null >"$tmp/out" 2>&1; rc=$?
  check "answering yes at the prompt restores" [ "$rc" = 0 ]
  check "and loads the dump" grep -qx "load reentry-empty-ask" "$FAKE_LOG"
fi

run restore postgres --yes
check "postgres refuses to restore into a database that already has tables" [ "$rc" = 1 ]
check "the refusal explains why" has "already has tables"
run restore postgres --target reentry-empty-pg --yes
check "postgres restores into an empty database" [ "$rc" = 0 ]

run restore
check "restore without an engine exits 2" [ "$rc" = 2 ]
run restore oracle --yes
check "an unknown engine exits 2" [ "$rc" = 2 ]
run restore mysql --backup ../etc/passwd --yes
check "a path as the backup name exits 2" [ "$rc" = 2 ]
run restore mysql --backup postgres_shop_20260101T000000Z.sql.gz --yes
check "a backup of the other engine exits 2" [ "$rc" = 2 ]
run restore mysql --backup mysql_shop_20200101T000000Z.sql.gz --yes
check "a missing named backup exits 1" [ "$rc" = 1 ]
run restore mysql --target "bad name" --yes
check "a bad container name exits 2" [ "$rc" = 2 ]
FAKE_DOWN=reentry-mysql run restore mysql --yes
check "a target that is not running exits 3" [ "$rc" = 3 ]
printf x >> "$REENTRY_BACKUP_DIR/$latest_my"
: > "$FAKE_LOG"
run restore mysql --yes
check "a corrupted backup is refused on its checksum" [ "$rc" = 1 ]
check "and nothing is loaded" bash -c "! grep -q '^load' '$FAKE_LOG'"

fresh n
run restore mysql --yes
check "restore with no backups exits 1" [ "$rc" = 1 ]

fresh e
check "list exits 1 on an empty folder" bash -c "! '$ROOT/reentry' list"

exit "$fail"
