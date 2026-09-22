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

    # Repo apt Ookla yang stale (codename tidak didukung) bikin 'apt update' 404 terus.
    # File ini milik kita; _ookla_install_apt_repo akan menulis ulang bila jalur itu dipakai.
    rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list 2>/dev/null || true

    apt-get update -y </dev/null || log_warn "apt update ada peringatan (lanjut)."

    _apt_install_group "core" \
        curl wget git jq tar gnupg lsb-release ca-certificates \
        iproute2 iptables net-tools \
        python3 python3-venv python3-pip \
        sqlite3 openssl

    _apt_install_group "vpn" \
        wireguard wireguard-tools qrencode \
        strongswan xl2tpd ppp

    # CATATAN: di Ubuntu 24.04 'ufw' Breaks 'iptables-persistent' — keduanya tidak
    # bisa hidup bersama. Kita pakai ufw untuk allow-rules dan menyimpan/menerapkan
    # rule NAT sendiri lewat tunn-awg-firewall.service (nat_apply saat boot).
    _apt_install_group "firewall" \
        nftables ufw fail2ban

    _apt_install_optional strongswan-pki mtr-tiny traceroute tcpdump

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
    if command -v speedtest >/dev/null 2>&1 \
        && speedtest --version 2>/dev/null | grep -qi ookla; then
        return 0
    fi
    log_info "Menginstal Ookla Speedtest CLI..."

    # Paket Python 'speedtest-cli' menyediakan /usr/bin/speedtest — konflik dengan Ookla.
    if dpkg -l speedtest-cli 2>/dev/null | grep -q '^ii'; then
        log_info "Menghapus speedtest-cli (Python, apt) yang konflik dengan binary Ookla."
        apt-get remove -y speedtest-cli </dev/null >/dev/null 2>&1 || true
    fi
    # Wrapper pip speedtest-cli (mis. /usr/local/bin/speedtest) tidak terdeteksi dpkg.
    local cur; cur="$(command -v speedtest 2>/dev/null || true)"
    if [[ -n "$cur" ]] && "$cur" --version 2>/dev/null | grep -qi 'speedtest-cli'; then
        log_info "Menimpa wrapper speedtest-cli (pip) di $cur dengan binary Ookla."
        rm -f "$cur" 2>/dev/null || true
        hash -r 2>/dev/null || true
    fi

    # Metode utama: binary statis resmi Ookla (tidak bergantung repo/codename apt).
    if _ookla_install_static; then
        return 0
    fi

    # Metode kedua: repo apt packagecloud (jalan bila codename didukung Ookla).
    if _ookla_install_apt_repo; then
        return 0
    fi

    log_warn "Ookla tidak tersedia. Fallback terakhir: speedtest-cli (Python)."
    apt-get install -y speedtest-cli </dev/null >/dev/null 2>&1 || true
    command -v speedtest-cli >/dev/null 2>&1
}

_ookla_install_static() {
    local ver="1.2.0" arch tgz url tmp
    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        armv7l)        arch="armhf" ;;
        armv6l)        arch="armel" ;;
        i386|i686)     arch="i386" ;;
        *) log_warn "Arsitektur $(uname -m) tidak ada binary statis Ookla."; return 1 ;;
    esac

    tgz="ookla-speedtest-${ver}-linux-${arch}.tgz"
    url="https://install.speedtest.net/app/cli/${tgz}"
    tmp="$(mktemp -d)"
    log_info "Mengunduh $url"
    if curl -fL --retry 3 --connect-timeout 10 -o "$tmp/$tgz" "$url" 2>/dev/null \
        && tar -xzf "$tmp/$tgz" -C "$tmp" speedtest 2>/dev/null; then
        install -m 755 "$tmp/speedtest" /usr/local/bin/speedtest
        rm -rf "$tmp"
        hash -r 2>/dev/null || true
        if /usr/local/bin/speedtest --version 2>/dev/null | grep -qi ookla; then
            log_ok "Ookla Speedtest CLI $ver terpasang (binary statis, /usr/local/bin/speedtest)."
            return 0
        fi
    fi
    rm -rf "$tmp"
    log_warn "Unduh binary statis Ookla gagal."
    return 1
}

_ookla_install_apt_repo() {
    local codename os_slug
    codename="$(lsb_release -cs 2>/dev/null)"
    if [[ -z "$codename" ]]; then
        # shellcheck disable=SC1091
        codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-bookworm}")"
    fi
    case "${OS_ID:-}" in
        ubuntu) os_slug="ubuntu" ;;
        debian) os_slug="debian" ;;
        *) return 1 ;;
    esac

    local key=/usr/share/keyrings/ookla_speedtest-cli-archive-keyring.gpg
    if [[ ! -s "$key" ]]; then
        curl -fsSL https://packagecloud.io/ookla/speedtest-cli/gpgkey \
            | gpg --dearmor -o "$key" 2>/dev/null || { log_warn "Gagal ambil GPG key Ookla."; return 1; }
        chmod 644 "$key"
    fi
    echo "deb [signed-by=$key] https://packagecloud.io/ookla/speedtest-cli/$os_slug/ $codename main" \
        > /etc/apt/sources.list.d/ookla_speedtest-cli.list
    apt-get update -y </dev/null >/dev/null 2>&1 || true
    if apt-get install -y speedtest </dev/null; then
        log_ok "Ookla Speedtest CLI terpasang via repo apt."
        return 0
    fi
    # Codename belum didukung -> buang repo agar apt update berikutnya tidak error.
    rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list
    apt-get update -y </dev/null >/dev/null 2>&1 || true
    log_warn "Repo apt Ookla tidak menyediakan '$codename'."
    return 1
}

install_python_bot_deps() {
    log_step "Menyiapkan virtualenv bot Telegram"
    # Di luar /opt/tunn-awg supaya tidak dihapus oleh rsync --delete saat update.
    local venv="${TUNN_VENV:-/var/lib/tunn-awg/venv}"
    mkdir -p "$(dirname "$venv")"
    if [[ ! -x "$venv/bin/python" ]]; then
        python3 -m venv "$venv" || { log_err "Gagal membuat venv di $venv"; return 1; }
    fi
    "$venv/bin/pip" install -q --upgrade pip wheel 2>&1 | tail -2 || true
    if ! "$venv/bin/pip" install -q -r /opt/tunn-awg/bot/requirements.txt; then
        log_err "pip install requirements gagal. Cek koneksi internet / output di atas."
        return 1
    fi
    # Venv lama di lokasi salah tidak dipakai lagi.
    rm -rf /opt/tunn-awg/bot/venv 2>/dev/null || true
    log_ok "Virtualenv bot siap di $venv."
}
