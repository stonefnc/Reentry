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

# encryption at rest
printf 'correct horse battery staple\n' > "$tmp/key"; chmod 600 "$tmp/key"
printf 'a different passphrase\n' > "$tmp/wrongkey"; chmod 600 "$tmp/wrongkey"
mkdir -p "$tmp/gnupg"; chmod 700 "$tmp/gnupg"; export GNUPGHOME="$tmp/gnupg"
for tool in openssl gpg; do
  if ! command -v "$tool" >/dev/null 2>&1; then echo "skip $tool tests, $tool not installed"; continue; fi
  fresh "enc-$tool"; off="$tmp/off-$tool"; mkdir -p "$off"
  REENTRY_ENCRYPT=$tool REENTRY_ENCRYPT_KEY_FILE="$tmp/key" REENTRY_OFFHOST_DEST="$off" run backup
  check "$tool: encrypted backup exits 0" [ "$rc" = 0 ]
  check "$tool: the log says the backup is encrypted" has "encrypted with $tool"
  check "$tool: both dumps are stored as .sql.gz.enc" [ "$(files '\.sql\.gz\.enc$')" = 2 ]
  check "$tool: no plaintext dump or partial file is left" [ "$(files '\.sql\.gz$')$(files partial)" = 00 ]
  enc_my="$(ls "$REENTRY_BACKUP_DIR" | grep '^mysql.*\.sql\.gz\.enc$')"
  check "$tool: the stored file is not a gzip stream" bash -c "! gzip -t '$REENTRY_BACKUP_DIR/$enc_my'"
  check "$tool: the checksum covers the stored file and passes without the key" bash -c "cd '$REENTRY_BACKUP_DIR' && sha256sum -c --status '$enc_my.sha256'"
  check "$tool: the encrypted backups are copied off-host" [ "$(ls "$off" | grep -c '\.sql\.gz\.enc$')" = 2 ]

  REENTRY_ENCRYPT_KEY_FILE="$tmp/key" run verify
  check "$tool: verify decrypts and passes (no REENTRY_ENCRYPT needed)" [ "$rc" = 0 ]
  check "$tool: verify reports PASS for both engines" [ "$(grep -c PASS "$tmp/out")" = 2 ]
  : > "$FAKE_LOG"
  REENTRY_ENCRYPT_KEY_FILE="$tmp/key" run restore mysql --target reentry-empty-enc --yes
  check "$tool: restore decrypts and loads" [ "$rc" = 0 ]
  check "$tool: the decrypted dump reached the target" grep -qx "load reentry-empty-enc" "$FAKE_LOG"

  REENTRY_ENCRYPT_KEY_FILE="$tmp/wrongkey" run verify
  check "$tool: verify with the wrong key exits 1" [ "$rc" = 1 ]
  check "$tool: the wrong key is reported as a decrypt problem" has "cannot be decrypted"
  run verify
  check "$tool: verify without a key setting exits 2" [ "$rc" = 2 ]
  check "$tool: the missing key is named" has "REENTRY_ENCRYPT_KEY_FILE"
  REENTRY_ENCRYPT_KEY_FILE="$tmp/no-such-key" run restore mysql --target reentry-empty-x --yes
  check "$tool: restore with a missing key file exits 3" [ "$rc" = 3 ]
  run list
  check "$tool: list works without the key" [ "$rc" = 0 ]
  run prune
  check "$tool: prune handles encrypted backups and keeps the newest" [ "$rc" = 0 ] 
  check "$tool: both encrypted backups are still there after prune" [ "$(files '\.sql\.gz\.enc$')" = 2 ]
done

fresh o
REENTRY_ENCRYPT=openssl run backup
check "encryption on with no key setting exits 2" [ "$rc" = 2 ]
check "and no backup is taken" [ ! -e "$REENTRY_BACKUP_DIR" ] 
fresh p
REENTRY_ENCRYPT=openssl REENTRY_ENCRYPT_KEY_FILE="$tmp/no-such-key" run backup
check "encryption on with a missing key file exits 3" [ "$rc" = 3 ]
check "no plaintext backup is written as a fallback" [ "$(files '\.sql\.gz')" = 0 ]
fresh q
REENTRY_ENCRYPT=rot13 REENTRY_ENCRYPT_KEY_FILE="$tmp/key" run backup
check "an unknown encryption tool exits 2" [ "$rc" = 2 ]
: > "$tmp/empty-key"
REENTRY_ENCRYPT=openssl REENTRY_ENCRYPT_KEY_FILE="$tmp/empty-key" run backup
check "an empty key file exits 3" [ "$rc" = 3 ]

# catalog and status
fresh s1
run status
check "status with no catalog exits 1" [ "$rc" = 1 ]
check "and says how to create it" has "status --refresh"
run backup
check "backup writes the catalog" [ -f "$REENTRY_BACKUP_DIR/.catalog.tsv" ]
check "the catalog has one row per backup" [ "$(wc -l < "$REENTRY_BACKUP_DIR/.catalog.tsv" | tr -d ' ')" = 2 ]
check "both rows record checksum ok" [ "$(cut -f4 "$REENTRY_BACKUP_DIR/.catalog.tsv" | grep -c '^ok$')" = 2 ]
check "off-host is none when no destination is set" [ "$(cut -f6 "$REENTRY_BACKUP_DIR/.catalog.tsv" | grep -c '^none$')" = 2 ]
run status
check "status exits 0 after a good backup" [ "$rc" = 0 ]
check "status names both engines" [ "$(grep -c '^mysql/shop\|^postgres/shop' "$tmp/out")" = 2 ]
check "status shows the latest good backup and its age" has "latest good .*age 0h"
check "status says off-host is not configured" has "off-host not configured"
run list
check "list shows the off-host state from the catalog" has "off-host none"

first_my="$(ls "$REENTRY_BACKUP_DIR" | grep '^mysql.*\.sql\.gz$')"
printf x >> "$REENTRY_BACKUP_DIR/$first_my"
run status
check "status trusts the catalog until a refresh (size changed, hash cached)" [ "$rc" = 0 ] 
run status --refresh
check "status --refresh re-hashes and finds the damaged backup" [ "$rc" = 1 ]
check "the failure names the engine" has "has no good backup"
check "the catalog now records the mismatch" grep -q "mismatch" "$REENTRY_BACKUP_DIR/.catalog.tsv"

fresh s2
mkdir -p "$REENTRY_BACKUP_DIR"
mkold() { # mkold <engine> <stamp>: a small fake backup with a valid checksum file
  local n="${1}_shop_${2}.sql.gz"
  printf 'x' > "$REENTRY_BACKUP_DIR/$n"
  (cd "$REENTRY_BACKUP_DIR" && sha256sum "$n" > "$n.sha256")
}
mkold mysql 20200101T000000Z; mkold postgres 20200101T000000Z
run status --refresh
check "backups older than the age limit make status exit 1" [ "$rc" = 1 ]
check "the stale backup is named" has "older than 48 hours"
REENTRY_MAX_AGE_HOURS=100000 run status
check "REENTRY_MAX_AGE_HOURS raises the limit" [ "$rc" = 0 ]
REENTRY_MAX_AGE_HOURS=abc run status
check "a bad REENTRY_MAX_AGE_HOURS exits 2" [ "$rc" = 2 ]
run status --bogus
check "an unknown status option exits 2" [ "$rc" = 2 ]
mkold mysql 20200102T000000Z
run status
check "status warns when the catalog is out of date" has "does not match the files"

fresh s3; off="$tmp/off-s3"; mkdir -p "$off"
REENTRY_OFFHOST_DEST="$off" run backup
REENTRY_OFFHOST_DEST="$off" run status
check "off-host verified: status exits 0" [ "$rc" = 0 ]
check "status shows the off-host state as verified" has "off-host verified"
check "the catalog records verified for both" [ "$(cut -f6 "$REENTRY_BACKUP_DIR/.catalog.tsv" | grep -c '^verified$')" = 2 ]
fresh s4; off="$tmp/off-s4"; mkdir -p "$off"
run backup
REENTRY_OFFHOST_DEST="$off" run status
check "off-host configured but never copied: status exits 1" [ "$rc" = 1 ]
check "the missing copy is reported" has "no verified off-host copy"
check "status shows missing" has "off-host missing"
fresh s5
REENTRY_OFFHOST_DEST="$tmp/not-mounted" run backup
check "a failed off-host copy is recorded as failed" [ "$(cut -f6 "$REENTRY_BACKUP_DIR/.catalog.tsv" | grep -c '^failed$')" = 2 ]
REENTRY_OFFHOST_DEST="$tmp/not-mounted" run status
check "and status exits 1 for it" [ "$rc" = 1 ]
run prune
check "prune keeps the catalog in step (rows survive, off-host state kept)" [ "$(cut -f6 "$REENTRY_BACKUP_DIR/.catalog.tsv" | grep -c '^failed$')" = 2 ]

# failure notification
export NOTE="$tmp/note" FAKE_CURL_LOG="$tmp/curl.log"
rm -f "$NOTE" "$FAKE_CURL_LOG"
export REENTRY_NOTIFY_CMD='printf "%s|%s\n" "$REENTRY_EVENT" "$REENTRY_MESSAGE" >> "$NOTE"'
fresh n1
run backup
run verify
check "no notice is sent when backup and verify succeed" [ ! -e "$NOTE" ]
FAKE_FAIL_DUMP=1 run backup
check "a failed backup keeps its exit code" [ "$rc" = 1 ]
check "a failed backup runs the notify command once" [ "$(grep -c . "$NOTE")" = 1 ]
check "the event is backup-failed" grep -q '^backup-failed|' "$NOTE"
check "the notice carries the exit code and the reason" grep -q 'exit code 1.*dump failed' "$NOTE"
rm -f "$NOTE"
FAKE_DOWN=reentry-mysql run backup
check "a missing container is exit 3" [ "$rc" = 3 ]
check "the notice carries exit code 3" grep -q 'exit code 3' "$NOTE"
rm -f "$NOTE"
FAKE_DROP_ROW=1 run verify
check "a failed verify keeps its exit code" [ "$rc" = 1 ]
check "the event is verify-failed" grep -q '^verify-failed|.*row counts differ' "$NOTE"
rm -f "$NOTE"
fresh n2
REENTRY_OFFHOST_DEST="$tmp/not-mounted" run backup
check "an off-host failure keeps exit 1" [ "$rc" = 1 ]
check "the event is offhost-failed" grep -q '^offhost-failed|' "$NOTE"
check "one notice per failed run" [ "$(grep -c . "$NOTE")" = 1 ]
rm -f "$NOTE"
FAKE_FAIL_DUMP=1 REENTRY_OFFHOST_DEST="$tmp/not-mounted" run backup
check "a dump failure plus an off-host problem is a backup-failed event" grep -q '^backup-failed|' "$NOTE"
rm -f "$NOTE"
REENTRY_NOTIFY_CMD='exit 7' FAKE_FAIL_DUMP=1 run backup
check "a failing notify command never changes the exit code" [ "$rc" = 1 ]
check "and is only a warning" has "WARN notify: REENTRY_NOTIFY_CMD failed"
unset REENTRY_NOTIFY_CMD
FAKE_FAIL_DUMP=1 run backup
check "with nothing configured a failure is silent about notices" bash -c "! grep -q notify '$tmp/out'"
check "and nothing was sent" [ ! -e "$NOTE" ]

export REENTRY_NOTIFY_WEBHOOK='https://hooks.example.test/services/not-a-real-secret'
fresh n3
run backup
check "webhook: nothing is posted on success" [ ! -s "$FAKE_CURL_LOG" ]
FAKE_FAIL_DUMP=1 run backup
check "webhook: a failed backup posts once" [ "$(grep -c '^args:' "$FAKE_CURL_LOG")" = 1 ]
check "webhook: the body names the event" grep -q 'backup-failed' "$FAKE_CURL_LOG"
check "webhook: the URL is read from stdin" grep -q '^config: url = "https://hooks.example.test/services/not-a-real-secret"' "$FAKE_CURL_LOG"
check "webhook: the URL is not in the curl arguments" bash -c "! grep '^args:' '$FAKE_CURL_LOG' | grep -q not-a-real-secret"
: > "$FAKE_CURL_LOG"
FAKE_CURL_FAIL=1 FAKE_FAIL_DUMP=1 run backup
check "webhook: a failing call keeps the exit code" [ "$rc" = 1 ]
check "webhook: and is only a warning" has "WARN notify: the webhook call failed"
REENTRY_NOTIFY_WEBHOOK='ftp://example.test/x' FAKE_FAIL_DUMP=1 run backup
check "webhook: a URL that is not http or https is refused with a warning" has "not an http or https URL"
check "webhook: and the exit code is kept" [ "$rc" = 1 ]
unset REENTRY_NOTIFY_WEBHOOK

fresh e
check "list exits 1 on an empty folder" bash -c "! '$ROOT/reentry' list"

exit "$fail"
