#!/usr/bin/env bash
# =============================================================================
# common.sh -- shared helpers for the sysops toolkit
#
# Every sysops command module (lib/*.sh) and the bin/sysops dispatcher source
# this file.  It intentionally contains no command logic of its own; it only
# provides:
#   * colour handling (NO_COLOR aware, TTY aware)
#   * levelled logging (DEBUG/INFO/WARN/ERROR) with optional log file
#   * a strict-mode helper + ERR trap
#   * safe configuration file parsing (KEY=VAL, NO eval on file contents)
#   * integer-only maths helpers (human sizes, percentages)
#   * path helpers (lexical abspath), du-based byte sizes
#   * command availability checks
#   * advisory locks (flock with a mkdir fallback)
#   * interactive confirmation (respects the global --yes flag)
#   * minimal JSON string escaping
#
# Design rules used throughout sysops:
#   * never eval() untrusted input
#   * destructive operations default to dry-run
#   * commands that may legitimately fail are guarded with `|| true` or `if`
#     so that `set -Eeuo pipefail` does not abort the toolkit unexpectedly
# =============================================================================

# --- include guard -----------------------------------------------------------
if [[ -n "${__SYOPS_COMMON_SH:-}" ]]; then
    return 0
fi
__SYOPS_COMMON_SH=1

# --- version -----------------------------------------------------------------
SYOPS_VERSION="${SYOPS_VERSION:-1.0.0}"
SYOPS_LIB_COMMON="1"

# =============================================================================
# Colour handling
# =============================================================================
# Colours are enabled only when ALL of the following are true:
#   * the environment variable NO_COLOR is not set (https://no-color.org)
#   * SYOPS_NO_COLOR is not set (same idea, sysops-specific)
#   * stdout is a terminal (or SYOPS_FORCE_COLOR=1 overrides that check)
C_RESET="" ; C_BOLD="" ; C_DIM=""
C_RED="" ; C_GREEN="" ; C_YELLOW="" ; C_BLUE="" ; C_MAGENTA="" ; C_CYAN=""

sysops_init_color() {
    local enable=1
    if [[ -n "${NO_COLOR:-}" ]]; then
        enable=0
    fi
    if [[ -n "${SYOPS_NO_COLOR:-}" ]]; then
        enable=0
    fi
    if [[ "${SYOPS_FORCE_COLOR:-0}" != "1" && ! -t 1 ]]; then
        enable=0
    fi
    if [[ "$enable" == "1" ]]; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m'
        C_MAGENTA=$'\033[35m'
        C_CYAN=$'\033[36m'
    else
        C_RESET="" ; C_BOLD="" ; C_DIM=""
        C_RED="" ; C_GREEN="" ; C_YELLOW=""
        C_BLUE="" ; C_MAGENTA="" ; C_CYAN=""
    fi
    return 0
}
sysops_init_color

# =============================================================================
# Logging
# =============================================================================
# All levelled output goes to stderr so that stdout stays parseable (tables,
# JSON, values).  say() writes to stdout for normal user-facing lines.
# When SYOPS_LOG_FILE points to a writable location, every message is also
# appended there (best effort -- a broken log file never aborts a command).

_log_emit() {
    # _log_emit LEVEL MESSAGE...
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
    local color="$C_RESET"
    case "$level" in
        DEBUG)  color="$C_DIM" ;;
        INFO)   color="$C_GREEN" ;;
        WARN)   color="$C_YELLOW" ;;
        ERROR)  color="$C_RED" ;;
        *)      color="$C_RESET" ;;
    esac
    if [[ "${OPT_QUIET:-0}" == "1" && "$level" == "DEBUG" ]]; then
        return 0
    fi
    printf '%s[%s] [%-5s]%s %s\n' "$color" "$ts" "$level" "$C_RESET" "$msg" >&2
    if [[ -n "${SYOPS_LOG_FILE:-}" ]]; then
        # best effort append; a read-only log file must not break commands
        printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" \
            >> "$SYOPS_LOG_FILE" 2>/dev/null || true
    fi
    return 0
}

debug() { _log_emit "DEBUG" "$@"; }
info()  { _log_emit "INFO"  "$@"; }
warn()  { _log_emit "WARN"  "$@"; }
error() { _log_emit "ERROR" "$@"; }

say() {
    # plain user-facing output on stdout
    printf '%s\n' "$*"
}

# Print a highlighted section header (used by report/audit).
section() {
    printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"
}

die() {
    # die EXIT_CODE MESSAGE...
    local code="$1"; shift
    error "$*"
    exit "$code"
}

# =============================================================================
# Strict mode + error trap
# =============================================================================
# bin/sysops calls sysops_set_strict() once.  Command modules deliberately
# turn the ERR trap off before returning non-zero exit codes (monitor uses
# exit codes as data: 0=ok 1=warn 2=crit) to avoid spurious trap messages.
sysops_err_trap() {
    # sysops_err_trap RC LINENO COMMAND
    local rc="$1" line="$2" cmd="$3"
    error "command failed (rc=$rc) near line $line: $cmd"
}

sysops_set_strict() {
    set -Eeuo pipefail
    trap 'sysops_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
}

# =============================================================================
# Small validation helpers
# =============================================================================
is_int() {
    # true when $1 is a (possibly negative) base-10 integer
    [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

is_uint() {
    # true when $1 is a non-negative integer
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

clamp_int() {
    # clamp_int VALUE MIN MAX -> prints VALUE restricted to [MIN, MAX]
    local v="$1" lo="$2" hi="$3"
    if ! is_int "$v"; then
        printf '%s' "$lo"
        return 1
    fi
    if (( v < lo )); then v="$lo"; fi
    if (( v > hi )); then v="$hi"; fi
    printf '%s' "$v"
}

trim() {
    # trim STRING -> prints STRING without leading/trailing whitespace
    local s="${1-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# =============================================================================
# Integer-only maths helpers (no bc / awk dependency)
# =============================================================================
human_size() {
    # human_size BYTES -> "1.500 MiB" style, integer maths only.
    # Fraction is truncated to 3 digits (never rounded up past the boundary).
    local bytes="${1:-0}"
    if ! is_int "$bytes"; then
        printf '%s' "n/a"
        return 1
    fi
    local neg=""
    if (( bytes < 0 )); then
        neg="-"
        bytes=$(( -bytes ))
    fi
    local -a units=("B" "KiB" "MiB" "GiB" "TiB" "PiB")
    local idx=0
    local whole="$bytes" rem=0 frac=0
    while (( whole >= 1024 && idx < 5 )); do
        rem=$(( whole % 1024 ))
        whole=$(( whole / 1024 ))
        idx=$(( idx + 1 ))
        frac=$(( rem * 1000 / 1024 ))
    done
    if (( idx == 0 )); then
        printf '%s%d %s' "$neg" "$whole" "${units[$idx]}"
    else
        printf '%s%d.%03d %s' "$neg" "$whole" "$frac" "${units[$idx]}"
    fi
    return 0
}

pct() {
    # pct NUM DEN -> integer percentage rounded half-up; DEN<=0 yields 0
    local num="$1" den="$2"
    if ! is_int "$num" || ! is_int "$den"; then
        printf '%s' "0"
        return 1
    fi
    if (( den <= 0 )); then
        printf '%s' "0"
        return 0
    fi
    if (( num < 0 )); then
        num=0
    fi
    printf '%d' $(( (num * 100 + den / 2) / den ))
    return 0
}

div_round() {
    # div_round NUM DEN -> NUM/DEN rounded half-up (DEN>0 required)
    local num="$1" den="$2"
    if ! is_int "$num" || ! is_int "$den" || (( den <= 0 )); then
        printf '%s' "0"
        return 1
    fi
    printf '%d' $(( (num + den / 2) / den ))
}

# =============================================================================
# Path helpers
# =============================================================================
abspath() {
    # abspath PATH -> absolute path without requiring the file to exist.
    # Uses realpath -m when available, otherwise performs a purely lexical
    # normalisation (no symlink resolution, no filesystem access).
    local p="${1:-}"
    if [[ -z "$p" ]]; then
        printf '%s' "/"
        return 0
    fi
    if have_cmd realpath; then
        local r=""
        if r="$(realpath -m -- "$p" 2>/dev/null)" && [[ -n "$r" ]]; then
            printf '%s' "$r"
            return 0
        fi
    fi
    case "$p" in
        /*) : ;;
        *)  p="$PWD/$p" ;;
    esac
    local -a segs=() stack=()
    local IFS='/'
    read -r -a segs <<< "$p" || true
    local s
    for s in "${segs[@]}"; do
        case "$s" in
            ""|".") continue ;;
            "..")
                if (( ${#stack[@]} > 0 )); then
                    unset "stack[$(( ${#stack[@]} - 1 ))]"
                fi
                ;;
            *) stack+=("$s") ;;
        esac
    done
    local out="" first=1
    if [[ "$p" == /* ]]; then
        out="/"
    fi
    for s in "${stack[@]}"; do
        if (( first )); then
            out+="$s"
            first=0
        else
            out+="/$s"
        fi
    done
    if [[ -z "$out" ]]; then
        out="/"
    fi
    printf '%s' "$out"
    return 0
}

path_inside() {
    # path_inside CANDIDATE ROOT -> true when CANDIDATE is strictly inside ROOT
    local cand="$1" root="$2"
    [[ -n "$cand" && -n "$root" ]] || return 1
    [[ "$cand" != "$root" ]] || return 1
    case "$cand" in
        "$root") return 1 ;;
        "$root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Byte size of a file or directory tree.  Prefers GNU du -sb, falls back to
# du -sk * 1024 for BSD/macOS du.
du_bytes() {
    # du_bytes PATH -> prints byte count (0 + rc 1 when not measurable)
    local p="${1:-}"
    local out=""
    if [[ -z "$p" ]]; then
        printf '%s' "0"
        return 1
    fi
    if out="$(du -sb -- "$p" 2>/dev/null)"; then
        printf '%s' "${out%%$'\t'*}"
        return 0
    fi
    if out="$(du -sk -- "$p" 2>/dev/null)"; then
        printf '%s' $(( ${out%%$'\t'*} * 1024 ))
        return 0
    fi
    printf '%s' "0"
    return 1
}

file_age_days() {
    # file_age_days PATH -> integer whole days since last modification
    # Uses the file's mtime versus current time; unknown -> 0.
    local p="${1:-}"
    local mtime=""
    if [[ ! -e "$p" ]]; then
        printf '%s' "0"
        return 1
    fi
    if mtime="$(stat -c '%Y' -- "$p" 2>/dev/null)"; then
        :
    elif mtime="$(stat -f '%m' -- "$p" 2>/dev/null)"; then
        :  # BSD stat
    else
        printf '%s' "0"
        return 1
    fi
    if ! is_int "$mtime"; then
        printf '%s' "0"
        return 1
    fi
    local now
    now="$(date '+%s')"
    local diff=$(( now - mtime ))
    if (( diff < 0 )); then
        diff=0
    fi
    printf '%d' $(( diff / 86400 ))
    return 0
}

# =============================================================================
# Configuration handling
# =============================================================================
# Config files are simple KEY=VAL text with '#' or ';' comments.  Values may
# be quoted with single or double quotes (quotes are stripped).  Keys must
# match [A-Za-z_][A-Za-z0-9_]* and are stored as shell variables named
# SYOPS_CFG_<KEY> using printf -v -- eval() is never applied to file content.
config_load() {
    # config_load FILE -> rc 0 parsed, 1 unreadable, 2 bad usage
    local file="${1:-}"
    if [[ -z "$file" ]]; then
        error "config_load: no file given"
        return 2
    fi
    if [[ ! -r "$file" ]]; then
        error "config: cannot read '$file'"
        return 1
    fi
    local lineno=0
    local raw="" line="" key="" val=""
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        lineno=$(( lineno + 1 ))
        line="${raw%$'\r'}"
        line="$(trim "$line")"
        if [[ -z "$line" || "$line" == '#'* || "$line" == ';'* ]]; then
            continue
        fi
        if [[ "$line" != *=* ]]; then
            warn "config $file:$lineno: not KEY=VAL, line skipped: $line"
            continue
        fi
        key="${line%%=*}"
        val="${line#*=}"
        key="$(trim "$key")"
        val="$(trim "$val")"
        if [[ ${#val} -ge 2 ]]; then
            local first="${val:0:1}" last="${val: -1}"
            if [[ ( "$first" == '"' && "$last" == '"' ) || ( "$first" == "'" && "$last" == "'" ) ]]; then
                val="${val:1:${#val}-2}"
            fi
        fi
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            warn "config $file:$lineno: invalid key '$key', line skipped"
            continue
        fi
        printf -v "SYOPS_CFG_${key}" '%s' "$val"
    done < "$file"
    debug "config: loaded $file"
    return 0
}

# cfg KEY DEFAULT -- lookup order:
#   1. SYOPS_CFG_<KEY>   (set by config_load)
#   2. SYOPS_<KEY>       (environment override)
#   3. DEFAULT
cfg() {
    local key="${1:-}" def="${2-}"
    local cfg_name="SYOPS_CFG_${key}"
    local env_name="SYOPS_${key}"
    local val=""
    if [[ -n "${!cfg_name:-}" ]]; then
        val="${!cfg_name}"
    elif [[ -n "${!env_name:-}" ]]; then
        val="${!env_name}"
    else
        val="$def"
    fi
    printf '%s' "$val"
}

cfg_int() {
    # cfg_int KEY DEFAULT -> prints KEY as integer; falls back to DEFAULT
    local v
    v="$(cfg "$1" "$2")"
    if ! is_int "$v"; then
        warn "config: '$1' is not an integer ('${v:-(unset)}'), using default $2"
        printf '%s' "$2"
        return 1
    fi
    printf '%s' "$v"
    return 0
}

cfg_bool() {
    # cfg_bool KEY DEFAULT(0|1) -> prints 0 or 1
    local v
    v="$(cfg "$1" "$2")"
    case "$v" in
        1|true|TRUE|yes|YES|on|ON)  printf '%s' "1" ;;
        0|false|FALSE|no|NO|off|OFF) printf '%s' "0" ;;
        *) warn "config: '$1' is not boolean ('${v:-(unset)}'), using default $2"
           printf '%s' "$2" ;;
    esac
    return 0
}

# Load the standard configuration chain (later files win).  Files that do not
# exist are silently skipped.  Honors SYOPS_CONFIG as a single explicit file.
load_config_chain() {
    local -a candidates=(
        "/etc/sysops/sysops.conf"
        "${SYOPS_ROOT:-}/conf/sysops.conf"
        "${HOME:-}/.config/sysops/sysops.conf"
    )
    if [[ -n "${SYOPS_CONFIG:-}" ]]; then
        candidates=("${SYOPS_CONFIG}")
    fi
    local f
    for f in "${candidates[@]}"; do
        [[ -n "$f" && -r "$f" ]] || continue
        config_load "$f" || true
    done
    return 0
}

# =============================================================================
# Command availability
# =============================================================================
have_cmd() {
    # quiet check: rc 0 when $1 is an executable in PATH
    command -v "$1" >/dev/null 2>&1
}

require_cmd() {
    # require_cmd CMD [HINT] -- rc 1 (with an error message) when missing
    local cmd="${1:-}" hint="${2:-}"
    if have_cmd "$cmd"; then
        return 0
    fi
    if [[ -n "$hint" ]]; then
        error "required command not found: $cmd ($hint)"
    else
        error "required command not found: $cmd"
    fi
    return 1
}

# =============================================================================
# Advisory locking
# =============================================================================
# acquire_lock PATH [DESCRIPTION]
#   Uses flock on a file descriptor when available (bash 4.1+ dynamic fds),
#   otherwise falls back to a mkdir-based lock.  On success the caller MUST
#   call release_lock (usually from a trap).  rc 1 when the lock is held.
__SYOPS_LOCK_FD=""
__SYOPS_LOCK_PATH=""

acquire_lock() {
    local path="${1:-}" desc="${2:-operation}"
    if [[ -z "$path" ]]; then
        error "acquire_lock: no lock path given"
        return 2
    fi
    if have_cmd flock; then
        if ! exec {__SYOPS_LOCK_FD}>"$path"; then
            error "cannot create lock file: $path"
            return 1
        fi
        if ! flock -n "$__SYOPS_LOCK_FD"; then
            { exec {__SYOPS_LOCK_FD}>&-; } 2>/dev/null || true
            __SYOPS_LOCK_FD=""
            error "another $desc appears to be running (lock held: $path)"
            return 1
        fi
        debug "lock acquired (flock): $path"
    else
        local d="${path}.lockdir"
        if ! mkdir "$d" 2>/dev/null; then
            error "another $desc appears to be running (lock held: $d)"
            return 1
        fi
        __SYOPS_LOCK_PATH="$d"
        debug "lock acquired (mkdir): $d"
    fi
    return 0
}

release_lock() {
    if [[ -n "${__SYOPS_LOCK_FD:-}" ]]; then
        # dynamic fd close without eval: use a subshell redirect
        { exec {__SYOPS_LOCK_FD}>&-; } 2>/dev/null || true
        __SYOPS_LOCK_FD=""
    fi
    if [[ -n "${__SYOPS_LOCK_PATH:-}" && -d "${__SYOPS_LOCK_PATH}" ]]; then
        rmdir "$__SYOPS_LOCK_PATH" 2>/dev/null || true
        __SYOPS_LOCK_PATH=""
    fi
    return 0
}

# =============================================================================
# Interactive confirmation
# =============================================================================
confirm() {
    # confirm PROMPT -> rc 0 when the user agrees (or --yes was given).
    # In non-interactive sessions confirmation fails closed: the caller must
    # pass the global --yes flag to proceed.
    local prompt="${1:-Proceed?}"
    if [[ "${OPT_YES:-0}" == "1" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "non-interactive session and --yes not given: refusing to continue"
        return 1
    fi
    local ans=""
    if ! read -r -p "$prompt [y/N] " ans; then
        return 1
    fi
    ans="$(trim "${ans:-n}")"
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# =============================================================================
# JSON helpers (minimal, dependency free)
# =============================================================================
json_escape() {
    # json_escape STRING -> prints the string escaped for embedding in JSON
    local s="${1:-}"
    local out="" ch="" i=0
    local len=${#s}
    for (( i = 0; i < len; i++ )); do
        ch="${s:i:1}"
        case "$ch" in
            '\')    out+='\\' ;;
            '"')    out+='\"' ;;
            "$'\n'") out+='\n' ;;
            "$'\t'") out+='\t' ;;
            "$'\r'") out+='\r' ;;
            *)      out+="$ch" ;;
        esac
    done
    printf '%s' "$out"
    return 0
}

json_kv() {
    # json_kv KEY VALUE -> prints `  "key": "value"` (values JSON-escaped)
    printf '  "%s": "%s"' "$(json_escape "$1")" "$(json_escape "${2-}")"
    return 0
}

# =============================================================================
# Text table helpers
# =============================================================================
repeat_char() {
    # repeat_char CH N -> prints CH repeated N times (N<=0: nothing)
    local ch="${1:-}" n="${2:-0}"
    local out=""
    local i
    for (( i = 0; i < n; i++ )); do
        out+="$ch"
    done
    printf '%s' "$out"
    return 0
}

pad_right() {
    # pad_right STRING WIDTH -> string padded/truncated to exactly WIDTH
    local s="${1:-}" w="${2:-0}"
    local len=${#s}
    if (( len > w )); then
        if (( w > 3 )); then
            printf '%s' "${s:0:w-3}..."
        else
            printf '%s' "${s:0:w}"
        fi
        return 0
    fi
    printf '%s%*s' "$s" $(( w - len )) ""
    return 0
}

truncate_mid() {
    # truncate_mid STRING WIDTH -- keep head and tail, mark the cut with "..."
    local s="${1:-}" w="${2:-0}"
    local len=${#s}
    if (( len <= w || w < 8 )); then
        printf '%s' "$s"
        return 0
    fi
    local keep=$(( w - 3 ))
    local head=$(( keep / 2 ))
    local tail=$(( keep - head ))
    printf '%s...%s' "${s:0:head}" "${s: -tail}"
    return 0
}

# =============================================================================
# Temp file helper
# =============================================================================
# mktemp_sysops VARNAME PREFIX -- creates a temp file, stores path in VARNAME
# and registers cleanup on EXIT.  Multiple files are supported; all are
# removed when the shell exits.
__SYOPS_TMP_FILES=()

mktemp_sysops() {
    # mktemp_sysops VARNAME [TEMPLATE]
    local varname="$1" tmpl="${2:-sysops.XXXXXX}"
    local f=""
    if ! f="$(mktemp -t "$tmpl" 2>/dev/null)"; then
        if ! f="$(mktemp "${TMPDIR:-/tmp}/${tmpl}")"; then
            error "cannot create temporary file"
            return 1
        fi
    fi
    __SYOPS_TMP_FILES+=("$f")
    printf -v "$varname" '%s' "$f"
    if [[ "${__SYOPS_TMP_TRAP_SET:-0}" != "1" ]]; then
        trap '__syops_tmp_cleanup' EXIT
        __SYOPS_TMP_TRAP_SET=1
    fi
    return 0
}

__syops_tmp_cleanup() {
    local f
    for f in "${__SYOPS_TMP_FILES[@]}"; do
        [[ -e "$f" ]] && rm -f -- "$f" 2>/dev/null || true
    done
    return 0
}

# =============================================================================
# Misc
# =============================================================================
now_iso() {
    date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
}

now_stamp() {
    # compact timestamp used for backup archive names
    date '+%Y%m%d-%H%M%S'
}

hostname_of() {
    local h=""
    if h="$(hostname 2>/dev/null)" && [[ -n "$h" ]]; then
        printf '%s' "$h"
        return 0
    fi
    if [[ -r /proc/sys/kernel/hostname ]]; then
        read -r h < /proc/sys/kernel/hostname || true
        printf '%s' "$h"
        return 0
    fi
    printf '%s' "unknown"
    return 0
}

cpu_count() {
    # number of logical CPUs; /proc/cpuinfo first, nproc fallback
    local n=0
    if [[ -r /proc/cpuinfo ]]; then
        n="$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo 2>/dev/null || true)"
        [[ -z "$n" ]] && n=0
    fi
    if (( n <= 0 )); then
        if have_cmd nproc; then
            n="$(nproc 2>/dev/null || true)"
        fi
    fi
    if ! is_uint "${n:-}" || (( n <= 0 )); then
        n=1
    fi
    printf '%s' "$n"
    return 0
}
