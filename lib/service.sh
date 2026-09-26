#!/usr/bin/env bash
# =============================================================================
# service.sh -- `sysops service`: service / TCP helpers
#
# Subcommands:
#   status NAME...            Is a service running?  systemctl when present,
#                             pgrep fallback otherwise.
#   list                      List running services (systemctl) or init.d
#                             scripts with a best-effort state.
#   port HOST PORT [TMO]      TCP connect test via bash /dev/tcp
#   wait-port HOST PORT [TMO] Poll a TCP port until it opens or TMO expires
#   exists NAME               Does a unit/init-script with this name exist?
#
# Exit codes: 0 success/running/open, 1 stopped/closed, 2 usage error,
#             3 timeout or unknown service.
# The TCP probe never interprets HOST/PORT as code: they are validated
# against strict patterns and passed as an argument to a child bash, so no
# command injection is possible.
# =============================================================================

SERVICE_TCP_DEFAULT_TIMEOUT=3

service_usage() {
    cat <<'EOF'
sysops service -- service status and TCP port checks

USAGE
  sysops service status NAME...        # running? (systemctl or pgrep)
  sysops service list                  # running services
  sysops service port HOST PORT [TMO]  # TCP connect test (default TMO 3s)
  sysops service wait-port HOST PORT [TMO]   # poll until open (default 30s)
  sysops service exists NAME           # unit or init script present?
  sysops service help                  # this help

EXIT CODES
  status/port:      0 running/open   1 stopped/closed   3 timeout/unknown
  any subcommand:   2 usage error
  status with several services: 0 all running, 1 any stopped,
                                3 none resolvable

EXAMPLES
  sysops service status nginx sshd
  sysops service port db.internal 5432 2
  sysops service wait-port 127.0.0.1 8080 15 && echo "app is up"
EOF
}

_service_validate_host() {
    # strict hostname / IPv4 pattern; blocks everything that could be
    # interpreted by a shell or is not a resolvable name
    [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,251}[A-Za-z0-9])?$ ]]
}

_service_validate_port() {
    is_uint "${1:-}" || return 1
    (( ${1} >= 1 && ${1} <= 65535 )) || return 1
    return 0
}

# _service_tcp_once HOST PORT TIMEOUT -> rc 0 open, 1 refused/closed,
# 3 timed out.  Uses `timeout` around a child bash whose /dev/tcp builtin
# does the connect; HOST/PORT were validated before we get here.
_service_tcp_once() {
    local host="$1" port="$2" tmo="$3"
    local probe="/dev/tcp/${host}/${port}"
    if have_cmd timeout; then
        local rc=0
        timeout "$tmo" bash -c 'exec 3<>"$1" 2>/dev/null' _ "$probe" 2>/dev/null || rc=$?
        case "$rc" in
            0)   return 0 ;;
            124) return 3 ;;
            *)   return 1 ;;
        esac
    fi
    # no timeout(1): fall back to a plain connect attempt
    if bash -c 'exec 3<>"$1" 2>/dev/null' _ "$probe" 2>/dev/null; then
        return 0
    fi
    return 1
}

# _service_systemctl_state NAME -> prints "ACTIVE_STATE ENABLED_STATE"
# with values like active/inactive/failed and enabled/disabled/static.
_service_systemctl_state() {
    local name="$1"
    local active="unknown" enabled="unknown"
    local out=""
    out="$(systemctl is-active "$name" 2>/dev/null || true)"
    case "$out" in
        active|activating|inactive|failed|unknown) active="$out" ;;
    esac
    out="$(systemctl is-enabled "$name" 2>/dev/null || true)"
    case "$out" in
        enabled|disabled|static|masked|indirect) enabled="$out" ;;
    esac
    printf '%s %s' "$active" "$enabled"
    return 0
}

# _service_pgrep_state NAME -> prints "RUNNING <n>" or "STOPPED 0"
_service_pgrep_state() {
    local name="$1"
    local pids=""
    pids="$(pgrep -x "$name" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
        printf 'RUNNING %s' "$(printf '%s\n' "$pids" | wc -l | tr -d ' ')"
    else
        printf 'STOPPED 0'
    fi
    return 0
}

_service_status_one() {
    # prints a status line; returns 0 running, 1 stopped, 3 unknown
    local name="$1"
    local state="UNKNOWN" detail="" rc=3
    if have_cmd systemctl; then
        local st en
        read -r st en <<< "$(_service_systemctl_state "$name")"
        state="$st"
        detail="enabled=$en"
        case "$st" in
            active)             rc=0 ;;
            activating)         rc=0 ;;
            inactive|failed)    rc=1 ;;
            *)                  rc=3 ;;
        esac
    elif have_cmd pgrep; then
        read -r state detail <<< "$(_service_pgrep_state "$name")"
        if [[ "$state" == "RUNNING" ]]; then
            detail="pids=$detail"
            rc=0
        else
            detail=""
            rc=1
        fi
    else
        detail="no systemctl and no pgrep available"
        rc=3
    fi
    local color="$C_YELLOW"
    case "$rc" in
        0) color="$C_GREEN" ;;
        1) color="$C_RED" ;;
    esac
    printf '%s%-8s%s %-24s %s\n' "$color" "$state" "$C_RESET" "$name" "$detail"
    return "$rc"
}

cmd_service_status() {
    if (( $# == 0 )); then
        error "service status: provide at least one service name"
        return 2
    fi
    local worst=0 name rc
    local any_resolvable=0
    for name in "$@"; do
        if [[ ! "$name" =~ ^[A-Za-z0-9@._-]+$ ]]; then
            error "service status: invalid service name: $name"
            return 2
        fi
        rc=0
        _service_status_one "$name" || rc=$?
        if (( rc != 3 )); then
            any_resolvable=1
        fi
        if (( rc > worst )); then
            worst="$rc"
        fi
    done
    # worst is the MAXIMUM rc over resolvable services: 0 only when every
    # requested service is running, 1 when any is stopped.  When nothing was
    # resolvable at all the answer is "unknown" (3).
    if (( any_resolvable != 1 )); then
        return 3
    fi
    return "$worst"
}

cmd_service_list() {
    if have_cmd systemctl; then
        local -a rows=()
        mapfile -t rows < <(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null || true)
        if (( ${#rows[@]} == 0 )); then
            say "(no running units reported by systemctl)"
            return 0
        fi
        printf '%-34s %-10s %s\n' "UNIT" "STATE" "DESCRIPTION"
        local row unit desc
        for row in "${rows[@]}"; do
            unit="$(printf '%s' "$row" | awk '{print $1}')"
            desc="$(printf '%s' "$row" | cut -d' ' -f5-)"
            printf '%-34s %-10s %s\n' "$unit" "running" "$desc"
        done
        return 0
    fi
    # fallback: init.d scripts + pgrep guess
    if [[ ! -d /etc/init.d ]]; then
        say "(no systemctl and no /etc/init.d -- cannot list services)"
        return 3
    fi
    printf '%-24s %s\n' "SCRIPT" "GUESS"
    local script name
    for script in /etc/init.d/*; do
        [[ -x "$script" ]] || continue
        name="$(basename -- "$script")"
        case "$name" in
            README|rc*|skeleton) continue ;;
        esac
        if have_cmd pgrep && pgrep -x "$name" >/dev/null 2>&1; then
            printf '%-24s %s\n' "$name" "process running"
        else
            printf '%-24s %s\n' "$name" "unknown (no systemctl)"
        fi
    done
    return 0
}

cmd_service_port() {
    local host="" port="" tmo="$SERVICE_TCP_DEFAULT_TIMEOUT"
    if (( $# >= 1 )); then host="$1"; shift; fi
    if (( $# >= 1 )); then port="$1"; shift; fi
    if (( $# >= 1 )); then tmo="$1"; shift; fi
    if (( $# > 0 )); then
        error "service port: too many arguments"
        return 2
    fi
    if ! _service_validate_host "$host"; then
        error "service port: invalid host '$host'"
        return 2
    fi
    if ! _service_validate_port "$port"; then
        error "service port: invalid port '$port' (1-65535)"
        return 2
    fi
    if ! is_uint "$tmo" || (( tmo < 1 )); then
        error "service port: invalid timeout '$tmo'"
        return 2
    fi
    local rc=0
    _service_tcp_once "$host" "$port" "$tmo" || rc=$?
    case "$rc" in
        0) printf '%sOPEN%s   %s:%s (tcp)\n' "$C_GREEN" "$C_RESET" "$host" "$port"; return 0 ;;
        1) printf '%sCLOSED%s %s:%s (tcp)\n' "$C_RED" "$C_RESET" "$host" "$port"; return 1 ;;
        3) printf '%sTIMEOUT%s %s:%s after %ss\n' "$C_YELLOW" "$C_RESET" "$host" "$port" "$tmo"; return 3 ;;
    esac
    return "$rc"
}

cmd_service_wait_port() {
    local host="" port="" tmo=30
    if (( $# >= 1 )); then host="$1"; shift; fi
    if (( $# >= 1 )); then port="$1"; shift; fi
    if (( $# >= 1 )); then tmo="$1"; shift; fi
    if (( $# > 0 )); then
        error "service wait-port: too many arguments"
        return 2
    fi
    if ! _service_validate_host "$host"; then
        error "service wait-port: invalid host '$host'"
        return 2
    fi
    if ! _service_validate_port "$port"; then
        error "service wait-port: invalid port '$port'"
        return 2
    fi
    if ! is_uint "$tmo" || (( tmo < 1 )); then
        error "service wait-port: invalid timeout '$tmo'"
        return 2
    fi
    local waited=0 attempt_rc=0
    while (( waited < tmo )); do
        attempt_rc=0
        _service_tcp_once "$host" "$port" 2 || attempt_rc=$?
        if (( attempt_rc == 0 )); then
            printf '%sOPEN%s   %s:%s (after %ss)\n' "$C_GREEN" "$C_RESET" "$host" "$port" "$waited"
            return 0
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    printf '%sTIMEOUT%s %s:%s not open within %ss\n' "$C_YELLOW" "$C_RESET" "$host" "$port" "$tmo"
    return 3
}

cmd_service_exists() {
    if (( $# != 1 )); then
        error "service exists: exactly one service name required"
        return 2
    fi
    local name="$1"
    if [[ ! "$name" =~ ^[A-Za-z0-9@._-]+$ ]]; then
        error "service exists: invalid service name: $name"
        return 2
    fi
    if have_cmd systemctl; then
        if systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q "^${name}\\.service"; then
            say "yes: ${name}.service exists"
            return 0
        fi
        say "no: ${name}.service not found"
        return 1
    fi
    if [[ -x "/etc/init.d/${name}" ]]; then
        say "yes: /etc/init.d/${name} exists"
        return 0
    fi
    say "no: ${name} not found in /etc/init.d"
    return 1
}

cmd_service() {
    local action="${1:-help}"
    if (( $# > 0 )); then
        shift
    fi
    case "$action" in
        status)    cmd_service_status "$@" ;;
        list)      cmd_service_list "$@" ;;
        port)      cmd_service_port "$@" ;;
        wait-port) cmd_service_wait_port "$@" ;;
        exists)    cmd_service_exists "$@" ;;
        help|-h|--help) service_usage; return 0 ;;
        *)         error "service: unknown action '$action' (see: sysops service help)"
                   return 2 ;;
    esac
}
