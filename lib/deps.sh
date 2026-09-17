#!/usr/bin/env bash
# Install minimal dependencies for the OS matrix. Idempotent.

install_deps() {
    log_step "Menginstal dependensi sistem"
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

    # Bersihkan lock yang mungkin tersangkut dari installer sebelumnya.
    killall -q apt apt-get dpkg 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true
    dpkg --configure -a >/dev/null 2>&1 || true

    apt-get update -y -qq

    local pkgs=(
        curl wget git jq tar gnupg lsb-release ca-certificates
        iproute2 iptables iptables-persistent nftables net-tools
        wireguard wireguard-tools qrencode
        strongswan strongswan-pki xl2tpd ppp
        python3 python3-venv python3-pip
        sqlite3
        fail2ban ufw
        openssl
    )
    apt-get install -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "${pkgs[@]}"

    install_ookla_speedtest || log_warn "Ookla speedtest gagal terpasang (opsional)."
    log_ok "Dependensi siap."
}

install_ookla_speedtest() {
    command -v speedtest >/dev/null 2>&1 && return 0
    local codename
    codename="$(lsb_release -cs 2>/dev/null || echo bookworm)"
    curl -fsSL "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh" \
        | os=${OS_ID} dist=${codename} bash >/dev/null 2>&1 || return 1
    apt-get install -y -qq speedtest >/dev/null 2>&1
}

install_python_bot_deps() {
    log_step "Menyiapkan virtualenv bot Telegram"
    local venv=/opt/tunn-awg/bot/venv
    mkdir -p "$(dirname "$venv")"
    python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet --upgrade pip wheel
    "$venv/bin/pip" install --quiet -r /opt/tunn-awg/bot/requirements.txt
    log_ok "Virtualenv bot siap di $venv."
}
