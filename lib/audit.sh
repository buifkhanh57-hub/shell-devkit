#!/usr/bin/env bash
# =============================================================================
# audit.sh -- `sysops audit`: security quick-audit
#
# Checks (individually selectable, all by default):
#   users      accounts with empty/missing passwords, extra UID-0 accounts
#   sudo       members of sudo-style groups (sudo, wheel, admin)
#   writable   world-writable files in PATH directories and world-writable
#              directories (without the sticky bit)
#   homes      home directories above a size threshold
#   suid       SUID binaries, flagging ones outside a well-known allowlist
#   ssh        permissive permissions on private SSH keys / .ssh dirs
#   sysctl     hardening-relevant kernel tunables (kptr, dmesg, ASLR, ...)
#   sshd       risky directives in /etc/ssh/sshd_config (effective values)
#
# Findings are printed with severities and summarised at the end.
# Exit codes: 0 no findings, 1 medium/low only, 2 at least one HIGH,
#             3 internal error.
# Everything is strictly read-only.
# =============================================================================

AUDIT_SUID_ALLOW="sudo su passwd chsh chfn newgrp mount umount gpasswd chage \
pkexec fusermount fusermount3 sg crontab at staprun unix_chkpwd ssh-keysign \
pam_timestamp_check mount.nfs skeyinit uulog"

audit_usage() {
    cat <<'EOF'
sysops audit -- read-only security quick-audit

USAGE
  sysops audit [OPTIONS] [CHECKS...]

CHECKS
  users sudo writable homes suid ssh sysctl sshd     (default: all)

OPTIONS
  --home-threshold MB   Report home dirs larger than MB megabytes
                        (default: 500, config: AUDIT_HOME_THRESHOLD_MB)
  --max-list N          Maximum items listed per check (default: 20)
  --json                Emit findings as one JSON object (stdout)
  -h, --help            Show this help

SEVERITIES
  HIGH  urgent, fix today      MED  should be reviewed
  LOW   informational risk     INFO context, no action needed

EXIT CODES
  0  no findings          1  only LOW/MED findings
  2  at least one HIGH    3  internal error

EXAMPLES
  sysops audit                      # everything
  sysops audit writable suid        # only two checks
  sysops audit sysctl sshd          # kernel + sshd hardening
  sysops audit --json               # feed to a dashboard
EOF
}

# --- finding collector -------------------------------------------------------
A_SEV=()
A_CODE=()
A_MSG=()

audit_finding() {
    # audit_finding SEVERITY CODE MESSAGE...
    local sev="$1" code="$2"; shift 2
    local msg="$*"
    A_SEV+=("$sev")
    A_CODE+=("$code")
    A_MSG+=("$msg")
    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        return 0
    fi
    local color="$C_RESET"
    case "$sev" in
        HIGH) color="$C_RED" ;;
        MED)  color="$C_YELLOW" ;;
        LOW)  color="$C_CYAN" ;;
        INFO) color="$C_BLUE" ;;
    esac
    printf '%s[%-4s]%s %-11s %s\n' "$color" "$sev" "$C_RESET" "$code" "$msg"
    return 0
}

audit_reset() {
    A_SEV=()
    A_CODE=()
    A_MSG=()
}

audit_count() {
    # audit_count SEVERITY -> number of findings with that severity
    local sev="$1" n=0 s
    for s in "${A_SEV[@]}"; do
        [[ "$s" == "$sev" ]] && n=$(( n + 1 ))
    done
    printf '%s' "$n"
    return 0
}

# _audit_limit LIST -> caps stdout to AUDIT_MAX_LIST items with a marker
_audit_cap() {
    local max_n="${1:-20}"
    if ! is_uint "$max_n" || (( max_n < 1 )); then
        max_n=20
    fi
    tail -n "$max_n"
}

# -----------------------------------------------------------------------------
# Check: users
# -----------------------------------------------------------------------------
_audit_users() {
    [[ -r /etc/passwd ]] || { error "audit: /etc/passwd unreadable"; return 3; }
    # shadow map (only when readable, i.e. usually root)
    declare -A shadow=()
    if [[ -r /etc/shadow ]]; then
        local sline suser shash
        while IFS=: read -r suser shash _; do
            [[ -n "$suser" ]] || continue
            shadow["$suser"]="$shash"
        done < /etc/shadow
    fi
    local have_shadow=0
    if [[ -r /etc/shadow ]]; then have_shadow=1; fi

    local line user pw uid gid gecos home shell hash status
    while IFS=: read -r user pw uid gid gecos home shell; do
        [[ -n "$user" ]] || continue
        # extra root-equivalent accounts
        if [[ "$uid" == "0" && "$user" != "root" ]]; then
            audit_finding HIGH "user-uid0" "account '$user' has UID 0 (root-equivalent)"
        fi
        # password state for accounts with a login shell
        case "$shell" in
            */nologin|*/false|/bin/sync) continue ;;
        esac
        hash=""
        if (( have_shadow == 1 )); then
            hash="${shadow[$user]:-}"
        elif [[ -n "$pw" && "$pw" != "x" && "$pw" != "*" ]]; then
            hash="$pw"   # old-style: hash directly in /etc/passwd
        fi
        if [[ -n "$hash" ]]; then
            case "$hash" in
                "") audit_finding HIGH "user-nopass" "account '$user' has an EMPTY password" ;;
                '!'|'!!'|'!'*) : ;;   # locked -- fine
                '*'|'x') : ;;        # no login via password -- fine
                '$'*) : ;;           # real hash -- fine
                *) audit_finding MED "user-crypt" "account '$user' has unexpected password field format" ;;
            esac
        elif (( have_shadow == 0 )); then
            # no shadow access: try passwd -S (works for root)
            if have_cmd passwd; then
                status="$(passwd -S "$user" 2>/dev/null | awk '{print $2}')"
                case "$status" in
                    NP) audit_finding HIGH "user-nopass" "account '$user' has NO password (passwd -S: NP)" ;;
                    L|LK) : ;;
                    P) : ;;
                    "") : ;;   # unknown user or query failed
                esac
            fi
        fi
    done < /etc/passwd
    return 0
}

# -----------------------------------------------------------------------------
# Check: sudo groups
# -----------------------------------------------------------------------------
_audit_sudo() {
    local group members_line member
    local -a groups=(sudo wheel admin)
    for group in "${groups[@]}"; do
        members_line="$(getent group "$group" 2>/dev/null || true)"
        if [[ -z "$members_line" ]] && [[ -r /etc/group ]]; then
            members_line="$(grep -h "^${group}:" /etc/group 2>/dev/null || true)"
        fi
        [[ -n "$members_line" ]] || continue
        local gid
        gid="$(printf '%s' "$members_line" | cut -d: -f3)"
        members_line="$(printf '%s' "$members_line" | cut -d: -f4)"
        local -a users=()
        IFS=',' read -r -a users <<< "$members_line" || true
        # also surface users whose primary group is the sudo group
        if [[ -r /etc/passwd && -n "$gid" ]]; then
            while IFS=: read -r user _ uid _ _ _ _; do
                if [[ "$uid" == "$gid" ]]; then
                    users+=("$user")
                fi
            done < /etc/passwd
        fi
        if (( ${#users[@]} > 0 )); then
            audit_finding INFO "sudo-members" "group '$group' (gid ${gid:-?}): ${users[*]}"
        fi
    done
    return 0
}

# -----------------------------------------------------------------------------
# Check: world-writable entries in PATH directories
# -----------------------------------------------------------------------------
_audit_writable() {
    local -a pdirs=()
    local d
    IFS=':' read -r -a pdirs <<< "$PATH" || true
    for d in "${pdirs[@]}"; do
        if [[ -z "$d" ]]; then
            audit_finding MED "path-empty" "PATH contains an empty element (means current directory)"
            continue
        fi
        [[ -d "$d" ]] || continue
        local -a wf=()
        mapfile -t wf < <(find "$d" -xdev -maxdepth 2 -type f -perm -0002 -print 2>/dev/null | _audit_cap "${AUDIT_MAX_LIST:-20}" || true)
        local f
        for f in "${wf[@]}"; do
            audit_finding HIGH "world-writable" "world-writable FILE in PATH: $f"
        done
        local -a wd=()
        mapfile -t wd < <(find "$d" -xdev -maxdepth 2 -type d -perm -0002 ! -perm -1000 -print 2>/dev/null | _audit_cap "${AUDIT_MAX_LIST:-20}" || true)
        for f in "${wd[@]}"; do
            audit_finding MED "world-writable-dir" "world-writable dir without sticky bit in PATH: $f"
        done
    done
    return 0
}

# -----------------------------------------------------------------------------
# Check: large home directories
# -----------------------------------------------------------------------------
_audit_homes() {
    local threshold="${AUDIT_HOME_THRESHOLD_MB:-}"
    if ! is_int "$threshold"; then
        threshold="$(cfg_int AUDIT_HOME_THRESHOLD_MB 500)"
    fi
    local -a homes=()
    local h
    if [[ -d /home ]]; then
        mapfile -t homes < <(find /home -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
    fi
    [[ -d /root ]] && homes+=("/root")
    local total_mb
    for h in "${homes[@]}"; do
        [[ -x "$h" || -r "$h" ]] || { audit_finding INFO "home-noaccess" "cannot measure $h (no permission)"; continue; }
        local bytes
        bytes="$(du_bytes "$h")" || bytes=0
        total_mb=$(( bytes / 1048576 ))
        if (( total_mb > threshold )); then
            audit_finding LOW "home-large" \
                "home directory $h is large: $(human_size "$bytes") (>${threshold} MB)"
        fi
    done
    return 0
}

# -----------------------------------------------------------------------------
# Check: SUID binaries
# -----------------------------------------------------------------------------
_audit_suid() {
    declare -A known=()
    local k
    for k in $AUDIT_SUID_ALLOW; do
        known["$k"]=1
    done
    local -a dirs=()
    local d
    for d in /usr /bin /sbin /lib /lib64 /opt /usr/local; do
        [[ -d "$d" ]] && dirs+=("$d")
    done
    declare -A reported=()
    local -a found=()
    for d in "${dirs[@]}"; do
        while IFS= read -r -d '' f; do
            found+=("$f")
        done < <(find "$d" -xdev -type f -perm -4000 -print0 2>/dev/null || true)
    done
    local f base
    for f in "${found[@]}"; do
        base="$(basename -- "$f")"
        if [[ -n "${reported[$f]:-}" ]]; then
            continue
        fi
        reported["$f"]=1
        if [[ -z "${known[$base]:-}" ]]; then
            audit_finding MED "suid-unknown" "unexpected SUID binary: $f"
        fi
    done
    if (( ${#found[@]} == 0 )); then
        audit_finding INFO "suid-none" "no SUID binaries found in ${dirs[*]}"
    else
        audit_finding INFO "suid-count" "${#found[@]} SUID binary/b binaries scanned in ${dirs[*]} (allowlist mismatches listed above)"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Check: SSH key permissions
# -----------------------------------------------------------------------------
_audit_ssh() {
    local -a homes=()
    local h
    [[ -d /root ]] && homes+=("/root")
    if [[ -d /home ]]; then
        while IFS= read -r h; do
            homes+=("$h")
        done < <(find /home -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
    fi
    local sshdir key mode
    for h in "${homes[@]}"; do
        sshdir="$h/.ssh"
        [[ -d "$sshdir" && -r "$sshdir" ]] || continue
        mode="$(stat -c '%a' "$sshdir" 2>/dev/null || stat -f '%Lp' "$sshdir" 2>/dev/null || echo "700")"
        case "$mode" in
            700|600|640|750|755) : ;;
            *) audit_finding MED "ssh-dir-perm" "$sshdir has permissive mode $mode (700 recommended)" ;;
        esac
        while IFS= read -r -d '' key; do
            case "$key" in
                *.pub) continue ;;
            esac
            mode="$(stat -c '%a' "$key" 2>/dev/null || stat -f '%Lp' "$key" 2>/dev/null || echo "600")"
            if ! [[ "$mode" =~ ^[0-7]00$ ]]; then
                audit_finding HIGH "ssh-key-perm" "private key readable by group/others: $key (mode $mode, use 600)"
            fi
        done < <(find "$sshdir" -maxdepth 1 -type f -name 'id_*' -print0 2>/dev/null || true)
        if [[ -f "$sshdir/authorized_keys" ]]; then
            mode="$(stat -c '%a' "$sshdir/authorized_keys" 2>/dev/null || echo "600")"
            case "$mode" in
                600|640) : ;;
                *) audit_finding MED "ssh-authkeys-perm" "authorized_keys mode $mode in $sshdir (600 recommended)" ;;
            esac
        fi
    done
    return 0
}

# -----------------------------------------------------------------------------
# Check: kernel sysctl hardening values
# -----------------------------------------------------------------------------
_audit_sysctl() {
    # each entry: proc-path|want-check-id
    local -a entries=(
        "kernel/kptr_restrict"
        "kernel/dmesg_restrict"
        "kernel/randomize_va_space"
        "kernel/unprivileged_bpf_disabled"
        "fs/suid_dumpable"
        "net/ipv4/conf/all/accept_redirects"
        "net/ipv4/conf/all/rp_filter"
    )
    local p val label
    for p in "${entries[@]}"; do
        label="${p//\//.}"
        if [[ -r "/proc/sys/$p" ]]; then
            val="$(< "/proc/sys/$p")"
            val="$(trim "$val")"
            is_uint "$val" || val=0
            case "$p" in
                kernel/kptr_restrict)
                    (( val >= 1 )) || audit_finding HIGH "sysctl-kptr" \
                        "$label=$val (>=1 recommended: hide kernel pointers)" ;;
                kernel/dmesg_restrict)
                    (( val >= 1 )) || audit_finding MED "sysctl-dmesg" \
                        "$label=$val (>=1 recommended: restrict dmesg to root)" ;;
                kernel/randomize_va_space)
                    [[ "$val" == "2" ]] || audit_finding MED "sysctl-aslr" \
                        "$label=$val (2 = full ASLR recommended)" ;;
                kernel/unprivileged_bpf_disabled)
                    [[ "$val" == "1" || "$val" == "2" ]] || audit_finding MED "sysctl-bpf" \
                        "$label=$val (1 or 2 recommended: unprivileged bpf())" ;;
                fs/suid_dumpable)
                    [[ "$val" == "0" ]] || audit_finding MED "sysctl-dumpable" \
                        "$label=$val (0 recommended: no suid core dumps)" ;;
                net/ipv4/conf/all/accept_redirects)
                    [[ "$val" == "0" ]] || audit_finding MED "sysctl-redirects" \
                        "$label=$val (0 recommended: ignore ICMP redirects)" ;;
                net/ipv4/conf/all/rp_filter)
                    (( val >= 1 )) || audit_finding LOW "sysctl-rpfilter" \
                        "$label=$val (>=1 recommended: reverse path filtering)" ;;
            esac
        else
            audit_finding INFO "sysctl-unread" "$label not exposed by this kernel"
        fi
    done
    return 0
}

# -----------------------------------------------------------------------------
# Check: sshd configuration directives (effective = last occurrence wins)
# -----------------------------------------------------------------------------
# _sshd_effective FILE KEY -> prints the effective value (rc 1 when unset)
_sshd_effective() {
    local file="$1" key="$2"
    local val=""
    val="$(awk -v k="$key" '
        $1 ~ /^[[:space:]]*#/ { next }
        tolower($1) == tolower(k) { v = $2 }
        END { if (v != "") print v }
    ' "$file" 2>/dev/null || true)"
    [[ -n "$val" ]] || return 1
    printf '%s' "$val"
    return 0
}

_audit_sshd() {
    local -a candidates=(/etc/ssh/sshd_config /etc/sshd_config)
    local cfg_path="" c
    for c in "${candidates[@]}"; do
        [[ -r "$c" ]] && { cfg_path="$c"; break; }
    done
    if [[ -z "$cfg_path" ]]; then
        audit_finding INFO "sshd-absent" "no readable sshd_config found (sshd likely not installed)"
        return 0
    fi
    audit_finding INFO "sshd-config" "checking $cfg_path"
    local v
    if v="$(_sshd_effective "$cfg_path" PermitRootLogin)"; then
        case "$v" in
            no|prohibit-password|without-password|forced-commands-only) : ;;
            yes) audit_finding HIGH "sshd-rootlogin" \
                     "PermitRootLogin yes in $cfg_path (use prohibit-password or no)" ;;
            *)   audit_finding MED "sshd-rootlogin" \
                     "PermitRootLogin '$v' in $cfg_path is not a known safe value" ;;
        esac
    fi
    if v="$(_sshd_effective "$cfg_path" PermitEmptyPasswords)"; then
        [[ "$v" == "no" ]] || audit_finding HIGH "sshd-emptypw" \
            "PermitEmptyPasswords $v in $cfg_path (must be no)"
    fi
    if v="$(_sshd_effective "$cfg_path" PasswordAuthentication)"; then
        [[ "$v" == "no" ]] || audit_finding MED "sshd-password" \
            "PasswordAuthentication $v in $cfg_path (keys-only auth recommended)"
    fi
    if v="$(_sshd_effective "$cfg_path" PubkeyAuthentication)"; then
        [[ "$v" == "yes" ]] || audit_finding MED "sshd-pubkey" \
            "PubkeyAuthentication $v in $cfg_path (key auth disabled)"
    fi
    if v="$(_sshd_effective "$cfg_path" X11Forwarding)"; then
        [[ "$v" == "yes" ]] && audit_finding LOW "sshd-x11" \
            "X11Forwarding yes in $cfg_path (disable on servers)"
    fi
    if v="$(_sshd_effective "$cfg_path" MaxAuthTries)"; then
        if is_uint "$v" && (( v > 6 )); then
            audit_finding LOW "sshd-authtries" \
                "MaxAuthTries $v in $cfg_path (>6 eases brute force)"
        fi
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Command entry point
# -----------------------------------------------------------------------------
cmd_audit() {
    local -a checks=()
    local max_list=20
    AUDIT_MAX_LIST="$max_list"

    while (( $# > 0 )); do
        case "$1" in
            users|sudo|writable|homes|suid|ssh|sysctl|sshd) checks+=("$1"); shift ;;
            all) checks=(users sudo writable homes suid ssh sysctl sshd); shift ;;
            --home-threshold) [[ $# -ge 2 ]] || { error "--home-threshold needs a value"; return 2; }
                        AUDIT_HOME_THRESHOLD_MB="$2"; shift 2 ;;
            --home-threshold=*) AUDIT_HOME_THRESHOLD_MB="${1#*=}"; shift ;;
            --max-list) [[ $# -ge 2 ]] || { error "--max-list needs a value"; return 2; }
                        max_list="$2"; AUDIT_MAX_LIST="$max_list"; shift 2 ;;
            --max-list=*) max_list="${1#*=}"; AUDIT_MAX_LIST="$max_list"; shift ;;
            --json) OPT_JSON=1; shift ;;
            -h|--help) audit_usage; return 0 ;;
            *) error "audit: unknown option: $1"; return 2 ;;
        esac
    done
    if ! is_uint "$AUDIT_MAX_LIST" ; then
        AUDIT_MAX_LIST=20
    fi
    if (( ${#checks[@]} == 0 )); then
        checks=(users sudo writable homes suid ssh sysctl sshd)
    fi

    audit_reset
    if [[ "${OPT_JSON:-0}" != "1" ]]; then
        printf '%ssysops audit v%s -- %s%s\n' "$C_BOLD" "$SYOPS_VERSION" "$(hostname_of)" "$C_RESET"
        printf '%s%s%s\n\n' "$C_DIM" "$(now_iso)" "$C_RESET"
    fi

    local c
    for c in "${checks[@]}"; do
        local rc=0
        case "$c" in
            users)    _audit_users    || rc=$? ;;
            sudo)     _audit_sudo     || rc=$? ;;
            writable) _audit_writable || rc=$? ;;
            homes)    _audit_homes    || rc=$? ;;
            suid)     _audit_suid     || rc=$? ;;
            ssh)      _audit_ssh      || rc=$? ;;
            sysctl)   _audit_sysctl   || rc=$? ;;
            sshd)     _audit_sshd     || rc=$? ;;
        esac
        if (( rc == 3 )); then
            return 3
        fi
    done

    if [[ "${OPT_JSON:-0}" == "1" ]]; then
        local i
        say "{"
        say "  \"generated\": \"$(json_escape "$(now_iso)")\","
        say "  \"hostname\": \"$(json_escape "$(hostname_of)")\","
        say "  \"findings\": ["
        for i in "${!A_SEV[@]}"; do
            (( i > 0 )) && say ","
            printf '    {"severity": "%s", "code": "%s", "message": "%s"}' \
                "$(json_escape "${A_SEV[$i]}")" \
                "$(json_escape "${A_CODE[$i]}")" \
                "$(json_escape "${A_MSG[$i]}")"
        done
        say ""
        say "  ],"
        say "  \"summary\": {"
        say "    \"high\": $(audit_count HIGH),"
        say "    \"med\": $(audit_count MED),"
        say "    \"low\": $(audit_count LOW),"
        say "    \"info\": $(audit_count INFO)"
        say "  }"
        say "}"
    else
        say ""
        local high med low info
        high="$(audit_count HIGH)"
        med="$(audit_count MED)"
        low="$(audit_count LOW)"
        info="$(audit_count INFO)"
        printf '%sSummary:%s HIGH=%s  MED=%s  LOW=%s  INFO=%s\n' \
            "$C_BOLD" "$C_RESET" "$high" "$med" "$low" "$info"
        if (( high > 0 )); then
            printf '%sAction required: fix HIGH findings first%s\n' "$C_RED" "$C_RESET"
        elif (( med > 0 )); then
            printf '%sReview recommended (MED findings present)%s\n' "$C_YELLOW" "$C_RESET"
        elif (( low > 0 || info > 0 )); then
            printf '%sNo urgent findings%s\n' "$C_GREEN" "$C_RESET"
        else
            printf '%sNothing to report%s\n' "$C_GREEN" "$C_RESET"
        fi
    fi

    if (( $(audit_count HIGH) > 0 )); then
        return 2
    fi
    if (( $(audit_count MED) > 0 )); then
        return 1
    fi
    return 0
}
