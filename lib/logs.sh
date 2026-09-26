#!/usr/bin/env bash
# =============================================================================
# logs.sh -- `sysops logs`: error summary from journalctl or classic logfiles
#
# Sources (first match wins, --file overrides everything):
#   1. --file PATH        any readable logfile
#   2. journalctl         when available and /var/log/journal exists
#   3. /var/log/syslog    Debian-family
#   4. /var/log/messages  RHEL-family
#   5. /var/log/daemon.log, /var/log/kern.log
#
# The command counts occurrences of error keywords in ONE awk pass (no
# grep-per-keyword spawning), shows the last matching line per keyword and
# can print a sample tail of matches.  Exit codes: 0 ok, 2 usage,
# 3 no readable log source.
# =============================================================================

LOGS_DEFAULT_KEYWORDS="error fail warn fatal panic denied refused timeout segfault"

logs_usage() {
    cat <<'EOF'
sysops logs -- summarize errors from journalctl / syslog / any logfile

USAGE
  sysops logs [OPTIONS]

OPTIONS
  --file PATH       Analyze this logfile instead of the system journal
  --lines N         How many lines to read (journalctl -n / tail N)
                    (default: 2000, config: LOGS_LINES)
  --since SPEC      journalctl time span: 1h, 24h, 7d, 2w or any
                    journalctl --since value (default: 24h)
  --keyword K       Add a custom keyword bucket (repeatable)
  --tail N          Show the last N matching lines for the top keyword
  --json            Emit a JSON summary instead of the table
  -h, --help        Show this help

EXIT CODES
  0  summary produced            2  usage error
  3  no readable log source

EXAMPLES
  sysops logs                          # last 24h from journal/syslog
  sysops logs --file /var/log/nginx/error.log --keyword upstream
  sysops logs --since 7d --json
EOF
}

# logs_normalize_since "24h" -> "-24h" (journalctl relative span)
# Accepts plain journalctl specs too (e.g. "today", "2026-01-01 00:00:00").
logs_normalize_since() {
    local spec="${1:-24h}"
    case "$spec" in
        [0-9]*h|[0-9]*d|[0-9]*w|[0-9]*m)
            printf '%s' "-${spec}"
            ;;
        *)
            printf '%s' "$spec"
            ;;
    esac
    return 0
}

# logs_pick_source -> prints "journal" or a file path; rc 3 when nothing found
logs_pick_source() {
    if [[ -n "${LOGS_FILE:-}" ]]; then
        if [[ ! -r "$LOGS_FILE" ]]; then
            error "logs: file not readable: $LOGS_FILE"
            return 3
        fi
        printf '%s' "$LOGS_FILE"
        return 0
    fi
    if have_cmd journalctl && [[ -d /var/log/journal ]]; then
        printf '%s' "journal"
        return 0
    fi
    local f
    for f in /var/log/syslog /var/log/messages /var/log/daemon.log /var/log/kern.log; do
        if [[ -r "$f" ]]; then
            printf '%s' "$f"
            return 0
        fi
    done
    if have_cmd journalctl; then
        # some setups keep the journal in /run/log/journal (volatile)
        if journalctl -q --no-pager -n 1 >/dev/null 2>&1; then
            printf '%s' "journal"
            return 0
        fi
    fi
    error "logs: no readable source (tried --file, journalctl, /var/log/syslog, /var/log/messages)"
    return 3
}

# logs_snapshot SRC LINES SINCE TMPFILE -> dumps the log text into TMPFILE
logs_snapshot() {
    local src="$1" lines="$2" since="$3" out="$4"
    if [[ "$src" == "journal" ]]; then
        local -a jcmd=(journalctl -q --no-pager -n "$lines")
        if [[ -n "$since" ]]; then
            jcmd+=(--since "$since")
        fi
        "${jcmd[@]}" > "$out" 2>/dev/null
        return $?
    fi
    tail -n "$lines" -- "$src" > "$out" 2>/dev/null
    return $?
}

# logs_count_keywords FILE "kw1 kw2 ..." -> prints per keyword:
#   KEYWORD<TAB>COUNT<TAB>LAST_LINE_FIRST_FIELD<TAB>FULL_KEYWORD_BUCKET
# One awk pass, case-insensitive substring match.
logs_count_keywords() {
    local file="$1" kwlist="$2"
    awk -v kws="$kwlist" '
        BEGIN {
            n = split(kws, a, " ")
            for (i = 1; i <= n; i++) { kw[i] = tolower(a[i]); cnt[i] = 0 }
        }
        {
            lines++
            l = tolower($0)
            for (i = 1; i <= n; i++) {
                if (index(l, kw[i]) > 0) {
                    cnt[i]++
                    last[i] = $0
                }
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                ts = ""
                if (i in last) {
                    # first whitespace-separated token is usually the stamp
                    split(last[i], parts, " ")
                    ts = parts[1]
                    gsub(/\[/, "", ts)
                    gsub(/\]/, "", ts)
                }
                printf "%s\t%d\t%s\n", kw[i], cnt[i], ts
            }
        }
    ' "$file"
    return 0
}

# Counts lines of a snapshot file (used for the --json "lines_scanned" field).
logs_count_lines() {
    local file="$1"
    wc -l < "$file" 2>/dev/null | tr -d ' ' || echo 0
    return 0
}

cmd_logs() {
    local file_opt="" lines="" since="" tail_n=0 json=0
    local -a extra_kw=()
    LOGS_FILE=""

    while (( $# > 0 )); do
        case "$1" in
            --file)     [[ $# -ge 2 ]] || { error "--file needs a value"; return 2; }
                        file_opt="$2"; shift 2 ;;
            --file=*)   file_opt="${1#*=}"; shift ;;
            --lines)    [[ $# -ge 2 ]] || { error "--lines needs a value"; return 2; }
                        lines="$2"; shift 2 ;;
            --lines=*)  lines="${1#*=}"; shift ;;
            --since)    [[ $# -ge 2 ]] || { error "--since needs a value"; return 2; }
                        since="$2"; shift 2 ;;
            --since=*)  since="${1#*=}"; shift ;;
            --keyword)  [[ $# -ge 2 ]] || { error "--keyword needs a value"; return 2; }
                        extra_kw+=("$2"); shift 2 ;;
            --keyword=*) extra_kw+=("${1#*=}"); shift ;;
            --tail)     [[ $# -ge 2 ]] || { error "--tail needs a value"; return 2; }
                        tail_n="$2"; shift 2 ;;
            --tail=*)   tail_n="${1#*=}"; shift ;;
            --json)     json=1; shift ;;
            -h|--help)  logs_usage; return 0 ;;
            *)          error "logs: unknown option: $1"; return 2 ;;
        esac
    done

    LOGS_FILE="$file_opt"
    if ! is_uint "$lines" || (( lines < 1 )); then
        lines="$(cfg_int LOGS_LINES 2000)"
    fi
    if [[ -z "$since" ]]; then
        since="$(cfg LOGS_SINCE 24h)"
    fi
    if ! is_uint "$tail_n"; then
        tail_n=0
    fi
    # validate custom keywords: no spaces/tabs inside a single bucket
    local kw
    for kw in "${extra_kw[@]}"; do
        if [[ -z "$kw" || "$kw" =~ [[:space:]] ]]; then
            error "logs: invalid keyword '$kw' (must be one word)"
            return 2
        fi
    done

    local src=""
    if ! src="$(logs_pick_source)"; then
        return 3
    fi

    local jsince=""
    if [[ "$src" == "journal" ]]; then
        jsince="$(logs_normalize_since "$since")"
    fi

    local tmpf=""
    mktemp_sysops tmpf "sysops-logs.XXXXXX" || return 3
    if ! logs_snapshot "$src" "$lines" "$jsince" "$tmpf"; then
        error "logs: failed to read source '$src'"
        return 3
    fi

    # ---- keyword list (defaults + extras, deduplicated) --------------------
    local -a kws=()
    declare -A kwseen=()
    local k
    for k in $LOGS_DEFAULT_KEYWORDS; do
        kws+=("$k"); kwseen["$k"]=1
    done
    for k in "${extra_kw[@]}"; do
        if [[ -z "${kwseen[$k]:-}" ]]; then
            kws+=("$k"); kwseen["$k"]=1
        fi
    done
    local kwlist="${kws[*]}"

    # ---- count --------------------------------------------------------------
    local -a rows=()
    mapfile -t rows < <(logs_count_keywords "$tmpf" "$kwlist")
    local total_lines
    total_lines="$(logs_count_lines "$tmpf")"

    # ---- emit ------------------------------------------------------------------
    if (( json == 1 )); then
        say "{"
        say "  \"source\": \"$(json_escape "$src")\","
        say "  \"lines_scanned\": $total_lines,"
        say "  \"since\": \"$(json_escape "$since")\","
        say "  \"keywords\": ["
        local first=1 row kname kcnt kts
        for row in "${rows[@]}"; do
            IFS=$'\t' read -r kname kcnt kts <<< "$row" || true
            (( first )) || say ","
            first=0
            printf '    {"keyword": "%s", "count": %s, "last_seen": "%s"}' \
                "$(json_escape "$kname")" "$kcnt" "$(json_escape "$kts")"
        done
        say ""
        say "  ]"
        say "}"
    else
        section "Log error summary"
        say "  source: $src  (scanned $total_lines lines, since ${since})"
        printf '  %-12s %8s  %s\n' "KEYWORD" "COUNT" "LAST SEEN"
        local row kname kcnt kts top_kw="" top_cnt=-1
        for row in "${rows[@]}"; do
            IFS=$'\t' read -r kname kcnt kts <<< "$row" || true
            if (( kcnt > top_cnt )); then
                top_cnt="$kcnt"
                top_kw="$kname"
            fi
            if (( kcnt > 0 )); then
                printf '  %-12s %8s  %s\n' "$kname" "$kcnt" "$kts"
            else
                printf '  %-12s %8s  %s\n' "$kname" "$kcnt" "-"
            fi
        done
        say ""
        if (( top_cnt <= 0 )); then
            say "  no matches for any keyword -- looks healthy"
        else
            say "  top keyword: '$top_kw' with $top_cnt hit(s)"
        fi
    fi

    # ---- optional sample tail ---------------------------------------------------
    if (( tail_n > 0 && top_cnt > 0 )); then
        if (( json != 1 )); then
            say ""
            section "Sample: last $tail_n line(s) matching '$top_kw'"
            grep -i -F -- "$top_kw" "$tmpf" 2>/dev/null | tail -n "$tail_n" | while IFS= read -r sline; do
                printf '  %s\n' "$(truncate_mid "$sline" 100)"
            done
        fi
    fi
    return 0
}
