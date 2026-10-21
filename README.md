# Reentry

Backups that prove they restore. Reentry takes logical dumps of a MySQL and a
PostgreSQL database, checksums them, and restores the latest one into a
throwaway container to check it. Everything runs in Docker.

All sample data is fake. Passwords live in a git-ignored `.env`. The
`backups/` folder is git-ignored and must never be committed.

## Requirements

Docker with Compose, bash 4 or newer, GNU date, `sha256sum`, `gzip` and
`flock`. That means Linux, WSL or Git Bash. `reentry list` and `reentry prune`
need no Docker.

## Usage

```
cp .env.example .env     # then set the passwords
./reentry up             # start MySQL and PostgreSQL
./reentry backup         # dump both databases into backups/
./reentry verify         # restore the latest backups and check them
./reentry list           # backups with size and checksum state
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
backup folder, and one `backup`, `verify` or `prune` runs at a time (a lock
file in that folder).

### Exit codes

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | the command failed, a check failed (an off-host copy that fails counts), or `list` found no backups or a bad checksum |
| 2 | usage error or bad setting |
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
- Single-database dumps and the sample schema only.

## Status

| Piece | State |
|---|---|
| Compose with seeded MySQL and PostgreSQL | written, not run (no Docker on the build machine) |
| `backup`, `verify` | written, logic tested against a fake `docker`, not run against real Docker |
| Off-host copy (folder and rsync/ssh) | written, logic tested against a fake `docker`, `rsync` and `ssh`, not run against real Docker, a real ssh host or a real share |
| `prune`, `list` | built and tested, no Docker needed |
| Runbook | written, restore commands not run |
| End-to-end test (`test/e2e.sh`) | written, not run (needs Docker) |

Done when `./reentry up && ./reentry backup && ./reentry verify` succeeds and
the corruption test fails verify as expected. That has not been shown yet.

## Tests

| Command | Needs Docker | Result so far |
|---|---|---|
| `bash test/prune.sh` | no | 18 checks passed under WSL bash |
| `bash test/fake.sh` | no | 43 checks passed under WSL bash |
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
