#!/usr/bin/env bash
# =============================================================================
# net.sh -- `sysops net`: listening sockets, connections, interfaces, TCP stats
#
# Subcommands:
#   listen [--port N] [--json]     listening TCP sockets (ss -> netstat -> /proc)
#   conns  [--top N] [--json]      established connections grouped by peer
#   ifaces [--json]                interface state from /sys/class/net
#   stats  [--json]                TCP counters from /proc/net/snmp + sockstat
#   ports  PORT...                 are these local ports listening? (0/1/2)
#
# Data sources, first available wins:
#   sockets : ss(8) -tlnpH, netstat(8) -tlnp, /proc/net/tcp + /proc/net/tcp6
#   conns   : ss(8) -tnH, netstat(8) -tnp, /proc/net/tcp
#   ifaces  : /sys/class/net (kernel sysfs, always present on Linux)
#   stats   : /proc/net/snmp and /proc/net/sockstat
#
# All parsers are pure functions (input string/file -> output string) so that
# tests/run_tests.sh can exercise them without a real socket table.
# Exit codes: 0 ok, 1 "not listening"/data difference, 2 usage, 3 no source.
# Everything here is read-only.
# =============================================================================

NET_MAX_ROWS_DEFAULT=100
NET_CONNS_TOP_DEFAULT=10

net_usage() {
    cat <<'EOF'
sysops net -- listening sockets, connections, interfaces, TCP statistics

USAGE
  sysops net listen [--port N] [--json]     # listening TCP sockets
  sysops net conns  [--top N] [--json]      # established peers (grouped)
  sysops net ifaces [--json]                # interfaces from /sys/class/net
  sysops net stats  [--json]                # TCP counters (/proc/net/snmp)
  sysops net ports PORT...                  # 0 all listening, 1 some missing
  sysops net help                           # this help

OPTIONS
  --port N        listen: only show entries for local port N (repeatable)
  --top N         conns: show N most frequent peers (default 10)
  --json          machine-readable output
  -h, --help      Show this help

EXIT CODES
  listen/conns/ifaces/stats:  0 ok   2 usage   3 no usable data source
  ports:                      0 all listening   1 at least one missing
                              2 usage error

EXAMPLES
  sysops net listen --port 22
  sysops net conns --top 5
  sysops net ports 22 80 443 && echo "web stack is listening"
  sysops net stats --json
EOF
}

# _net_valid_port PORT -> rc 0 when PORT is an integer in [1, 65535]
# (local copy so net.sh does not depend on service.sh being loaded first)
_net_valid_port() {
    is_uint "${1:-}" || return 1
    (( $1 >= 1 && $1 <= 65535 )) || return 1
    return 0
}

# -----------------------------------------------------------------------------
# Pure parsing helpers (unit-testable)
# -----------------------------------------------------------------------------
# net_extract_port "0.0.0.0:22" | "[::]:443" | "*:81" -> 22 | 443 | 81
net_extract_port() {
    local addr="${1:-}"
    [[ "$addr" == *:* ]] || return 1
    local port="${addr##*:}"
    is_uint "$port" || return 1
    printf '%s' "$port"
    return 0
}

# net_strip_port "0.0.0.0:22" -> "0.0.0.0"   (keeps [::] and * as-is)
net_strip_port() {
    local addr="${1:-}"
    [[ "$addr" == *:* ]] || { printf '%s' "$addr"; return 1; }
    printf '%s' "${addr%:*}"
    return 0
}

# net_parse_ss_process 'users:(("sshd",pid=812,fd=3))' -> "sshd"
net_parse_ss_process() {
    local s="${1:-}"
    if [[ "$s" =~ users:\(\(\"([A-Za-z0-9_.@/-]+)\" ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# net_parse_ss_line
#   input : one row of `ss -tlnpH [-p]`
#           "LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))"
#   output: "tcp LISTEN 0.0.0.0 22 sshd"   (process "-" when unknown)
net_parse_ss_line() {
    local line="${1:-}"
    local -a f=()
    read -r -a f <<< "$line" || return 1
    (( ${#f[@]} >= 5 )) || return 1
    local state="${f[0]}" local_addr="${f[3]}" proc="-"
    local port
    port="$(net_extract_port "$local_addr")" || return 1
    if (( ${#f[@]} >= 6 )); then
        local pname=""
        if pname="$(net_parse_ss_process "${f[*]:5}")"; then
            proc="$pname"
        fi
    fi
    printf 'tcp %s %s %s %s\n' "$state" "$(net_strip_port "$local_addr")" "$port" "$proc"
    return 0
}

# net_parse_netstat_line
#   input : one row of `netstat -tlnp`
#           "tcp  0  0 0.0.0.0:22  0.0.0.0:*  LISTEN  812/sshd"
#   output: "tcp LISTEN 0.0.0.0 22 sshd"
net_parse_netstat_line() {
    local line="${1:-}"
    local -a f=()
    read -r -a f <<< "$line" || return 1
    (( ${#f[@]} >= 6 )) || return 1
    local proto="${f[0]}"
    [[ "$proto" == tcp* ]] || return 1
    local local_addr="${f[3]}" state="${f[5]}" proc="-"
    if (( ${#f[@]} >= 7 )); then
        proc="${f[6]#*/}"
        [[ -n "$proc" ]] || proc="-"
    fi
    local port
    port="$(net_extract_port "$local_addr")" || return 1
    printf '%s %s %s %s %s\n' "$proto" "$state" "$(net_strip_port "$local_addr")" "$port" "$proc"
    return 0
}

# net_hex_ip_to_dotted "0100007F" (little-endian hex from /proc/net/tcp) -> "127.0.0.1"
net_hex_ip_to_dotted() {
    local hex="${1:-}"
    [[ "$hex" =~ ^[0-9A-Fa-f]{8}$ ]] || return 1
    local b1=$(( 16#${hex:6:2} ))
    local b2=$(( 16#${hex:4:2} ))
    local b3=$(( 16#${hex:2:2} ))
    local b4=$(( 16#${hex:0:2} ))
    printf '%d.%d.%d.%d' "$b1" "$b2" "$b3" "$b4"
    return 0
}

# net_hex_port_to_dec "1F90" -> "8080"
net_hex_port_to_dec() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    printf '%d' $(( 16#$p ))
    return 0
}

# net_parse_proc_line "0: 0100007F:1F90 00000000:0000 0A ..." (one data row of
# /proc/net/tcp) -> "127.0.0.1 8080 LISTEN"
# States: 01 ESTAB, 0A LISTEN, 06 TIME-WAIT, 08 CLOSE-WAIT (others -> raw hex)
net_parse_proc_line() {
    local line="${1:-}"
    local -a f=()
    read -r -a f <<< "$line" || return 1
    (( ${#f[@]} >= 4 )) || return 1
    local laddr="${f[1]}"
    [[ "$laddr" == *:* ]] || return 1
    local ip_hex="${laddr%%:*}" port_hex="${laddr##*:}" st="${f[3]}"
    local ip port state="?"
    ip="$(net_hex_ip_to_dotted "$ip_hex")" || return 1
    port="$(net_hex_port_to_dec "$port_hex")" || return 1
    case "$st" in
        01) state="ESTAB" ;;
        0A) state="LISTEN" ;;
        06) state="TIME-WAIT" ;;
        08) state="CLOSE-WAIT" ;;
        *)  state="$st" ;;
    esac
    printf '%s %s %s\n' "$ip" "$port" "$state"
    return 0
}

# net_parse_sockstat "TCP: inuse 41 orphan 0 tw 105 alloc 120 mem 4"
#   -> "inuse=41 orphan=0 tw=105 alloc=120 mem=4"
net_parse_sockstat() {
    local line="${1:-}"
    local -a f=()
    read -r -a f <<< "$line" || return 1
    (( ${#f[@]} >= 3 )) || return 1
    local proto="${f[0]%:}"
    [[ -n "$proto" ]] || return 1
    local out="" i=$(( 1 ))
    while (( i + 1 < ${#f[@]} )); do
        out+="${f[$i]}=${f[$(( i + 1 ))]} "
        i=$(( i + 2 ))
    done
    out="${out% }"
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
    return 0
}

# net_parse_snmp_tcp [FILE] -> "ActiveOpens=N PassiveOpens=N CurrEstab=N
# RetransSegs=N" from the two "Tcp:" rows of /proc/net/snmp.
net_parse_snmp_tcp() {
    local file="${1:-/proc/net/snmp}"
    [[ -r "$file" ]] || return 1
    local header="" values="" line
    while IFS= read -r line; do
        case "$line" in
            Tcp:*)
                if [[ -z "$header" ]]; then
                    header="$line"
                elif [[ -z "$values" ]]; then
                    values="$line"
                    break
                fi
                ;;
        esac
    done < "$file"
    [[ -n "$header" && -n "$values" ]] || return 1
    local -a h=() v=()
    read -r -a h <<< "$header" || return 1
    read -r -a v <<< "$values" || return 1
    (( ${#h[@]} == ${#v[@]} )) || return 1
    local i out=""
    for i in "${!h[@]}"; do
        case "${h[$i]}" in
            ActiveOpens|PassiveOpens|CurrEstab|RetransSegs)
                out+="${h[$i]}=${v[$i]} "
                ;;
        esac
    done
    out="${out% }"
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
    return 0
}

# -----------------------------------------------------------------------------
# Data collection
# -----------------------------------------------------------------------------
# net_collect_listen -> rows "PROTO STATE LOCAL_ADDR PORT PROCESS", one per
# listening TCP socket.  Source order: ss, netstat, /proc/net/tcp{,6}.
net_collect_listen() {
    local line
    if have_cmd ss; then
        local -a srows=()
        mapfile -t srows < <(ss -tlnpH 2>/dev/null || true)
        if (( ${#srows[@]} == 0 )); then
            mapfile -t srows < <(ss -tlnH 2>/dev/null || true)
        fi
        if (( ${#srows[@]} > 0 )); then
            for line in "${srows[@]}"; do
                net_parse_ss_line "$line" 2>/dev/null || true
            done
            return 0
        fi
    fi
    if have_cmd netstat; then
        local -a nrows=()
        mapfile -t nrows < <(netstat -tlnp 2>/dev/null | tail -n +3 || true)
        if (( ${#nrows[@]} > 0 )); then
            for line in "${nrows[@]}"; do
                net_parse_netstat_line "$line" 2>/dev/null || true
            done
            return 0
        fi
    fi
    # last resort: /proc/net/tcp (IPv4) and /proc/net/tcp6 (IPv6)
    local procfile proto
    for procfile in /proc/net/tcp /proc/net/tcp6; do
        [[ -r "$procfile" ]] || continue
        proto="tcp4"
        [[ "$procfile" == *tcp6 ]] && proto="tcp6"
        while IFS= read -r line; do
            case "$line" in *:*) : ;; *) continue ;; esac
            local parsed=""
            parsed="$(net_parse_proc_line "$line")" || continue
            local ip port state
            read -r ip port state <<< "$parsed"
            case "$state" in LISTEN) : ;; *) continue ;; esac
            printf '%s LISTEN %s %s -\n' "$proto" "$ip" "$port"
        done < "$procfile"
    done
    return 0
}

# net_collect_conns -> rows "PEER_IP PEER_PORT", one per established socket
net_collect_conns() {
    local line
    if have_cmd ss; then
        local -a srows=()
        mapfile -t srows < <(ss -tnH state established 2>/dev/null || true)
        if (( ${#srows[@]} > 0 )); then
            for line in "${srows[@]}"; do
                local -a f=()
                read -r -a f <<< "$line" || continue
                (( ${#f[@]} >= 5 )) || continue
                local peer="${f[4]}"
                [[ "$peer" == *:* ]] || continue
                printf '%s %s\n' "$(net_strip_port "$peer")" "$(net_extract_port "$peer")"
            done
            return 0
        fi
    fi
    if have_cmd netstat; then
        while IFS= read -r line; do
            local -a f=()
            read -r -a f <<< "$line" || continue
            (( ${#f[@]} >= 6 )) || continue
            [[ "${f[5]}" == "ESTABLISHED" ]] || continue
            local peer="${f[4]}"
            [[ "$peer" == *:* ]] || continue
            printf '%s %s\n' "$(net_strip_port "$peer")" "$(net_extract_port "$peer")"
        done < <(netstat -tnp 2>/dev/null | tail -n +3 || true)
        return 0
    fi
    if [[ -r /proc/net/tcp ]]; then
        while IFS= read -r line; do
            case "$line" in *:*) : ;; *) continue ;; esac
            local parsed=""
            parsed="$(net_parse_proc_line "$line")" || continue
            local lip lport state raddr
            read -r lip lport state <<< "$parsed"
            [[ "$state" == "ESTAB" ]] || continue
            read -r -a f <<< "$line"
            raddr="${f[2]}"
            [[ "$raddr" == *:* ]] || continue
            local rip rport
            rip="$(net_hex_ip_to_dotted "${raddr%%:*}")" || continue
            rport="$(net_hex_port_to_dec "${raddr##*:}")" || continue
            printf '%s %s\n' "$rip" "$rport"
        done < /proc/net/tcp
    fi
    return 0
}

# net_listening_ports -> prints the sorted, de-duplicated set of listening
# local port numbers (reads rows of net_collect_listen: "PROTO STATE ADDR PORT PROC")
net_listening_ports() {
    local row proto state addr port proc
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        read -r proto state addr port proc <<< "$row" || true
        [[ -n "$port" ]] || continue
        printf '%s\n' "$port"
    done < <(net_collect_listen) | sort -n -u
    return 0
}

# -----------------------------------------------------------------------------
# Report integration: called by `sysops report --section sockets`
# -----------------------------------------------------------------------------
_report_sockets() {
    local -a rows=() crows=()
    mapfile -t rows < <(net_collect_listen 2>/dev/null || true)
    mapfile -t crows < <(net_collect_conns 2>/dev/null || true)
    local n_listen=${#rows[@]} n_estab=${#crows[@]}

    # count listeners per local port
    declare -A port_count=()
    local row port
    for row in "${rows[@]}"; do
        port="$(printf '%s' "$row" | awk '{print $4}')"
        [[ -n "$port" ]] || continue
        port_count["$port"]=$(( ${port_count["$port"]:-0} + 1 ))
    done
    local -a ports_sorted=()
    local _p
    mapfile -t ports_sorted < <(for _p in "${!port_count[@]}"; do
            printf '%s\n' "$_p"
        done | sort -n || true
    )

    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        report_kv sockets listening_count "$n_listen"
        report_kv sockets established_count "$n_estab"
        for port in "${ports_sorted[@]}"; do
            report_kv sockets "listen_port_${port}" "${port_count[$port]}"
        done
        return 0
    fi

    section "Sockets"
    _report_kv_line "Listening"    "$n_listen socket(s)"
    _report_kv_line "Established"  "$n_estab connection(s)"
    if (( ${#ports_sorted[@]} == 0 )); then
        _report_unavailable "Ports" "no listening sockets detected"
        return 0
    fi
    printf '  %-8s %s\n' "PORT" "SOCKETS"
    local shown=0
    for port in "${ports_sorted[@]}"; do
        if (( shown >= 15 )); then
            printf '  %-8s %s\n' "..." "(+$(( ${#ports_sorted[@]} - shown )) more ports)"
            break
        fi
        printf '  %-8s %s\n' "$port" "${port_count[$port]}"
        shown=$(( shown + 1 ))
    done
    return 0
}

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------
cmd_net_listen() {
    local json="${OPT_JSON:-0}"
    local max_rows
    max_rows="$(cfg_int NET_MAX_ROWS "$NET_MAX_ROWS_DEFAULT")"
    local -a want_ports=()
    while (( $# > 0 )); do
        case "$1" in
            --port)  [[ $# -ge 2 ]] || { error "net listen: --port needs a value"; return 2; }
                     want_ports+=("$2"); shift 2 ;;
            --port=*) want_ports+=("${1#*=}"); shift ;;
            --json)  json=1; shift ;;
            -h|--help) net_usage; return 0 ;;
            *)       error "net listen: unknown option: $1"; return 2 ;;
        esac
    done
    local p
    for p in "${want_ports[@]}"; do
        if ! _net_valid_port "$p"; then
            error "net listen: invalid port '$p'"
            return 2
        fi
    done

    local -a rows=()
    mapfile -t rows < <(net_collect_listen 2>/dev/null || true)
    local shown=0
    if (( json == 1 )); then
        say "["
        local first=1 row proto state addr port proc keep
        for row in "${rows[@]}"; do
            read -r proto state addr port proc <<< "$row"
            if (( ${#want_ports[@]} > 0 )); then
                keep=0
                for p in "${want_ports[@]}"; do
                    [[ "$p" == "$port" ]] && keep=1
                done
                (( keep == 1 )) || continue
            fi
            (( first )) || say ","
            first=0
            printf '  {"proto": "%s", "state": "%s", "local": "%s", "port": %s, "process": "%s"}\n' \
                "$(json_escape "$proto")" "$(json_escape "$state")" \
                "$(json_escape "$addr")" "$port" "$(json_escape "$proc")"
            shown=$(( shown + 1 ))
        done
        say "]"
        return 0
    fi
    printf '  %-6s %-12s %-20s %6s  %s\n' "PROTO" "STATE" "LOCAL" "PORT" "PROCESS"
    for row in "${rows[@]}"; do
        read -r proto state addr port proc <<< "$row"
        if (( ${#want_ports[@]} > 0 )); then
            keep=0
            for p in "${want_ports[@]}"; do
                [[ "$p" == "$port" ]] && keep=1
            done
            (( keep == 1 )) || continue
        fi
        (( shown < max_rows )) || continue
        printf '  %-6s %-12s %-20s %6s  %s\n' \
            "$proto" "$state" "$(truncate_mid "$addr" 20)" "$port" "$(truncate_mid "$proc" 24)"
        shown=$(( shown + 1 ))
    done
    if (( shown < ${#rows[@]} )); then
        say "  ($(( ${#rows[@]} - shown )) row(s) not shown)"
    fi
    say "  total: $shown listening socket(s) shown of ${#rows[@]}"
    return 0
}

cmd_net_conns() {
    local json="${OPT_JSON:-0}" top_n="$NET_CONNS_TOP_DEFAULT"
    while (( $# > 0 )); do
        case "$1" in
            --top)   [[ $# -ge 2 ]] || { error "net conns: --top needs a value"; return 2; }
                     top_n="$2"; shift 2 ;;
            --top=*) top_n="${1#*=}"; shift ;;
            --json)  json=1; shift ;;
            -h|--help) net_usage; return 0 ;;
            *)       error "net conns: unknown option: $1"; return 2 ;;
        esac
    done
    if ! is_uint "$top_n" || (( top_n < 1 )); then
        top_n="$NET_CONNS_TOP_DEFAULT"
    fi

    local -a rows=()
    mapfile -t rows < <(net_collect_conns 2>/dev/null || true)
    local total=${#rows[@]}

    # group by peer address
    declare -A by_peer=()
    local row peer
    for row in "${rows[@]}"; do
        read -r peer _ <<< "$row"
        by_peer["$peer"]=$(( ${by_peer["$peer"]:-0} + 1 ))
    done
    local -a peers_sorted=()
    mapfile -t peers_sorted < <(for peer in "${!by_peer[@]}"; do
        printf '%6d %s\n' "${by_peer[$peer]}" "$peer"
    done | sort -rn | awk '{print $2}' || true)

    if (( json == 1 )); then
        say "{"
        say "  \"total\": $total,"
        say "  \"peers\": ["
        local first=1 i=0
        for peer in "${peers_sorted[@]}"; do
            (( i >= top_n )) && break
            (( first )) || say ","
            first=0
            printf '    {"peer": "%s", "connections": %s}' \
                "$(json_escape "$peer")" "${by_peer[$peer]}"
            i=$(( i + 1 ))
        done
        say ""
        say "  ]"
        say "}"
        return 0
    fi

    section "Established connections"
    _report_kv_line "Total" "$total"
    if (( total == 0 )); then
        say "  (no established connections)"
        return 0
    fi
    printf '  %-32s %s\n' "PEER" "CONNS"
    local i=0
    for peer in "${peers_sorted[@]}"; do
        (( i >= top_n )) && break
        printf '  %-32s %s\n' "$(truncate_mid "$peer" 32)" "${by_peer[$peer]}"
        i=$(( i + 1 ))
    done
    return 0
}

cmd_net_ifaces() {
    local json="${OPT_JSON:-0}"
    while (( $# > 0 )); do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) net_usage; return 0 ;;
            *)      error "net ifaces: unknown option: $1"; return 2 ;;
        esac
    done
    if [[ ! -d /sys/class/net ]]; then
        error "net ifaces: /sys/class/net is not available (non-Linux system?)"
        return 3
    fi
    local -a names=()
    mapfile -t names < <(ls /sys/class/net 2>/dev/null || true)
    if (( json == 1 )); then
        say "["
        local first=1 n name state mtu mac rx tx
        for name in "${names[@]}"; do
            state="unknown" mtu="-" mac="-" rx="0" tx="0"
            [[ -r "/sys/class/net/$name/operstate" ]] && state="$(< "/sys/class/net/$name/operstate")"
            [[ -r "/sys/class/net/$name/mtu" ]]      && mtu="$(< "/sys/class/net/$name/mtu")"
            [[ -r "/sys/class/net/$name/address" ]]  && mac="$(< "/sys/class/net/$name/address")"
            [[ -r "/sys/class/net/$name/statistics/rx_bytes" ]] && rx="$(< "/sys/class/net/$name/statistics/rx_bytes")"
            [[ -r "/sys/class/net/$name/statistics/tx_bytes" ]] && tx="$(< "/sys/class/net/$name/statistics/tx_bytes")"
            is_uint "$rx" || rx=0
            is_uint "$tx" || tx=0
            (( first )) || say ","
            first=0
            printf '  {"name": "%s", "state": "%s", "mtu": "%s", "mac": "%s", "rx_bytes": %s, "tx_bytes": %s}\n' \
                "$(json_escape "$name")" "$(json_escape "$state")" \
                "$(json_escape "$mtu")" "$(json_escape "$mac")" "$rx" "$tx"
        done
        say "]"
        return 0
    fi
    printf '  %-16s %-10s %-6s %-20s %12s %12s\n' "IFACE" "STATE" "MTU" "MAC" "RX" "TX"
    local name state mtu mac rx tx
    for name in "${names[@]}"; do
        state="unknown" mtu="-" mac="-" rx="0" tx="0"
        [[ -r "/sys/class/net/$name/operstate" ]] && state="$(< "/sys/class/net/$name/operstate")"
        [[ -r "/sys/class/net/$name/mtu" ]]      && mtu="$(< "/sys/class/net/$name/mtu")"
        [[ -r "/sys/class/net/$name/address" ]]  && mac="$(< "/sys/class/net/$name/address")"
        [[ -r "/sys/class/net/$name/statistics/rx_bytes" ]] && rx="$(< "/sys/class/net/$name/statistics/rx_bytes")"
        [[ -r "/sys/class/net/$name/statistics/tx_bytes" ]] && tx="$(< "/sys/class/net/$name/statistics/tx_bytes")"
        is_uint "$rx" || rx=0
        is_uint "$tx" || tx=0
        printf '  %-16s %-10s %-6s %-20s %12s %12s\n' \
            "$name" "$state" "$mtu" "$mac" \
            "$(human_size "$rx")" "$(human_size "$tx")"
    done
    return 0
}

cmd_net_stats() {
    local json="${OPT_JSON:-0}"
    while (( $# > 0 )); do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) net_usage; return 0 ;;
            *)      error "net stats: unknown option: $1"; return 2 ;;
        esac
    done
    if [[ ! -r /proc/net/snmp ]]; then
        error "net stats: /proc/net/snmp is not readable"
        return 3
    fi
    local tcp_stats=""
    if ! tcp_stats="$(net_parse_snmp_tcp /proc/net/snmp)"; then
        error "net stats: cannot parse /proc/net/snmp Tcp rows"
        return 3
    fi
    local -a pairs=()
    read -r -a pairs <<< "$tcp_stats" || true
    local -a sockstat_rows=()
    if [[ -r /proc/net/sockstat ]]; then
        mapfile -t sockstat_rows < <(grep -E '^(TCP|UDP|TCP6|Sockets):' /proc/net/sockstat 2>/dev/null || true)
    fi
    if (( json == 1 )); then
        say "{"
        say "  \"tcp\": {"
        local first=1 kv k v
        for kv in "${pairs[@]}"; do
            k="${kv%%=*}"; v="${kv#*=}"
            (( first )) || say ","
            first=0
            printf '    "%s": %s' "$(json_escape "$k")" "$v"
        done
        say ""
        say "  },"
        say "  \"sockstat\": ["
        first=1
        local line proto rest
        for line in "${sockstat_rows[@]}"; do
            proto="${line%%:*}"
            rest="$(net_parse_sockstat "$line" 2>/dev/null || true)"
            (( first )) || say ","
            first=0
            printf '    {"proto": "%s", "values": "%s"}' \
                "$(json_escape "$proto")" "$(json_escape "$rest")"
        done
        say ""
        say "  ]"
        say "}"
        return 0
    fi
    section "TCP statistics"
    local kv k v
    for kv in "${pairs[@]}"; do
        k="${kv%%=*}"; v="${kv#*=}"
        _report_kv_line "$k" "$v"
    done
    if (( ${#sockstat_rows[@]} > 0 )); then
        local line proto rest
        printf '\n  %-10s %s\n' "PROTO" "COUNTERS"
        for line in "${sockstat_rows[@]}"; do
            proto="${line%%:*}"
            rest="$(net_parse_sockstat "$line" 2>/dev/null || true)"
            printf '  %-10s %s\n' "$proto" "$rest"
        done
    fi
    return 0
}

cmd_net_ports() {
    local -a want=()
    while (( $# > 0 )); do
        case "$1" in
            -h|--help) net_usage; return 0 ;;
            -*)        error "net ports: unknown option: $1"; return 2 ;;
            *)         want+=("$1"); shift ;;
        esac
    done
    if (( ${#want[@]} == 0 )); then
        error "net ports: provide at least one port number"
        return 2
    fi
    local p
    for p in "${want[@]}"; do
        if ! _net_valid_port "$p"; then
            error "net ports: invalid port '$p' (1-65535)"
            return 2
        fi
    done

    # set of currently listening ports
    declare -A listening=()
    local row port
    while IFS= read -r port; do
        [[ -n "$port" ]] || continue
        listening["$port"]=1
    done < <(net_listening_ports)

    local rc_all=0 found
    for p in "${want[@]}"; do
        if [[ -n "${listening[$p]:-}" ]]; then
            printf '%sOPEN%s   %s (listening)\n' "$C_GREEN" "$C_RESET" "$p"
            found=1
        else
            printf '%sCLOSED%s %s (not listening)\n' "$C_RED" "$C_RESET" "$p"
            found=0
        fi
        if (( found == 0 )); then
            rc_all=1
        fi
    done
    return "$rc_all"
}

cmd_net() {
    local action="${1:-help}"
    if (( $# > 0 )); then
        shift
    fi
    case "$action" in
        listen)  cmd_net_listen  "$@" ;;
        conns)   cmd_net_conns   "$@" ;;
        ifaces)  cmd_net_ifaces  "$@" ;;
        stats)   cmd_net_stats   "$@" ;;
        ports)   cmd_net_ports   "$@" ;;
        help|-h|--help) net_usage; return 0 ;;
        *)       error "net: unknown action '$action' (see: sysops net help)"
                 return 2 ;;
    esac
}
