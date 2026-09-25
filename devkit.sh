#!/usr/bin/env bash
# shellcheck shell=bash
#
# shell-devkit — a library of handy shell functions for daily dev work.
# Source it in your shell:   source devkit.sh
# Or run a command:          ./devkit.sh backup ~/project

set -euo pipefail

# --- colors -----------------------------------------------------------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'

info()  { printf '%s[info]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$c_ylw" "$c_rst" "$*"; }
err()   { printf '%s[err ]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }

# --- backup: timestamped copy of a file or directory ------------------
backup() {
    local target="${1:?usage: backup <path>}"
    [[ -e "$target" ]] || { err "khong ton tai: $target"; return 1; }
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    local dest="${target}.bak-${stamp}"
    cp -r "$target" "$dest"
    info "da sao luu -> $dest"
}

# --- http_status: print the HTTP status code of a URL -----------------
http_status() {
    local url="${1:?usage: http_status <url>}"
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url"
}

# --- rand_password: generate a random password ------------------------
rand_password() {
    local length="${1:-16}"
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "$length"; echo
}

# --- disk_alert: warn when disk usage exceeds a threshold -------------
disk_alert() {
    local threshold="${1:-80}"
    df -P / | awk 'NR==2 {gsub("%","",$5); print $5}' | {
        read -r usage
        if (( usage >= threshold )); then
            warn "dung luong dia ${usage}% (>= ${threshold}%)"
        else
            info "dung luong dia ${usage}% — OK"
        fi
    }
}

# --- mkcd: mkdir + cd --------------------------------------------------
mkcd() {
    local dir="${1:?usage: mkcd <dir>}"
    mkdir -p "$dir" && cd "$dir"
}

# --- largest_files: top N largest files under a directory -------------
largest_files() {
    local dir="${1:-.}" count="${2:-10}"
    du -ah "$dir" 2>/dev/null | sort -rh | head -n "$count"
}

# --- stopwatch: simple elapsed-time timer ------------------------------
stopwatch() {
    local start; start=$(date +%s)
    info "bat dau bam gio... (Ctrl+C de ket thuc)"
    trap 'echo; info "tong thoi gian: $(( $(date +%s) - start ))s"; trap - INT; return' INT
    while true; do
        printf '\r%s giay...' "$(( $(date +%s) - start ))"
        sleep 1
    done
}

# --- git branch info ---------------------------------------------------
git_summary() {
    command -v git >/dev/null || { err "git chua duoc cai dat"; return 1; }
    local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || {
        warn "khong nam trong git repository"; return 1
    }
    local dirty; dirty=$(git status --porcelain | wc -l | tr -d ' ')
    info "branch: ${c_blu}${branch}${c_rst} | thay doi chua commit: ${dirty}"
}

# --- CLI dispatcher ----------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"
    shift || true
    case "$cmd" in
        backup)        backup "$@" ;;
        http_status)   http_status "$@" ;;
        rand_password) rand_password "$@" ;;
        disk_alert)    disk_alert "$@" ;;
        mkcd)          mkcd "$@" ;;
        largest_files) largest_files "$@" ;;
        stopwatch)     stopwatch ;;
        git_summary)   git_summary ;;
        help|*)
            cat <<'EOF'
shell-devkit — bo cong cu shell tien ich
Cach dung: ./devkit.sh <lenh> [tham so]
  backup <path>            sao luu co thoi gian
  http_status <url>        in ma HTTP cua mot URL
  rand_password [len]      tao mat khau ngau nhien (mac dinh 16)
  disk_alert [nguong]      canh bao dia day (mac dinh 80%)
  largest_files [dir] [n]  tim file lon nhat
  git_summary              thong tin nhanh ve git branch hien tai
  stopwatch                bam gio don gian
EOF
            ;;
    esac
fi
