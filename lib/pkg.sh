#!/usr/bin/env bash
# =============================================================================
# pkg.sh -- `sysops pkg`: installed-package inventory across package managers
#
# Subcommands:
#   count [--json]      installed package count per detected manager
#   owner FILE          which manager/package owns FILE (dpkg -S / rpm -qf /
#                       pacman -Qo)
#   cache [--json]      package cache directories, sizes and archive counts
#   info  [--json]      one-page overview: managers, counts, cache, owner backend
#
# Supported managers (first detection order): dpkg (Debian family),
# rpm (RHEL/openSUSE family), pacman (Arch family), apk (Alpine).
# Everything is strictly read-only -- this module never installs, upgrades or
# refreshes package metadata (see update-check.sh for the offline update scan).
#
# Parsers that read databases (/var/lib/dpkg/status, /lib/apk/db/installed)
# are pure functions with an explicit FILE argument so tests can feed them
# synthetic databases.
# Exit codes: 0 ok, 2 usage, 3 no package manager / unreadable database.
# =============================================================================

PKG_MAX_ROWS_DEFAULT=50

pkg_usage() {
    cat <<'EOF'
sysops pkg -- installed-package inventory (read-only)

USAGE
  sysops pkg count [--json]     # installed packages per manager
  sysops pkg owner FILE         # which package owns FILE
  sysops pkg cache [--json]     # package cache dirs, sizes, archive counts
  sysops pkg info  [--json]     # overview: managers, counts, cache totals
  sysops pkg help               # this help

MANAGERS
  dpkg (Debian/Ubuntu), rpm (RHEL/Fedora/openSUSE),
  pacman (Arch), apk (Alpine) -- whichever is installed

OPTIONS
  --json        machine-readable output
  -h, --help    Show this help

EXIT CODES
  owner:  0 owned   1 not owned by any package   2 usage   3 no manager
  others: 0 ok      2 usage   3 no manager / database unreadable

EXAMPLES
  sysops pkg count
  sysops pkg owner /usr/bin/curl
  sysops pkg cache --json
  sysops pkg info
EOF
}

# -----------------------------------------------------------------------------
# Detection helpers
# -----------------------------------------------------------------------------
# pkg_detect -> prints every available manager, one per line, detection order
# dpkg rpm pacman apk; empty output when none are installed.
pkg_detect() {
    have_cmd dpkg   && printf 'dpkg\n'
    have_cmd rpm    && printf 'rpm\n'
    have_cmd pacman && printf 'pacman\n'
    have_cmd apk    && printf 'apk\n'
    return 0
}

pkg_has_manager() {
    pkg_detect | grep -q "^${1}$"
}

# -----------------------------------------------------------------------------
# Pure parsing helpers (unit-testable)
# -----------------------------------------------------------------------------
# pkg_count_dpkg_status FILE -> number of fully installed packages in a
# dpkg status database (blocks with "Status: install ok installed").
pkg_count_dpkg_status() {
    local file="${1:-}"
    [[ -r "$file" ]] || return 1
    awk '
        /^Package:/   { inpkg = 1 }
        /^Status: install ok installed$/ { if (inpkg) n++ }
        /^$/          { inpkg = 0 }
        END { print n + 0 }
    ' "$file"
    return 0
}

# pkg_count_apk_db FILE -> number of installed packages in an apk database
# (each record starts with "Package:NAME").
pkg_count_apk_db() {
    local file="${1:-}"
    [[ -r "$file" ]] || return 1
    awk '/^(P|Package):/ { n++ } END { print n + 0 }' "$file"
    return 0
}

# pkg_count_rpm_query TEXT -> count non-empty rows of `rpm -qa` style output
pkg_count_rpm_query() {
    awk 'NF { n++ } END { print n + 0 }'
    return 0
}

# pkg_parse_dpkg_owner "coreutils: /usr/bin/ls" -> "coreutils"
pkg_parse_dpkg_owner() {
    local line="${1:-}"
    [[ "$line" == *:* ]] || return 1
    local pkg="${line%%:*}"
    pkg="$(trim "$pkg")"
    [[ -n "$pkg" ]] || return 1
    printf '%s' "$pkg"
    return 0
}

# pkg_parse_pacman_owner "/usr/bin/ls is owned by coreutils 9.1-1" -> "coreutils"
pkg_parse_pacman_owner() {
    local line="${1:-}"
    if [[ "$line" == *" is owned by "* ]]; then
        local rest="${line#* is owned by }"
        local pkg="${rest%% *}"
        [[ -n "$pkg" ]] || return 1
        printf '%s' "$pkg"
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Counting backends (each prints COUNT and rc 1 when its database is missing)
# -----------------------------------------------------------------------------
pkg_count_dpkg() {
    local status_file="/var/lib/dpkg/status"
    if ! have_cmd dpkg; then return 1; fi
    if [[ -r "$status_file" ]]; then
        pkg_count_dpkg_status "$status_file"
        return 0
    fi
    # fall back to the query tool (slower, always works)
    local out=""
    out="$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1
    printf '%s' "$(pkg_count_rpm_query <<< "$out")"
    return 0
}

pkg_count_rpm() {
    have_cmd rpm || return 1
    local out=""
    out="$(rpm -qa --qf '%{NAME}\n' 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1
    printf '%s' "$(pkg_count_rpm_query <<< "$out")"
    return 0
}

pkg_count_pacman() {
    have_cmd pacman || return 1
    local out=""
    out="$(pacman -Qq 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        # fall back to the local database directory
        if [[ -d /var/lib/pacman/local ]]; then
            printf '%s' "$(find /var/lib/pacman/local -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ' || true)"
            return 0
        fi
        return 1
    fi
    printf '%s' "$(pkg_count_rpm_query <<< "$out")"
    return 0
}

pkg_count_apk() {
    have_cmd apk || return 1
    if [[ -r /lib/apk/db/installed ]]; then
        pkg_count_apk_db /lib/apk/db/installed
        return 0
    fi
    local out=""
    out="$(apk info 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1
    printf '%s' "$(pkg_count_rpm_query <<< "$out")"
    return 0
}

pkg_count_for() {
    # pkg_count_for MANAGER -> prints count; rc 1 when unavailable
    case "$1" in
        dpkg)   pkg_count_dpkg ;;
        rpm)    pkg_count_rpm ;;
        pacman) pkg_count_pacman ;;
        apk)    pkg_count_apk ;;
        *)      return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Cache paths
# -----------------------------------------------------------------------------
# pkg_cache_dirs -> prints "<manager> <path>" pairs for EXISTING cache dirs
pkg_cache_dirs() {
    local m p
    while IFS= read -r m; do
        case "$m" in
            dpkg)   for p in /var/cache/apt/archives /var/cache/apt/archives/partial; do
                        [[ -d "$p" ]] && printf '%s %s\n' "$m" "$p"
                    done ;;
            rpm)    for p in /var/cache/dnf /var/cache/yum /var/cache/zypp/packages; do
                        [[ -d "$p" ]] && printf '%s %s\n' "$m" "$p"
                    done ;;
            pacman) [[ -d /var/cache/pacman/pkg ]] && printf '%s %s\n' "$m" /var/cache/pacman/pkg ;;
            apk)    [[ -d /var/cache/apk ]] && printf '%s %s\n' "$m" /var/cache/apk ;;
        esac
    done < <(pkg_detect)
    return 0
}

# pkg_cache_glob MANAGER -> glob matching downloaded archives in a cache dir
pkg_cache_glob() {
    case "$1" in
        dpkg)   printf '%s' "*.deb" ;;
        rpm)    printf '%s' "*.rpm" ;;
        pacman) printf '%s' "*.pkg.tar.*" ;;
        apk)    printf '%s' "*.apk" ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# Report integration: called by `sysops report --section packages`
# -----------------------------------------------------------------------------
_report_packages() {
    local -a managers=()
    mapfile -t managers < <(pkg_detect)
    if (( ${#managers[@]} == 0 )); then
        if [[ "${OPT_JSON:-0}" == "1" ]]; then
            report_kv packages managers "none"
        else
            section "Packages"
            _report_unavailable "Managers" "no dpkg/rpm/pacman/apk detected"
        fi
        return 0
    fi

    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        local m c
        for m in "${managers[@]}"; do
            if c="$(pkg_count_for "$m")" && is_uint "$c"; then
                report_kv packages "installed_${m}" "$c"
            else
                report_kv packages "installed_${m}" "unknown"
            fi
        done
        # offline pending-update count, when the updates module is loaded
        if declare -F updates_count_offline >/dev/null 2>&1; then
            local total
            total="$(updates_count_offline 2>/dev/null || true)"
            report_kv packages "updates_pending_offline" "${total:-unknown}"
        fi
        if [[ -e /var/run/reboot-required ]]; then
            report_kv packages "reboot_required" "yes"
        fi
        return 0
    fi

    section "Packages"
    printf '  %-16s %10s  %s\n' "MANAGER" "PACKAGES" "DATABASE"
    local m c db
    for m in "${managers[@]}"; do
        case "$m" in
            dpkg)   db="/var/lib/dpkg/status" ;;
            rpm)    db="rpmdb" ;;
            pacman) db="/var/lib/pacman" ;;
            apk)    db="/lib/apk/db/installed" ;;
            *)      db="?" ;;
        esac
        if c="$(pkg_count_for "$m")" && is_uint "$c"; then
            printf '  %-16s %10s  %s\n' "$m" "$c" "$db"
        else
            printf '  %-16s %10s  %s\n' "$m" "?" "$db (unreadable)"
        fi
    done
    if declare -F updates_count_offline >/dev/null 2>&1; then
        local total
        total="$(updates_count_offline 2>/dev/null || true)"
        if is_uint "${total:-}" ; then
            _report_kv_line "Updates pending" "$total (cached indexes, offline)"
        fi
    fi
    if [[ -e /var/run/reboot-required ]]; then
        _report_kv_line "Reboot" "required (/var/run/reboot-required present)"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------
cmd_pkg_count() {
    local json="${OPT_JSON:-0}"
    while (( $# > 0 )); do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) pkg_usage; return 0 ;;
            *)      error "pkg count: unknown option: $1"; return 2 ;;
        esac
    done
    local -a managers=()
    mapfile -t managers < <(pkg_detect)
    if (( ${#managers[@]} == 0 )); then
        error "pkg: no package manager detected (dpkg/rpm/pacman/apk)"
        return 3
    fi
    local m c
    if (( json == 1 )); then
        say "["
        local first=1
        for m in "${managers[@]}"; do
            (( first )) || say ","
            first=0
            if c="$(pkg_count_for "$m")" && is_uint "$c"; then
                printf '  {"manager": "%s", "installed": %s}\n' "$(json_escape "$m")" "$c"
            else
                printf '  {"manager": "%s", "installed": null}\n' "$(json_escape "$m")"
            fi
        done
        say "]"
        return 0
    fi
    printf '  %-10s %10s\n' "MANAGER" "PACKAGES"
    for m in "${managers[@]}"; do
        if c="$(pkg_count_for "$m")" && is_uint "$c"; then
            printf '  %-10s %10s\n' "$m" "$c"
        else
            printf '  %-10s %10s\n' "$m" "?"
        fi
    done
    return 0
}

cmd_pkg_owner() {
    local file="${1:-}"
    shift || true
    if [[ -n "${1:-}" || -z "$file" || "$file" == -* ]]; then
        error "pkg owner: exactly one FILE argument is required"
        return 2
    fi
    if [[ ! -e "$file" ]]; then
        error "pkg owner: no such file: $file"
        return 2
    fi
    file="$(abspath "$file")"

    if pkg_has_manager dpkg; then
        local line="" pkg=""
        if line="$(dpkg -S -- "$file" 2>/dev/null | head -n 1)" && [[ -n "$line" ]]; then
            if pkg="$(pkg_parse_dpkg_owner "$line")"; then
                printf '%s: owned by %s (dpkg)\n' "$file" "$pkg"
                return 0
            fi
        fi
    fi
    if pkg_has_manager rpm; then
        local out=""
        if out="$(rpm -qf -- "$file" 2>/dev/null)" && [[ -n "$out" && "$out" != *"not owned"* ]]; then
            printf '%s: owned by %s (rpm)\n' "$file" "$out"
            return 0
        fi
    fi
    if pkg_has_manager pacman; then
        local out="" pkg=""
        if out="$(pacman -Qo -- "$file" 2>/dev/null)" && pkg="$(pkg_parse_pacman_owner "$out")"; then
            printf '%s: owned by %s (pacman)\n' "$file" "$pkg"
            return 0
        fi
    fi
    if ! pkg_detect | grep -q .; then
        error "pkg owner: no package manager detected (dpkg/rpm/pacman/apk)"
        return 3
    fi
    printf '%s: not owned by any installed package\n' "$file"
    return 1
}

cmd_pkg_cache() {
    local json="${OPT_JSON:-0}"
    while (( $# > 0 )); do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) pkg_usage; return 0 ;;
            *)      error "pkg cache: unknown option: $1"; return 2 ;;
        esac
    done
    local -a rows=()
    mapfile -t rows < <(pkg_cache_dirs)
    if (( json == 1 )); then
        say "["
        local first=1 row m p bytes n
        for row in "${rows[@]}"; do
            read -r m p <<< "$row"
            bytes="$(du_bytes "$p" 2>/dev/null || echo 0)"
            n="$(find "$p" -maxdepth 1 -name "$(pkg_cache_glob "$m")" 2>/dev/null | wc -l | tr -d ' ' || true)"
            is_uint "$n" || n=0
            (( first )) || say ","
            first=0
            printf '  {"manager": "%s", "path": "%s", "bytes": %s, "archives": %s}\n' \
                "$(json_escape "$m")" "$(json_escape "$p")" "$bytes" "$n"
        done
        say "]"
        return 0
    fi
    if (( ${#rows[@]} == 0 )); then
        say "(no package cache directories found)"
        return 0
    fi
    printf '  %-10s %-36s %12s %8s\n' "MANAGER" "PATH" "SIZE" "ARCHIVES"
    local row m p bytes n total=0
    for row in "${rows[@]}"; do
        read -r m p <<< "$row"
        bytes="$(du_bytes "$p" 2>/dev/null || echo 0)"
        n="$(find "$p" -maxdepth 1 -name "$(pkg_cache_glob "$m")" 2>/dev/null | wc -l | tr -d ' ' || true)"
        is_uint "$n" || n=0
        total=$(( total + bytes ))
        printf '  %-10s %-36s %12s %8s\n' \
            "$m" "$(truncate_mid "$p" 36)" \
            "$(human_size "$bytes" 2>/dev/null || echo '?')" "$n"
    done
    say "  total cache: $(human_size "$total")"
    return 0
}

cmd_pkg_info() {
    local json="${OPT_JSON:-0}"
    while (( $# > 0 )); do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) pkg_usage; return 0 ;;
            *)      error "pkg info: unknown option: $1"; return 2 ;;
        esac
    done
    local -a managers=() cache_rows=()
    mapfile -t managers < <(pkg_detect)
    mapfile -t cache_rows < <(pkg_cache_dirs)

    # total cache bytes
    local total_cache=0 row m p bytes
    for row in "${cache_rows[@]}"; do
        read -r m p <<< "$row"
        bytes="$(du_bytes "$p" 2>/dev/null || echo 0)"
        total_cache=$(( total_cache + bytes ))
    done

    # primary manager = first detected
    local primary="none"
    (( ${#managers[@]} > 0 )) && primary="${managers[0]}"

    if (( json == 1 )); then
        say "{"
        say "  \"primary_manager\": \"$(json_escape "$primary")\","
        printf '  "managers": ['
        local i first=1
        for i in "${!managers[@]}"; do
            (( first )) || printf ', '
            first=0
            printf '"%s"' "$(json_escape "${managers[$i]}")"
        done
        printf '],\n'
        say "  \"installed\": {"
        local first=1 c
        for m in "${managers[@]}"; do
            (( first )) || say ","
            first=0
            if c="$(pkg_count_for "$m")" && is_uint "$c"; then
                printf '    "%s": %s' "$(json_escape "$m")" "$c"
            else
                printf '    "%s": null' "$(json_escape "$m")"
            fi
        done
        say ""
        say "  },"
        say "  \"cache_bytes\": $total_cache,"
        say "  \"cache_dirs\": ${#cache_rows[@]}"
        say "}"
        return 0
    fi
    section "Package managers"
    if (( ${#managers[@]} == 0 )); then
        say "  (no package manager detected)"
        return 0
    fi
    _report_kv_line "Primary" "$primary"
    _report_kv_line "Detected" "${managers[*]}"
    local c
    for m in "${managers[@]}"; do
        if c="$(pkg_count_for "$m")" && is_uint "$c"; then
            _report_kv_line "$m installed" "$c"
        else
            _report_kv_line "$m installed" "unknown"
        fi
    done
    _report_kv_line "Cache size" "$(human_size "$total_cache") ($(( ${#cache_rows[@]} )) dir(s))"
    return 0
}

cmd_pkg() {
    local action="${1:-help}"
    if (( $# > 0 )); then
        shift
    fi
    case "$action" in
        count) cmd_pkg_count "$@" ;;
        owner) cmd_pkg_owner "$@" ;;
        cache) cmd_pkg_cache "$@" ;;
        info)  cmd_pkg_info  "$@" ;;
        help|-h|--help) pkg_usage; return 0 ;;
        *)     error "pkg: unknown action '$action' (see: sysops pkg help)"
               return 2 ;;
    esac
}
