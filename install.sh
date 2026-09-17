#!/usr/bin/env bash
# tunn-awg — installer / updater / orchestrator.
# Usage:
#   bash install.sh                 # install baru (mode default: hybrid)
#   bash install.sh --mode=gateway  # install dengan mode tertentu
#   bash install.sh --update        # update tanpa menimpa config.env / data.db
#   bash install.sh --no-bot        # skip bot install
#   bash install.sh --branch=BRANCH # ambil branch tertentu saat bootstrap-clone
set -euo pipefail

REPO_URL="${TUNN_REPO:-https://github.com/DomeiNokiO/tunn-awg.git}"
REPO_BRANCH="${TUNN_BRANCH:-main}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/tunn-awg

MODE="hybrid"
UPDATE=0
NO_BOT=0
for a in "$@"; do
    case "$a" in
        --mode=*)   MODE="${a#*=}" ;;
        --branch=*) REPO_BRANCH="${a#*=}" ;;
        --update)   UPDATE=1 ;;
        --no-bot)   NO_BOT=1 ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Argumen tidak dikenal: $a"; exit 1 ;;
    esac
done

# --- Bootstrap: clone repo bila SRC_DIR belum lengkap, ATAU bila mode --update
#     (supaya --update selalu mengambil kode terbaru dari GitHub).
#     Dilewati bila kita adalah proses re-exec (sumber sudah di DEST).
NEED_BOOTSTRAP=0
if [[ -z "${TUNN_REEXEC:-}" ]]; then
    [[ ! -d "$SRC_DIR/lib" ]] && NEED_BOOTSTRAP=1
    [[ "$UPDATE" -eq 1 ]] && NEED_BOOTSTRAP=1
fi

if [[ "$NEED_BOOTSTRAP" -eq 1 ]]; then
    if [[ "$UPDATE" -eq 1 ]]; then
        echo "[tunn-awg] --update: mengambil kode terbaru dari $REPO_URL ($REPO_BRANCH)"
    else
        echo "[tunn-awg] Sumber tidak lengkap di $SRC_DIR — bootstrap clone dari $REPO_URL ($REPO_BRANCH)"
    fi
    if ! command -v git >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y -qq
        apt-get install -y -qq git ca-certificates
    fi
    BOOT_DIR="/tmp/tunn-awg-src.$$"
    rm -rf "$BOOT_DIR"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$BOOT_DIR"
    SRC_DIR="$BOOT_DIR"
fi

# --- Guard: kalau user salah cwd, clone bisa nyasar ke $DEST/tunn-awg. Bersihkan.
if [[ -d "$DEST/tunn-awg/.git" ]] \
   && git -C "$DEST/tunn-awg" remote get-url origin 2>/dev/null | grep -q 'tunn-awg'; then
    echo "[tunn-awg] Menghapus clone nyasar di $DEST/tunn-awg"
    rm -rf "$DEST/tunn-awg"
fi

# --- Salin sumber ke /opt/tunn-awg (idempotent). Sertakan .git supaya DEST juga
#     jadi git checkout: bikin 'git pull' & 'git log' di DEST langsung jalan.
#     Venv bot hidup di /var/lib/tunn-awg/venv (di luar DEST) agar tidak terhapus --delete.
if [[ -z "${TUNN_REEXEC:-}" ]]; then
    mkdir -p "$DEST"
    RSYNC_EXCLUDES=(--exclude 'etc/tunn-awg' --exclude 'bot/venv' --exclude 'tunn-awg/')
    if ! command -v rsync >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y -qq && apt-get install -y -qq rsync
    fi
    rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$SRC_DIR"/ "$DEST"/

    # Bash sudah memuat skrip INI (mungkin versi lama) ke memori. Supaya alur
    # install/update yang berjalan adalah versi yang baru saja di-rsync, re-exec.
    echo "[tunn-awg] Menjalankan installer versi terbaru dari $DEST/install.sh"
    TUNN_REEXEC=1 exec bash "$DEST/install.sh" "$@"
fi

# --- Load semua modul lib/ ---
if ! compgen -G "$DEST/lib/*.sh" >/dev/null; then
    echo "[FATAL] $DEST/lib/*.sh tidak ditemukan setelah rsync. Cek $SRC_DIR/lib/." >&2
    exit 1
fi
for f in "$DEST"/lib/*.sh; do
    # shellcheck disable=SC1090
    . "$f"
done

require_root
detect_os
ensure_dirs

# --- Helpers khusus installer (dipakai --update juga) ---
install_units() {
    log_step "Memasang systemd unit"
    install -m 644 "$DEST"/systemd/*.service /etc/systemd/system/
    install -m 644 "$DEST"/systemd/*.timer   /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now tunn-awg-expiry.timer tunn-awg-quota.timer >/dev/null 2>&1 || true
    systemctl enable tunn-awg-firewall.service >/dev/null 2>&1 || true
}

_install_menu() {
    install -m 755 "$DEST"/menu/vpn /usr/local/bin/vpn
    log_ok "Perintah 'vpn' terpasang di /usr/local/bin/vpn."
}

_bot_config_bootstrap() {
    if [[ ! -f "$TUNN_CONFIG" ]]; then
        install -m 600 "$DEST"/bot/config.example.env "$TUNN_CONFIG"
    fi
    chmod 600 "$TUNN_CONFIG"
}

_bot_prompt_credentials() {
    local tok ids own
    tok="$(config_get BOT_TOKEN)"
    if [[ -z "$tok" ]]; then
        echo
        log_step "Setup Bot Telegram (bisa dilewati; isi manual nanti via 'vpn')"
        read -rp "Bot Token (Enter untuk skip): " tok
        [[ -n "$tok" ]] && config_set BOT_TOKEN "$tok"
    fi
    ids="$(config_get ADMIN_IDS)"
    if [[ -z "$ids" ]]; then
        read -rp "Admin Chat ID (pisah koma): " ids
        [[ -n "$ids" ]] && config_set ADMIN_IDS "$ids"
    fi
    own="$(config_get OWNER_ID)"
    if [[ -z "$own" && -n "$ids" ]]; then
        config_set OWNER_ID "${ids%%,*}"
    fi
    systemctl enable --now tunn-awg-bot >/dev/null 2>&1
    systemctl restart tunn-awg-bot 2>/dev/null || true
}

_print_summary() {
    local pub; pub="$(detect_public_ip)"
    echo
    printf "${C_GREEN}=====================================================${C_NC}\n"
    printf "${C_GREEN}  TUNN-AWG %s siap.${C_NC}\n" "$(cat "$DEST"/VERSION 2>/dev/null || echo 3.0.0)"
    printf "${C_GREEN}=====================================================${C_NC}\n"
    echo  " IP publik VPS  : $pub"
    echo  " Mode operasi   : $(mode_get)"
    echo  " Endpoint WG    : $(config_get WG_SERVER_ENDPOINT)"
    echo  " L2TP PSK       : $(config_get IPSEC_PSK)"
    echo
    echo  " Ketik 'vpn' untuk membuka panel."
    echo  " Dokumentasi    : $DEST/docs/"
    echo
    echo  " Contoh perintah bot (setelah token diisi):"
    echo  "   buatkan wg budi 30 hari quota 50gb"
    echo  "   hapus l2tp joko"
    echo  "   forward port 8080 ke 192.168.88.10:80"
    echo
}

_print_update_summary() {
    local ver st_ver bot_st fw_st venv_st
    ver="$(cat "$DEST"/VERSION 2>/dev/null || echo '?')"
    st_ver="$(speedtest --version 2>/dev/null | head -1 || echo 'tidak ada')"
    bot_st="$(systemctl is-active tunn-awg-bot 2>/dev/null || echo 'n/a')"
    fw_st="$(systemctl is-enabled tunn-awg-firewall.service 2>/dev/null || echo 'n/a')"
    if [[ -x /var/lib/tunn-awg/venv/bin/python ]]; then venv_st="ok"; else venv_st="TIDAK ADA"; fi
    echo
    printf "${C_GREEN}=============== RINGKASAN UPDATE ===============${C_NC}\n"
    echo " Versi           : $ver"
    echo " Speedtest       : $st_ver"
    echo " Bot service     : $bot_st"
    echo " Venv bot        : $venv_st (/var/lib/tunn-awg/venv)"
    echo " Firewall unit   : $fw_st"
    if [[ "$bot_st" != "active" ]]; then
        echo
        log_warn "Bot tidak active. Log terakhir:"
        journalctl -u tunn-awg-bot -n 15 --no-pager 2>/dev/null || true
        echo " Hint: cek BOT_TOKEN / ADMIN_IDS via 'vpn' -> 8."
    fi
    printf "${C_GREEN}================================================${C_NC}\n"
}

# --- Alur update ---
if [[ "$UPDATE" -eq 1 ]]; then
    log_step "Update tunn-awg (config.env & data.db dipertahankan)"
    install_deps
    db_init
    mtlan_db_init
    firewall_setup
    # Re-tulis template WG/L2TP agar fix konfigurasi ikut terpasang di instalasi lama.
    # Idempotent: wg0.conf yang ada dilewati, PSK & akun L2TP dipertahankan.
    wg_server_init
    l2tp_server_init
    if [[ "$NO_BOT" -eq 0 ]]; then
        install_python_bot_deps || log_warn "Venv bot bermasalah; bot mungkin tidak jalan."
        _bot_config_bootstrap
    fi
    install_units
    _install_menu
    if [[ "$NO_BOT" -eq 0 ]]; then
        systemctl enable tunn-awg-bot >/dev/null 2>&1 || true
        systemctl restart tunn-awg-bot 2>/dev/null || true
        sleep 2
    fi
    log_ok "Update selesai. Ketik 'vpn' untuk buka panel."
    _print_update_summary
    exit 0
fi

# --- Alur install baru ---
mode_set "$MODE"

install_deps
db_init
mtlan_db_init
firewall_setup
wg_server_init
l2tp_server_init

if [[ "$NO_BOT" -eq 0 ]]; then
    install_python_bot_deps
    _bot_config_bootstrap
fi

install_units
_install_menu

if [[ "$NO_BOT" -eq 0 ]]; then
    _bot_prompt_credentials
fi

_print_summary
