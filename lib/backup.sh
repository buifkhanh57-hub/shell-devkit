#!/usr/bin/env bash
# =============================================================================
# backup.sh -- `sysops backup`: tar+gzip backups with rotation and verify
#
# Creates a timestamped archive  <dest>/<name>-YYYYmmdd-HHMMSS.tar.gz  from
# one or more source paths, optionally verifies it (gzip -t + tar -tf +
# sha256 sidecar), then rotates old archives keeping the newest N.
#
# Safety model:
#   * --dry-run prints the exact plan (archive name, rotation list) and
#     creates/removes nothing
#   * deletion during rotation only ever touches files matching
#     "<name>-*.tar.gz" inside the destination directory plus their .sha256
#     sidecars -- user data with other names is never removed
#   * tar is invoked through an argument array; no shell string building
# =============================================================================
BACKUP_DEFAULT_KEEP=5
BACKUP_DEFAULT_GZIP=6

backup_usage() {
    cat <<'EOF'
sysops backup -- create tar.gz backups with rotation and verification

USAGE
  sysops backup [OPTIONS] SRC...

OPTIONS
  -d, --dest DIR          Destination directory (required unless
                          BACKUP_DEST is set in the config file)
  -n, --name NAME         Archive basename (default: "backup")
  -k, --keep N            Keep N newest archives after rotation
                          (default: 5, config: BACKUP_KEEP)
  -e, --excludes FILE     Pass FILE to tar as --exclude-from (one pattern
                          per line)
  -x, --exclude PAT       Add one --exclude pattern (repeatable)
  -g, --gzip N            gzip level 1-9 (default: 6, config: BACKUP_GZIP)
  --verify                Verify the archive after creation (gzip -t +
                          tar -tf + sha256 sidecar when sha256sum exists)
  --dry-run               Print the plan, change nothing
  --stamp STRING          Override the timestamp part of the archive name
                          (useful for reproducible tests / scripted runs)
  --list [DIR] [NAME]     List existing backups in DIR matching NAME
  -h, --help              Show this help

EXIT CODES
  0  backup created (and verified, if requested)
  1  verification failed
  2  usage error / bad paths
  3  archive creation failed
  4  another backup into the same destination is already running

EXAMPLES
  sysops backup -d /var/backups/app -n app -k 7 /etc/app /var/lib/app
  sysops backup -d /tmp/bk --exclude '*.log' --verify ~/notes
  sysops backup -d /tmp/bk --dry-run ~/notes        # show the plan first
EOF
}

_backup_validate_gzip_level() {
    [[ "${1:-}" =~ ^[1-9]$ ]]
}

# _backup_list_archives DIR NAME -> prints matching archives, oldest first
_backup_list_archives() {
    local dir="$1" name="$2"
    local -a found=()
    mapfile -t -d '' found < <(find "$dir" -maxdepth 1 -type f -name "${name}-*.tar.gz" -print0 2>/dev/null | sort -z || true)
    local f
    for f in "${found[@]}"; do
        printf '%s\0' "$f"
    done
    return 0
}

# _backup_plan_summary -- print what a real run would do (dry-run mode)
_backup_plan_summary() {
    local archive="$1" keep="$2" dest="$3" name="$4" level="$5"
    local -a sources=("${@:6}")
    local src
    say "dry-run plan for backup:"
    say "  archive          : $archive"
    say "  destination      : $dest"
    say "  name             : $name"
    say "  gzip level       : $level"
    say "  keep (rotation)  : $keep"
    say "  verify           : $([[ "${OPT_VERIFY:-0}" == 1 ]] && echo yes || echo no)"
    if [[ -n "${BACKUP_EXCLUDES_FILE:-}" ]]; then
        say "  excludes file    : $BACKUP_EXCLUDES_FILE"
    fi
    if (( ${#BACKUP_EXCLUDES[@]} > 0 )); then
        local p
        for p in "${BACKUP_EXCLUDES[@]}"; do
            say "  exclude pattern  : $p"
        done
    fi
    say "  sources:"
    for src in "${sources[@]}"; do
        local bytes
        bytes="$(du_bytes "$src" 2>/dev/null || echo 0)"
        say "    - $src ($(human_size "$bytes" 2>/dev/null || echo '?'))"
    done
    # rotation preview: which archives would be removed
    local -a existing=()
    mapfile -t -d '' existing < <(_backup_list_archives "$dest" "$name") || true
    if (( ${#existing[@]} >= keep )); then
        local excess=$(( ${#existing[@]} + 1 - keep ))
        local i
        say "  rotation would remove:"
        for (( i = 0; i < excess && i < ${#existing[@]}; i++ )); do
            say "    - ${existing[$i]}"
        done
    fi
    return 0
}

cmd_backup() {
    local dest="" name="backup" keep="" level=""
    local -a sources=()
    local -a BACKUP_EXCLUDES=()
    local BACKUP_EXCLUDES_FILE=""
    local OPT_VERIFY=0
    local BACKUP_STAMP=""
    local do_list="" list_dir="" list_name=""

    while (( $# > 0 )); do
        case "$1" in
            -d|--dest)   [[ $# -ge 2 ]] || { error "--dest needs a value"; return 2; }
                         dest="$2"; shift 2 ;;
            --dest=*)    dest="${1#*=}"; shift ;;
            -n|--name)   [[ $# -ge 2 ]] || { error "--name needs a value"; return 2; }
                         name="$2"; shift 2 ;;
            --name=*)    name="${1#*=}"; shift ;;
            -k|--keep)   [[ $# -ge 2 ]] || { error "--keep needs a value"; return 2; }
                         keep="$2"; shift 2 ;;
            --keep=*)    keep="${1#*=}"; shift ;;
            -e|--excludes) [[ $# -ge 2 ]] || { error "--excludes needs a value"; return 2; }
                         BACKUP_EXCLUDES_FILE="$2"; shift 2 ;;
            --excludes=*) BACKUP_EXCLUDES_FILE="${1#*=}"; shift ;;
            -x|--exclude) [[ $# -ge 2 ]] || { error "--exclude needs a value"; return 2; }
                         BACKUP_EXCLUDES+=("$2"); shift 2 ;;
            --exclude=*) BACKUP_EXCLUDES+=("${1#*=}"); shift ;;
            -g|--gzip)   [[ $# -ge 2 ]] || { error "--gzip needs a value"; return 2; }
                         level="$2"; shift 2 ;;
            --gzip=*)    level="${1#*=}"; shift ;;
            --verify)    OPT_VERIFY=1; shift ;;
            --no-verify) OPT_VERIFY=0; shift ;;
            --dry-run)   OPT_DRY_RUN=1; shift ;;
            --stamp)     [[ $# -ge 2 ]] || { error "--stamp needs a value"; return 2; }
                         BACKUP_STAMP="$2"; shift 2 ;;
            --stamp=*)   BACKUP_STAMP="${1#*=}"; shift ;;
            --list)      do_list=1
                         if [[ $# -ge 2 && "$2" != -* ]]; then list_dir="$2"; shift; fi
                         if [[ $# -ge 2 && "$2" != -* ]]; then list_name="$2"; shift; fi
                         shift ;;
            -h|--help)   backup_usage; return 0 ;;
            --)          shift; sources+=("$@"); break ;;
            -*)          error "backup: unknown option: $1"; return 2 ;;
            *)           sources+=("$1"); shift ;;
        esac
    done

    # ---- list mode ---------------------------------------------------------
    if [[ -n "$do_list" ]]; then
        list_dir="${list_dir:-$(cfg BACKUP_DEST "")}"
        if [[ -z "$list_dir" || ! -d "$list_dir" ]]; then
            error "backup --list: directory '$list_dir' does not exist"
            return 2
        fi
        list_name="${list_name:-backup}"
        local -a archives=()
        mapfile -t -d '' archives < <(_backup_list_archives "$list_dir" "$list_name") || true
        if (( ${#archives[@]} == 0 )); then
            say "(no archives matching ${list_name}-*.tar.gz in $list_dir)"
            return 0
        fi
        printf '%-42s %12s\n' "ARCHIVE" "SIZE"
        local a
        for a in "${archives[@]}"; do
            printf '%-42s %12s\n' "$(basename -- "$a")" "$(human_size "$(du_bytes "$a")")"
        done
        return 0
    fi

    # ---- validate inputs ---------------------------------------------------
    if (( ${#sources[@]} == 0 )); then
        error "backup: at least one source path is required"
        return 2
    fi
    if [[ -z "$dest" ]]; then
        dest="$(cfg BACKUP_DEST "")"
    fi
    if [[ -z "$dest" ]]; then
        error "backup: destination required (-d/--dest or BACKUP_DEST in config)"
        return 2
    fi
    if ! is_uint "$keep" || (( keep < 1 )); then
        keep="$(cfg_int BACKUP_KEEP "$BACKUP_DEFAULT_KEEP")"
    fi
    if ! _backup_validate_gzip_level "$level"; then
        level="$(cfg_int BACKUP_GZIP "$BACKUP_DEFAULT_GZIP")"
        if ! _backup_validate_gzip_level "$level"; then
            level="$BACKUP_DEFAULT_GZIP"
        fi
    fi
    if [[ -n "$BACKUP_EXCLUDES_FILE" && ! -r "$BACKUP_EXCLUDES_FILE" ]]; then
        error "backup: excludes file not readable: $BACKUP_EXCLUDES_FILE"
        return 2
    fi
    local src
    for src in "${sources[@]}"; do
        if [[ ! -e "$src" ]]; then
            error "backup: source does not exist: $src"
            return 2
        fi
    done
    if ! require_cmd tar "tar is the core of the backup module"; then
        return 3
    fi

    if [[ -n "${BACKUP_STAMP:-}" ]]; then
        if [[ ! "$BACKUP_STAMP" =~ ^[A-Za-z0-9._-]+$ ]]; then
            error "backup: --stamp must match [A-Za-z0-9._-]+ (got '$BACKUP_STAMP')"
            return 2
        fi
    else
        BACKUP_STAMP="$(now_stamp)"
    fi

    dest="${dest%/}"
    local archive="${dest}/${name}-${BACKUP_STAMP}.tar.gz"

    # ---- dry run (before touching anything on disk) -------------------------
    if [[ "${OPT_DRY_RUN:-0}" == "1" ]]; then
        _backup_plan_summary "$archive" "$keep" "$dest" "$name" "$level" "${sources[@]}"
        return 0
    fi

    if ! mkdir -p -- "$dest"; then
        error "backup: cannot create destination directory: $dest"
        return 2
    fi

    # ---- exclusive lock per destination -------------------------------------
    if ! acquire_lock "${dest}/.sysops-backup.lock" "backup into $dest"; then
        return 4
    fi
    trap "release_lock" EXIT

    # ---- build tar argument array -------------------------------------------
    local -a tar_cmd=(tar --create "--use-compress-program=gzip -$level" "--file=$archive")
    local p
    for p in "${BACKUP_EXCLUDES[@]}"; do
        tar_cmd+=("--exclude=$p")
    done
    if [[ -n "$BACKUP_EXCLUDES_FILE" ]]; then
        tar_cmd+=("--exclude-from=$BACKUP_EXCLUDES_FILE")
    fi
    for src in "${sources[@]}"; do
        local sdir sbase
        sdir="$(dirname -- "$src")"
        sbase="$(basename -- "$src")"
        tar_cmd+=(-C "$sdir" "$sbase")
    done

    info "creating archive: $archive"
    local rc=0
    "${tar_cmd[@]}" || rc=$?
    if (( rc >= 2 )); then
        error "backup: tar failed (rc=$rc), removing partial archive"
        rm -f -- "$archive" 2>/dev/null || true
        return 3
    fi
    if (( rc == 1 )); then
        warn "backup: some files changed while archiving (tar rc=1) -- archive kept"
    fi
    if [[ ! -s "$archive" ]]; then
        error "backup: archive is empty, removing"
        rm -f -- "$archive" 2>/dev/null || true
        return 3
    fi

    # ---- verify --------------------------------------------------------------
    if [[ "$OPT_VERIFY" == "1" ]]; then
        info "verifying archive integrity"
        if ! gzip -t "$archive" 2>/dev/null; then
            error "backup: gzip integrity check failed for $archive"
            return 1
        fi
        local n_entries=0
        n_entries="$(tar -tzf "$archive" 2>/dev/null | wc -l || true)"
        if ! is_uint "$n_entries" || (( n_entries < 1 )); then
            error "backup: tar listing failed for $archive"
            return 1
        fi
        if have_cmd sha256sum; then
            local sum_file="${archive}.sha256"
            if sha256sum "$archive" > "$sum_file" 2>/dev/null; then
                debug "wrote checksum sidecar: $sum_file"
            else
                rm -f -- "$sum_file" 2>/dev/null || true
                warn "backup: could not write sha256 sidecar (continuing)"
            fi
        fi
        info "verified: $n_entries entries"
    fi

    # ---- rotate ---------------------------------------------------------------
    local -a existing=()
    mapfile -t -d '' existing < <(_backup_list_archives "$dest" "$name") || true
    local removed=0
    while (( ${#existing[@]} > keep )); do
        local oldest="${existing[0]}"
        if [[ -f "$oldest" ]]; then
            info "rotating (keep=$keep): removing $(basename -- "$oldest")"
            rm -f -- "$oldest" 2>/dev/null || true
            rm -f -- "${oldest%.tar.gz}.tar.gz.sha256" 2>/dev/null || true
            removed=$(( removed + 1 ))
        fi
        existing=("${existing[@]:1}")
    done

    # ---- summary ----------------------------------------------------------------
    local total=0
    total="$(du_bytes "$archive")"
    say "backup OK: $(basename -- "$archive") ($(human_size "$total"), gzip -$level)"
    if [[ "$OPT_VERIFY" == "1" ]]; then
        say "verify OK: gzip + tar listing passed"
    fi
    say "archives kept: ${#existing[@]} (removed during rotation: $removed)"
    return 0
}
