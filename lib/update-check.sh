#!/usr/bin/env bash
# =============================================================================
# update-check.sh -- `sysops updates`: offline pending-update + reboot state
#
# Answers three cron-friendly questions WITHOUT touching the network:
#   1. how many package updates are pending?      (cached package indexes)
#   2. which packages would be upgraded?          (names, best effort)
#   3. is a reboot required (kernel drift marker)?
#
# Backends (whichever is installed), all forced to CACHED metadata:
#   apt/dpkg : apt-get -s dist-upgrade       (simulate; never downloads)
#   dnf/yum  : dnf --cacheonly check-update  (rc 100 == updates available)
#   pacman   : checkupdates(1) or pacman -Qu (reads the local sync db)
#   apk      : apk version -l '<'            (compares against cached index)
#
# Reboot detection:
#   * /var/run/reboot-required marker (Debian/Ubuntu update-notifier-common)
#   * kernel drift: running `uname -r` vs the newest /boot/vmlinuz-*
#
# Exit codes: 0 ok/clean, 1 updates pending, 2 reboot required,
#             3 internal error, 2 usage errors share code 2.
# Parsers are pure functions (FILE/stdin based) so tests can feed samples.
# =============================================================================

UPDATES_MAX_LIST_DEFAULT=25

updates_usage() {
    cat <<'EOF'
sysops updates -- offline pending-update and reboot state (read-only)

USAGE
  sysops updates check [--json]        # pending counts per manager
  sysops updates list [--limit N]      # pending package names (best effort)
  sysops updates reboot [--json]       # reboot required / kernel drift
  sysops updates summary               # check + reboot, exit 0/1/2
  sysops updates help

OPTIONS
  --limit N     list: maximum package names to print (default 25,
                config: UPDATES_MAX_LIST)
  --json        machine-readable output
  -h, --help    Show this help

OFFLINE GUARANTEE
  All backends read CACHED package indexes only (apt simulate mode,
  dnf --cacheonly, pacman local db, apk local index).  No downloads,
  no installs, no metadata refresh -- safe to run every minute.

EXIT CODES (summary/reboot)
  0 clean   1 updates pending   2 reboot required   3 internal error

EXAMPLES
  sysops updates check
  sysops updates list --limit 10
  sysops updates reboot
  */30 * * * * sysops updates summary -q || logger -t sysops "updates rc=$?"
EOF
}

# -----------------------------------------------------------------------------
# Pure parsing helpers (unit-testable)
# -----------------------------------------------------------------------------
# updates_parse_apt_sim [--names] [FILE]
#   counts "Inst pkg ..." rows of `apt-get -s dist-upgrade` output, or prints
#   the package names (one per line) with --names.
updates_parse_apt_sim() {
    local mode="count" file=""
    while (( $# > 0 )); do
        case "$1" in
            --names) mode="names"; shift ;;
            -h|--help) updates_usage; return 0 ;;
            *)       file="$1"; shift ;;
        esac
    done
    if [[ -n "$file" && "$file" != "-" ]]; then
        [[ -r "$file" ]] || return 1
        awk -v mode="$mode" '
            /^Inst [^[:space:]]+/ {
                if (mode == "names") print $2
                n++
            }
            END { if (mode == "count") print n + 0 }
        ' "$file"
        return 0
    fi
    awk -v mode="$mode" '
        /^Inst [^[:space:]]+/ {
            if (mode == "names") print $2
            n++
        }
        END { if (mode == "count") print n + 0 }
    '
    return 0
}

# updates_parse_dnf_output [--names] [FILE]
#   counts package rows of `dnf --cacheonly check-update`, skipping headers
#   ("Obsoleting Packages", metadata notices).  Package rows look like:
#     kernel-core-5.10.134-013.15.al8.x86_64    baseos  1.2 M
#   --names prints a BEST-EFFORT package name (arch + version suffix stripped).
updates_parse_dnf_output() {
    local mode="count" file=""
    while (( $# > 0 )); do
        case "$1" in
            --names) mode="names"; shift ;;
            -h|--help) updates_usage; return 0 ;;
            *)       file="$1"; shift ;;
        esac
    done
    local -a cmd=(awk -v mode="$mode" '
        /^[A-Za-z0-9._+%-]+-[A-Za-z0-9._%+-]+[.][A-Za-z0-9_]+[[:space:]]/ {
            if (mode == "names") {
                name = $1
                sub(/[.][A-Za-z0-9_]+$/, "", name)   # strip .arch
                sub(/-[0-9].*$/, "", name)            # strip -version...
                print name
            }
            n++
        }
        END { if (mode == "count") print n + 0 }
    ')
    if [[ -n "$file" && "$file" != "-" ]]; then
        [[ -r "$file" ]] || return 1
        "${cmd[@]}" "$file"
        return 0
    fi
    "${cmd[@]}"
    return 0
}

# updates_parse_pacman_output [--names] [FILE]
#   counts rows of `checkupdates` / `pacman -Qu`: "pkg 1.0-1 -> 1.1-1"
updates_parse_pacman_output() {
    local mode="count" file=""
    while (( $# > 0 )); do
        case "$1" in
            --names) mode="names"; shift ;;
            -h|--help) updates_usage; return 0 ;;
            *)       file="$1"; shift ;;
        esac
    done
    local -a cmd=(awk -v mode="$mode" '
        /^[^[:space:]]+[[:space:]]+[^[:space:]]+( -> | [^[:space:]]+$)/ {
            if (mode == "names") print $1
            n++
        }
        END { if (mode == "count") print n + 0 }
    ')
    if [[ -n "$file" && "$file" != "-" ]]; then
        [[ -r "$file" ]] || return 1
        "${cmd[@]}" "$file"
        return 0
    fi
    "${cmd[@]}"
    return 0
}

# updates_parse_apk_output [--names] [FILE]
#   counts rows of `apk version -l '<'`: "< pkg-1.2 < 1.3 x86_64 @repo"
#   --names prints a BEST-EFFORT package name (revision + version stripped).
updates_parse_apk_output() {
    local mode="count" file=""
    while (( $# > 0 )); do
        case "$1" in
            --names) mode="names"; shift ;;
            -h|--help) updates_usage; return 0 ;;
            *)       file="$1"; shift ;;
        esac
    done
    local -a cmd=(awk -v mode="$mode" '
        $1 == "<" {
            if (mode == "names") {
                name = $2
                sub(/-r[0-9]+$/, "", name)   # strip apk revision
                sub(/-[0-9].*$/, "", name)    # strip version
                print name
            }
            n++
        }
        END { if (mode == "count") print n + 0 }
    ')
    if [[ -n "$file" && "$file" != "-" ]]; then
        [[ -r "$file" ]] || return 1
        "${cmd[@]}" "$file"
        return 0
    fi
    "${cmd[@]}"
    return 0
}

# updates_newest_kernel [BOOTDIR] -> newest "vmlinuz-*" version, or "none"
updates_newest_kernel() {
    local bootdir="${1:-/boot}"
    [[ -d "$bootdir" ]] || { printf '%s' "none"; return 0; }
    local newest=""
    newest="$(find "$bootdir" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null \
        | sed 's/^vmlinuz-//' | sort -V | tail -n 1 || true)"
    [[ -n "$newest" ]] || newest="none"
    printf '%s' "$newest"
    return 0
}

# updates_kernel_state RUNNING NEWEST -> same | drift | unknown | none
updates_kernel_state() {
    local running="${1:-}" newest="${2:-}"
    if [[ -z "$running" ]]; then
        printf '%s' "unknown"
        return 0
    fi
    if [[ -z "$newest" || "$newest" == "none" ]]; then
        printf '%s' "none"
        return 0
    fi
    if [[ "$running" == "$newest" ]]; then
        printf '%s' "same"
    else
        printf '%s' "drift"
    fi
    return 0
}

# updates_reboot_required [MARKER_FILE] -> required | no
updates_reboot_required() {
    local marker="${1:-/var/run/reboot-required}"
    if [[ -e "$marker" ]]; then
        printf '%s' "required"
    else
        printf '%s' "no"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Backend wrappers (each prints COUNT and rc 1 when its backend is unusable)
# -----------------------------------------------------------------------------
updates_tmp_file() {
    # shared temp capture file for the current command invocation
    if [[ -z "${UPDATES_TMP:-}" ]]; then
        mktemp_sysops UPDATES_TMP "sysops-updates.XXXXXX" || return 1
    fi
    printf '%s' "$UPDATES_TMP"
    return 0
}

updates_count_apt() {
    have_cmd apt-get || return 1
    local tmpf
    tmpf="$(updates_tmp_file)" || return 1
    if ! LC_ALL=C apt-get -s dist-upgrade > "$tmpf" 2>/dev/null; then
        # rc 100 == broken/unreadable lists; without a usable simulate output
        # we must not invent a number
        return 1
    fi
    updates_parse_apt_sim < "$tmpf"
    return 0
}

updates_count_dnf() {
    local runner=""
    if have_cmd dnf; then runner="dnf"
    elif have_cmd yum; then runner="yum"
    else return 1
    fi
    local tmpf
    tmpf="$(updates_tmp_file)" || return 1
    # rc 100 means "updates available" -- not an error
    LC_ALL=C "$runner" -q --cacheonly check-update > "$tmpf" 2>/dev/null
    local rc=$?
    case "$rc" in
        0)   printf '%s' "0"; return 0 ;;
        100) updates_parse_dnf_output < "$tmpf"; return 0 ;;
        *)   return 1 ;;
    esac
}

updates_count_pacman() {
    local tmpf
    tmpf="$(updates_tmp_file)" || return 1
    if have_cmd checkupdates; then
        LC_ALL=C checkupdates > "$tmpf" 2>/dev/null || true
        updates_parse_pacman_output < "$tmpf"
        return 0
    fi
    have_cmd pacman || return 1
    LC_ALL=C pacman -Qu > "$tmpf" 2>/dev/null || true
    updates_parse_pacman_output < "$tmpf"
    return 0
}

updates_count_apk() {
    have_cmd apk || return 1
    local tmpf
    tmpf="$(updates_tmp_file)" || return 1
    LC_ALL=C apk version -l '<' > "$tmpf" 2>/dev/null || true
    updates_parse_apk_output < "$tmpf"
    return 0
}

updates_count_for() {
    case "$1" in
        apt)    updates_count_apt ;;
        dnf)    updates_count_dnf ;;
        pacman) updates_count_pacman ;;
        apk)    updates_count_apk ;;
        *)      return 1 ;;
    esac
}

# updates_count_offline -> TOTAL pending updates across all backends
# (used by pkg.sh `_report_packages` and by `updates summary`)
updates_count_offline() {
    local m total=0 c
    for m in apt dnf pacman apk; do
        if c="$(updates_count_for "$m")" && is_uint "$c"; then
            total=$(( total + c ))
        fi
    done
    printf '%d' "$total"
    return 0
}

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------
UPDATES_TMP=""

cmd_updates_check() {
    local json="${OPT_JSON:-0}"
    while (( $# > 0 )); do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) updates_usage; return 0 ;;
            *)      error "updates check: unknown option: $1"; return 2 ;;
        esac
    done
    UPDATES_TMP=""
    local -a avail=()
    local m
    for m in apt dnf pacman apk; do
        case "$m" in
            apt)    have_cmd apt-get && avail+=("$m") || true ;;
            dnf)    have_cmd dnf && avail+=("$m") || true
                    have_cmd yum && avail+=("$m") || true ;;
            pacman) have_cmd pacman && avail+=("$m") || true ;;
            apk)    have_cmd apk && avail+=("$m") || true ;;
        esac
    done
    if (( ${#avail[@]} == 0 )); then
        error "updates: no supported package manager found (apt/dnf/yum/pacman/apk)"
        return 3
    fi

    local -a names=() counts=()
    local total=0 c
    for m in "${avail[@]}"; do
        c=""
        if c="$(updates_count_for "$m")" && is_uint "$c"; then
            :
        else
            c="?"
        fi
        names+=("$m")
        counts+=("$c")
        is_uint "$c" && total=$(( total + c )) || true
    done
    local reboot_state kernel_state
    reboot_state="$(updates_reboot_required)"
    kernel_state="$(updates_kernel_state "$(uname -r 2>/dev/null || true)" "$(updates_newest_kernel)")"

    if (( json == 1 )); then
        say "{"
        say "  \"managers\": {"
        local i val
        for i in "${!names[@]}"; do
            (( i > 0 )) && say ","
            if [[ "${counts[$i]}" == "?" ]]; then
                val="null"
            else
                val="${counts[$i]}"
            fi
            printf '    "%s": %s' "$(json_escape "${names[$i]}")" "$val"
        done
        say ""
        say "  },"
        say "  \"total\": $total,"
        say "  \"reboot_required\": \"$(json_escape "$reboot_state")\","
        say "  \"kernel_state\": \"$(json_escape "$kernel_state")\""
        say "}"
        return 0
    fi
    section "Pending updates (offline scan)"
    printf '  %-10s %10s\n' "MANAGER" "PENDING"
    local i
    for i in "${!names[@]}"; do
        printf '  %-10s %10s\n' "${names[$i]}" "${counts[$i]}"
    done
    say "  total pending: $total"
    _report_kv_line "Reboot" "$reboot_state"
    _report_kv_line "Kernel" "$(uname -r 2>/dev/null || echo '?') ($kernel_state vs /boot)"
    return 0
}

cmd_updates_list() {
    local limit="" json=0
    while (( $# > 0 )); do
        case "$1" in
            --limit)  [[ $# -ge 2 ]] || { error "updates list: --limit needs a value"; return 2; }
                      limit="$2"; shift 2 ;;
            --limit=*) limit="${1#*=}"; shift ;;
            --json)   json=1; shift ;;
            -h|--help) updates_usage; return 0 ;;
            *)        error "updates list: unknown option: $1"; return 2 ;;
        esac
    done
    if ! is_uint "$limit" || (( limit < 1 )); then
        limit="$(cfg_int UPDATES_MAX_LIST "$UPDATES_MAX_LIST_DEFAULT")"
    fi
    UPDATES_TMP=""
    # find the first backend that yields a usable count
    local chosen="" names_file="" m c
    mktemp_sysops names_file "sysops-updlist.XXXXXX" || return 3
    for m in apt dnf pacman apk; do
        c="$(updates_count_for "$m" 2>/dev/null || true)"
        if is_uint "$c" && (( c > 0 )); then
            chosen="$m"
            break
        elif is_uint "$c" && [[ -z "$chosen" ]]; then
            chosen="$m"   # remember the first usable (possibly empty) backend
        fi
    done
    if [[ -z "$chosen" ]]; then
        error "updates list: no package manager available to list updates"
        return 3
    fi
    # re-run the chosen backend to capture names into names_file
    case "$chosen" in
        apt)    have_cmd apt-get && \
                { LC_ALL=C apt-get -s dist-upgrade 2>/dev/null | updates_parse_apt_sim --names > "$names_file" || true; } ;;
        dnf)    if have_cmd dnf; then
                    LC_ALL=C dnf -q --cacheonly check-update 2>/dev/null | updates_parse_dnf_output --names > "$names_file" || true
                elif have_cmd yum; then
                    LC_ALL=C yum -q --cacheonly check-update 2>/dev/null | updates_parse_dnf_output --names > "$names_file" || true
                fi ;;
        pacman) if have_cmd checkupdates; then
                    LC_ALL=C checkupdates 2>/dev/null | updates_parse_pacman_output --names > "$names_file" || true
                elif have_cmd pacman; then
                    LC_ALL=C pacman -Qu 2>/dev/null | updates_parse_pacman_output --names > "$names_file" || true
                fi ;;
        apk)    have_cmd apk && \
                { LC_ALL=C apk version -l '<' 2>/dev/null | updates_parse_apk_output --names > "$names_file" || true; } ;;
    esac
    local n
    n="$(pkg_count_rpm_query < "$names_file")"
    if (( json == 1 )); then
        say "{"
        say "  \"manager\": \"$(json_escape "$chosen")\","
        say "  \"total\": $n,"
        say "  \"packages\": ["
        local first=1 name i=0
        while IFS= read -r name; do
            (( i >= limit )) && break
            (( first )) || say ","
            first=0
            printf '    "%s"' "$(json_escape "$name")"
            i=$(( i + 1 ))
        done < "$names_file"
        say ""
        say "  ]"
        say "}"
        return 0
    fi
    if (( n == 0 )); then
        say "(no pending updates detected via $chosen)"
        return 0
    fi
    section "Pending updates ($chosen, showing ${limit} of $n)"
    local name i=0
    while IFS= read -r name; do
        (( i >= limit )) && break
        printf '  %s\n' "$name"
        i=$(( i + 1 ))
    done < "$names_file"
    return 0
}

cmd_updates_reboot() {
    local json="${OPT_JSON:-0}"
    while (( $# > 0 )); do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) updates_usage; return 0 ;;
            *)      error "updates reboot: unknown option: $1"; return 2 ;;
        esac
    done
    local marker="/var/run/reboot-required"
    local state running newest kstate boot_since=""
    state="$(updates_reboot_required "$marker")"
    running="$(uname -r 2>/dev/null || true)"
    newest="$(updates_newest_kernel /boot)"
    kstate="$(updates_kernel_state "$running" "$newest")"
    if have_cmd uptime; then
        boot_since="$(uptime -s 2>/dev/null || true)"
    fi
    if (( json == 1 )); then
        say "{"
        say "  \"reboot_required\": \"$(json_escape "$state")\","
        say "  \"marker\": \"$(json_escape "$marker")\","
        say "  \"running_kernel\": \"$(json_escape "$running")\","
        say "  \"newest_kernel\": \"$(json_escape "$newest")\","
        say "  \"kernel_state\": \"$(json_escape "$kstate")\","
        say "  \"booted_since\": \"$(json_escape "$boot_since")\""
        say "}"
    else
        section "Reboot state"
        _report_kv_line "Reboot required" "$state"
        _report_kv_line "Running kernel" "$running"
        _report_kv_line "Newest /boot" "$newest"
        _report_kv_line "Kernel state" "$kstate"
        [[ -n "$boot_since" ]] && _report_kv_line "Booted since" "$boot_since"
        if [[ -r "$marker" ]]; then
            say ""
            say "  marker contents:"
            sed 's/^/    /' "$marker" 2>/dev/null || true
        fi
    fi
    case "$state" in
        required) return 2 ;;
        *)        return 0 ;;
    esac
}

cmd_updates_summary() {
    local json="${OPT_JSON:-0}"
    while (( $# > 0 )); do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) updates_usage; return 0 ;;
            *)      error "updates summary: unknown option: $1"; return 2 ;;
        esac
    done
    UPDATES_TMP=""
    local total
    total="$(updates_count_offline)" || total=0
    local reboot_state kstate
    reboot_state="$(updates_reboot_required)"
    kstate="$(updates_kernel_state "$(uname -r 2>/dev/null || true)" "$(updates_newest_kernel)")"
    if (( json == 1 )); then
        printf '{"updates_pending": %s, "reboot_required": "%s", "kernel_state": "%s"}\n' \
            "$total" "$(json_escape "$reboot_state")" "$(json_escape "$kstate")"
    else
        section "Update summary"
        _report_kv_line "Updates pending" "$total"
        _report_kv_line "Reboot required" "$reboot_state"
        _report_kv_line "Kernel state" "$kstate"
        if [[ "$reboot_state" == "required" ]]; then
            printf '%sACTION: reboot required%s\n' "$C_RED" "$C_RESET"
        elif (( total > 0 )); then
            printf '%sNOTICE: %s update(s) pending%s\n' "$C_YELLOW" "$total" "$C_RESET"
        else
            printf '%sSystem up to date%s\n' "$C_GREEN" "$C_RESET"
        fi
    fi
    if [[ "$reboot_state" == "required" ]]; then
        return 2
    fi
    if (( total > 0 )); then
        return 1
    fi
    return 0
}

cmd_updates() {
    local action="${1:-help}"
    if (( $# > 0 )); then
        shift
    fi
    case "$action" in
        check)   cmd_updates_check   "$@" ;;
        list)    cmd_updates_list    "$@" ;;
        reboot)  cmd_updates_reboot  "$@" ;;
        summary) cmd_updates_summary "$@" ;;
        help|-h|--help) updates_usage; return 0 ;;
        *)       error "updates: unknown action '$action' (see: sysops updates help)"
                 return 2 ;;
    esac
}
