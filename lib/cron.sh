#!/usr/bin/env bash
# =============================================================================
# cron.sh -- `sysops cron`: marker-comment managed crontab entries
#
# sysops manages ONE clearly delimited block inside the user's crontab:
#
#   # BEGIN SYSOPS MANAGED BLOCK -- DO NOT EDIT BETWEEN MARKERS
#   */5 * * * * /usr/local/bin/sysops monitor -q # sysops:label=monitor
#   15 2 * * *   /usr/local/bin/sysops backup ... # sysops:label=nightly
#   # END SYSOPS MANAGED BLOCK
#
# Everything outside the markers belongs to the user and is never touched.
# Entries inside the block are identified by "sysops:label=NAME" tags.
# The crontab is re-written through a temp file (crontab FILE); crontab
# content is never passed through eval or composed into a shell command.
# =============================================================================
CRON_MARKER_BEGIN='# BEGIN SYSOPS MANAGED BLOCK -- DO NOT EDIT BETWEEN MARKERS'
CRON_MARKER_END='# END SYSOPS MANAGED BLOCK'
CRON_TAG_PREFIX='# sysops:label='

cron_usage() {
    cat <<'EOF'
sysops cron -- manage sysops entries inside the crontab (marker block)

USAGE
  sysops cron install --schedule S --command C --label L [--user U]
  sysops cron remove  (--label L | --all) [--user U]
  sysops cron list    [--user U]
  sysops cron raw     [--user U]
  sysops cron help

SUBCOMMANDS
  install   Add (or replace, same label) an entry inside the managed block.
            --schedule must be exactly 5 cron fields, e.g. "*/5 * * * *".
            --command is the full command line to run.
  remove    Remove the entry with --label L, or the whole block with --all.
  list      Show managed entries: index, label, schedule, command.
  raw       Print the managed block as it currently appears.

OPTIONS
  --user U       Edit another user's crontab (requires root)
  --dry-run      Show the resulting crontab without writing it
  -h, --help     Show this help

EXIT CODES
  0  success                 1  entry/block not found
  2  usage error             3  crontab read/write failure

EXAMPLES
  sysops cron install --schedule '*/5 * * * *' \
      --command '/usr/local/bin/sysops monitor -q' --label monitor
  sysops cron list
  sysops cron remove --label monitor
EOF
}

# --- schedule validation -----------------------------------------------------
_cron_field_ok() {
    # one cron field: '*', '*/n', 'a', 'a-b', 'a-b/n', comma lists of those
    local f="${1:-}"
    local -a parts=()
    local IFS=','
    read -r -a parts <<< "$f" || return 1
    local p
    for p in "${parts[@]}"; do
        [[ "$p" =~ ^(\*|[0-9]{1,4}(-[0-9]{1,4})?)(/[0-9]{1,4})?$ ]] || return 1
    done
    return 0
}

cron_validate_schedule() {
    # cron_validate_schedule "m h dom mon dow" -> rc 0 valid, 1 invalid
    local sched="${1:-}"
    local -a fields=()
    read -r -a fields <<< "$sched" || true
    if (( ${#fields[@]} != 5 )); then
        return 1
    fi
    local f
    for f in "${fields[@]}"; do
        _cron_field_ok "$f" || return 1
    done
    return 0
}

cron_validate_label() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

# --- crontab plumbing ---------------------------------------------------------
cron_read_crontab() {
    # prints the current crontab to stdout; rc 3 when unavailable
    # (CRON_READ_RC: 0 = crontab read, 1 = no crontab yet, 2+ = other error)
    local -a cmd=(crontab -l)
    if [[ -n "${CRON_USER:-}" ]]; then
        cmd=(crontab -u "$CRON_USER" -l)
    fi
    local out="" rc=0
    out="$("${cmd[@]}" 2>/dev/null)" || rc=$?
    case "$rc" in
        0) CRON_READ_RC=0
           printf '%s\n' "$out"
           return 0 ;;
        1) CRON_READ_RC=1    # "no crontab for user" -- a fresh install case
           printf '%s' ""
           return 3 ;;
        *) CRON_READ_RC="$rc"
           printf '%s' ""
           return 3 ;;
    esac
}

cron_write_crontab() {
    # cron_write_crontab FILE -> installs FILE as the new crontab
    local file="$1"
    if [[ -n "${CRON_USER:-}" ]] && [[ "$(id -u)" != "0" ]]; then
        error "cron: --user requires root"
        return 2
    fi
    if [[ -n "${CRON_USER:-}" ]]; then
        crontab -u "$CRON_USER" "$file" 2>/dev/null
    else
        crontab "$file" 2>/dev/null
    fi
}

# _cron_strip_block INPUT -> prints INPUT without the managed block,
# trimming a doubled trailing blank line.  INPUT is read from STDIN
# (feed it with a herestring: _cron_strip_block <<< "$text").
_cron_strip_block() {
    local in_block=0
    local line="" have_prev=0
    local __cron_prev=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$CRON_MARKER_BEGIN" ]]; then
            in_block=1
            continue
        fi
        if [[ "$line" == "$CRON_MARKER_END" ]]; then
            in_block=0
            continue
        fi
        if (( in_block )); then
            continue
        fi
        if (( have_prev )); then
            printf '%s\n' "$__cron_prev"
        fi
        __cron_prev="$line"
        have_prev=1
    done
    # drop one trailing blank line if present (block spacer)
    if (( have_prev )) && [[ -z "$__cron_prev" ]]; then
        :
    elif (( have_prev )); then
        printf '%s\n' "$__cron_prev"
    fi
    return 0
}

# _cron_extract_entries INPUT -> prints the entry lines inside the block.
# INPUT is read from STDIN (feed it with: _cron_extract_entries <<< "$text").
_cron_extract_entries() {
    local in_block=0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$CRON_MARKER_BEGIN" ]]; then in_block=1; continue; fi
        if [[ "$line" == "$CRON_MARKER_END" ]]; then in_block=0; continue; fi
        if (( in_block )) && [[ -n "$line" ]]; then
            printf '%s\n' "$line"
        fi
    done
    return 0
}

# cron_entry_label LINE -> prints the label (or nothing)
cron_entry_label() {
    local line="$1"
    if [[ "$line" == *"$CRON_TAG_PREFIX"* ]]; then
        local rest="${line##*"$CRON_TAG_PREFIX"}"
        printf '%s' "$rest"
        return 0
    fi
    return 1
}

# cron_entry_split LINE -> prints "SCHEDULE" then "COMMAND" (tag removed)
cron_entry_split() {
    local line="$1"
    local sched="" cmd=""
    if [[ "$line" == *"$CRON_TAG_PREFIX"* ]]; then
        line="${line%%"$CRON_TAG_PREFIX"*}"
        line="${line% }"
    fi
    sched="${line%% *}"
    cmd="${line#"$sched"}"
    cmd="${cmd# }"
    printf '%s\n%s' "$sched" "$cmd"
    return 0
}

# _cron_assemble USER_PART ENTRIES... -> prints the new crontab content
_cron_assemble() {
    local user_part="$1"; shift
    local -a entries=("$@")
    printf '%s' "$user_part"
    # make sure the user part ends with a newline
    if [[ -n "$user_part" && "${user_part: -1}" != $'\n' ]]; then
        printf '\n'
    fi
    printf '%s\n' "$CRON_MARKER_BEGIN"
    local e
    if (( ${#entries[@]} == 0 )); then
        printf '%s\n' "# (no sysops managed entries)"
    fi
    for e in "${entries[@]}"; do
        printf '%s\n' "$e"
    done
    printf '%s\n' "$CRON_MARKER_END"
    return 0
}

cmd_cron() {
    local action="${1:-help}"
    if (( $# > 0 )); then
        shift
    fi
    CRON_USER=""
    local label="" schedule="" command="" remove_all=0

    while (( $# > 0 )); do
        case "$1" in
            --label)    [[ $# -ge 2 ]] || { error "--label needs a value"; return 2; }
                        label="$2"; shift 2 ;;
            --label=*)  label="${1#*=}"; shift ;;
            --schedule) [[ $# -ge 2 ]] || { error "--schedule needs a value"; return 2; }
                        schedule="$2"; shift 2 ;;
            --schedule=*) schedule="${1#*=}"; shift ;;
            --command)  [[ $# -ge 2 ]] || { error "--command needs a value"; return 2; }
                        command="$2"; shift 2 ;;
            --command=*) command="${1#*=}"; shift ;;
            --all)      remove_all=1; shift ;;
            --user)     [[ $# -ge 2 ]] || { error "--user needs a value"; return 2; }
                        CRON_USER="$2"; shift 2 ;;
            --user=*)   CRON_USER="${1#*=}"; shift ;;
            --dry-run)  OPT_DRY_RUN=1; shift ;;
            -h|--help)  cron_usage; return 0 ;;
            *)          error "cron: unknown option: $1"; return 2 ;;
        esac
    done

    if ! have_cmd crontab; then
        error "cron: 'crontab' not found (install cron/cronie or use sudo)"
        return 3
    fi

    case "$action" in
        install)
            if [[ -z "$schedule" || -z "$command" || -z "$label" ]]; then
                error "cron install: --schedule, --command and --label are all required"
                return 2
            fi
            if ! cron_validate_schedule "$schedule"; then
                error "cron install: invalid schedule '$schedule' (5 fields: m h dom mon dow)"
                return 2
            fi
            if ! cron_validate_label "$label"; then
                error "cron install: invalid label '$label' (use [A-Za-z0-9._-])"
                return 2
            fi
            if [[ "$command" == *$'\n'* || "$command" == *$'\r'* ]]; then
                error "cron install: command must not contain newlines"
                return 2
            fi
            local crontab_text=""
            if ! crontab_text="$(cron_read_crontab)"; then
                if [[ "${CRON_READ_RC:-0}" != "0" ]]; then
                    warn "cron: no existing crontab; creating a new one"
                fi
            fi
            # rebuild entries: keep all except the label being replaced
            local -a entries=()
            local line elabel entry
            entry="${schedule} ${command} ${CRON_TAG_PREFIX}${label}"
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if elabel="$(cron_entry_label "$line")" && [[ "$elabel" == "$label" ]]; then
                    continue   # replaced below
                fi
                entries+=("$line")
            done < <(_cron_extract_entries <<< "$crontab_text")
            entries+=("$entry")
            local user_part
            user_part="$(_cron_strip_block <<< "$crontab_text")"
            local new_crontab
            new_crontab="$(_cron_assemble "$user_part" "${entries[@]}")"
            if [[ "${OPT_DRY_RUN:-0}" == "1" ]]; then
                say "--- dry-run: new crontab would be: ---"
                printf '%s\n' "$new_crontab"
                return 0
            fi
            local tmpf=""
            mktemp_sysops tmpf "sysops-cron.XXXXXX" || return 3
            printf '%s\n' "$new_crontab" > "$tmpf" || return 3
            if ! cron_write_crontab "$tmpf"; then
                error "cron: failed to install new crontab"
                return 3
            fi
            info "cron: installed entry '$label' ($schedule)"
            return 0
            ;;
        remove)
            local crontab_text=""
            if ! crontab_text="$(cron_read_crontab)"; then
                if [[ "${CRON_READ_RC:-0}" != "0" ]]; then
                    warn "cron: no existing crontab; nothing to remove"
                    return 1
                fi
            fi
            local -a old_entries=() new_entries=()
            mapfile -t old_entries < <(_cron_extract_entries <<< "$crontab_text")
            if (( ${#old_entries[@]} == 0 )); then
                warn "cron: no managed block found; nothing to remove"
                return 1
            fi
            local line elabel kept=0
            for line in "${old_entries[@]}"; do
                if [[ "$remove_all" == "1" ]]; then
                    continue
                fi
                if elabel="$(cron_entry_label "$line")" && [[ "$elabel" == "$label" ]]; then
                    continue
                fi
                new_entries+=("$line")
                kept=$(( kept + 1 ))
            done
            if [[ "$remove_all" != "1" ]]; then
                if (( kept == ${#old_entries[@]} )); then
                    warn "cron: label '$label' not found in managed block"
                    return 1
                fi
            fi
            local user_part
            user_part="$(_cron_strip_block <<< "$crontab_text")"
            local new_crontab
            new_crontab="$(_cron_assemble "$user_part" "${new_entries[@]}")"
            if [[ "${OPT_DRY_RUN:-0}" == "1" ]]; then
                say "--- dry-run: new crontab would be: ---"
                printf '%s\n' "$new_crontab"
                return 0
            fi
            local tmpf=""
            mktemp_sysops tmpf "sysops-cron.XXXXXX" || return 3
            printf '%s\n' "$new_crontab" > "$tmpf" || return 3
            if ! cron_write_crontab "$tmpf"; then
                error "cron: failed to install new crontab"
                return 3
            fi
            info "cron: removed entries ($kept remaining)"
            return 0
            ;;
        list)
            local crontab_text=""
            crontab_text="$(cron_read_crontab)" || true
            local -a entries=()
            mapfile -t entries < <(_cron_extract_entries <<< "$crontab_text")
            if (( ${#entries[@]} == 0 )); then
                say "(no sysops managed cron entries)"
                return 0
            fi
            printf '%-4s %-16s %-16s %s\n' "IDX" "LABEL" "SCHEDULE" "COMMAND"
            local i=0 line sched cmd elabel
            for line in "${entries[@]}"; do
                elabel="$(cron_entry_label "$line" || echo "-")"
                sched="$(cron_entry_split "$line" | head -n 1)"
                cmd="$(cron_entry_split "$line" | tail -n +2)"
                printf '%-4s %-16s %-16s %s\n' "$i" "$elabel" "$sched" "$(truncate_mid "$cmd" 60)"
                i=$(( i + 1 ))
            done
            return 0
            ;;
        raw)
            local crontab_text=""
            crontab_text="$(cron_read_crontab)" || true
            if ! grep -qF "$CRON_MARKER_BEGIN" <<< "$crontab_text"; then
                warn "cron: no managed block present"
                return 1
            fi
            local in_block=0 line
            while IFS= read -r line; do
                if [[ "$line" == "$CRON_MARKER_BEGIN" ]]; then in_block=1; fi
                if (( in_block )); then
                    printf '%s\n' "$line"
                fi
                if [[ "$line" == "$CRON_MARKER_END" ]]; then in_block=0; fi
            done <<< "$crontab_text"
            return 0
            ;;
        help|-h|--help)
            cron_usage
            return 0
            ;;
        *)
            error "cron: unknown action '$action' (see: sysops cron help)"
            return 2
            ;;
    esac
}
