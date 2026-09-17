#!/usr/bin/env bash
# Shared helpers: logging, OS detect, IP detect, PSK gen, config load.

set -u

: "${TUNN_ETC:=/etc/tunn-awg}"
: "${TUNN_LIB:=/opt/tunn-awg/lib}"
: "${TUNN_LOG:=/var/log/tunn-awg}"
: "${TUNN_STATE:=$TUNN_ETC/mode.state}"
: "${TUNN_CONFIG:=$TUNN_ETC/config.env}"
: "${TUNN_DB:=$TUNN_ETC/data.db}"

C_GREEN='\e[32m'; C_CYAN='\e[36m'; C_YELLOW='\e[33m'; C_RED='\e[31m'; C_NC='\e[0m'

log_info()  { printf "${C_CYAN}[INFO]${C_NC}  %s\n" "$*"; }
log_ok()    { printf "${C_GREEN}[OK]${C_NC}    %s\n" "$*"; }
log_warn()  { printf "${C_YELLOW}[WARN]${C_NC}  %s\n" "$*"; }
log_err()   { printf "${C_RED}[ERR]${C_NC}   %s\n" "$*" >&2; }
log_step()  { printf "\n${C_CYAN}==>${C_NC} ${C_YELLOW}%s${C_NC}\n" "$*"; }

die() { log_err "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Harus dijalankan sebagai root (gunakan sudo)."
}

detect_os() {
    [[ -r /etc/os-release ]] || die "OS tidak dikenali (tidak ada /etc/os-release)."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-0}"
    case "$OS_ID" in
        debian) [[ "$OS_VER" =~ ^(11|12)$ ]] || log_warn "Debian $OS_VER belum diuji." ;;
        ubuntu) [[ "$OS_VER" =~ ^(20.04|22.04|24.04)$ ]] || log_warn "Ubuntu $OS_VER belum diuji." ;;
        *)      die "OS $OS_ID tidak didukung. Gunakan Debian 11/12 atau Ubuntu 20.04/22.04/24.04." ;;
    esac
    export OS_ID OS_VER
}

detect_wan_iface() {
    ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

detect_public_ip() {
    local ip
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    printf "%s" "$ip"
}

gen_psk() { openssl rand -base64 32 | tr -d '\n=' | tr '+/' '-_'; }

gen_password() { openssl rand -base64 12 | tr -d '\n=+/' | cut -c1-14; }

# Load config safely without executing arbitrary code.
config_get() {
    local key="$1" file="${2:-$TUNN_CONFIG}"
    [[ -r "$file" ]] || return 1
    awk -F= -v k="$key" '$1==k {sub(/^[^=]+=/, ""); gsub(/^"|"$/, ""); print; exit}' "$file"
}

config_set() {
    local key="$1" val="$2" file="${3:-$TUNN_CONFIG}"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if grep -qE "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$file"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$file"
    fi
    chmod 600 "$file"
}

mode_get() {
    [[ -r "$TUNN_STATE" ]] && cat "$TUNN_STATE" || echo "hybrid"
}

mode_set() {
    local m="$1"
    case "$m" in gateway|tunnel|hybrid) ;; *) die "Mode tidak valid: $m" ;; esac
    mkdir -p "$(dirname "$TUNN_STATE")"
    echo "$m" > "$TUNN_STATE"
}

ensure_dirs() {
    mkdir -p "$TUNN_ETC" "$TUNN_LOG" /var/lib/tunn-awg
    chmod 750 "$TUNN_ETC"
}
