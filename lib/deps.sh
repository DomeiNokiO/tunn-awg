#!/usr/bin/env bash
# Install minimal dependencies for the OS matrix. Idempotent.

install_deps() {
    log_step "Menginstal dependensi sistem"
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 UCF_FORCE_CONFOLD=1

    # Bersihkan lock yang mungkin tersangkut dari installer sebelumnya.
    killall -q apt apt-get dpkg 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true
    dpkg --configure -a >/dev/null 2>&1 || true

    # Ubuntu 24.04+: nonaktifkan prompt needrestart supaya apt tidak menggantung.
    if [[ -d /etc/needrestart ]]; then
        mkdir -p /etc/needrestart/conf.d
        cat >/etc/needrestart/conf.d/99-tunn-awg.conf <<'NRCONF'
# tunn-awg: jalankan restart otomatis, jangan tampilkan prompt TUI apapun.
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
$nrconf{ucodehints} = 0;
NRCONF
    fi

    # Preseed iptables-persistent supaya tidak minta konfirmasi interaktif.
    if command -v debconf-set-selections >/dev/null 2>&1; then
        debconf-set-selections <<'PRESEED'
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
PRESEED
    fi

    apt-get update -y </dev/null || log_warn "apt update ada peringatan (lanjut)."

    _apt_install_group "core" \
        curl wget git jq tar gnupg lsb-release ca-certificates \
        iproute2 iptables net-tools \
        python3 python3-venv python3-pip \
        sqlite3 openssl

    _apt_install_group "vpn" \
        wireguard wireguard-tools qrencode \
        strongswan xl2tpd ppp

    _apt_install_group "firewall" \
        iptables-persistent nftables ufw fail2ban

    # Paket opsional; kalau gagal cukup warn.
    _apt_install_optional strongswan-pki

    install_ookla_speedtest || log_warn "Ookla speedtest gagal terpasang (opsional)."
    log_ok "Dependensi siap."
}

# Install satu grup paket. Kalau gagal, coba lagi per-paket untuk mengidentifikasi
# paket yang bermasalah, tampilkan error asli, lalu keluar.
_apt_install_group() {
    local label="$1"; shift
    local pkgs=("$@")
    log_info "Grup [$label]: ${pkgs[*]}"
    if apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "${pkgs[@]}" </dev/null; then
        return 0
    fi
    log_warn "Instalasi grup [$label] gagal — coba per-paket untuk cari penyebab."
    local failed=()
    for p in "${pkgs[@]}"; do
        if ! apt-get install -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "$p" </dev/null; then
            log_err "Paket wajib gagal terpasang: $p"
            failed+=("$p")
        fi
    done
    if ((${#failed[@]} > 0)); then
        log_err "Paket wajib gagal: ${failed[*]}"
        log_err "Coba: 'apt-get -f install' lalu 'apt-get update && apt-get upgrade -y' sebelum menjalankan installer lagi."
        exit 1
    fi
}

_apt_install_optional() {
    for p in "$@"; do
        apt-get install -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "$p" </dev/null >/dev/null 2>&1 || log_warn "Opsional '$p' dilewati (tidak tersedia di repo)."
    done
}

install_ookla_speedtest() {
    command -v speedtest >/dev/null 2>&1 && return 0
    local codename
    codename="$(lsb_release -cs 2>/dev/null || echo bookworm)"
    curl -fsSL "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh" \
        | os=${OS_ID} dist=${codename} bash >/dev/null 2>&1 || return 1
    apt-get install -y speedtest >/dev/null 2>&1
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
