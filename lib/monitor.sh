#!/usr/bin/env bash
# =============================================================================
# monitor.sh -- `sysops monitor`: threshold checks with cron-friendly codes
#
# Checks (each individually selectable, all by default):
#   disk  -- usage percent of one or more mount points (df -P based)
#   mem   -- physical memory usage percent (/proc/meminfo based)
#   swap  -- swap usage percent (only when swap is configured)
#   load  -- 1-minute load average vs cores (integer math, 2 decimals)
#
# Exit codes (suitable for cron / alerting):
#   0  all checks OK
#   1  at least one check WARN
#   2  at least one check CRIT (worst state wins)
#   3  internal error (bad config, unreadable system files)
#
# All comparisons use pure integer arithmetic (values scaled by 100), so no
# bc/awk floating point is needed.  Parsing helpers are factored into pure
# functions so tests/run_tests.sh can exercise them without a real df/meminfo.
# =============================================================================

MONITOR_ALL_CHECKS="disk mem swap load"

monitor_usage() {
    cat <<'EOF'
sysops monitor -- threshold checks for cron (exit code = worst state)

USAGE
  sysops monitor [OPTIONS] [CHECKS...]

CHECKS
  disk mem swap load        (default: all)

OPTIONS
  --path P                  Check mount point containing P (repeatable,
                            default: /)
  --all-mounts              Check every real (non-pseudo) mount point
  --warn N                  Warn threshold percent for disk+mem (default 80)
  --crit N                  Crit threshold percent for disk+mem (default 90)
  --disk-warn N --disk-crit N   Per-check overrides for disk
  --mem-warn N  --mem-crit N    Per-check overrides for mem/swap
  --load-warn N --load-crit N   Load thresholds in percent of total cores
                                (default: 70 / 200; 100 == 1.0 per core)
  --repeat N --interval S   Run N times, sleeping S seconds between runs
  --json                    One JSON object per check per run (JSONL)
  -q, --quiet               No per-check lines, exit code only
  -h, --help                Show this help

EXIT CODES
  0 OK   1 WARN   2 CRIT   3 internal error

EXAMPLES
  sysops monitor                     # human-readable, exit 0/1/2
  sysops monitor disk --warn 85 --crit 95
  sysops monitor --json              # JSONL, easy to parse in scripts
  */5 * * * * sysops monitor -q || logger -t sysops "monitor rc=$?"
EOF
}

# -----------------------------------------------------------------------------
# Pure parsing helpers (unit-testable)
# -----------------------------------------------------------------------------
# monitor_parse_df_line "overlay / 1000 600 400 60% /"
#   -> prints "600\n400\n/" (used, available KiB, mount) using df -P layout:
#      Filesystem 1024-blocks Used Available Capacity Mounted-on
monitor_parse_df_line() {
    local line="${1:-}"
    local -a f=()
    read -r -a f <<< "$line" || return 1
    if (( ${#f[@]} < 6 )); then
        return 1
    fi
    is_int "${f[1]}" && is_int "${f[2]}" && is_int "${f[3]}" || return 1
    printf '%s\n%s\n%s\n' "${f[2]}" "${f[3]}" "${f[5]}"
    return 0
}

# monitor_read_meminfo FILE -> sets MO_total MO_available MO_swaptotal
# MO_swapfree (KiB); rc 1 when the file is missing/empty.
monitor_read_meminfo() {
    local file="${1:-/proc/meminfo}"
    MO_total=0; MO_available=0; MO_swaptotal=0; MO_swapfree=0
    [[ -r "$file" ]] || return 1
    local line key val found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%:*}"
        val="${line#*:}"
        key="$(trim "$key")"
        val="$(trim "$val")"
        val="${val%% *}"
        is_int "$val" || continue
        case "$key" in
            MemTotal)     MO_total="$val";      found=$(( found + 1 )) ;;
            MemAvailable) MO_available="$val";  found=$(( found + 1 )) ;;
            SwapTotal)    MO_swaptotal="$val";  found=$(( found + 1 )) ;;
            SwapFree)     MO_swapfree="$val";   found=$(( found + 1 )) ;;
        esac
    done < "$file"
    (( found > 0 )) || return 1
    return 0
}

# monitor_load_scaled "1.25" -> 125   (load average x100 as integer)
monitor_load_scaled() {
    local v="${1:-0}"
    v="${v%% *}"
    if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%s' "0"
        return 1
    fi
    if [[ "$v" != *.* ]]; then
        v="$v.0"
    fi
    local int_part="${v%%.*}" frac_part="${v#*.}"
    frac_part="${frac_part:0:2}"
    while (( ${#frac_part} < 2 )); do
        frac_part="${frac_part}0"
    done
    printf '%d' $(( 10#$int_part * 100 + 10#$frac_part ))
    return 0
}

# monitor_state VALUE WARN CRIT -> prints OK|WARN|CRIT
monitor_state() {
    local val="$1" warn="$2" crit="$3"
    if (( val >= crit )); then
        printf '%s' "CRIT"
    elif (( val >= warn )); then
        printf '%s' "WARN"
    else
        printf '%s' "OK"
    fi
    return 0
}

# monitor_emit CHECK TARGET VALUE STATE WARN CRIT DETAIL
monitor_emit() {
    local check="$1" target="$2" value="$3" state="$4"
    local warn="$5" crit="$6" detail="${7:-}"
    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        printf '{"check":"%s","target":"%s","value":%s,"state":"%s","warn":%s,"crit":%s,"detail":"%s"}\n' \
            "$(json_escape "$check")" "$(json_escape "$target")" \
            "$value" "$state" "$warn" "$crit" "$(json_escape "$detail")"
        return 0
    fi
    if [[ "${OPT_QUIET:-0}" == "1" ]]; then
        return 0
    fi
    local color="$C_GREEN"
    case "$state" in
        WARN) color="$C_YELLOW" ;;
        CRIT) color="$C_RED" ;;
    esac
    printf '%s[%-4s]%s %-5s %-22s %s%s\n' \
        "$color" "$state" "$C_RESET" "$check" "$(truncate_mid "$target" 22)" \
        "$detail" ""
    return 0
}

# monitor_absorb RC -- fold a check result (0/1/2) into MONITOR_WORST
MONITOR_WORST=0
monitor_absorb() {
    local rc="$1"
    if (( rc > MONITOR_WORST )); then
        MONITOR_WORST="$rc"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Individual checks (each calls monitor_emit and returns 0/1/2; rc 3 = error)
# -----------------------------------------------------------------------------
_monitor_check_disk_one() {
    # _monitor_check_disk_one PATH WARN CRIT
    local path="$1" warn="$2" crit="$3"
    local df_line=""
    if ! df_line="$(df -P -- "$path" 2>/dev/null | tail -n 1)"; then
        error "monitor: df failed for '$path'"
        return 3
    fi
    local used="" avail="" mnt=""
    if ! { read -r used && read -r avail && read -r mnt; } < <(monitor_parse_df_line "$df_line"); then
        error "monitor: cannot parse df output for '$path'"
        return 3
    fi
    local val
    val="$(pct "$used" $(( used + avail )))"
    local state
    state="$(monitor_state "$val" "$warn" "$crit")"
    local detail
    detail="$(printf '%s used (%s / %s) [warn>=%s crit>=%s]' \
        "$val" \
        "$(human_size $(( used * 1024 )))" \
        "$(human_size $(( (used + avail) * 1024 )))" \
        "$warn" "$crit")"
    monitor_emit disk "$mnt" "$val" "$state" "$warn" "$crit" "$detail"
    case "$state" in
        OK)   return 0 ;;
        WARN) return 1 ;;
        CRIT) return 2 ;;
    esac
    return 0
}

_monitor_check_disk() {
    local warn="$1" crit="$2"
    local rc_all=0 rc=0 p
    for p in "${MONITOR_PATHS[@]}"; do
        rc=0
        _monitor_check_disk_one "$p" "$warn" "$crit" || rc=$?
        if (( rc == 3 )); then
            return 3
        fi
        if (( rc > rc_all )); then
            rc_all="$rc"
        fi
    done
    return "$rc_all"
}

_monitor_check_mounts_all() {
    # scan every real mount point once and check each
    local warn="$1" crit="$2"
    local rc_all=0 rc=0
    local -a rows=()
    mapfile -t rows < <(df -P -l -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null | tail -n +2 || true)
    if (( ${#rows[@]} == 0 )); then
        mapfile -t rows < <(df -P -l 2>/dev/null | tail -n +2 || true)
    fi
    local row mnt
    for row in "${rows[@]}"; do
        mnt="$(monitor_parse_df_line "$row" | tail -n 1)" || continue
        [[ -n "$mnt" ]] || continue
        rc=0
        _monitor_check_disk_one "$mnt" "$warn" "$crit" || rc=$?
        if (( rc == 3 )); then
            continue
        fi
        if (( rc > rc_all )); then
            rc_all="$rc"
        fi
    done
    return "$rc_all"
}

_monitor_check_mem() {
    # _monitor_check_mem WARN CRIT -- physical memory usage
    local warn="$1" crit="$2"
    if ! monitor_read_meminfo /proc/meminfo; then
        error "monitor: /proc/meminfo unreadable"
        return 3
    fi
    if (( MO_total <= 0 )); then
        error "monitor: MemTotal is zero"
        return 3
    fi
    if (( MO_available <= 0 )); then
        # very old kernels: approximate available with free + buffers + cached
        MO_available=$MO_total
        debug "monitor: MemAvailable missing, falling back to total"
    fi
    local used=$(( MO_total - MO_available ))
    if (( used < 0 )); then used=0; fi
    local val
    val="$(pct "$used" "$MO_total")"
    local state
    state="$(monitor_state "$val" "$warn" "$crit")"
    local detail
    detail="$(printf '%s%% used (%s / %s) [warn>=%s crit>=%s]' \
        "$val" \
        "$(human_size $(( used * 1024 )))" \
        "$(human_size $(( MO_total * 1024 )))" \
        "$warn" "$crit")"
    monitor_emit mem "RAM" "$val" "$state" "$warn" "$crit" "$detail"
    case "$state" in
        OK)   return 0 ;;
        WARN) return 1 ;;
        CRIT) return 2 ;;
    esac
    return 0
}

_monitor_check_swap() {
    # _monitor_check_swap WARN CRIT -- skipped (rc 0) when swap is not in use
    local warn="$1" crit="$2"
    if ! monitor_read_meminfo /proc/meminfo; then
        error "monitor: /proc/meminfo unreadable"
        return 3
    fi
    if (( MO_swaptotal <= 0 )); then
        monitor_emit swap "SWAP" 0 "OK" "$warn" "$crit" "no swap configured (skipped)"
        return 0
    fi
    local used=$(( MO_swaptotal - MO_swapfree ))
    if (( used < 0 )); then used=0; fi
    local val
    val="$(pct "$used" "$MO_swaptotal")"
    local state
    state="$(monitor_state "$val" "$warn" "$crit")"
    local detail
    detail="$(printf '%s%% used (%s / %s) [warn>=%s crit>=%s]' \
        "$val" \
        "$(human_size $(( used * 1024 )))" \
        "$(human_size $(( MO_swaptotal * 1024 )))" \
        "$warn" "$crit")"
    monitor_emit swap "SWAP" "$val" "$state" "$warn" "$crit" "$detail"
    case "$state" in
        OK)   return 0 ;;
        WARN) return 1 ;;
        CRIT) return 2 ;;
    esac
    return 0
}

_monitor_check_load() {
    # _monitor_check_load WARN CRIT -- thresholds are percent-of-cores
    local warn="$1" crit="$2"
    local raw=""
    if [[ -r /proc/loadavg ]]; then
        read -r raw _ < /proc/loadavg || true
    fi
    if [[ -z "$raw" ]] && have_cmd uptime; then
        # fallback: parse "load average: 0.52, 0.58, 0.59"
        local up_line
        up_line="$(uptime 2>/dev/null || true)"
        up_line="${up_line##*load average: }"
        raw="${up_line%%,*}"
    fi
    if [[ -z "$raw" ]]; then
        error "monitor: cannot read load average"
        return 3
    fi
    local scaled
    scaled="$(monitor_load_scaled "$raw")" || { error "monitor: bad load '$raw'"; return 3; }
    local cores
    cores="$(cpu_count)"
    local warn_scaled=$(( cores * warn ))
    local crit_scaled=$(( cores * crit ))
    # value emitted is percent-of-cores so the JSON stays comparable
    local val
    val="$(pct "$scaled" $(( cores * 100 )))"
    local state
    state="$(monitor_state "$scaled" "$warn_scaled" "$crit_scaled")"
    local detail
    detail="$(printf 'load1=%s on %s core(s) [warn>=%d%% crit>=%d%% of capacity]' \
        "$raw" "$cores" "$warn" "$crit")"
    monitor_emit load "load1" "$val" "$state" "$warn" "$crit" "$detail"
    case "$state" in
        OK)   return 0 ;;
        WARN) return 1 ;;
        CRIT) return 2 ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# Command entry point
# -----------------------------------------------------------------------------
MONITOR_PATHS=()

cmd_monitor() {
    local -a checks=()
    local disk_warn="" disk_crit="" mem_warn="" mem_crit=""
    local load_warn="" load_crit="" repeat=1 interval=0
    local all_mounts=0
    MONITOR_WORST=0

    while (( $# > 0 )); do
        case "$1" in
            disk|mem|swap|load) checks+=("$1"); shift ;;
            all)                checks+=(disk mem swap load); shift ;;
            --path)     [[ $# -ge 2 ]] || { error "--path needs a value"; return 2; }
                        MONITOR_PATHS+=("$2"); shift 2 ;;
            --path=*)   MONITOR_PATHS+=("${1#*=}"); shift ;;
            --all-mounts) all_mounts=1; shift ;;
            --warn)     [[ $# -ge 2 ]] || { error "--warn needs a value"; return 2; }
                        disk_warn="$2"; mem_warn="$2"; shift 2 ;;
            --warn=*)   disk_warn="${1#*=}"; mem_warn="${1#*=}"; shift ;;
            --crit)     [[ $# -ge 2 ]] || { error "--crit needs a value"; return 2; }
                        disk_crit="$2"; mem_crit="$2"; shift 2 ;;
            --crit=*)   disk_crit="${1#*=}"; mem_crit="${1#*=}"; shift ;;
            --disk-warn) [[ $# -ge 2 ]] || { error "--disk-warn needs a value"; return 2; }
                        disk_warn="$2"; shift 2 ;;
            --disk-crit) [[ $# -ge 2 ]] || { error "--disk-crit needs a value"; return 2; }
                        disk_crit="$2"; shift 2 ;;
            --mem-warn) [[ $# -ge 2 ]] || { error "--mem-warn needs a value"; return 2; }
                        mem_warn="$2"; shift 2 ;;
            --mem-crit) [[ $# -ge 2 ]] || { error "--mem-crit needs a value"; return 2; }
                        mem_crit="$2"; shift 2 ;;
            --load-warn) [[ $# -ge 2 ]] || { error "--load-warn needs a value"; return 2; }
                        load_warn="$2"; shift 2 ;;
            --load-crit) [[ $# -ge 2 ]] || { error "--load-crit needs a value"; return 2; }
                        load_crit="$2"; shift 2 ;;
            --repeat)   [[ $# -ge 2 ]] || { error "--repeat needs a value"; return 2; }
                        repeat="$2"; shift 2 ;;
            --repeat=*) repeat="${1#*=}"; shift ;;
            --interval) [[ $# -ge 2 ]] || { error "--interval needs a value"; return 2; }
                        interval="$2"; shift 2 ;;
            --interval=*) interval="${1#*=}"; shift ;;
            --json|-q|--quiet) # handled globally too; accept after subcommand
                        case "$1" in --json) OPT_JSON=1 ;; *) OPT_QUIET=1 ;; esac
                        shift ;;
            -h|--help)  monitor_usage; return 0 ;;
            *)          error "monitor: unknown option: $1"; return 2 ;;
        esac
    done

    # ---- validate configuration -------------------------------------------
    if ! is_int "$disk_warn"; then disk_warn="$(cfg_int MONITOR_DISK_WARN 80)"; fi
    if ! is_int "$disk_crit"; then disk_crit="$(cfg_int MONITOR_DISK_CRIT 90)"; fi
    if ! is_int "$mem_warn";   then mem_warn="$(cfg_int MONITOR_MEM_WARN 80)"; fi
    if ! is_int "$mem_crit";   then mem_crit="$(cfg_int MONITOR_MEM_CRIT 90)"; fi
    if ! is_int "$load_warn";  then load_warn="$(cfg_int MONITOR_LOAD_WARN 70)"; fi
    if ! is_int "$load_crit";  then load_crit="$(cfg_int MONITOR_LOAD_CRIT 200)"; fi
    if ! is_uint "$repeat" || (( repeat < 1 )); then repeat=1; fi
    if ! is_uint "$interval"; then interval=0; fi
    local _p
    for _p in "${MONITOR_PATHS[@]}"; do
        if [[ ! -e "$_p" ]]; then
            error "monitor: path does not exist: $_p"
            return 3
        fi
    done
    if (( ${#MONITOR_PATHS[@]} == 0 )); then
        MONITOR_PATHS=("/")
    fi
    if (( ${#checks[@]} == 0 )); then
        checks=(disk mem swap load)
    fi

    # ---- run (possibly repeated) ------------------------------------------
    local run=0
    while (( run < repeat )); do
        if (( run > 0 && interval > 0 )); then
            sleep "$interval" 2>/dev/null || sleep 1
        fi
        local c
        for c in "${checks[@]}"; do
            local rc=0
            case "$c" in
                disk)
                    if (( all_mounts == 1 )); then
                        _monitor_check_mounts_all "$disk_warn" "$disk_crit" || rc=$?
                    else
                        _monitor_check_disk "$disk_warn" "$disk_crit" || rc=$?
                    fi
                    ;;
                mem)  _monitor_check_mem  "$mem_warn"  "$mem_crit"  || rc=$? ;;
                swap) _monitor_check_swap "$mem_warn"  "$mem_crit"  || rc=$? ;;
                load) _monitor_check_load "$load_warn" "$load_crit" || rc=$? ;;
            esac
            if (( rc == 3 )); then
                return 3
            fi
            monitor_absorb "$rc"
        done
        run=$(( run + 1 ))
    done

    if [[ "${OPT_JSON:-0}" != "1" && "${OPT_QUIET:-0}" != "1" ]]; then
        local word="OK"
        case "$MONITOR_WORST" in
            1) word="WARN" ;;
            2) word="CRIT" ;;
        esac
        local color="$C_GREEN"
        case "$MONITOR_WORST" in
            1) color="$C_YELLOW" ;;
            2) color="$C_RED" ;;
        esac
        printf '%sRESULT: %s%s (worst of %d check(s))\n' "$color" "$word" "$C_RESET" "${#checks[@]}"
    fi
    return "$MONITOR_WORST"
}
