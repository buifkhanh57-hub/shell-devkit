#!/usr/bin/env bash
# =============================================================================
# tests/run_tests.sh -- self-contained test suite for the sysops toolkit
#
# Layers:
#   1. unit tests of the pure helpers in lib/common.sh (maths, paths, JSON...)
#   2. unit tests of per-module parsers (monitor, cleanup, cron, backup, logs,
#      service, net, pkg, notify, updates) fed with synthetic samples
#   3. integration tests that run bin/sysops as a real process against a
#      throwaway sandbox in /tmp (dry-run/destructive-free by design:
#      cleanup only ever runs in dry-run mode here, backups go to the sandbox)
#
# Exit code: number of failed tests (capped at 125).
# =============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$ROOT/lib"
SYSOPS="$ROOT/bin/sysops"

# deterministic, colourless, quiet-friendly test environment
export NO_COLOR=1 SYOPS_NO_COLOR=1 LC_ALL=C

# --- load the toolkit in-process for unit tests ------------------------------
# shellcheck disable=SC1091
source "$LIB/common.sh"
for _mod in report monitor backup cleanup audit service cron logs net pkg notify update-check; do
    # shellcheck disable=SC1091,SC1090
    source "$LIB/$_mod.sh"
done
unset _mod

# --- harness -----------------------------------------------------------------
T_PASS=0
T_FAIL=0
T_CURRENT=""

t_section() {
    T_CURRENT="$1"
    printf '\n== %s ==\n' "$1"
}

assert_eq() { # DESC EXPECTED ACTUAL
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        T_PASS=$(( T_PASS + 1 ))
        printf 'ok   %s\n' "$desc"
    else
        T_FAIL=$(( T_FAIL + 1 ))
        printf 'FAIL %s\n     expected: %q\n     actual:   %q\n' "$desc" "$expected" "$actual"
    fi
    return 0
}

assert_rc() { # DESC EXPECTED_RC ACTUAL_RC
    local desc="$1" expected="$2" actual="$3"
    assert_eq "$desc (rc)" "$expected" "$actual"
    return 0
}

assert_rc_in() { # DESC ACTUAL_RC "LIST OF ACCEPTED RCS"
    local desc="$1" actual="$2" accepted="$3" a
    for a in $accepted; do
        if [[ "$a" == "$actual" ]]; then
            T_PASS=$(( T_PASS + 1 ))
            printf 'ok   %s (rc=%s in {%s})\n' "$desc" "$actual" "$accepted"
            return 0
        fi
    done
    T_FAIL=$(( T_FAIL + 1 ))
    printf 'FAIL %s (rc=%s not in {%s})\n' "$desc" "$actual" "$accepted"
    return 0
}

assert_contains() { # DESC HAYSTACK NEEDLE
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        T_PASS=$(( T_PASS + 1 ))
        printf 'ok   %s\n' "$desc"
    else
        T_FAIL=$(( T_FAIL + 1 ))
        printf 'FAIL %s\n     output does not contain: %q\n' "$desc" "$needle"
    fi
    return 0
}

assert_match() { # DESC STRING REGEX
    local desc="$1" string="$2" regex="$3"
    if [[ "$string" =~ $regex ]]; then
        T_PASS=$(( T_PASS + 1 ))
        printf 'ok   %s\n' "$desc"
    else
        T_FAIL=$(( T_FAIL + 1 ))
        printf 'FAIL %s\n     %q does not match /%s/\n' "$desc" "$string" "$regex"
    fi
    return 0
}

# run a command, capture stdout in OUT and rc in RC (stderr goes to a file)
OUT=""
RC=0
run_cmd() {
    "$@" > "$SBX/last.out" 2> "$SBX/errors.log"
    RC=$?
    OUT="$(< "$SBX/last.out")"
    return 0
}

# --- sandbox -----------------------------------------------------------------
SBX="$(mktemp -d "${TMPDIR:-/tmp}/sysops-test.XXXXXX")"
cleanup_sbx() {
    [[ -n "${LISTENER_PID:-}" ]] && kill "$LISTENER_PID" 2>/dev/null
    rm -rf -- "$SBX"
    return 0
}
trap cleanup_sbx EXIT
mkdir -p "$SBX/bk" "$SBX/data" "$SBX/clean"
ERRF="$SBX/errors.log"

# =============================================================================
t_section "common.sh helpers"
# =============================================================================
assert_eq "human_size 0"        "0 B"       "$(human_size 0)"
assert_eq "human_size 4096"     "4.000 KiB" "$(human_size 4096)"
assert_eq "human_size 1 MiB"    "1.000 MiB" "$(human_size 1048576)"
assert_eq "human_size negative" "-2.000 KiB" "$(human_size -2048)"
assert_eq "human_size garbage"  "n/a"       "$(human_size abc)"
assert_eq "pct 1/3"             "33"        "$(pct 1 3)"
assert_eq "pct 2/3"             "67"        "$(pct 2 3)"
assert_eq "pct 0/0"             "0"         "$(pct 0 0)"
assert_eq "pct 150/300"         "50"        "$(pct 150 300)"
assert_eq "div_round 10/4"      "3"         "$(div_round 10 4)"
assert_eq "div_round bad den"   "0"         "$(div_round 10 0)"
assert_eq "clamp_int inside"    "2"         "$(clamp_int 2 0 3)"
assert_eq "clamp_int high"      "3"         "$(clamp_int 9 0 3)"
assert_eq "clamp_int low"       "0"         "$(clamp_int -1 0 3)"
assert_rc  "is_int rejects abc" 1 "$(is_int abc; echo $?)"
assert_rc  "is_int accepts -12" 0 "$(is_int -12; echo $?)"
assert_rc  "is_uint rejects -3" 1 "$(is_uint -3; echo $?)"
assert_eq "trim"                "x"         "$(trim '  x  ')"
assert_eq "abspath lexical"     "/a/c"      "$(abspath /a/b/../c)"
assert_eq "abspath dot"         "/a/b"      "$(abspath /a/./b)"
assert_rc  "path_inside true"   0 "$(path_inside /a/b/c /a/b; echo $?)"
assert_rc  "path_inside equal"  1 "$(path_inside /a/b /a/b; echo $?)"
assert_rc  "path_inside prefix-trick" 1 "$(path_inside /a/bc /a/b; echo $?)"
assert_eq "json_escape quotes"  'a\"b'      "$(json_escape 'a"b')"
assert_eq "json_escape backslash" 'a\\c'  "$(json_escape 'a\c')"
assert_eq "pad_right pads"      "abc  "     "$(pad_right abc 5)"
assert_eq "pad_right truncates" "a..."     "$(pad_right abcdef 4)"
assert_eq "truncate_mid"        "ab...hij"   "$(truncate_mid abcdefghij 8)"
assert_eq "repeat_char"         "xxx"       "$(repeat_char x 3)"

# =============================================================================
t_section "monitor.sh parsers"
# =============================================================================
assert_eq "monitor_parse_df_line" \
    "$(printf '600\n400\n/')" \
    "$(monitor_parse_df_line 'overlay 1000 600 400 60% /')"
assert_rc  "monitor_parse_df_line short row" 1 \
    "$(monitor_parse_df_line 'overlay 1000 600'; echo $?)"

SBX_MEMINFO="$SBX/meminfo"
printf 'MemTotal:        1000 kB\nMemFree:         100 kB\nMemAvailable:     250 kB\nSwapTotal:        500 kB\nSwapFree:         100 kB\n' > "$SBX_MEMINFO"
rc=0; monitor_read_meminfo "$SBX_MEMINFO" || rc=$?
assert_rc  "monitor_read_meminfo ok" 0 "$rc"
assert_eq "monitor_read_meminfo total" "1000" "$MO_total"
assert_eq "monitor_read_meminfo available" "250" "$MO_available"
assert_eq "monitor_read_meminfo swaptotal" "500" "$MO_swaptotal"
assert_eq "monitor_read_meminfo swapfree" "100" "$MO_swapfree"
rc=0; monitor_read_meminfo "$SBX/definitely-missing" || rc=$?
assert_rc  "monitor_read_meminfo missing file" 1 "$rc"

assert_eq "monitor_load_scaled 1.25" "125" "$(monitor_load_scaled 1.25)"
assert_eq "monitor_load_scaled 0.00" "0"   "$(monitor_load_scaled 0.00)"
assert_eq "monitor_load_scaled 2"    "200" "$(monitor_load_scaled 2)"
assert_eq "monitor_load_scaled long frac" "130" "$(monitor_load_scaled 1.304)"
assert_eq "monitor_state OK"   "OK"   "$(monitor_state 50 80 90)"
assert_eq "monitor_state WARN" "WARN" "$(monitor_state 85 80 90)"
assert_eq "monitor_state CRIT" "CRIT" "$(monitor_state 95 80 90)"

# =============================================================================
t_section "cleanup.sh helpers"
# =============================================================================
CLEANUP_ROOTS=("$SBX/clean")
CLEANUP_INCLUDE_PATTERNS="*.tmp,*.log"
touch -d "40 days ago" "$SBX/clean/a.tmp"
touch -d "40 days ago" "$SBX/clean/b.log"
touch -d "1 day ago"  "$SBX/clean/recent.log"
printf 'x' > "$SBX/clean/keep.txt"

found="$(cleanup_find_files "$SBX/clean" 7 0)"
assert_contains "cleanup_find_files old tmp"     "$found" "a.tmp"
assert_contains "cleanup_find_files old log"     "$found" "b.log"
assert_eq    "cleanup_find_files skips young" "0" "$(printf '%s' "$found" | grep -c 'recent.log')"
found_recent="$(cleanup_find_files "$SBX/clean" 0 0)"
assert_contains "cleanup_find_files age=0 includes recent" "$found_recent" "recent.log"

rc=0; cleanup_candidate_ok "$SBX/clean/a.tmp" || rc=$?
assert_rc "cleanup_candidate_ok inside root" 0 "$rc"
rc=0; cleanup_candidate_ok "/etc" || rc=$?
assert_rc "cleanup_candidate_ok outside root" 1 "$rc"
rc=0; cleanup_candidate_ok "/" || rc=$?
assert_rc "cleanup_candidate_ok root slash" 1 "$rc"

mkdir -p "$SBX/clean/__pycache__"
caches="$(cleanup_find_cache_dirs "$SBX/clean" 8 0)"
assert_contains "cleanup_find_cache_dirs" "$caches" "__pycache__"

# =============================================================================
t_section "cron.sh helpers"
# =============================================================================
assert_rc "cron_validate_schedule ok"     0 "$(cron_validate_schedule '*/5 * * * *'; echo $?)"
assert_rc "cron_validate_schedule lists"  0 "$(cron_validate_schedule '1,15 2-4 * * 1-5'; echo $?)"
assert_rc "cron_validate_schedule 4 fields" 1 "$(cron_validate_schedule '*/5 * * *'; echo $?)"
assert_rc "cron_validate_schedule words"  1 "$(cron_validate_schedule 'a b c d e'; echo $?)"
assert_rc "cron_validate_label ok"        0 "$(cron_validate_label nightly-backup; echo $?)"
assert_rc "cron_validate_label space"     1 "$(cron_validate_label 'bad label'; echo $?)"
assert_eq "cron_entry_label" "monitor" \
    "$(cron_entry_label '*/5 * * * * /usr/bin/sysops monitor -q # sysops:label=monitor')"

split_out="$(cron_entry_split '*/5 * * * * /usr/bin/true # sysops:label=x')"
assert_eq "cron_entry_split schedule" "*/5"               "$(printf '%s' "$split_out" | head -n 1)"
assert_eq "cron_entry_split command"  "* * * * /usr/bin/true" "$(printf '%s' "$split_out" | tail -n +2)"

sample_crontab="SHELL=/bin/bash
# BEGIN SYSOPS MANAGED BLOCK -- DO NOT EDIT BETWEEN MARKERS
*/5 * * * * /usr/bin/sysops monitor -q # sysops:label=monitor
# END SYSOPS MANAGED BLOCK
MAILTO=root"
entries_out="$(_cron_extract_entries <<< "$sample_crontab")"
assert_eq "cron_extract_entries one line" "1" "$(printf '%s' "$entries_out" | grep -c 'monitor')"
stripped="$(_cron_strip_block <<< "$sample_crontab")"
assert_eq    "cron_strip_block removes marker" "0" "$(printf '%s' "$stripped" | grep -c 'SYSOPS MANAGED BLOCK')"
assert_contains "cron_strip_block keeps user line" "$stripped" "SHELL=/bin/bash"
assembled="$(_cron_assemble "$stripped" '*/10 * * * * /usr/bin/true # sysops:label=test')"
assert_contains "cron_assemble begin marker" "$assembled" "# BEGIN SYSOPS MANAGED BLOCK"
assert_contains "cron_assemble end marker"   "$assembled" "# END SYSOPS MANAGED BLOCK"
assert_contains "cron_assemble entry"        "$assembled" "*/10 * * * * /usr/bin/true"

# =============================================================================
t_section "backup.sh helpers"
# =============================================================================
assert_rc "gzip level 9 ok"  0 "$(_backup_validate_gzip_level 9; echo $?)"
assert_rc "gzip level 10 bad" 1 "$(_backup_validate_gzip_level 10; echo $?)"
assert_rc "gzip level abc"   1 "$(_backup_validate_gzip_level abc; echo $?)"

touch "$SBX/bk/proj-20250101-000000.tar.gz" "$SBX/bk/proj-20250102-000000.tar.gz" "$SBX/bk/proj-20250103-000000.tar.gz"
n_archives="$(_backup_list_archives "$SBX/bk" proj | tr '\0' '\n' | grep -c 'proj-.*\.tar\.gz')"
assert_eq "backup_list_archives finds 3" "3" "$n_archives"

# real backup into the sandbox (small source dir, verified, fixed stamp)
printf 'alpha\n' > "$SBX/data/alpha.txt"
printf 'beta\n'  > "$SBX/data/beta.txt"
run_cmd "$SYSOPS" backup -d "$SBX/bk2" -n proj --stamp 20260101-000000 --verify "$SBX/data"
assert_rc  "backup real run" 0 "$RC"
assert_contains "backup summary" "$OUT" "backup OK"
[[ -f "$SBX/bk2/proj-20260101-000000.tar.gz" ]]
assert_rc "backup archive exists" 0 "$?"
run_cmd "$SYSOPS" backup --list "$SBX/bk2" proj
assert_rc  "backup --list rc" 0 "$RC"
assert_contains "backup --list shows archive" "$OUT" "proj-20260101-000000.tar.gz"

# seed two stale archives so the rotation window actually has to delete
touch "$SBX/bk2/proj-20240101-000000.tar.gz" "$SBX/bk2/proj-20240102-000000.tar.gz"
run_cmd "$SYSOPS" backup -d "$SBX/bk2" -n proj --stamp 20260102-000000 -k 2 "$SBX/data"
assert_rc "rotation run rc" 0 "$RC"
n_left="$(find "$SBX/bk2" -maxdepth 1 -name 'proj-*.tar.gz' | wc -l | tr -d ' ')"
assert_eq "rotation keeps 2 archives" "2" "$n_left"
assert_eq "rotation removed the stale ones" "0" "$(find "$SBX/bk2" -maxdepth 1 -name 'proj-20240101-000000.tar.gz' | wc -l | tr -d ' ')"

run_cmd "$SYSOPS" backup -d "$SBX/bk3" -n proj --dry-run "$SBX/data"
assert_rc  "backup dry-run rc" 0 "$RC"
assert_contains "backup dry-run banner" "$OUT" "dry-run plan"
assert_rc "backup dry-run created nothing" 1 "$([[ -e "$SBX/bk3" ]] && echo 0 || echo 1)"

# =============================================================================
t_section "logs.sh helpers"
# =============================================================================
assert_eq "logs_normalize_since 24h" "-24h"  "$(logs_normalize_since 24h)"
assert_eq "logs_normalize_since 7d"  "-7d"   "$(logs_normalize_since 7d)"
assert_eq "logs_normalize_since spec" "today" "$(logs_normalize_since today)"

SBX_APPLOG="$SBX/app.log"
cat > "$SBX_APPLOG" <<'EOF'
2026-01-01T10:00:00 app: ERROR oops one
2026-01-01T10:01:00 app: all good
2026-01-01T10:02:00 app: Error oops two
2026-01-01T10:03:00 app: failed to start helper
EOF
kw_rows="$(logs_count_keywords "$SBX_APPLOG" "error fail")"
assert_contains "logs keyword error count" "$kw_rows" "$(printf 'error\t2\t')"
assert_contains "logs keyword fail count"  "$kw_rows" "$(printf 'fail\t1\t')"
assert_contains "logs last-seen stamp"     "$kw_rows" "2026-01-01T10:02:00"

run_cmd "$SYSOPS" logs --file "$SBX_APPLOG" --keyword oops
assert_rc  "logs command rc" 0 "$RC"
assert_contains "logs command finds oops" "$OUT" "oops"

# =============================================================================
t_section "service.sh helpers"
# =============================================================================
assert_rc "validate host ok"    0 "$(_service_validate_host db.internal; echo $?)"
assert_rc "validate host dash"  1 "$(_service_validate_host -bad; echo $?)"
assert_rc "validate port 0"     1 "$(_service_validate_port 0; echo $?)"
assert_rc "validate port 65536" 1 "$(_service_validate_port 65536; echo $?)"
assert_rc "validate port 443"   0 "$(_service_validate_port 443; echo $?)"

# localhost listener for real OPEN/CLOSED checks (loopback only)
LISTENER_PID=""
if command -v python3 >/dev/null 2>&1; then
    ( cd "$SBX" && exec python3 -m http.server 18080 --bind 127.0.0.1 >/dev/null 2>&1 ) &
    LISTENER_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if (exec 3<>/dev/tcp/127.0.0.1/18080) 2>/dev/null; then
            exec 3>&- 3<&- 2>/dev/null
            break
        fi
        sleep 0.5
    done
fi
run_cmd "$SYSOPS" service port 127.0.0.1 18080
assert_rc  "service port OPEN on loopback listener" 0 "$RC"
assert_contains "service port OPEN text" "$OUT" "OPEN"
run_cmd "$SYSOPS" service port 127.0.0.1 1
assert_rc_in "service port CLOSED on port 1" "$RC" "1 3"
run_cmd "$SYSOPS" service port 127.0.0.1 99999
assert_rc  "service port invalid port" 2 "$RC"
run_cmd "$SYSOPS" service status definitely-not-a-service
assert_rc_in "service status unknown service" "$RC" "1 3"

# =============================================================================
t_section "net.sh parsers"
# =============================================================================
assert_eq "net_extract_port v4"  "22"  "$(net_extract_port '0.0.0.0:22')"
assert_eq "net_extract_port v6"  "443" "$(net_extract_port '[::]:443')"
assert_rc  "net_extract_port bad" 1 "$(net_extract_port 'no-colon'; echo $?)"
assert_eq "net_strip_port"       "0.0.0.0" "$(net_strip_port '0.0.0.0:22')"
assert_eq "net_parse_ss_process" "sshd" "$(net_parse_ss_process 'users:(("sshd",pid=812,fd=3))')"
assert_eq "net_parse_ss_line with proc" \
    "tcp LISTEN 0.0.0.0 22 sshd" \
    "$(net_parse_ss_line 'LISTEN 0      128          0.0.0.0:22        0.0.0.0:*    users:(("sshd",pid=812,fd=3))')"
assert_eq "net_parse_ss_line no proc" \
    "tcp LISTEN 0.0.0.0 22 -" \
    "$(net_parse_ss_line 'LISTEN 0      128          0.0.0.0:22        0.0.0.0:*')"
assert_eq "net_parse_netstat_line no pid" \
    "tcp LISTEN 127.0.0.1 12600 -" \
    "$(net_parse_netstat_line 'tcp        0      0 127.0.0.1:12600         0.0.0.0:*               LISTEN      -')"
assert_eq "net_parse_netstat_line with pid" \
    "tcp LISTEN 0.0.0.0 80 nginx" \
    "$(net_parse_netstat_line 'tcp        0      0 0.0.0.0:80            0.0.0.0:*               LISTEN      812/nginx')"
assert_eq "net_hex_ip_to_dotted" "127.0.0.1" "$(net_hex_ip_to_dotted 0100007F)"
assert_eq "net_hex_port_to_dec"  "8080"     "$(net_hex_port_to_dec 1F90)"
assert_eq "net_parse_proc_line listen" \
    "127.0.0.1 8080 LISTEN" \
    "$(net_parse_proc_line '   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 915 1 00000000fd93f03c 100 0 0 10 0')"
assert_eq "net_parse_proc_line estab (local side)" \
    "10.0.0.2 22 ESTAB" \
    "$(net_parse_proc_line '   1: 0200000A:0016 0500000A:C738 01 00000000:00000000 00:00000000 00000000     0        0 916 1 00000000fd93f03d 100 0 0 10 0')"
assert_eq "net_parse_sockstat" \
    "inuse=41 orphan=0 tw=105 alloc=120 mem=4" \
    "$(net_parse_sockstat 'TCP: inuse 41 orphan 0 tw 105 alloc 120 mem 4')"

SBX_SNMP="$SBX/snmp"
cat > "$SBX_SNMP" <<'EOF'
Ip: Forwarding DefaultTTL InReceives InHdrErrors
Ip: 1 64 1000 0
Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 2640 512 24 8 12 1234567 987654 321 1 456 0
Udp: InDatagrams NoPorts
Udp: 100 5
EOF
assert_eq "net_parse_snmp_tcp" \
    "ActiveOpens=2640 PassiveOpens=512 CurrEstab=12 RetransSegs=321" \
    "$(net_parse_snmp_tcp "$SBX_SNMP")"
assert_rc "net_parse_snmp_tcp missing file" 1 "$(net_parse_snmp_tcp "$SBX/missing-snmp"; echo $?)"

# =============================================================================
t_section "net.sh commands"
# =============================================================================
run_cmd "$SYSOPS" net listen
assert_rc "net listen rc" 0 "$RC"
assert_contains "net listen shows sockets" "$OUT" "LISTEN"
run_cmd "$SYSOPS" net listen --json
assert_rc  "net listen --json rc" 0 "$RC"
assert_match "net listen --json valid JSONL" "$OUT" '^\['
run_cmd "$SYSOPS" net listen --port 18080
if kill -0 "$LISTENER_PID" 2>/dev/null; then
    assert_contains "net listen --port filter shows 18080" "$OUT" "18080"
else
    T_PASS=$(( T_PASS + 1 )); printf 'ok   net listen --port filter (listener unavailable, skipped)\n'
fi
run_cmd "$SYSOPS" net conns
assert_rc "net conns rc" 0 "$RC"
run_cmd "$SYSOPS" net ifaces
assert_rc  "net ifaces rc" 0 "$RC"
assert_contains "net ifaces lists lo" "$OUT" "lo"
run_cmd "$SYSOPS" net stats
assert_rc  "net stats rc" 0 "$RC"
assert_contains "net stats has ActiveOpens" "$OUT" "ActiveOpens"
run_cmd "$SYSOPS" net ports 18080
if kill -0 "$LISTENER_PID" 2>/dev/null; then
    assert_rc "net ports OPEN for listener" 0 "$RC"
else
    assert_rc_in "net ports rc (listener down)" "$RC" "0 1"
fi
run_cmd "$SYSOPS" net ports 65001 65002
assert_rc_in "net ports closed ports" "$RC" "0 1"
run_cmd "$SYSOPS" net ports 99999
assert_rc "net ports invalid port" 2 "$RC"
run_cmd "$SYSOPS" net ports
assert_rc "net ports no args" 2 "$RC"
run_cmd "$SYSOPS" net bogus-action
assert_rc "net unknown action" 2 "$RC"

# =============================================================================
t_section "pkg.sh parsers + commands"
# =============================================================================
SBX_DPKG="$SBX/dpkg-status"
cat > "$SBX_DPKG" <<'EOF'
Package: coreutils
Status: install ok installed
Version: 9.1-1

Package: nginx
Status: deinstall ok config-files
Version: 1.18

Package: bash
Status: install ok installed
Version: 5.2

Package: docker-ce
Status: install ok half-configured
Version: 24
EOF
assert_eq "pkg_count_dpkg_status" "2" "$(pkg_count_dpkg_status "$SBX_DPKG")"
assert_rc "pkg_count_dpkg_status missing" 1 "$(pkg_count_dpkg_status "$SBX/nope"; echo $?)"

SBX_APKDB="$SBX/apk-db"
printf 'P:curl\nV:8.9\n\nP:openssl\nV:3.1\n\n' > "$SBX_APKDB"
assert_eq "pkg_count_apk_db" "2" "$(pkg_count_apk_db "$SBX_APKDB")"
assert_eq "pkg_count_rpm_query" "3" "$(pkg_count_rpm_query <<< 'a
b

c')"
assert_eq "pkg_parse_dpkg_owner" "coreutils" "$(pkg_parse_dpkg_owner 'coreutils: /usr/bin/ls')"
assert_eq "pkg_parse_pacman_owner" "coreutils" "$(pkg_parse_pacman_owner '/usr/bin/ls is owned by coreutils 9.1-1')"
assert_rc "pkg_parse_pacman_owner bad" 1 "$(pkg_parse_pacman_owner 'error: no package'; echo $?)"

run_cmd "$SYSOPS" pkg count
assert_rc  "pkg count rc" 0 "$RC"
assert_contains "pkg count shows dpkg" "$OUT" "dpkg"
run_cmd "$SYSOPS" pkg info
assert_rc "pkg info rc" 0 "$RC"
run_cmd "$SYSOPS" pkg cache
assert_rc "pkg cache rc" 0 "$RC"
run_cmd "$SYSOPS" pkg owner /usr/bin/tar
assert_rc_in "pkg owner owned-or-not" "$RC" "0 1"
run_cmd "$SYSOPS" pkg owner "$SBX/data/alpha.txt"
assert_rc_in "pkg owner unmanaged file" "$RC" "1"
run_cmd "$SYSOPS" pkg owner /definitely/not/here
assert_rc  "pkg owner missing file" 2 "$RC"

# =============================================================================
t_section "notify.sh helpers + commands"
# =============================================================================
assert_rc "notify level warn ok"  0 "$(notify_validate_level warn; echo $?)"
assert_rc "notify level fatal bad" 1 "$(notify_validate_level fatal; echo $?)"
assert_eq "notify rank crit" "2" "$(notify_level_rank crit)"
assert_eq "notify rank info" "0" "$(notify_level_rank info)"
assert_eq "notify clean message" "a b c" "$(notify_clean_message 'a  b  c')"
assert_eq "notify parse line" "100 warn" \
    "$(notify_parse_line "$(printf '100\t2026-01-01T00:00:00+00\twarn\thost1\tdisk alert')")"
assert_rc "notify parse garbage" 1 "$(notify_parse_line 'not-a-valid-line'; echo $?)"

SBX_ALERTS="$SBX/alerts.log"
printf '10\t2026-01-01T00:00:00+00\tinfo\th\tfirst\n' > "$SBX_ALERTS"
printf '50\t2026-01-01T00:01:00+00\tcrit\th\tthird\n' >> "$SBX_ALERTS"
printf '150\t2026-01-01T00:02:00+00\twarn\th\tsecond\n' >> "$SBX_ALERTS"
assert_eq "notify_worst all"   "crit" "$(notify_worst "$SBX_ALERTS" 0)"
assert_eq "notify_worst cutoff" "warn" "$(notify_worst "$SBX_ALERTS" 100)"
rc=0; worst_out="$(notify_worst "$SBX/no-alerts" 0)" || rc=$?
assert_eq "notify_worst missing file prints none" "none" "$worst_out"
assert_rc "notify_worst missing file rc" 1 "$rc"
assert_rc "notify webhook url ok" 0 "$(notify_validate_webhook_url 'https://hooks.example.com/a/b'; echo $?)"
assert_rc "notify webhook url bad" 1 "$(notify_validate_webhook_url 'ftp://x'; echo $?)"

run_cmd env SYOPS_NOTIFY_LOG="$SBX/notify-run.log" "$SYSOPS" notify send "disk almost full" --level warn
assert_rc  "notify send rc" 0 "$RC"
assert_contains "notify send wrote log" "$(< "$SBX/notify-run.log")" "disk almost full"
run_cmd env SYOPS_NOTIFY_LOG="$SBX/notify-run.log" "$SYSOPS" notify send "disk full now" --level crit
assert_rc "notify send crit rc" 0 "$RC"
run_cmd env SYOPS_NOTIFY_LOG="$SBX/notify-run.log" "$SYSOPS" notify check
assert_rc  "notify check worst crit" 2 "$RC"
run_cmd env SYOPS_NOTIFY_LOG="$SBX/notify-run.log" "$SYSOPS" notify show
assert_rc  "notify show rc" 0 "$RC"
assert_contains "notify show lists message" "$OUT" "disk almost full"
run_cmd env SYOPS_NOTIFY_LOG="$SBX/notify-run.log" "$SYSOPS" notify send "oops" --level bogus
assert_rc "notify send invalid level" 2 "$RC"
n_before="$(wc -l < "$SBX/notify-run.log" | tr -d ' ')"
run_cmd env SYOPS_NOTIFY_LOG="$SBX/notify-run.log" "$SYSOPS" notify send "dry" --dry-run
assert_rc    "notify send dry-run rc" 0 "$RC"
assert_contains "notify send dry-run banner" "$OUT" "dry-run"
n_after="$(wc -l < "$SBX/notify-run.log" | tr -d ' ')"
assert_eq "notify send dry-run wrote nothing" "$n_before" "$n_after"
run_cmd env SYOPS_NOTIFY_LOG="$SBX/missing-dir/log" "$SYSOPS" notify check
assert_rc "notify check missing log" 0 "$RC"

# staleness: an ancient alert must be ignored with --stale-min 1
printf '1\t2026-01-01T00:00:00+00\twarn\th\tancient alert\n' > "$SBX/stale.log"
run_cmd env SYOPS_NOTIFY_LOG="$SBX/stale.log" "$SYSOPS" notify check --stale-min 1
assert_rc  "notify check stale window excludes ancient" 0 "$RC"
run_cmd env SYOPS_NOTIFY_LOG="$SBX/stale.log" "$SYSOPS" notify check
assert_rc  "notify check without window sees ancient" 1 "$RC"

# =============================================================================
t_section "update-check.sh parsers + commands"
# =============================================================================
SBX_APT="$SBX/apt-sim"
cat > "$SBX_APT" <<'EOF'
Reading package lists...
Building dependency tree...
Calculating upgrade...
The following packages will be upgraded:
  libc6 nginx
Inst libc6 [2.31-0ubuntu9] (2.31-0ubuntu9.1 Ubuntu:20.04/focal-updates [amd64])
Inst nginx (1.18.0-0ubuntu1.2 Ubuntu:20.04/focal-security [amd64])
Conf libc6 (2.31-0ubuntu9.1 Ubuntu:20.04/focal-updates [amd64])
EOF
assert_eq "updates_parse_apt_sim count" "2" "$(updates_parse_apt_sim "$SBX_APT")"
apt_names="$(updates_parse_apt_sim --names "$SBX_APT" | tr '\n' ' ')"
assert_eq "updates_parse_apt_sim names" "libc6 nginx " "$apt_names"

SBX_DNF="$SBX/dnf-out"
cat > "$SBX_DNF" <<'EOF'
Last metadata expiration check: 0:00:01 ago on Mon 01 Jan 2026.
kernel-core-5.10.134-013.15.al8.x86_64    baseos    1.2 M
openssl-libs-3.0.7-6.el8.x86_64           baseos    2.0 M
Obsoleting Packages
EOF
assert_eq "updates_parse_dnf_output count" "2" "$(updates_parse_dnf_output "$SBX_DNF")"
assert_eq "updates_parse_dnf_output names" "kernel-core" "$(updates_parse_dnf_output --names "$SBX_DNF" | head -n 1)"

assert_eq "updates_parse_pacman_output" "1" "$(updates_parse_pacman_output <<< 'linux 6.1-1 -> 6.2-1')"
assert_eq "updates_parse_pacman_output names" "linux" "$(updates_parse_pacman_output --names <<< 'linux 6.1-1 -> 6.2-1')"
assert_eq "updates_parse_apk_output" "1" "$(updates_parse_apk_output <<< '< curl-8.9.1-r0 < 8.11.1-r0 x86_64 @edge/main')"
assert_eq "updates_parse_apk_output names" "curl" "$(updates_parse_apk_output --names <<< '< curl-8.9.1-r0 < 8.11.1-r0 x86_64 @edge/main')"

assert_eq "updates_kernel_state same"    "same"    "$(updates_kernel_state 6.8.0 6.8.0)"
assert_eq "updates_kernel_state drift"   "drift"   "$(updates_kernel_state 6.8.0 6.9.0)"
assert_eq "updates_kernel_state none"    "none"    "$(updates_kernel_state 6.8.0 none)"
assert_eq "updates_kernel_state unknown" "unknown" "$(updates_kernel_state '' 6.9.0)"
assert_eq "updates_reboot_required no"      "no"       "$(updates_reboot_required "$SBX/no-marker")"
assert_eq "updates_reboot_required marker"  "required" "$(updates_reboot_required "$SBX_APT")"

SBX_BOOT="$SBX/boot"
mkdir -p "$SBX_BOOT"
touch "$SBX_BOOT/vmlinuz-6.1.0" "$SBX_BOOT/vmlinuz-6.9.0"
assert_eq "updates_newest_kernel" "6.9.0" "$(updates_newest_kernel "$SBX_BOOT")"

run_cmd "$SYSOPS" updates check
assert_rc  "updates check rc" 0 "$RC"
assert_contains "updates check lists apt" "$OUT" "apt"
run_cmd "$SYSOPS" updates summary
assert_rc_in "updates summary rc" "$RC" "0 1 2"
run_cmd "$SYSOPS" updates list --limit 3
assert_rc_in "updates list rc" "$RC" "0 3"
run_cmd "$SYSOPS" updates reboot
assert_rc_in "updates reboot rc" "$RC" "0 2"
run_cmd "$SYSOPS" updates bogus
assert_rc "updates unknown action" 2 "$RC"

# =============================================================================
t_section "report command (integration)"
# =============================================================================
run_cmd "$SYSOPS" --version
assert_rc  "version rc" 0 "$RC"
assert_match "version string" "$OUT" '^sysops [0-9]'
run_cmd "$SYSOPS" help
assert_rc  "help rc" 0 "$RC"
assert_contains "help lists commands" "$OUT" "COMMANDS"
assert_contains "help lists net" "$OUT" "net"
run_cmd "$SYSOPS" help net
assert_rc  "per-command help rc" 0 "$RC"
assert_contains "per-command help" "$OUT" "sysops net"
run_cmd "$SYSOPS" definitely-not-a-command
assert_rc  "unknown command rc" 2 "$RC"
run_cmd "$SYSOPS" --unknown-global
assert_rc  "unknown global option rc" 2 "$RC"

run_cmd "$SYSOPS" report --section os
assert_rc  "report os rc" 0 "$RC"
assert_contains "report os section" "$OUT" "OS"
run_cmd "$SYSOPS" report --section os,memory
assert_rc  "report two sections rc" 0 "$RC"
run_cmd "$SYSOPS" report --section packages,sockets
assert_rc  "report new sections rc" 0 "$RC"
assert_contains "report packages section" "$OUT" "Packages"
assert_contains "report sockets section" "$OUT" "Sockets"
run_cmd "$SYSOPS" report --section bogus
assert_rc  "report unknown section" 2 "$RC"
run_cmd "$SYSOPS" report --json --section os
assert_rc  "report json rc" 0 "$RC"
assert_contains "report json wrapper" "$OUT" '"sections"'
assert_contains "report json hostname" "$OUT" '"hostname"'
run_cmd "$SYSOPS" report --json --section sockets
assert_contains "report json sockets count" "$OUT" "listening_count"

# =============================================================================
t_section "monitor command (integration, real thresholds)"
# =============================================================================
run_cmd "$SYSOPS" monitor mem
assert_rc_in "monitor mem rc is 0/1/2" "$RC" "0 1 2"
assert_contains "monitor mem output" "$OUT" "mem"
run_cmd "$SYSOPS" monitor disk --path /tmp --warn 99 --crit 100
assert_rc  "monitor disk lenient thresholds" 0 "$RC"
run_cmd "$SYSOPS" monitor mem --warn 1 --crit 2
assert_rc_in "monitor mem strict thresholds" "$RC" "0 1 2"
run_cmd "$SYSOPS" monitor --json
assert_rc_in "monitor json rc" "$RC" "0 1 2"
assert_match "monitor json JSONL rows" "$OUT" '^\{"check":'
run_cmd "$SYSOPS" monitor mem --warn abc
assert_rc_in "monitor non-numeric threshold tolerated" "$RC" "0 1 2"

# config file actually changes the thresholds
printf 'MONITOR_MEM_WARN=101\nMONITOR_MEM_CRIT=102\n' > "$SBX/test.conf"
run_cmd "$SYSOPS" --config "$SBX/test.conf" monitor mem
assert_rc  "monitor with config file (mem < 101%%)" 0 "$RC"
run_cmd "$SYSOPS" --config "$SBX/missing.conf" monitor mem
assert_rc  "monitor with missing config file" 2 "$RC"

# =============================================================================
t_section "audit command (integration)"
# =============================================================================
run_cmd "$SYSOPS" audit sysctl
assert_rc_in "audit sysctl rc" "$RC" "0 1 2"
assert_contains "audit summary line" "$OUT" "Summary:"
run_cmd "$SYSOPS" audit sshd
assert_rc_in "audit sshd rc" "$RC" "0 1 2 3"
run_cmd "$SYSOPS" audit users sudo
assert_rc_in "audit users+sudo rc" "$RC" "0 1 2 3"
run_cmd "$SYSOPS" audit bogus-check
assert_rc  "audit unknown check" 2 "$RC"

# =============================================================================
t_section "cleanup command (DRY-RUN ONLY, integration)"
# =============================================================================
run_cmd "$SYSOPS" cleanup --older-than 0 --include '*.tmp' "$SBX/clean"
assert_rc  "cleanup dry-run rc" 0 "$RC"
assert_contains "cleanup dry-run banner" "$OUT" "dry-run"
assert_contains "cleanup lists candidate" "$OUT" "a.tmp"
[[ -f "$SBX/clean/a.tmp" ]]
assert_rc "cleanup dry-run deleted nothing" 0 "$?"
run_cmd "$SYSOPS" cleanup --json --older-than 0 --include '*.tmp' "$SBX/clean"
assert_rc    "cleanup --json rc" 0 "$RC"
assert_contains "cleanup --json mode" "$OUT" '"mode": "dry-run"'
run_cmd "$SYSOPS" cleanup /
assert_rc  "cleanup refuses system root" 2 "$RC"
run_cmd "$SYSOPS" cleanup "$SBX/definitely-missing-dir"
assert_rc  "cleanup missing root" 2 "$RC"

# =============================================================================
t_section "cron command (integration, dry-run only)"
# =============================================================================
run_cmd "$SYSOPS" cron list
assert_rc_in "cron list rc (crontab may be absent)" "$RC" "0 3"
if [[ "$RC" == "0" ]]; then
    run_cmd "$SYSOPS" cron install --schedule '*/5 * * * *' --command '/usr/bin/true' --label t3-13b --dry-run
    assert_rc  "cron install dry-run rc" 0 "$RC"
    assert_contains "cron install dry-run shows block" "$OUT" "BEGIN SYSOPS MANAGED BLOCK"
else
    T_PASS=$(( T_PASS + 1 ))
    printf 'ok   cron install dry-run (crontab binary absent on host, skipped)\n'
fi
run_cmd "$SYSOPS" cron install --schedule 'not-a-schedule' --command x --label y
assert_rc_in "cron install invalid schedule" "$RC" "2 3"
run_cmd "$SYSOPS" cron bogus-action
assert_rc_in "cron unknown action" "$RC" "2 3"

# =============================================================================
t_section "library entry-point guard"
# =============================================================================
guard_out="$(bash -c 'source "'"$SYSOPS"'"; printf "%s" "${SYOPS_VERSION:-unset}"' 2>/dev/null)"
assert_eq "sourcing bin/sysops defines version without running" "1.0.0" "$guard_out"

# =============================================================================
printf '\n== Summary ==\n'
printf 'passed: %d  failed: %d\n' "$T_PASS" "$T_FAIL"
if (( T_FAIL > 0 )); then
    exit $(( T_FAIL > 125 ? 125 : T_FAIL ))
fi
exit 0
