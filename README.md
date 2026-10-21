# Reentry

Backups that prove they restore. Reentry takes logical dumps of a MySQL and a
PostgreSQL database, checksums them, and restores the latest one into a
throwaway container to check it. Everything runs in Docker.

All sample data is fake. Passwords live in a git-ignored `.env`. The
`backups/` folder is git-ignored and must never be committed.

## Requirements

Docker with Compose, bash 4 or newer, GNU date, `sha256sum`, `gzip` and
`flock`. That means Linux, WSL or Git Bash. `reentry list` and `reentry prune`
need no Docker. Encryption needs `gpg` or `openssl`, and a remote off-host
destination needs `rsync` and `ssh`.

## Usage

```
cp .env.example .env     # then set the passwords
./reentry up             # start MySQL and PostgreSQL
./reentry backup         # dump both databases into backups/
./reentry verify         # restore the latest backups and check them
./reentry list           # backups with size, checksum state and off-host state
./reentry status         # latest good backup, age and off-host state per engine
./reentry restore mysql  # restore the latest backup into a running container (asks first)
./reentry prune          # apply retention (add --dry-run to preview)
./reentry down           # stop and delete the data volumes (asks first, or pass --yes)
```

The Compose file lives in `compose/`, so a bare `docker compose up` from the
repo root will not find it. `./reentry up` runs
`docker compose -f compose/docker-compose.yml --env-file .env up -d --wait`.
Use that command directly if you prefer.

### backup

Dumps each database with `mysqldump` and `pg_dump` inside its container, so
passwords never appear on the host command line. Files go to `backups/`:

| File | Content |
|---|---|
| `<engine>_<db>_<UTC timestamp>.sql.gz` | the compressed dump |
| `<same name>.sha256` | SHA-256 of the dump and of the counts file |
| `<same name>.counts` | `table=rows` per table, read before and after the dump |

A dump is written to a `.partial` file, then checked: valid gzip and the
closing comment that a finished dump ends with. Only then is it renamed. A
failed or interrupted run leaves no backup and no leftovers. One engine
failing does not stop the other. If rows changed during the dump, no counts
file is written and `verify` falls back to the live source with a warning.

#### Encryption

Opt-in. Set `REENTRY_ENCRYPT` to `gpg` (symmetric, AES256) or `openssl`
(`aes-256-cbc` with `pbkdf2`) and `REENTRY_ENCRYPT_KEY_FILE` to a file whose
first line is the passphrase. The passphrase is read from that file and never
appears on a command line or in `.env`. Keep the file off the backup volume and
off the off-host destination, restrict it with `chmod 600`, and keep a copy
somewhere safe. Without it the backups cannot be read.

With encryption on, the finished and checked dump is encrypted and stored as
`<engine>_<db>_<UTC timestamp>.sql.gz.enc`. The plaintext is removed, and a
failure leaves no plaintext behind. The `.sha256` file covers the file as
stored, so `list`, `prune` and the off-host check work without the key.
`verify` and `restore` decrypt on the fly and tell `gpg` and `openssl` files
apart by their header, so they only need the key file. A missing or empty key
file stops the run before anything is dumped or restored (exit 3), an unset
`REENTRY_ENCRYPT_KEY_FILE` or unknown tool is a bad setting (exit 2), and there
is never a fallback to a plaintext backup. A wrong key fails `verify` and
`restore` with exit 1. Encrypted and plaintext backups can sit in the same
folder. `.counts` files are not encrypted and hold table names and row counts.
This protects backups at rest. It does not hide data from anyone who holds the
key file, and the gpg and openssl tools are used as installed on your system.

#### Off-host copy

Opt-in. Set `REENTRY_OFFHOST_DEST` in `.env` and each successful backup is
copied, with its `.counts` and `.sha256` files, to that place. Unset, the step
is skipped and one log line says so. The destination is one of:

- A folder, such as a mounted share. It must already exist and be writable.
  Reentry never creates it, because an unmounted share would then fill the
  local disk.
- `host:/path` (or `user@host:/path`), copied with `rsync` over `ssh`. Both
  tools must be on `PATH` and ssh must work without a prompt.

After the copy, `sha256sum -c` is run on the `.sha256` file at the destination.
If the copy fails or does not match, the bad copy is removed from the
destination, the run logs an error, and `backup` exits 1. The local backup is
never touched by an off-host failure. The destination may only contain letters,
digits and `_ . / @ : + -`, and may not be the backup folder itself.
`prune` works on the local folder only and does not delete off-host copies.

### verify

For each engine, takes the latest backup and checks the SHA-256 file and gzip
integrity. It then starts a throwaway container from the same image as the
source, with no network, restores the dump into it and compares the row count
of every table with the `.counts` file recorded at backup time. Then it runs
integrity checks:

- A query that must return 0. By default, no `order_items` row without a
  parent `orders` row, which fits the sample schema. Set
  `REENTRY_INTEGRITY_SQL` in `.env` to use your own query. If the sample
  tables are absent and no query is set, this check is skipped with a warning.
- `mysqlcheck` on MySQL, and a check that all constraints are valid on
  PostgreSQL.

The throwaway container is removed on exit. `verify` exits non-zero if either
engine fails.

### status and the catalog

```
./reentry status [--refresh]
```

`backup` and `prune` keep a small catalog, `backups/.catalog.tsv`, next to the
backups. It is tab separated with one row per backup: file name, size, mtime,
checksum state (`ok`, `mismatch` or `none`), when that was checked, off-host
state (`verified`, `failed` or `none`) and when that was set. It is written
through a temporary file under the same lock as the other commands, and a
failure to write it only logs a warning. `list` shows the off-host state from it.

`status` needs no Docker. It reads the catalog and prints one line per engine
with the latest good backup, its age, the off-host state and how many backups
there are and how many are bad. It exits 1 and logs a `PROBLEM` line when an
engine has no good backup, when its newest backup fails its checksum, when the
latest good backup is older than `REENTRY_MAX_AGE_HOURS` (default 48), or when
`REENTRY_OFFHOST_DEST` is set and that backup has no verified off-host copy.
Without a catalog it exits 1 and says how to create one. A bad option or a bad
`REENTRY_MAX_AGE_HOURS` exits 2.

The catalog is a cache. To keep `backup` and `prune` quick, a row whose size and
mtime are unchanged and was `ok` is not hashed again, so damage that keeps the
size and mtime goes unnoticed until `./reentry status --refresh`, which hashes
every backup and rewrites the catalog. `status` warns when the files in the
folder and the catalog disagree. The off-host state is what Reentry last
recorded. It is not a live check of the destination.

### restore

```
./reentry restore <mysql|postgres> [--backup FILE] [--target CONTAINER] [--database NAME] [--yes]
```

Loads a backup into a database on a running container. `verify` only ever
writes into a throwaway container it starts and removes itself. `restore` is
the command for real recovery, so it writes where you point it.

- The backup is the latest one for that engine, or the file named with
  `--backup` (a bare file name from `backups/`, for the same engine).
- The target container defaults to the sample source container
  (`reentry-mysql` or `reentry-postgres`). Use `--target` for any other running
  container. It must follow the same conventions as the sample containers: a
  MySQL container with `MYSQL_ROOT_PASSWORD` set, or a PostgreSQL container
  with the `postgres` user and trust access from inside the container.
- The database name defaults to the one in the backup file name. `--database`
  restores into another name. A database that does not exist is created.
- Before anything is written the SHA-256 file and gzip integrity are checked,
  and a backup that fails is refused.
- Safety: unless the target is a `verify` throwaway container, `restore` shows
  the backup, database and container and asks you to type `yes`. With no
  terminal it refuses and exits 2 unless you pass `--yes`, in line with
  `down --yes`. On MySQL, tables with the same names in an existing database
  are replaced. On PostgreSQL the load runs as one transaction and is refused if
  the database already has tables, so restore into an empty database.
- After the load, row counts are compared with the `.counts` file. A mismatch
  exits 1. Without a counts file the check is skipped with a warning.

`restore` exits 0 on success, 1 if a check fails, the load fails or you answer
no, 2 for a usage error or a missing `--yes`, and 3 if Docker or the target
container is not available. A failed MySQL load can leave the database partly
loaded, because MySQL cannot roll back the statements in a dump.

### prune

Works on each engine and database separately. Keeps the newest backup of each
of the last 7 days, 4 ISO weeks and 6 months that have one, and deletes the
rest with their `.sha256` and `.counts` files. Set `REENTRY_KEEP_DAILY`,
`REENTRY_KEEP_WEEKLY` and `REENTRY_KEEP_MONTHLY` in `.env` to change the
numbers. The newest backup of a group is never deleted, even if every limit is
0. If the newest backup of a group fails its checksum, that group is left
alone and prune exits 1, so a corrupt backup cannot push good ones out. Prune
also removes orphan sidecars and leftover `.partial` files.

### Settings

`reentry` reads only `MYSQL_DATABASE`, `POSTGRES_DB` and the `REENTRY_*`
settings from `.env`, and it never runs the file as shell code. A value
already in the environment wins. Quote values that contain `$` with single
quotes. Inline comments are not supported. `REENTRY_BACKUP_DIR` moves the
backup folder, and one `backup`, `verify`, `restore`, `prune` or `status --refresh` runs at a time (a lock
file in that folder).

### Exit codes

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | the command failed, a check failed (an off-host copy that fails counts), `list` found no backups or a bad checksum, or `status` found a problem |
| 2 | usage error or bad setting (for `restore`, also a missing `--yes` when there is no terminal) |
| 3 | prerequisite missing (Docker, a tool, or a container not running) |

When both engines run, the worst code is returned. Every step writes one log
line to stderr.

## Recovery

[`docs/runbook.md`](docs/runbook.md) is a generic ransomware recovery runbook
written to be followed under pressure.

## Limits

- Backups stay in a local folder unless you set `REENTRY_OFFHOST_DEST`. For the
  copy to protect against ransomware, the destination must be a place the
  database host cannot delete from or overwrite, such as an append-only or
  versioned store. Reentry cannot check that.
- The checksum file sits next to the backup. It detects damage, not
  tampering. Record hashes somewhere else at backup time.
- Dumps hold tables and data, not database users or grants.
- The encryption passphrase file is not backed up or rotated by Reentry.
  Changing it makes older backups unreadable with the new file.
- Single-database dumps and the sample schema only.

## Status

| Piece | State |
|---|---|
| Compose with seeded MySQL and PostgreSQL | written, not run (no Docker on the build machine) |
| `backup`, `verify` | written, logic tested against a fake `docker`, not run against real Docker |
| `restore` | written, logic and the confirmation prompt tested against a fake `docker`, not run against real Docker |
| Encryption (`gpg`, `openssl`) | written, logic tested against a fake `docker` with the real `gpg` and `openssl`, not run against real Docker |
| Off-host copy (folder and rsync/ssh) | written, logic tested against a fake `docker`, `rsync` and `ssh`, not run against real Docker, a real ssh host or a real share |
| `prune`, `list` | built and tested, no Docker needed |
| `status` and the backup catalog | written, tested against the fake `docker`, no Docker needed to run it |
| Runbook | written, restore commands not run |
| End-to-end test (`test/e2e.sh`) | written, not run (needs Docker) |

Done when `./reentry up && ./reentry backup && ./reentry verify` succeeds and
the corruption test fails verify as expected. That has not been shown yet.

## Tests

| Command | Needs Docker | Result so far |
|---|---|---|
| `bash test/prune.sh` | no | 18 checks passed under WSL bash |
| `bash test/fake.sh` | no | 148 checks passed under WSL bash (uses the installed `gpg` and `openssl`, and skips a tool that is missing) |
| `bash test/e2e.sh` | yes | not run, only its syntax and the Docker-missing exit were checked |

`test/e2e.sh` starts the sample databases if needed, takes a real backup in a
temporary folder and checks that `verify` passes. It then damages copies of the
backup two ways and expects `verify` to fail each time. In case A the dump is
corrupted, and the SHA-256 check catches it. In case B a row is removed from the
PostgreSQL dump and the checksum files are rewritten to match, so only the
restore and the row count comparison can catch it. It tears Docker down at the
end if it started it, unless `E2E_KEEP_UP=1` is set.

`test/fake.sh` uses a stand-in `docker` command (`test/fake-docker/`) that
returns canned dumps and counts. It checks the script's own logic: file
handling, manifests, exit codes, cleanup and failure paths. It cannot show that
a real dump restores. No real MySQL or PostgreSQL has been run.
