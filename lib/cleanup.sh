#!/usr/bin/env bash
# =============================================================================
# cleanup.sh -- `sysops cleanup`: safe disk cleanup with dry-run default
#
# Finds cleanup candidates under one or more roots:
#   * files matching --include patterns (*.tmp, *.log, *.bak, core, ...)
#     that are older than --older-than days
#   * disposable cache directories (__pycache__, node_modules,
#     .pytest_cache, .mypy_cache, .ruff_cache, .tox) older than the same
#     age threshold (pass --older-than 0 to ignore age)
#
# DEFAULT IS DRY-RUN: nothing is deleted unless --apply is given, and even
# then an interactive confirmation is required unless --yes is passed.
# Deletion only ever touches paths that were listed as candidates under the
# requested roots; each path is re-validated immediately before removal.
# =============================================================================
CLEANUP_DEFAULT_INCLUDE="*.tmp,*.log,*.bak,*.old,*.swp,*.cache~,core,core.[0-9]*"
CLEANUP_CACHE_DIR_NAMES="__pycache__ node_modules .pytest_cache .mypy_cache .ruff_cache .tox"
CLEANUP_DEFAULT_AGE=7
CLEANUP_MAX_DEPTH=8
CLEANUP_MAX_LIST=500

cleanup_usage() {
    cat <<'EOF'
sysops cleanup -- find and remove disposable files (DRY-RUN BY DEFAULT)

USAGE
  sysops cleanup [OPTIONS] [ROOT...]

  ROOT                    Directories to scan (default: /tmp /var/tmp and
                          $XDG_CACHE_HOME or ~/.cache when they exist)

OPTIONS
  --apply                 Actually delete (default: dry-run listing only)
  -y, --yes               Skip the confirmation prompt with --apply
  --older-than N          Only match files/dirs older than N days
                          (default: 7; use 0 to ignore age entirely)
  --include PATTERNS      Comma-separated file name patterns
                          (default: *.tmp,*.log,*.bak,*.old,*.swp,core)
  --no-caches             Do not scan for disposable cache directories
  --keep-node-modules     Exclude node_modules from the cache dir scan
  --min-size BYTES        Ignore files smaller than BYTES (default: 0)
  --max-depth N           Depth limit for cache-dir scan (default: 8)
  --json                  JSON summary instead of the human table
  -h, --help              Show this help

EXIT CODES
  0  done (candidates found or not -- this is not an error)
  2  usage error
  3  one or more deletions failed in --apply mode

EXAMPLES
  sysops cleanup                        # dry-run listing, nothing deleted
  sysops cleanup --older-than 0 ~/dev   # all caches under ~/dev
  sysops cleanup --apply --yes /tmp     # actually delete (be sure!)
EOF
}

# Safety net: a candidate is only valid when it is strictly inside one of the
# requested roots, never equal to a root itself, never "/" and never a path
# that contains a newline (which would break the one-per-line listing).
cleanup_candidate_ok() {
    local cand="$1"
    local r
    if [[ -z "$cand" || "$cand" == "/" || "$cand" == "." ]]; then
        return 1
    fi
    if [[ "$cand" == *$'\n'* ]]; then
        return 1
    fi
    for r in "${CLEANUP_ROOTS[@]}"; do
        if path_inside "$cand" "$r"; then
            return 0
        fi
    done
    return 1
}

# Collect file candidates: find ... -type f (-mtime +N) (-size +Mc)
# with one find invocation per include pattern (patterns are few).
cleanup_find_files() {
    local root="$1" age="$2" min_size="$3"
    local -a pats=()
    local pat
    IFS=',' read -r -a pats <<< "$CLEANUP_INCLUDE_PATTERNS" || true
    for pat in "${pats[@]}"; do
        pat="$(trim "$pat")"
        [[ -z "$pat" ]] && continue
        local -a args=(find "$root" -xdev -type f -name "$pat")
        if (( age > 0 )); then
            args+=(-mtime "+$age")
        fi
        if (( min_size > 0 )); then
            args+=("-size" "+${min_size}c")
        fi
        args+=(-print0)
        # errors (permission denied etc.) are expected and ignored
        "${args[@]}" 2>/dev/null || true
    done
    return 0
}

# Collect disposable cache directories (pruned: no descent into matches).
cleanup_find_cache_dirs() {
    local root="$1" depth="$2" age="$3"
    local -a names=()
    local n
    for n in $CLEANUP_CACHE_DIR_NAMES; do
        if [[ "$n" == "node_modules" && "${CLEANUP_KEEP_NODE_MODULES:-0}" == "1" ]]; then
            continue
        fi
        names+=("$n")
    done
    if (( ${#names[@]} == 0 )); then
        return 0
    fi
    local -a args=(find "$root" -xdev -type d -maxdepth "$depth" \( -name "${names[0]}")
    local i
    for (( i = 1; i < ${#names[@]}; i++ )); do
        args+=(-o -name "${names[$i]}")
    done
    args+=( \) )
    if (( age > 0 )); then
        # age filter applies to the directory mtime (best-effort heuristic)
        args+=(-mtime "+$age")
    fi
    args+=(-prune -print)
    "${args[@]}" 2>/dev/null || true
    return 0
}

# Bytes of a candidate: for directories use du, for files use GNU stat with
# a BSD stat fallback, finally du as last resort.
cleanup_candidate_bytes() {
    local p="$1"
    if [[ -d "$p" ]]; then
        du_bytes "$p" 2>/dev/null || echo 0
        return 0
    fi
    local s=""
    if s="$(stat -c '%s' -- "$p" 2>/dev/null)" && is_uint "$s"; then
        printf '%s' "$s"
        return 0
    fi
    if s="$(stat -f '%z' -- "$p" 2>/dev/null)" && is_uint "$s"; then
        printf '%s' "$s"
        return 0
    fi
    du_bytes "$p" 2>/dev/null || echo 0
    return 0
}

cleanup_usage_line() {
    # one human-readable candidate row
    local action="$1" path="$2" bytes="$3" age_days="$4" kind="$5"
    printf '  %-7s %-58s %10s %5sd  %s\n' \
        "$action" "$(truncate_mid "$path" 58)" \
        "$(human_size "$bytes" 2>/dev/null || echo '?')" \
        "$age_days" "$kind"
    return 0
}

cmd_cleanup() {
    local -a user_roots=()
    local apply=0 older="" min_size=0 max_depth="$CLEANUP_MAX_DEPTH"
    local no_caches=0 json=0
    CLEANUP_KEEP_NODE_MODULES=0

    while (( $# > 0 )); do
        case "$1" in
            --apply)        apply=1; shift ;;
            -y|--yes)       OPT_YES=1; shift ;;
            --older-than)   [[ $# -ge 2 ]] || { error "--older-than needs a value"; return 2; }
                            older="$2"; shift 2 ;;
            --older-than=*) older="${1#*=}"; shift ;;
            --include)      [[ $# -ge 2 ]] || { error "--include needs a value"; return 2; }
                            CLEANUP_INCLUDE_PATTERNS="$2"; shift 2 ;;
            --include=*)    CLEANUP_INCLUDE_PATTERNS="${1#*=}"; shift ;;
            --no-caches)    no_caches=1; shift ;;
            --keep-node-modules) CLEANUP_KEEP_NODE_MODULES=1; shift ;;
            --min-size)     [[ $# -ge 2 ]] || { error "--min-size needs a value"; return 2; }
                            min_size="$2"; shift 2 ;;
            --min-size=*)   min_size="${1#*=}"; shift ;;
            --max-depth)    [[ $# -ge 2 ]] || { error "--max-depth needs a value"; return 2; }
                            max_depth="$2"; shift 2 ;;
            --max-depth=*)  max_depth="${1#*=}"; shift ;;
            --json)         json=1; shift ;;
            -h|--help)      cleanup_usage; return 0 ;;
            --)             shift; user_roots+=("$@"); break ;;
            -*)             error "cleanup: unknown option: $1"; return 2 ;;
            *)              user_roots+=("$1"); shift ;;
        esac
    done

    # ---- defaults & validation ---------------------------------------------
    if [[ -z "${CLEANUP_INCLUDE_PATTERNS:-}" ]]; then
        CLEANUP_INCLUDE_PATTERNS="$(cfg CLEANUP_INCLUDE_PATTERNS "$CLEANUP_DEFAULT_INCLUDE")"
    fi
    if ! is_uint "$older"; then
        older="$(cfg_int CLEANUP_OLDER_THAN "$CLEANUP_DEFAULT_AGE")"
    fi
    if ! is_uint "$min_size"; then
        min_size=0
    fi
    if ! is_uint "$max_depth" || (( max_depth < 1 )); then
        max_depth="$CLEANUP_MAX_DEPTH"
    fi

    CLEANUP_ROOTS=()
    if (( ${#user_roots[@]} > 0 )); then
        local r
        for r in "${user_roots[@]}"; do
            if [[ ! -d "$r" ]]; then
                error "cleanup: not a directory: $r"
                return 2
            fi
            CLEANUP_ROOTS+=("$(abspath "$r")")
        done
    else
        # default roots: tmp dirs plus the user cache dir, when present
        CLEANUP_ROOTS=("/tmp" "/var/tmp")
        local xdg="${XDG_CACHE_HOME:-$HOME/.cache}"
        if [[ -n "${HOME:-}" && -d "$xdg" ]]; then
            CLEANUP_ROOTS+=("$xdg")
        fi
    fi

    # refuse obviously dangerous root configurations
    local rr
    for rr in "${CLEANUP_ROOTS[@]}"; do
        case "$rr" in
            /|/bin|/boot|/dev|/etc|/lib|/lib64|/proc|/sys|/usr|/var|/sbin)
                error "cleanup: refusing to scan system root '$rr' (pick subdirectories)"
                return 2
                ;;
        esac
    done

    # ---- collect candidates --------------------------------------------------
    local -a cands=()
    local -a kinds=()
    declare -A seen=()
    local root out path
    for root in "${CLEANUP_ROOTS[@]}"; do
        while IFS= read -r -d '' out; do
            path="$(abspath "$out")"
            cleanup_candidate_ok "$path" || continue
            [[ -n "${seen[$path]:-}" ]] && continue
            seen["$path"]=1
            if [[ -d "$path" ]]; then
                cands+=("$path"); kinds+=("cache-dir")
            else
                cands+=("$path"); kinds+=("file")
            fi
        done < <(
            cleanup_find_files "$root" "$older" "$min_size"
            if (( no_caches != 1 )); then
                cleanup_find_cache_dirs "$root" "$max_depth" "$older"
            fi
        )
    done

    if (( ${#cands[@]} == 0 )); then
        if (( json == 1 )); then
            say '{"roots": [], "candidates": [], "total_bytes": 0, "mode": "dry-run"}'
        else
            say "no cleanup candidates under: ${CLEANUP_ROOTS[*]}"
        fi
        return 0
    fi

    # ---- sizes & ages ----------------------------------------------------------
    local -a sizes=() ages=()
    local c total_bytes=0
    for c in "${cands[@]}"; do
        local b a
        b="$(cleanup_candidate_bytes "$c")"
        a="$(file_age_days "$c" 2>/dev/null || echo 0)"
        sizes+=("$b")
        ages+=("$a")
        total_bytes=$(( total_bytes + b ))
    done

    # ---- output -----------------------------------------------------------------
    if (( json == 1 )); then
        local i
        say "{"
        say "  \"mode\": \"$( (( apply == 1 )) && echo apply || echo dry-run)\","
        printf '  "roots": ['
        for i in "${!CLEANUP_ROOTS[@]}"; do
            (( i > 0 )) && printf ', '
            printf '"%s"' "$(json_escape "${CLEANUP_ROOTS[$i]}")"
        done
        printf '],\n'
        say "  \"total_bytes\": $total_bytes,"
        say "  \"candidates\": ["
        local shown=0
        for i in "${!cands[@]}"; do
            (( shown > 0 )) && say ","
            shown=$(( shown + 1 ))
            printf '    {"path": "%s", "bytes": %s, "age_days": %s, "kind": "%s"}' \
                "$(json_escape "${cands[$i]}")" "${sizes[$i]}" "${ages[$i]}" "${kinds[$i]}"
        done
        say ""
        say "  ]"
        say "}"
    else
        section "Cleanup candidates ($( (( apply == 1 )) && echo APPLY || echo dry-run))"
        printf '  %-7s %-58s %10s %6s  %s\n' "ACTION" "PATH" "SIZE" "AGE" "KIND"
        local shown=0 i
        for i in "${!cands[@]}"; do
            if (( shown >= CLEANUP_MAX_LIST )); then
                say "  ... ($(( ${#cands[@]} - shown )) more candidates not shown)"
                break
            fi
            cleanup_usage_line "delete" "${cands[$i]}" "${sizes[$i]}" "${ages[$i]}" "${kinds[$i]}"
            shown=$(( shown + 1 ))
        done
        say ""
        say "  total: ${#cands[@]} candidate(s), $(human_size "$total_bytes") reclaimable"
        say "  roots: ${CLEANUP_ROOTS[*]}"
        if (( apply != 1 )); then
            say "  (dry-run: nothing deleted; add --apply to delete)"
        fi
    fi

    # ---- apply --------------------------------------------------------------------
    if (( apply != 1 )); then
        return 0
    fi
    if ! confirm "Delete ${#cands[@]} candidate(s) ($(human_size "$total_bytes"))?"; then
        warn "cleanup: aborted (nothing deleted)"
        return 0
    fi

    local failures=0 freed=0
    local i
    for i in "${!cands[@]}"; do
        c="${cands[$i]}"
        # re-validate every candidate immediately before removal
        if ! cleanup_candidate_ok "$c"; then
            warn "cleanup: skipped suspicious candidate: $c"
            failures=$(( failures + 1 ))
            continue
        fi
        if [[ -d "$c" ]]; then
            rm -rf -- "$c" 2>/dev/null || { error "cleanup: failed to remove dir: $c"; failures=$(( failures + 1 )); continue; }
        else
            rm -f -- "$c" 2>/dev/null || { error "cleanup: failed to remove file: $c"; failures=$(( failures + 1 )); continue; }
        fi
        debug "removed: $c"
        freed=$(( freed + ${sizes[$i]} ))
    done
    say "cleanup done: ${#cands[@]} candidate(s), $(human_size "$freed") freed, $failures failure(s)"
    if (( failures > 0 )); then
        return 3
    fi
    return 0
}
