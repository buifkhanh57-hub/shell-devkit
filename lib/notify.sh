#!/usr/bin/env bash
# =============================================================================
# notify.sh -- `sysops notify`: local alert log + optional webhook
#
# sysops always keeps a LOCAL alert log (one line per alert).  When a webhook
# URL is configured (config key NOTIFY_WEBHOOK_URL or --webhook) the same
# alert is optionally POSTed as JSON via curl -- curl is optional; a missing
# or failing webhook never loses the local alert.
#
# Log line format (TAB separated, machine parseable):
#   EPOCH  ISO-8601  LEVEL  HOST  MESSAGE
#
# Subcommands:
#   send MESSAGE [--level info|warn|crit] [--file LOG] [--webhook URL]
#                [--no-webhook] [--dry-run]
#   show [--tail N] [--level L] [--file LOG]
#   check [--stale-min N] [--file LOG]      exit code = worst recent level
#   clear [--file LOG]                      truncate the log (confirmed)
#
# Exit codes: send 0 ok / 1 webhook failed / 2 usage;
#             check 0 ok-worst-info / 1 warn / 2 crit / 3 unreadable log.
# =============================================================================
NOTIFY_WEBHOOK_DEFAULT_TIMEOUT=5
NOTIFY_DEFAULT_TAIL=20

notify_usage() {
    cat <<'EOF'
sysops notify -- local alert log with optional webhook delivery

USAGE
  sysops notify send MESSAGE... [OPTIONS]
  sysops notify show [OPTIONS]
  sysops notify check [OPTIONS]
  sysops notify clear [--file LOG]
  sysops notify help

SUBCOMMANDS
  send    Append an alert to the alert log (and POST it to the configured
          webhook, if any).  MESSAGE is one or more words; tabs and newlines
          are collapsed to spaces.
  show    Print recent alerts (default: last 20).
  check   Exit with the worst alert level found in the log:
          0 ok/info, 1 warn, 2 crit, 3 log exists but is unreadable.
          Designed for cron:  sysops notify check || logger -t sysops ...
  clear   Truncate the alert log (requires --yes or an interactive confirm).

OPTIONS
  --level L        send: alert level: info | warn | crit (default info)
  --file LOG       log path override (config: NOTIFY_LOG)
  --webhook URL    send: POST to this URL (config: NOTIFY_WEBHOOK_URL)
  --no-webhook     send: never POST, only write the local log
  --tail N         show: last N alerts (default 20)
  --stale-min N    check: ignore alerts older than N minutes
                   (default: 0 = consider all entries, config: NOTIFY_STALE_MIN)
  --dry-run        send: print what would happen, write/POST nothing
  -y, --yes        clear: skip the confirmation prompt
  --json           show/check: JSON output
  -h, --help       Show this help

EXAMPLES
  sysops notify send "disk / above 90%" --level crit
  sysops notify send "backup finished" --level info --no-webhook
  sysops notify show --tail 5
  sysops notify check; echo "worst level rc=$?"
EOF
}

# -----------------------------------------------------------------------------
# Level helpers
# -----------------------------------------------------------------------------
notify_validate_level() {
    case "${1:-}" in
        info|warn|crit) return 0 ;;
        *) return 1 ;;
    esac
}

notify_level_rank() {
    case "${1:-}" in
        crit) printf '2' ;;
        warn) printf '1' ;;
        info) printf '0' ;;
        *)    printf '0' ;;
    esac
    return 0
}

notify_level_color() {
    case "${1:-}" in
        crit) printf '%s' "$C_RED" ;;
        warn) printf '%s' "$C_YELLOW" ;;
        *)    printf '%s' "$C_GREEN" ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# Log path resolution
# -----------------------------------------------------------------------------
notify_default_log() {
    local configured
    configured="$(cfg NOTIFY_LOG "")"
    if [[ -n "$configured" ]]; then
        printf '%s' "$configured"
        return 0
    fi
    if [[ -d /var/log/sysops && -w /var/log/sysops ]]; then
        printf '%s' "/var/log/sysops/alerts.log"
        return 0
    fi
    local state_dir="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}"
    printf '%s' "$state_dir/sysops/alerts.log"
    return 0
}

# -----------------------------------------------------------------------------
# Pure parsing helpers (unit-testable)
# -----------------------------------------------------------------------------
# notify_clean_message TEXT -> single-line message (tabs/newlines -> spaces)
notify_clean_message() {
    local s="${1:-}"
    s="${s//$'\t'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\n'/ }"
    # collapse runs of spaces
    printf '%s' "$s" | tr -s ' '
    return 0
}

# notify_parse_line LINE -> prints "EPOCH LEVEL" (rc 1 when the line is
# malformed).  Full line layout: EPOCH ISO LEVEL HOST MESSAGE.
notify_parse_line() {
    local line="${1:-}"
    local epoch iso level rest
    epoch="${line%%$'\t'*}"
    is_uint "$epoch" || return 1
    rest="${line#*$'\t'}"
    iso="${rest%%$'\t'*}"
    [[ -n "$iso" ]] || return 1
    rest="${rest#*$'\t'}"
    level="${rest%%$'\t'*}"
    notify_validate_level "$level" || return 1
    printf '%s %s' "$epoch" "$level"
    return 0
}

# notify_worst FILE [CUTOFF_EPOCH] -> prints "none|info|warn|crit"
notify_worst() {
    local file="${1:-}" cutoff="${2:-0}"
    if [[ ! -r "$file" ]]; then
        printf '%s' "none"
        return 1
    fi
    if ! is_uint "$cutoff"; then
        cutoff=0
    fi
    local worst=-1 line parsed epoch level
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        if ! parsed="$(notify_parse_line "$line")"; then
            continue
        fi
        read -r epoch level <<< "$parsed"
        (( epoch >= cutoff )) || continue
        if (( $(notify_level_rank "$level") > worst )); then
            worst="$(notify_level_rank "$level")"
        fi
    done < "$file"
    case "$worst" in
        2) printf '%s' "crit" ;;
        1) printf '%s' "warn" ;;
        0) printf '%s' "info" ;;
        *) printf '%s' "none" ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# Webhook
# -----------------------------------------------------------------------------
notify_validate_webhook_url() {
    local url="${1:-}"
    [[ "$url" == http://* || "$url" == https://* ]] || return 1
    # no whitespace, no control characters
    [[ "$url" =~ ^[^[:space:][:cntrl:]]+$ ]] || return 1
    return 0
}

notify_webhook_post() {
    # notify_webhook_post URL LEVEL MESSAGE
    local url="$1" level="$2" msg="$3"
    local tmo
    tmo="$(cfg_int NOTIFY_WEBHOOK_TIMEOUT "$NOTIFY_WEBHOOK_DEFAULT_TIMEOUT")"
    if ! have_cmd curl; then
        warn "notify: webhook URL configured but curl is not installed (alert kept in local log)"
        return 1
    fi
    local payload
    payload="$(printf '{"level":"%s","host":"%s","message":"%s","source":"sysops"}' \
        "$(json_escape "$level")" "$(json_escape "$(hostname_of)")" \
        "$(json_escape "$msg")")"
    if ! curl -fsS -m "$tmo" -H 'Content-Type: application/json' \
            -X POST --data "$payload" -- "$url" >/dev/null 2>&1; then
        warn "notify: webhook delivery failed: $url (alert kept in local log)"
        return 1
    fi
    debug "notify: webhook delivered to $url"
    return 0
}

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------
cmd_notify_send() {
    local level="info" file="" webhook="" no_webhook=0
    local -a words=()
    while (( $# > 0 )); do
        case "$1" in
            --level)    [[ $# -ge 2 ]] || { error "notify send: --level needs a value"; return 2; }
                        level="$2"; shift 2 ;;
            --level=*)  level="${1#*=}"; shift ;;
            --file)     [[ $# -ge 2 ]] || { error "notify send: --file needs a value"; return 2; }
                        file="$2"; shift 2 ;;
            --file=*)   file="${1#*=}"; shift ;;
            --webhook)  [[ $# -ge 2 ]] || { error "notify send: --webhook needs a value"; return 2; }
                        webhook="$2"; shift 2 ;;
            --webhook=*) webhook="${1#*=}"; shift ;;
            --no-webhook) no_webhook=1; shift ;;
            --dry-run)  OPT_DRY_RUN=1; shift ;;
            -h|--help)  notify_usage; return 0 ;;
            -*)         error "notify send: unknown option: $1"; return 2 ;;
            *)          words+=("$1"); shift ;;
        esac
    done
    if (( ${#words[@]} == 0 )); then
        error "notify send: MESSAGE is required"
        return 2
    fi
    if ! notify_validate_level "$level"; then
        error "notify send: invalid level '$level' (info|warn|crit)"
        return 2
    fi
    if [[ -z "$file" ]]; then
        file="$(notify_default_log)"
    fi
    local msg
    msg="$(notify_clean_message "${words[*]}")"
    if [[ -z "$msg" ]]; then
        error "notify send: message is empty after normalisation"
        return 2
    fi

    # webhook target: explicit flag wins, then config
    if (( no_webhook != 1 )) && [[ -z "$webhook" ]]; then
        webhook="$(cfg NOTIFY_WEBHOOK_URL "")"
    fi
    if [[ -n "$webhook" ]] && ! notify_validate_webhook_url "$webhook"; then
        error "notify send: invalid webhook URL '$webhook' (must be http(s):// without whitespace)"
        return 2
    fi

    local epoch iso host
    epoch="$(date '+%s')"
    iso="$(now_iso)"
    host="$(hostname_of)"

    if [[ "${OPT_DRY_RUN:-0}" == "1" ]]; then
        say "dry-run: would append to $file:"
        say "  ${epoch}  ${iso}  ${level}  ${host}  ${msg}"
        if [[ -n "$webhook" ]]; then
            say "dry-run: would POST to webhook: $webhook"
        else
            say "dry-run: no webhook configured"
        fi
        return 0
    fi

    local log_dir
    log_dir="$(dirname -- "$file")"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p -- "$log_dir" 2>/dev/null || {
            error "notify: cannot create log directory: $log_dir"
            return 2;
        }
    fi
    if ! printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$iso" "$level" "$host" "$msg" \
            >> "$file" 2>/dev/null; then
        error "notify: cannot write alert log: $file"
        return 2
    fi
    info "notify: $level alert logged to $file"
    if [[ -n "$webhook" ]]; then
        if notify_webhook_post "$webhook" "$level" "$msg"; then
            return 0
        fi
        return 1
    fi
    return 0
}

cmd_notify_show() {
    local file="" tail_n="$NOTIFY_DEFAULT_TAIL" json=0 want_level=""
    while (( $# > 0 )); do
        case "$1" in
            --file)     [[ $# -ge 2 ]] || { error "notify show: --file needs a value"; return 2; }
                        file="$2"; shift 2 ;;
            --file=*)   file="${1#*=}"; shift ;;
            --tail)     [[ $# -ge 2 ]] || { error "notify show: --tail needs a value"; return 2; }
                        tail_n="$2"; shift 2 ;;
            --tail=*)   tail_n="${1#*=}"; shift ;;
            --level)    [[ $# -ge 2 ]] || { error "notify show: --level needs a value"; return 2; }
                        want_level="$2"; shift 2 ;;
            --level=*)  want_level="${1#*=}"; shift ;;
            --json)     json=1; shift ;;
            -h|--help)  notify_usage; return 0 ;;
            *)          error "notify show: unknown option: $1"; return 2 ;;
        esac
    done
    if ! notify_validate_level "$want_level" && [[ -n "$want_level" ]]; then
        error "notify show: invalid level '$want_level' (info|warn|crit)"
        return 2
    fi
    if ! is_uint "$tail_n"; then
        tail_n="$NOTIFY_DEFAULT_TAIL"
    fi
    if [[ -z "$file" ]]; then
        file="$(notify_default_log)"
    fi
    if [[ ! -r "$file" ]]; then
        if (( json == 1 )); then
            say '{"alerts": []}'
        else
            say "(no alert log at $file)"
        fi
        return 0
    fi
    # parse into "epoch<TAB>iso<TAB>level<TAB>host<TAB>msg" rows, filter, tail
    local -a rows=()
    mapfile -t rows < <(awk -F'\t' -v want="$want_level" '
        NF >= 5 && $1 ~ /^[0-9]+$/ {
            if (want != "" && $3 != want) next
            print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5
        }
    ' "$file" | tail -n "$tail_n" || true)

    if (( json == 1 )); then
        say "["
        local first=1 row epoch iso level host msg
        for row in "${rows[@]}"; do
            IFS=$'\t' read -r epoch iso level host msg <<< "$row"
            (( first )) || say ","
            first=0
            printf '  {"epoch": %s, "timestamp": "%s", "level": "%s", "host": "%s", "message": "%s"}\n' \
                "$epoch" "$(json_escape "$iso")" "$(json_escape "$level")" \
                "$(json_escape "$host")" "$(json_escape "$msg")"
        done
        say "]"
        return 0
    fi
    if (( ${#rows[@]} == 0 )); then
        say "(no alerts matching filter in $file)"
        return 0
    fi
    printf '  %-20s %-5s %-16s %s\n' "TIMESTAMP" "LEVEL" "HOST" "MESSAGE"
    local row epoch iso level host msg color
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r epoch iso level host msg <<< "$row"
        color="$(notify_level_color "$level")"
        printf '  %-20s %s%-5s%s %-16s %s\n' \
            "$(truncate_mid "$iso" 20)" "$color" "$level" "$C_RESET" \
            "$(truncate_mid "$host" 16)" "$(truncate_mid "$msg" 60)"
    done
    return 0
}

cmd_notify_check() {
    local file="" stale_min="" json=0
    while (( $# > 0 )); do
        case "$1" in
            --file)      [[ $# -ge 2 ]] || { error "notify check: --file needs a value"; return 2; }
                         file="$2"; shift 2 ;;
            --file=*)    file="${1#*=}"; shift ;;
            --stale-min) [[ $# -ge 2 ]] || { error "notify check: --stale-min needs a value"; return 2; }
                         stale_min="$2"; shift 2 ;;
            --stale-min=*) stale_min="${1#*=}"; shift ;;
            --json)      json=1; shift ;;
            -h|--help)   notify_usage; return 0 ;;
            *)           error "notify check: unknown option: $1"; return 2 ;;
        esac
    done
    if [[ -z "$file" ]]; then
        file="$(notify_default_log)"
    fi
    if ! is_uint "$stale_min"; then
        stale_min="$(cfg_int NOTIFY_STALE_MIN 0)"
    fi
    if [[ ! -e "$file" ]]; then
        if (( json == 1 )); then
            printf '{"worst": "none", "reason": "no alert log", "log": "%s"}\n' \
                "$(json_escape "$file")"
        else
            say "no alert log at $file -- nothing to report"
        fi
        return 0
    fi
    if [[ ! -r "$file" ]]; then
        error "notify check: alert log is not readable: $file"
        return 3
    fi
    local cutoff=0 now
    if (( stale_min > 0 )); then
        now="$(date '+%s')"
        cutoff=$(( now - stale_min * 60 ))
    fi
    local worst
    if ! worst="$(notify_worst "$file" "$cutoff")"; then
        error "notify check: cannot parse alert log: $file"
        return 3
    fi
    if (( json == 1 )); then
        printf '{"worst": "%s", "log": "%s"}\n' "$worst" "$(json_escape "$file")"
    else
        case "$worst" in
            crit) printf '%sWORST: crit%s (%s)\n' "$C_RED" "$C_RESET" "$file" ;;
            warn) printf '%sWORST: warn%s (%s)\n' "$C_YELLOW" "$C_RESET" "$file" ;;
            info) printf '%sWORST: info%s (%s)\n' "$C_GREEN" "$C_RESET" "$file" ;;
            *)    printf 'WORST: none (%s)\n' "$file" ;;
        esac
    fi
    case "$worst" in
        crit) return 2 ;;
        warn) return 1 ;;
        *)    return 0 ;;
    esac
}

cmd_notify_clear() {
    local file=""
    while (( $# > 0 )); do
        case "$1" in
            --file)     [[ $# -ge 2 ]] || { error "notify clear: --file needs a value"; return 2; }
                        file="$2"; shift 2 ;;
            --file=*)   file="${1#*=}"; shift ;;
            -y|--yes)   OPT_YES=1; shift ;;
            --dry-run)  OPT_DRY_RUN=1; shift ;;
            -h|--help)  notify_usage; return 0 ;;
            *)          error "notify clear: unknown option: $1"; return 2 ;;
        esac
    done
    if [[ -z "$file" ]]; then
        file="$(notify_default_log)"
    fi
    if [[ ! -e "$file" ]]; then
        say "no alert log at $file -- nothing to clear"
        return 0
    fi
    local n_lines
    n_lines="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
    if [[ "${OPT_DRY_RUN:-0}" == "1" ]]; then
        say "dry-run: would truncate $file ($n_lines alert(s))"
        return 0
    fi
    if ! confirm "Truncate alert log $file ($n_lines alert(s))?"; then
        warn "notify clear: aborted"
        return 0
    fi
    : > "$file" || { error "notify clear: cannot truncate $file"; return 2; }
    info "notify: cleared $file"
    return 0
}

cmd_notify() {
    local action="${1:-help}"
    if (( $# > 0 )); then
        shift
    fi
    case "$action" in
        send)  cmd_notify_send  "$@" ;;
        show)  cmd_notify_show  "$@" ;;
        check) cmd_notify_check "$@" ;;
        clear) cmd_notify_clear "$@" ;;
        help|-h|--help) notify_usage; return 0 ;;
        *)     error "notify: unknown action '$action' (see: sysops notify help)"
               return 2 ;;
    esac
}
