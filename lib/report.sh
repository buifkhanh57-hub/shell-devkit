#!/usr/bin/env bash
# =============================================================================
# report.sh -- `sysops report`: full system report
#
# Produces a sectioned, human-readable report of the machine state:
#   os | cpu | memory | disk | network | procs | logins | packages | sockets
#
# With --json the same data is emitted as a single JSON object (values are
# collected through report_kv() while the sections run, then serialised at
# the end -- no jq/awk-JSON magic, no dependencies).
#
# Everything here is read-only.  Missing data sources degrade gracefully:
# a section prints "(unavailable: reason)" instead of failing the command.
# =============================================================================

REPORT_ALL_SECTIONS="os cpu memory disk network procs logins packages sockets"
REPORT_DEFAULT_TOP=10

# JSON collector (see report_kv)
RK_SEC=()
RK_KEY=()
RK_VAL=()

report_reset_kv() {
    RK_SEC=()
    RK_KEY=()
    RK_VAL=()
}

report_kv() {
    # report_kv SECTION KEY VALUE -- record one key/value pair for --json
    RK_SEC+=("$1")
    RK_KEY+=("$2")
    RK_VAL+=("$3")
}

report_usage() {
    cat <<'EOF'
sysops report -- full system report (read-only)

USAGE
  sysops report [OPTIONS]

OPTIONS
  --section LIST    Comma-separated list of sections to include.
                    Sections: os, cpu, memory, disk, network, procs, logins,
                    packages, sockets
                    Default: all sections
  --top N           Number of processes / rows to show per section
                    (default: 10)
  --logins-lines N  Lines scanned for failed-login analysis (default: 5000)
  --json            Machine-readable output (single JSON object on stdout)
  -h, --help        Show this help

EXAMPLES
  sysops report                       # everything, human-readable
  sysops report --section os,memory   # only two sections
  sysops report --top 5 --json        # compact JSON for monitoring tools

EXIT CODES
  0  success
  2  usage error (unknown section or bad option)
EOF
}

_report_kv_line() {
    # human-mode key/value row: "  Key........: value"
    local key="$1" val="${2-}"
    printf '  %-16s %s\n' "${key}:" "$(truncate_mid "$val" 72)"
}

_report_unavailable() {
    # consistent "unavailable" note for a subsection
    local what="$1" reason="$2"
    printf '  %-16s (unavailable: %s)\n' "${what}:" "$reason"
}

# -----------------------------------------------------------------------------
# Section: os
# -----------------------------------------------------------------------------
_report_os() {
    local os_pretty="unknown" os_id="unknown" os_ver="unknown"
    local kernel="" arch="" host="" uptime_s="" load1="" load5="" load15=""

    if [[ -r /etc/os-release ]]; then
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                PRETTY_NAME=*)  os_pretty="${line#PRETTY_NAME=}";  os_pretty="${os_pretty%\"}"; os_pretty="${os_pretty#\"}" ;;
                ID=*)           os_id="${line#ID=}";               os_id="${os_id%\"}";        os_id="${os_id#\"}" ;;
                VERSION_ID=*)   os_ver="${line#VERSION_ID=}";      os_ver="${os_ver%\"}";      os_ver="${os_ver#\"}" ;;
            esac
        done < /etc/os-release
    fi
    kernel="$(uname -r 2>/dev/null || echo unknown)"
    arch="$(uname -m 2>/dev/null || echo unknown)"
    host="$(hostname_of)"

    if [[ -r /proc/uptime ]]; then
        read -r uptime_s _ < /proc/uptime || true
    fi
    local up_days=0 up_hours=0 up_mins=0 up_txt="unknown"
    if is_int "${uptime_s%%.*}" ; then
        local secs="${uptime_s%%.*}"
        up_days=$(( secs / 86400 ))
        up_hours=$(( (secs % 86400) / 3600 ))
        up_mins=$(( (secs % 3600) / 60 ))
        up_txt="${up_days}d ${up_hours}h ${up_mins}m"
    fi
    if [[ -r /proc/loadavg ]]; then
        read -r load1 load5 load15 _ < /proc/loadavg || true
    fi

    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        report_kv os hostname      "$host"
        report_kv os os            "$os_pretty"
        report_kv os os_id         "${os_id} ${os_ver}"
        report_kv os kernel        "$kernel"
        report_kv os arch          "$arch"
        report_kv os uptime        "$up_txt"
        report_kv os load_1m       "${load1:-unknown}"
        report_kv os load_5m       "${load5:-unknown}"
        report_kv os load_15m      "${load15:-unknown}"
        return 0
    fi

    section "Operating system"
    _report_kv_line "Host"        "$host"
    _report_kv_line "OS"          "$os_pretty"
    _report_kv_line "Release"     "${os_id} ${os_ver}"
    _report_kv_line "Kernel"      "$kernel"
    _report_kv_line "Arch"        "$arch"
    _report_kv_line "Uptime"      "$up_txt"
    _report_kv_line "Load"        "${load1:-?} ${load5:-?} ${load15:-?} (1/5/15 min)"
    return 0
}

# -----------------------------------------------------------------------------
# Section: cpu
# -----------------------------------------------------------------------------
_report_cpu() {
    local model="unknown" vendor="unknown" cores=0 mhz_min="" mhz_max=""
    cores="$(cpu_count)"
    if [[ -r /proc/cpuinfo ]]; then
        local line key val
        local -a mhz_all=()
        while IFS= read -r line || [[ -n "$line" ]]; do
            key="${line%%:*}"
            val="${line#*:}"
            key="$(trim "$key")"
            val="$(trim "$val")"
            case "$key" in
                "model name") [[ -n "$val" && "$model" == "unknown" ]] && model="$val" ;;
                "vendor_id")  [[ -n "$val" && "$vendor" == "unknown" ]] && vendor="$val" ;;
                "cpu MHz")    if is_uint "${val%%.*}"; then mhz_all+=("${val%%.*}"); fi ;;
            esac
        done < /proc/cpuinfo
        if (( ${#mhz_all[@]} > 0 )); then
            mhz_min="${mhz_all[0]}"
            mhz_max="${mhz_all[0]}"
            local m
            for m in "${mhz_all[@]}"; do
                if (( m < mhz_min )); then mhz_min="$m"; fi
                if (( m > mhz_max )); then mhz_max="$m"; fi
            done
        fi
    fi
    local per_core="n/a"
    if [[ -r /proc/loadavg ]]; then
        local load1
        read -r load1 _ < /proc/loadavg || true
        if is_int "${load1%%.*}"; then
            per_core="~${load1} per ${cores} core(s)"
        fi
    fi

    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        report_kv cpu model      "$model"
        report_kv cpu vendor     "$vendor"
        report_kv cpu cores      "$cores"
        if [[ -n "$mhz_min" ]]; then
            report_kv cpu mhz_range "${mhz_min}-${mhz_max}"
        fi
        report_kv cpu load_per_core "$per_core"
        return 0
    fi

    section "CPU"
    _report_kv_line "Model"     "$model"
    _report_kv_line "Vendor"    "$vendor"
    _report_kv_line "Cores"     "$cores"
    if [[ -n "$mhz_min" ]]; then
        _report_kv_line "Clock"   "${mhz_min}-${mhz_max} MHz"
    fi
    _report_kv_line "Load/core" "$per_core"
    return 0
}

# -----------------------------------------------------------------------------
# Section: memory
# -----------------------------------------------------------------------------
# Parses KEY: N kB lines from a meminfo-style file into MK_<key> variables.
_report_parse_meminfo() {
    # _report_parse_meminfo FILE -> sets MK_memtotal MK_memavailable MK_memfree
    #                                MK_buffers MK_cached MK_swaptotal MK_swapfree
    local file="$1"
    MK_memtotal=0; MK_memavailable=0; MK_memfree=0
    MK_buffers=0; MK_cached=0; MK_swaptotal=0; MK_swapfree=0
    [[ -r "$file" ]] || return 1
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%:*}"
        val="${line#*:}"
        key="$(trim "$key")"
        val="$(trim "$val")"
        val="${val%% *}"
        is_int "$val" || continue
        case "$key" in
            MemTotal)     MK_memtotal="$val" ;;
            MemAvailable) MK_memavailable="$val" ;;
            MemFree)      MK_memfree="$val" ;;
            Buffers)      MK_buffers="$val" ;;
            Cached)       MK_cached="$val" ;;
            SwapTotal)    MK_swaptotal="$val" ;;
            SwapFree)     MK_swapfree="$val" ;;
        esac
    done < "$file"
    return 0
}

_report_memory() {
    if ! _report_parse_meminfo /proc/meminfo; then
        if [[ "${OPT_JSON:-0}" == "1" ]]; then
            report_kv memory error "proc_meminfo_unavailable"
            return 0
        fi
        section "Memory"
        _report_unavailable "Memory" "/proc/meminfo not readable"
        return 0
    fi
    local used=$(( MK_memtotal - MK_memavailable ))
    if (( used < 0 )); then used=0; fi
    local used_pct
    used_pct="$(pct "$used" "$MK_memtotal")"
    local swap_used=$(( MK_swaptotal - MK_swapfree ))
    if (( swap_used < 0 )); then swap_used=0; fi
    local swap_pct
    swap_pct="$(pct "$swap_used" "$MK_swaptotal")"

    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        report_kv memory total_kib        "$MK_memtotal"
        report_kv memory available_kib    "$MK_memavailable"
        report_kv memory used_kib         "$used"
        report_kv memory used_pct         "$used_pct"
        report_kv memory buffers_kib      "$MK_buffers"
        report_kv memory cached_kib       "$MK_cached"
        report_kv memory swap_total_kib   "$MK_swaptotal"
        report_kv memory swap_used_kib    "$swap_used"
        report_kv memory swap_used_pct    "$swap_pct"
        return 0
    fi

    section "Memory"
    _report_kv_line "Total"     "$(human_size $(( MK_memtotal * 1024 )))"
    _report_kv_line "Used"      "$(human_size $(( used * 1024 ))) ($used_pct%)"
    _report_kv_line "Available" "$(human_size $(( MK_memavailable * 1024 )))"
    _report_kv_line "Buffers"   "$(human_size $(( MK_buffers * 1024 )))"
    _report_kv_line "Cached"    "$(human_size $(( MK_cached * 1024 )))"
    if (( MK_swaptotal > 0 )); then
        _report_kv_line "Swap"  "$(human_size $(( swap_used * 1024 ))) / $(human_size $(( MK_swaptotal * 1024 ))) ($swap_pct%)"
    else
        _report_kv_line "Swap"  "none configured"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Section: disk
# -----------------------------------------------------------------------------
_report_disk() {
    local -a lines=()
    # -x excludes need GNU df; fall back to a plain df -P listing
    mapfile -t lines < <(df -P -x tmpfs -x devtmpfs -x squashfs -x efivarfs -x overlay 2>/dev/null || true)
    if (( ${#lines[@]} <= 1 )); then
        mapfile -t lines < <(df -P 2>/dev/null || true)
    fi
    if (( ${#lines[@]} <= 1 )); then
        if [[ "${OPT_JSON:-0}" == "1" ]]; then
            report_kv disk error "df_unavailable"
            return 0
        fi
        section "Disk"
        _report_unavailable "Disk" "df produced no data"
        return 0
    fi
    local warn
    warn="$(cfg_int DISK_WARN 80)"

    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        local line fs total used avail mnt used_pct key
        local -a f
        for line in "${lines[@]:1}"; do
            read -r -a f <<< "$line"
            (( ${#f[@]} >= 6 )) || continue
            fs="${f[0]}"; total="${f[1]}"; used="${f[2]}"; avail="${f[3]}"
            mnt="${f[5]}"
            used_pct="$(pct "$used" $(( used + avail )))"
            key="$mnt"
            report_kv disk "${key}|filesystem"  "$fs"
            report_kv disk "${key}|total_kib"   "$total"
            report_kv disk "${key}|used_kib"    "$used"
            report_kv disk "${key}|avail_kib"   "$avail"
            report_kv disk "${key}|used_pct"    "$used_pct"
        done
        return 0
    fi

    section "Disk usage (warn>=${warn}%)"
    printf '  %-20s %10s %10s %10s %5s  %s\n' "MOUNT" "SIZE" "USED" "AVAIL" "USE%" "FILESYSTEM"
    local line fs total used avail cap mnt used_pct flag
    local -a f
    for line in "${lines[@]:1}"; do
        read -r -a f <<< "$line"
        (( ${#f[@]} >= 6 )) || continue
        fs="${f[0]}"; total="${f[1]}"; used="${f[2]}"; avail="${f[3]}"; mnt="${f[5]}"
        used_pct="$(pct "$used" $(( used + avail )))"
        flag=""
        if (( used_pct >= warn )); then
            flag="  ${C_RED}<< above warn threshold${C_RESET}"
        fi
        printf '  %-20s %10s %10s %10s %4s%%  %s%s\n' \
            "$(truncate_mid "$mnt" 20)" \
            "$(human_size $(( total * 1024 )))" \
            "$(human_size $(( used * 1024 )))" \
            "$(human_size $(( avail * 1024 )))" \
            "$used_pct" \
            "$(truncate_mid "$fs" 24)" \
            "$flag"
    done
    return 0
}

# -----------------------------------------------------------------------------
# Section: network
# -----------------------------------------------------------------------------
_hex_to_ip() {
    # _hex_to_ip C0A80001 -> 192.168.0.1 (input is little-endian hex from
    # /proc/net/route, e.g. gateway 0100A8C0 means 192.168.0.1)
    local hex="${1:-}"
    if [[ ! "$hex" =~ ^[0-9A-Fa-f]{1,8}$ ]]; then
        hex="00000000"
    fi
    local b1=$(( (16#${hex} & 0xFF000000) >> 24 ))
    local b2=$(( (16#${hex} & 0x00FF0000) >> 16 ))
    local b3=$(( (16#${hex} & 0x0000FF00) >> 8  ))
    local b4=$(( (16#${hex} & 0x000000FF)       ))
    printf '%d.%d.%d.%d' "$b1" "$b2" "$b3" "$b4"
}

_report_network() {
    local gateway="unknown"
    # preferred: ip route; fallback: /proc/net/route (little-endian hex)
    if have_cmd ip; then
        local gw_line=""
        gw_line="$(ip route show default 2>/dev/null | head -n 1 || true)"
        if [[ "$gw_line" == *via\ * ]]; then
            gateway="${gw_line#*via }"
            gateway="${gateway%% *}"
        fi
    elif [[ -r /proc/net/route ]]; then
        local line gw_hex="00000000"
        while IFS= read -r line; do
            read -r -a _rf <<< "$line"
            if [[ "${_rf[1]:-}" == "00000000" ]]; then
                gw_hex="${_rf[2]}"
                break
            fi
        done < /proc/net/route
        if [[ "$gw_hex" != "00000000" ]]; then
            gateway="$(_hex_to_ip "$gw_hex")"
        fi
    fi

    local -a ifaces=() rx=() tx=() addrs=()
    if [[ -r /proc/net/dev ]]; then
        local line name rest
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="$(trim "$line")"
            case "$line" in *":"*) : ;; *) continue ;; esac
            name="${line%%:*}"
            rest="${line#*:}"
            name="$(trim "$name")"
            read -r -a _nf <<< "$(trim "$rest")"
            ifaces+=("$name")
            rx+=("${_nf[0]:-0}")
            tx+=("${_nf[8]:-0}")
        done < <(tail -n +3 /proc/net/dev)
    fi
    # IPv4 addresses via ip(8) when available
    if have_cmd ip; then
        local ip_line ifn ipa
        while IFS= read -r ip_line; do
            [[ -z "$ip_line" ]] && continue
            read -r -a _pf <<< "$ip_line"
            ifn="${_pf[1]}"; ipa="${_pf[3]%%/*}"
            addrs+=("${ifn}=${ipa}")
        done < <(ip -o -4 addr show 2>/dev/null || true)
    fi

    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        report_kv network gateway "$gateway"
        local i
        for i in "${!ifaces[@]}"; do
            report_kv network "iface_${ifaces[$i]}_rx_bytes" "${rx[$i]}"
            report_kv network "iface_${ifaces[$i]}_tx_bytes" "${tx[$i]}"
        done
        local a
        for a in "${addrs[@]}"; do
            report_kv network "addr_${a%%=*}" "${a#*=}"
        done
        return 0
    fi

    section "Network"
    _report_kv_line "Gateway" "$gateway"
    if (( ${#ifaces[@]} == 0 )); then
        _report_unavailable "Interfaces" "/proc/net/dev not readable"
        return 0
    fi
    printf '  %-14s %14s %14s  %s\n' "IFACE" "RX" "TX" "IPv4"
    local i ip4="-"
    for i in "${!ifaces[@]}"; do
        ip4="-"
        local a
        for a in "${addrs[@]}"; do
            if [[ "${a%%=*}" == "${ifaces[$i]}" ]]; then
                ip4="${a#*=}"
                break
            fi
        done
        [[ "$ip4" == "-" && "${ifaces[$i]}" == "lo" ]] && ip4="127.0.0.1"
        printf '  %-14s %14s %14s  %s\n' \
            "${ifaces[$i]}" \
            "$(human_size ${rx[$i]})" \
            "$(human_size ${tx[$i]})" \
            "$ip4"
    done
    return 0
}

# -----------------------------------------------------------------------------
# Section: procs
# -----------------------------------------------------------------------------
_report_procs() {
    local top_n
    top_n="$(cfg_int REPORT_TOP_PROCS "${REPORT_DEFAULT_TOP}")"
    if [[ -n "${OPT_TOP_N:-}" ]]; then
        top_n="$OPT_TOP_N"
    fi
    local ps_ok=1
    local -a by_cpu=() by_mem=()
    if ! mapfile -t by_cpu < <(ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu --no-headers 2>/dev/null | head -n "$top_n"); then
        ps_ok=0
    fi
    if ! mapfile -t by_mem < <(ps -eo pid,user,pcpu,pmem,comm --sort=-pmem --no-headers 2>/dev/null | head -n "$top_n"); then
        ps_ok=0
    fi
    if (( ps_ok != 1 )) || (( ${#by_cpu[@]} == 0 )); then
        # fallback: POSIX ps aux + coreutils sort/head
        mapfile -t by_cpu < <(ps aux 2>/dev/null | tail -n +2 | sort -k3 -rn | head -n "$top_n" || true)
        mapfile -t by_mem < <(ps aux 2>/dev/null | tail -n +2 | sort -k4 -rn | head -n "$top_n" || true)
        # ps aux has 11 columns: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
        if [[ "${OPT_JSON:-0}" == "1" ]]; then
            local line
            local i=0
            for line in "${by_cpu[@]}"; do
                read -r -a f <<< "$line"
                (( ${#f[@]} >= 4 )) || continue
                report_kv procs "top_cpu_${i}" "pid=${f[1]} user=${f[0]} cpu=${f[2]} mem=${f[3]} cmd=${f[*]:10}"
                i=$(( i + 1 ))
            done
            i=0
            for line in "${by_mem[@]}"; do
                read -r -a f <<< "$line"
                (( ${#f[@]} >= 4 )) || continue
                report_kv procs "top_mem_${i}" "pid=${f[1]} user=${f[0]} cpu=${f[2]} mem=${f[3]} cmd=${f[*]:10}"
                i=$(( i + 1 ))
            done
            return 0
        fi
        section "Top processes (top $top_n)"
        if (( ${#by_cpu[@]} == 0 )); then
            _report_unavailable "Processes" "ps not usable"
            return 0
        fi
        printf '  %8s %-12s %6s %6s  %s\n' "PID" "USER" "%CPU" "%MEM" "COMMAND"
        local line f
        for line in "${by_cpu[@]}"; do
            read -r -a f <<< "$line"
            (( ${#f[@]} >= 11 )) || continue
            printf '  %8s %-12s %6s %6s  %s\n' "${f[1]}" "${f[0]}" "${f[2]}" "${f[3]}" "$(truncate_mid "${f[*]:10}" 40)"
        done
        return 0
    fi

    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        local line i=0
        for line in "${by_cpu[@]}"; do
            read -r -a f <<< "$line"
            (( ${#f[@]} >= 5 )) || continue
            report_kv procs "top_cpu_${i}" "pid=${f[0]} user=${f[1]} cpu=${f[2]} mem=${f[3]} cmd=${f[4]}"
            i=$(( i + 1 ))
        done
        i=0
        for line in "${by_mem[@]}"; do
            read -r -a f <<< "$line"
            (( ${#f[@]} >= 5 )) || continue
            report_kv procs "top_mem_${i}" "pid=${f[0]} user=${f[1]} cpu=${f[2]} mem=${f[3]} cmd=${f[4]}"
            i=$(( i + 1 ))
        done
        return 0
    fi

    section "Top processes (top $top_n)"
    printf '  %8s %-12s %6s %6s  %s\n' "PID" "USER" "%CPU" "%MEM" "COMMAND"
    local line
    for line in "${by_cpu[@]}"; do
        read -r -a f <<< "$line"
        (( ${#f[@]} >= 5 )) || continue
        printf '  %8s %-12s %6s %6s  %s\n' "${f[0]}" "${f[1]}" "${f[2]}" "${f[3]}" "$(truncate_mid "${f[4]}" 40)"
    done
    printf '\n  --- by resident memory ---\n'
    for line in "${by_mem[@]}"; do
        read -r -a f <<< "$line"
        (( ${#f[@]} >= 5 )) || continue
        printf '  %8s %-12s %6s %6s  %s\n' "${f[0]}" "${f[1]}" "${f[2]}" "${f[3]}" "$(truncate_mid "${f[4]}" 40)"
    done
    return 0
}

# -----------------------------------------------------------------------------
# Section: logins (failed login attempts)
# -----------------------------------------------------------------------------
_report_logins() {
    local lines_n="${OPT_LOGINS_LINES:-5000}"
    local src="none" detail=""
    local -a entries=()
    local total=0

    if have_cmd lastb && [[ -r /var/log/btmp || -e /var/log/btmp ]]; then
        src="lastb"
        mapfile -t entries < <(lastb -n "$lines_n" 2>/dev/null | grep -v '^$' | grep -v -e '^btmp begins' || true)
    elif [[ -r /var/log/auth.log ]]; then
        src="/var/log/auth.log"
        mapfile -t entries < <(grep -h 'Failed password' /var/log/auth.log 2>/dev/null | tail -n "$lines_n" || true)
    elif [[ -r /var/log/secure ]]; then
        src="/var/log/secure"
        mapfile -t entries < <(grep -h 'Failed password' /var/log/secure 2>/dev/null | tail -n "$lines_n" || true)
    elif have_cmd journalctl; then
        src="journalctl"
        mapfile -t entries < <(journalctl -q --no-pager -n "$lines_n" _COMM=sshd 2>/dev/null | grep 'Failed password' || true)
    fi
    total=${#entries[@]}

    # per-user failure counts: "Failed password for (invalid user )?NAME"
    local -a users=()
    local e user
    for e in "${entries[@]}"; do
        user=""
        if [[ "$e" == *" invalid user "* ]]; then
            user="${e#* invalid user }"
            user="${user%% *}"
        elif [[ "$e" == *"Failed password for "* ]]; then
            user="${e#*Failed password for }"
            user="${user%% *}"
        fi
        [[ -n "$user" ]] || continue
        users+=("$user")
    done
    local -a user_counts=()
    if (( ${#users[@]} > 0 )); then
        mapfile -t user_counts < <(printf '%s\n' "${users[@]}" | sort | uniq -c | sort -rn | head -n 5 || true)
    fi

    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        report_kv logins source "$src"
        report_kv logins failed_total "$total"
        local uc
        local i=0
        for uc in "${user_counts[@]}"; do
            local cnt="${uc%% *}"
            local uname="${uc#* }"
            report_kv logins "top_user_${i}" "${uname}:${cnt}"
            i=$(( i + 1 ))
        done
        return 0
    fi

    section "Failed logins"
    if [[ "$src" == "none" ]]; then
        _report_unavailable "Failed logins" "no lastb/auth.log/journalctl available"
        return 0
    fi
    _report_kv_line "Source"    "$src"
    _report_kv_line "Failures"  "$total"
    if (( ${#user_counts[@]} > 0 )); then
        printf '  %-22s %s\n' "USER" "FAILED"
        local uc
        for uc in "${user_counts[@]}"; do
            printf '  %-22s %s\n' "${uc#* }" "${uc%% *}"
        done
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Command entry point
# -----------------------------------------------------------------------------
cmd_report() {
    local -a wanted=()
    local want_str="$REPORT_ALL_SECTIONS"
    OPT_TOP_N=""
    OPT_LOGINS_LINES=""
    OPT_JSON_LOCAL="${OPT_JSON:-0}"

    while (( $# > 0 )); do
        case "$1" in
            --section)
                [[ $# -ge 2 ]] || { error "--section needs a value"; return 2; }
                want_str="$2"; shift 2 ;;
            --section=*) want_str="${1#*=}"; shift ;;
            --top)       [[ $# -ge 2 ]] || { error "--top needs a value"; return 2; }
                         OPT_TOP_N="$2"; shift 2 ;;
            --top=*)     OPT_TOP_N="${1#*=}"; shift ;;
            --logins-lines) [[ $# -ge 2 ]] || { error "--logins-lines needs a value"; return 2; }
                         OPT_LOGINS_LINES="$2"; shift 2 ;;
            --logins-lines=*) OPT_LOGINS_LINES="${1#*=}"; shift ;;
            --json)      OPT_JSON_LOCAL=1; OPT_JSON=1; shift ;;
            -h|--help)   report_usage; return 0 ;;
            *)           error "report: unknown option: $1"; return 2 ;;
        esac
    done

    # validate requested sections up-front
    local raw="" s
    IFS=',' read -r -a wanted <<< "$want_str" || true
    for s in "${wanted[@]}"; do
        s="$(trim "$s")"
        [[ -z "$s" ]] && continue
        case " $REPORT_ALL_SECTIONS " in
            *" $s "*) : ;;
            *) error "report: unknown section '$s' (valid: $REPORT_ALL_SECTIONS)"; return 2 ;;
        esac
    done

    report_reset_kv
    if [[ "$OPT_JSON_LOCAL" == "1" ]]; then
        say "{"
        say "  \"generated\": \"$(json_escape "$(now_iso)")\","
        say "  \"hostname\": \"$(json_escape "$(hostname_of)")\","
        say "  \"version\": \"$(json_escape "$SYOPS_VERSION")\","
        say '  "sections": {'
    else
        if [[ "${OPT_QUIET:-0}" != "1" ]]; then
            printf '%ssysops report v%s -- %s%s\n' "$C_BOLD" "$SYOPS_VERSION" "$(hostname_of)" "$C_RESET"
            printf '%s%s%s\n' "$C_DIM" "$(now_iso)" "$C_RESET"
        fi
    fi

    local first=1
    for s in "${wanted[@]}"; do
        s="$(trim "$s")"
        [[ -z "$s" ]] && continue
        if [[ "$OPT_JSON_LOCAL" == "1" ]]; then
            (( first )) || say ","
            first=0
            say "    \"$s\": {"
        fi
        case "$s" in
            os)       _report_os ;;
            cpu)      _report_cpu ;;
            memory)   _report_memory ;;
            disk)     _report_disk ;;
            network)  _report_network ;;
            procs)    _report_procs ;;
            logins)   _report_logins ;;
            packages) _report_packages ;;
            sockets)  _report_sockets ;;
        esac
        if [[ "$OPT_JSON_LOCAL" == "1" ]]; then
            # close this section object using the pairs recorded since the
            # section started
            local -a sec_keys=() sec_vals=()
            local i
            for i in "${!RK_SEC[@]}"; do
                if [[ "${RK_SEC[$i]}" == "$s" ]]; then
                    sec_keys+=("${RK_KEY[$i]}")
                    sec_vals+=("${RK_VAL[$i]}")
                fi
            done
            local j=0
            for i in "${!sec_keys[@]}"; do
                (( j )) && say ","
                j=1
                printf '      "%s": "%s"' \
                    "$(json_escape "${sec_keys[$i]}")" \
                    "$(json_escape "${sec_vals[$i]}")"
                printf '\n'
            done
            printf '    }'
        fi
        # drop this section's pairs so indices stay small
        local -a keep_sec=() keep_key=() keep_val=()
        local k
        for k in "${!RK_SEC[@]}"; do
            if [[ "${RK_SEC[$k]}" != "$s" ]]; then
                keep_sec+=("${RK_SEC[$k]}")
                keep_key+=("${RK_KEY[$k]}")
                keep_val+=("${RK_VAL[$k]}")
            fi
        done
        if (( ${#keep_sec[@]} > 0 )); then
            RK_SEC=("${keep_sec[@]}")
            RK_KEY=("${keep_key[@]}")
            RK_VAL=("${keep_val[@]}")
        else
            RK_SEC=()
            RK_KEY=()
            RK_VAL=()
        fi
    done

    if [[ "$OPT_JSON_LOCAL" == "1" ]]; then
        printf '\n'
        say "  }"
        say "}"
    fi
    return 0
}
