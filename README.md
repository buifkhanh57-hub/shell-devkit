# sysops

**A single-binary sysadmin toolkit in pure Bash — report, monitor, backup, cleanup, audit, sockets, packages, alerts and update checks with zero dependencies beyond coreutils.**

![language](https://img.shields.io/badge/language-bash%205.x-4EAA25)
![version](https://img.shields.io/badge/version-1.0.0-orange)
![license](https://img.shields.io/badge/license-MIT-green)
![tests](https://img.shields.io/badge/tests-239%20passing-brightgreen)
![dependencies](https://img.shields.io/badge/dependencies-coreutils%20only-yellowgreen)
![platform](https://img.shields.io/badge/platform-linux-lightgrey)

---

## Overview

`sysops` is a professional command-line toolkit for day-to-day Linux server
operations. One executable (`bin/sysops`) dispatches to twelve subcommands,
each implemented in a self-contained library module under `lib/`.

Design goals:

- **No dependencies beyond what a server already has** — bash 4.4+, GNU
  coreutils, `awk`, `find`, `tar`, `df`. Optional tools (`ss`, `netstat`,
  `systemctl`, `curl`, `dpkg`/`rpm`/`pacman`/`apk`) degrade gracefully: when a
  tool is missing the command falls back to `/proc`/`/sys` parsing or prints
  `(unavailable: reason)` instead of failing.
- **Safe by default** — `cleanup` is dry-run unless `--apply` is given,
  `backup` has a plan-first `--dry-run`, every candidate is re-validated
  immediately before removal, and nothing is ever `eval`'d (config files are
  parsed with `printf -v`, cron content is written through a temp file).
- **Cron-friendly** — stable, documented exit codes on every check-style
  command (`0 ok / 1 warn / 2 crit / 3 internal error`), `--json` output
  where it matters, quiet mode, and a managed crontab block that never
  touches user entries outside its markers.
- **Pure integer arithmetic** — all percentages, sizes and load thresholds
  are computed with bash integer maths (values scaled where needed), so no
  `bc`/`awk` floating point is required anywhere.

Everything runs as a normal user; nothing in the toolkit requires root
(read-only checks simply report more when run as root).

---

## Features

| Command | What it does |
|---|---|
| `report` | Sectioned machine report: OS, CPU, memory, disk, network, top processes, failed logins, **package inventory**, **listening sockets**. `--json` emits one object. |
| `monitor` | Threshold checks (disk, memory, swap, load) with per-check overrides, repeat/interval loops and cron-ready exit codes. |
| `backup` | Timestamped `tar.gz` archives with gzip-level control, excludes, verification (`gzip -t` + listing + sha256 sidecar), keep-N rotation and an exclusive per-destination lock. |
| `cleanup` | Disposable-file cleaner (tmp/log/bak patterns + cache dirs like `__pycache__`, `node_modules`) — **dry-run by default**, `--apply` to delete. |
| `audit` | Read-only security quick-audit: password/UID-0 accounts, sudo groups, world-writable PATH entries, large homes, unexpected SUID binaries, SSH key permissions, **kernel sysctl hardening**, **sshd directives**. |
| `service` | Service status via `systemctl`/`pgrep`, TCP port checks and `wait-port` polling through bash's `/dev/tcp`. |
| `cron` | Managed marker-block crontab entries with label replace/remove, schedule validation and dry-run. |
| `logs` | Error-keyword summary from journalctl / syslog / any logfile in one awk pass, with last-seen stamps and sample tails. |
| `net` | Listening sockets (`ss` → `netstat` → `/proc/net/tcp` fallback), established-peer grouping, interface state from sysfs, TCP counters from `/proc/net/snmp`, local port checks. |
| `pkg` | Installed-package counts across **dpkg / rpm / pacman / apk**, file ownership lookup, package-cache sizes. |
| `notify` | Local alert log (always written) plus optional JSON webhook via curl; `check` maps the worst recent alert to an exit code. |
| `updates` | Offline pending-update counts (apt simulate mode, `dnf --cacheonly`, pacman/apk local db), package names, reboot-required and kernel-drift detection. |

Cross-cutting:

- Global flags work before *and* after the subcommand: `--json`, `-q`,
  `--dry-run`, `-y`, `--no-color` / `--color` (also honours `NO_COLOR`).
- `KEY=VAL` config chain: `/etc/sysops/sysops.conf` → `<install>/conf/sysops.conf`
  → `~/.config/sysops/sysops.conf`, or one explicit file via `--config` /
  `$SYOPS_CONFIG`. File contents are never `eval`'d.
- Levelled logging (`DEBUG/INFO/WARN/ERROR`) to stderr, optionally mirrored
  to a log file via `LOG_FILE`.
- Advisory locks (`flock` with a `mkdir` fallback) protect concurrent backups.

---

## Requirements

| Requirement | Notes |
|---|---|
| Linux | any recent kernel; `/proc` and `/sys` are used as fallback data sources |
| bash ≥ 4.4 | arrays, `read -d ''`, `${var,,}`-era features (developed on 5.2) |
| GNU coreutils | `df`, `du`, `stat`, `tar`, `date`, `find`, `sort`, `wc` |
| awk | POSIX awk (tested with gawk/mawk) |

Optional, detected at runtime:

| Tool | Used by | Fallback |
|---|---|---|
| `ss` / `netstat` | `net`, `report` sockets section | `/proc/net/tcp{,6}` parser |
| `systemctl` / `pgrep` | `service`, `audit` | `pgrep` guess / `n/a` |
| `curl` | `notify` webhook delivery | local alert log only |
| `flock` | `backup` locking | `mkdir`-based lock |
| `sha256sum` | `backup --verify` | sidecar skipped |
| `dpkg`/`rpm`/`pacman`/`apk` | `pkg`, `updates` | "no manager detected" |
| `crontab` | `cron` | clean error message |

---

## Installation

From a checkout:

```bash
git clone <repo-url> sysops && cd sysops
sudo make install                 # -> /usr/local/bin/sysops + /usr/local/lib/sysops
```

Or without installing, run it straight from the tree:

```bash
./bin/sysops --version
```

`make install` runs a full `bash -n` syntax check first, installs the
dispatcher to `$PREFIX/bin`, the libraries to `$PREFIX/lib/sysops/` and the
example configuration to `$PREFIX/share/sysops/`. The dispatcher resolves its
own location (including through symlinks), so `ln -s` into `~/.local/bin`
works too. Use `make install PREFIX=$HOME/.local` for a user-local install.

Uninstall with `make uninstall`. Developer targets: `make check` (syntax),
`make test` (test suite), `make shellcheck` (when shellcheck is installed),
`make clean`.

---

## Quick Start

```console
$ sysops report --section os,memory
sysops report v1.0.0 -- web-01
2026-09-25T23:53:50+0000

== Operating system ==
  Host:            web-01
  OS:              Debian GNU/Linux 13 (trixie)
  Release:         debian 13
  Kernel:          5.10.134-013.15.kangaroo.al8.x86_64
  Arch:            x86_64
  Uptime:          0d 8h 50m
  Load:            0.14 0.03 0.01 (1/5/15 min)

== Memory ==
  Total:           4.061 GiB
  Used:            542.078 MiB (13%)
  Available:       3.532 GiB
  Buffers:         8.207 MiB
  Cached:          460.953 MiB
  Swap:            none configured

$ sysops monitor
[OK  ] disk  /                      1 used (109.074 MiB / 9.291 GiB) [warn>=80 crit>=90]
[OK  ] mem   RAM                    13% used (542.429 MiB / 4.061 GiB) [warn>=80 crit>=90]
[OK  ] swap  SWAP                   no swap configured (skipped)
[OK  ] load  load1                  load1=0.27 on 2 core(s) [warn>=70% crit>=200% of capacity]
RESULT: OK (worst of 4 check(s))
$ echo $?
0
```

Five-minute tour:

```bash
sysops report                          # everything, human-readable
sysops monitor --json                  # JSONL for monitoring pipelines
sysops backup -d /var/backups/app -n app --verify /etc/app
sysops cleanup                         # dry-run listing, deletes nothing
sysops audit                           # security findings with severities
sysops net listen                      # who is listening on what
sysops pkg count                       # installed packages per manager
sysops updates summary                 # offline update + reboot state
sysops notify send "backup done" --level info
```

---

## Usage

### Command table

| Command | Signature | Exit codes |
|---|---|---|
| `report` | `sysops report [--section LIST] [--top N] [--logins-lines N] [--json]` | `0` ok, `2` usage |
| `monitor` | `sysops monitor [CHECKS...] [--path P] [--all-mounts] [--warn N] [--crit N] [--repeat N --interval S] [--json]` | `0` ok, `1` warn, `2` crit, `3` error |
| `backup` | `sysops backup [-d DIR] [-n NAME] [-k N] [-g 1-9] [-x PAT] [-e FILE] [--verify] [--dry-run] [--list [DIR] [NAME]] SRC...` | `0` ok, `1` verify failed, `2` usage, `3` tar failed, `4` locked |
| `cleanup` | `sysops cleanup [ROOT...] [--apply] [--older-than N] [--include PATS] [--no-caches] [--min-size B] [--json]` | `0` done, `2` usage, `3` deletion failures |
| `audit` | `sysops audit [CHECKS...] [--home-threshold MB] [--max-list N] [--json]` | `0` clean, `1` low/med, `2` high, `3` error |
| `service` | `sysops service status\|list\|port\|wait-port\|exists ...` | `0` ok/open, `1` stopped/closed, `2` usage, `3` timeout/unknown |
| `cron` | `sysops cron install\|remove\|list\|raw [--schedule S] [--command C] [--label L] [--user U] [--dry-run]` | `0` ok, `1` not found, `2` usage, `3` crontab error |
| `logs` | `sysops logs [--file PATH] [--lines N] [--since SPEC] [--keyword K] [--tail N] [--json]` | `0` ok, `2` usage, `3` no source |
| `net` | `sysops net listen\|conns\|ifaces\|stats\|ports ...` | `0` ok, `1` port missing, `2` usage, `3` no source |
| `pkg` | `sysops pkg count\|owner\|cache\|info [--json]` | `0` ok, `1` not owned, `2` usage, `3` no manager |
| `notify` | `sysops notify send\|show\|check\|clear ...` | `send`: `0`/`1` webhook failed; `check`: `0/1/2` = worst level, `3` unreadable |
| `updates` | `sysops updates check\|list\|reboot\|summary [--json]` | `0` clean, `1` updates pending, `2` reboot required, `3` error |

Global flags: `--config FILE`, `-n/--dry-run`, `-y/--yes`, `--json`,
`-q/--quiet`, `--no-color`, `--color`, `-V/--version`, `-h/--help`.
Per-command help: `sysops help COMMAND` (e.g. `sysops help net`).

### Realistic outputs

`sysops net listen` (from a container with a loopback control socket):

```console
  PROTO  STATE        LOCAL                  PORT  PROCESS
  tcp    LISTEN       127.0.0.1             12600  -
  tcp    LISTEN       127.0.0.1             19001  -
  tcp    LISTEN       0.0.0.0               19005  -
  tcp    LISTEN       0.0.0.0               19006  -
  tcp    LISTEN       *                        81  -
  total: 5 listening socket(s) shown of 5
```

`sysops net stats` (excerpt):

```console
== TCP statistics ==
  ActiveOpens:     9851
  PassiveOpens:    3334
  CurrEstab:       8
  RetransSegs:     987

  PROTO      COUNTERS
  TCP        inuse=11 orphan=0 tw=19 alloc=35 mem=22
  UDP        inuse=1 mem=0
```

`sysops updates check` (offline — cached package indexes only):

```console
== Pending updates (offline scan) ==
  MANAGER       PENDING
  apt                 7
  total pending: 7
  Reboot:          no
  Kernel:          5.10.134-013.15.kangaroo.al8.x86_64 (none vs /boot)
```

`sysops pkg count` + `pkg owner`:

```console
  MANAGER      PACKAGES
  dpkg              932
$ sysops pkg owner /usr/bin/tar
/usr/bin/tar: owned by tar (dpkg)
```

`sysops audit sysctl sshd` (excerpt):

```console
[HIGH] sysctl-kptr kernel.kptr_restrict=0 (>=1 recommended: hide kernel pointers)
[MED ] sysctl-dmesg kernel.dmesg_restrict=0 (>=1 recommended: restrict dmesg to root)
[MED ] sysctl-bpf  kernel.unprivileged_bpf_disabled=0 (1 or 2 recommended: unprivileged bpf())
[INFO] sshd-absent no readable sshd_config found (sshd likely not installed)

Summary: HIGH=1  MED=2  LOW=1  INFO=1
Action required: fix HIGH findings first
```

`sysops cleanup` on a scratch directory (dry-run — nothing was deleted):

```console
== Cleanup candidates (dry-run) ==
  ACTION  PATH                                                             SIZE    AGE  KIND
  delete  /tmp/sysops-test/junk/old1.tmp                                    0 B    30d  file
  delete  /tmp/sysops-test/junk/old2.log                                    0 B    30d  file

  total: 2 candidate(s), 0 B reclaimable
  roots: /tmp/sysops-test
  (dry-run: nothing deleted; add --apply to delete)
```

`sysops monitor --json` (JSONL, one object per check):

```console
{"check":"disk","target":"/","value":1,"state":"OK","warn":80,"crit":90,"detail":"1 used (109.074 MiB / 9.291 GiB) [warn>=80 crit>=90]"}
{"check":"mem","target":"RAM","value":13,"state":"OK","warn":80,"crit":90,"detail":"13% used (542.863 MiB / 4.061 GiB) [warn>=80 crit>=90]"}
```

---

## Configuration reference

Copy `conf/sysops.conf.example` to one of the config locations and uncomment
what you need. Every key can also be exported as `SYOPS_<KEY>` in the
environment (e.g. `SYOPS_NOTIFY_LOG=/tmp/alerts.log`).

| Key | Default | Affects |
|---|---|---|
| `LOG_FILE` | *(unset)* | mirrors all levelled log lines to a file |
| `MONITOR_DISK_WARN` / `MONITOR_DISK_CRIT` | `80` / `90` | `monitor disk` |
| `MONITOR_MEM_WARN` / `MONITOR_MEM_CRIT` | `80` / `90` | `monitor mem` + `swap` |
| `MONITOR_LOAD_WARN` / `MONITOR_LOAD_CRIT` | `70` / `200` | `monitor load` (percent of core capacity) |
| `CLEANUP_OLDER_THAN` | `7` | default age for `cleanup` |
| `CLEANUP_INCLUDE_PATTERNS` | `*.tmp,*.log,*.bak,...` | `cleanup` file patterns |
| `AUDIT_HOME_THRESHOLD_MB` | `500` | `audit homes` |
| `BACKUP_DEST` / `BACKUP_KEEP` / `BACKUP_GZIP` | — / `5` / `6` | `backup` defaults |
| `LOGS_LINES` / `LOGS_SINCE` | `2000` / `24h` | `logs` |
| `REPORT_TOP_PROCS` | `10` | `report` procs section |
| `NET_MAX_ROWS` / `NET_CONNS_TOP` | `100` / `10` | `net listen` / `net conns` |
| `NOTIFY_LOG` | writable state dir | where `notify send` appends |
| `NOTIFY_WEBHOOK_URL` | *(unset)* | optional webhook target (requires curl) |
| `NOTIFY_WEBHOOK_TIMEOUT` | `5` | webhook POST timeout (seconds) |
| `NOTIFY_STALE_MIN` | `0` | default staleness window for `notify check` |
| `UPDATES_MAX_LIST` | `25` | rows printed by `updates list` |

Precedence per key: explicit CLI flag → config file → `SYOPS_<KEY>`
environment → built-in default (where applicable).

---

## Cron setup

`sysops cron` manages ONE clearly delimited block inside your crontab:

```
# BEGIN SYSOPS MANAGED BLOCK -- DO NOT EDIT BETWEEN MARKERS
*/5 * * * * /usr/local/bin/sysops monitor -q # sysops:label=monitor
15 2 * * *  /usr/local/bin/sysops backup -d /var/backups/app /etc/app # sysops:label=nightly
# END SYSOPS MANAGED BLOCK
```

Everything outside the markers belongs to you and is never touched. Entries
are identified by `# sysops:label=NAME` tags and replaced atomically by
label. Always rehearse with `--dry-run` first — it prints the resulting
crontab without installing it:

```bash
sysops cron install --schedule '*/5 * * * *' \
    --command '/usr/local/bin/sysops monitor -q' \
    --label monitor --dry-run

sysops cron install --schedule '*/5 * * * *' \
    --command '/usr/local/bin/sysops monitor -q' --label monitor

sysops cron list
sysops cron remove --label monitor
```

A sensible recurring set:

```bash
# every 5 minutes: threshold check, alerts land in the notify log
*/5 * * * * sysops monitor -q || logger -t sysops "monitor rc=$?"

# twice an hour: offline update summary (0 clean, 1 updates, 2 reboot)
*/30 * * * * sysops updates summary -q || logger -t sysops "updates rc=$?"

# nightly 02:15: verified backup with 7-generation rotation
15 2 * * * sysops backup -d /var/backups/app -k 7 --verify /etc/app
```

---

## Safety notes

- **`cleanup` never deletes in dry-run mode** and refuses obviously dangerous
  roots (`/`, `/etc`, `/usr`, `/var`, ...). With `--apply` it still requires
  an interactive confirmation unless `-y` is passed, and every candidate is
  re-validated against the original roots immediately before `rm`.
- **`backup` dry-run prints the full plan** (archive name, rotation victims,
  source sizes) and creates nothing — not even the destination directory.
  Rotation only ever removes files matching `<name>-*.tar.gz` plus their
  `.sha256` sidecars inside the destination directory.
- **No eval, anywhere.** Config files are parsed with `printf -v`; crontab
  content travels through temp files; tar is invoked via argument arrays;
  host/port values are validated against strict patterns before any
  `/dev/tcp` probe (probes run in a child bash with `timeout`).
- **`updates` is offline by construction** — apt simulate mode, `dnf
  --cacheonly`, pacman's local database, apk's local index. No downloads, no
  metadata refresh, no installs. `pkg` is read-only inventory only.
- **`notify` always writes the local alert log first**; a missing or failing
  webhook never loses an alert (it warns and returns `1` instead).
- Locks prevent concurrent backups into the same destination (`rc 4`).
- Colour output is disabled automatically when stdout is not a TTY or
  `NO_COLOR` is set, so piping/cron output stays clean.

---

## Project Structure

```
sysops/
├── bin/
│   └── sysops                  (244) entry point: global flag parsing,
│                               module loader, config chain, dispatch table
├── conf/
│   └── sysops.conf.example     (109) fully commented KEY=VAL reference config
├── docs/                       (reserved for future design notes)
├── lib/
│   ├── common.sh               (732) colours, levelled logging, strict mode +
│   │                                 ERR trap, config parser (no eval),
│   │                                 integer maths, paths, du sizes, locks,
│   │                                 confirm, JSON escaping, table helpers
│   ├── report.sh               (739) `report`: 9 sections + JSON collector
│   ├── monitor.sh              (474) `monitor`: disk/mem/swap/load checks
│   ├── backup.sh               (331) `backup`: tar+gzip, verify, rotation
│   ├── cleanup.sh              (359) `cleanup`: dry-run-first file cleaner
│   ├── audit.sh                (554) `audit`: 8 security checks incl. sysctl
│   │                                 and sshd hardening review
│   ├── service.sh              (327) `service`: systemctl/pgrep status,
│   │                                 /dev/tcp port probes
│   ├── cron.sh                 (408) `cron`: marker-block crontab manager
│   ├── logs.sh                 (293) `logs`: one-pass keyword summariser
│   ├── net.sh                  (732) `net`: sockets/connections/interfaces/
│   │                                 TCP stats + `report` sockets section
│   ├── pkg.sh                  (518) `pkg`: dpkg/rpm/pacman/apk inventory +
│   │                                 `report` packages section
│   ├── notify.sh               (486) `notify`: alert log + webhook delivery
│   └── update-check.sh         (586) `updates`: offline update scan, reboot
│                                 and kernel-drift detection
├── tests/
│   └── run_tests.sh            (693) self-contained suite: 239 assertions
│                                 (unit + integration) against a /tmp sandbox
├── Makefile                    (69)  check / test / install / uninstall
└── README.md
```

Total: ~7,650 lines of shell across 15 files. Every module has an include
guard, a `<module>_usage` help function, a `cmd_<module>` entry point and
pure parser helpers that the test suite exercises without touching the host.

---

## Testing

The suite is fully self-contained — it sources the libraries for unit tests
and runs `bin/sysops` as a real process against a throwaway `mktemp -d`
sandbox; destructive paths are only ever exercised in dry-run mode, and the
one real backup goes into the sandbox.

```bash
make test              # or: bash tests/run_tests.sh
```

```console
== Summary ==
passed: 239  failed: 0
```

Coverage by layer:

| Layer | What is verified |
|---|---|
| `common.sh` | human sizes, percentages, clamping, `trim`, lexical `abspath`, `path_inside`, JSON escaping, padding/truncation |
| `monitor.sh` | `df -P` row parser, synthetic `/proc/meminfo`, load scaling, state mapping |
| `cleanup.sh` | age/pattern candidate scan, root containment rules, cache-dir discovery |
| `cron.sh` | schedule/label validation, entry extraction, block strip/assemble round-trip |
| `backup.sh` | gzip-level validation, archive listing, real sandbox backup, `--verify`, keep-N rotation, dry-run touching nothing |
| `logs.sh` | since-normalisation, keyword counting with last-seen stamps |
| `service.sh` | host/port validation, real loopback OPEN/CLOSED probe |
| `net.sh` | ss/netstat/`/proc/net/tcp` parsers, hex IP/port conversion, SNMP counters, live socket table |
| `pkg.sh` | dpkg status + apk database parsers, owner-output parsing, live `pkg` commands |
| `notify.sh` | level validation, log-line parsing, worst-level selection, staleness window, dry-run write-guarantee |
| `update-check.sh` | apt/dnf/pacman/apk sample parses, kernel drift states, reboot marker, live offline scan |
| integration | help/version/exit codes, report sections (incl. JSON), monitor against real thresholds, audit, cleanup dry-run, cron dry-run, config-file threshold override |

Exit code of the suite = number of failed assertions (capped at 125).

---

## FAQ

**Why pure Bash instead of Go/Python?**
Servers already ship bash and coreutils. A single dispatcher + plain shell
libraries are trivially auditable (`cat lib/*.sh`), instantly hackable on any
box, and need no build step, runtime install or package dependencies.

**Does `monitor` work without `/proc`?**
`disk` uses `df -P`; `mem`/`swap` need `/proc/meminfo`; `load` reads
`/proc/loadavg` with an `uptime` fallback. On non-Linux systems those checks
return exit code 3 (internal error) with a clear message.

**Is `net listen` safe to run as non-root?**
Yes. `ss -p`/`netstat -p` simply show fewer process names without root; the
`/proc/net/tcp` fallback never needs privileges. No connections are made —
the socket table is read, not scanned.

**Can `updates` hit the network by accident?**
No. Every backend is forced to cached metadata: `apt-get -s dist-upgrade`
(simulate), `dnf/yum --cacheonly check-update`, `pacman -Qu`/`checkupdates`
(local db), `apk version` (local index). Nothing is downloaded or installed.

**How do I add a new check?**
Follow the module pattern: create `lib/mymod.sh` with `mymod_usage()` and
`cmd_mymod()`, add the module name to the loader loop in `bin/sysops`, add a
dispatch case and a `sysops_command_help` entry, then add tests. Pure
parsing helpers belong in the module with an explicit file/string argument
so they are unit-testable.

**Why does `cleanup` refuse `/var` or `/usr` as a root?**
Those are system directories; a bad include pattern there could match
runtime state files. Pick subdirectories (e.g. `/var/tmp/app`) — the guard
exists so that a typo can never become an `rm -rf` of a system root.

**What happens when two backups run at once?**
The second one fails with exit code 4 and an error naming the lock file.
The lock is `flock`-based when available with an `mkdir` fallback, released
via an `EXIT` trap.

**How accurate is the package count?**
dpkg counts blocks with `Status: install ok installed` in
`/var/lib/dpkg/status` (the same definition `dpkg -l | grep '^ii'` uses);
apk counts `P:` records in its installed database; rpm/pacman ask their
package managers directly.

---

## Roadmap

- `sysops secrets` — permission/age audit for `.env`/key files under project roots
- `sysops docker` — container/image inventory when the Docker socket is present
- `sysops snapshot` — LVM/btrfs snapshot helpers next to `backup`
- Prometheus text exposition format for `monitor --prom`
- Optional systemd timers generated alongside the cron block
- `sysops trend` — append monitor JSONL to a local history and diff against it
- Shell completion (bash/zsh) generated from the usage functions
- `--config` merge semantics (multiple explicit files, later wins)

---

## License

MIT License — see the header of `bin/sysops`. In short: use it, fork it,
ship it; no warranty.

Copyright (c) 2026 Bui Bao Khanh

---
**by Bui Bao Khanh**
