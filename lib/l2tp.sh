#!/usr/bin/env bash
# strongSwan + xl2tpd, preset Mikrotik RouterOS 6.49-friendly.

: "${L2TP_LOCAL_IP:=10.10.10.1}"
: "${L2TP_RANGE:=10.10.10.100-10.10.10.200}"
: "${L2TP_DNS1:=1.1.1.1}"
: "${L2TP_DNS2:=1.0.0.1}"

l2tp_server_init() {
    log_step "Inisialisasi L2TP/IPsec (strongSwan + xl2tpd)"

    local pub_ip psk
    pub_ip="$(detect_public_ip)"
    psk="$(config_get IPSEC_PSK 2>/dev/null)"
    if [[ -z "$psk" ]]; then
        psk="$(gen_psk)"
        config_set IPSEC_PSK "$psk"
    fi
    config_set L2TP_PUBLIC_IP "$pub_ip"

    _write_ipsec_conf "$pub_ip"
    _write_ipsec_secrets "$pub_ip" "$psk"
    _write_xl2tpd_conf
    _write_ppp_options
    _ensure_ppp_modules

    # Bersihkan lockfile lama xl2tpd yang bikin start gagal senyap.
    rm -f /var/run/xl2tpd/l2tp-control 2>/dev/null || true
    mkdir -p /var/run/xl2tpd

    systemctl enable --now strongswan-starter >/dev/null 2>&1 \
        || systemctl enable --now strongswan >/dev/null 2>&1 || true
    systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null || true

    systemctl enable --now xl2tpd >/dev/null 2>&1
    systemctl restart xl2tpd

    log_ok "L2TP/IPsec siap. PSK tersimpan di $TUNN_CONFIG (IPSEC_PSK)."
}

_write_ipsec_conf() {
    local pub_ip="$1"
    cat >/etc/ipsec.conf <<EOF
# tunn-awg IPsec - preset Mikrotik RouterOS 6.49 compatible
config setup
    uniqueids=never
    charondebug="ike 1, knl 1, cfg 0"

conn %default
    ikelifetime=8h
    keylife=1h
    rekeymargin=3m
    keyingtries=%forever

conn L2TP-PSK
    keyexchange=ikev1
    authby=secret
    auto=add
    type=transport
    left=%defaultroute
    leftid=$pub_ip
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    ike=aes128-sha1-modp2048,aes256-sha1-modp2048,3des-sha1-modp1024!
    esp=aes128-sha1,aes256-sha1,3des-sha1!
    pfs=no
    forceencaps=yes
    dpddelay=30
    dpdtimeout=120
    dpdaction=clear
    rekey=no

include /etc/ipsec.d/*.conf
EOF
    chmod 644 /etc/ipsec.conf
    mkdir -p /etc/ipsec.d
}

_write_ipsec_secrets() {
    local pub_ip="$1" psk="$2"
    umask 077
    cat >/etc/ipsec.secrets <<EOF
$pub_ip %any : PSK "$psk"
EOF
    chmod 600 /etc/ipsec.secrets
    include_line='include /etc/ipsec.d/*.secrets'
    grep -qxF "$include_line" /etc/ipsec.secrets || echo "$include_line" >> /etc/ipsec.secrets
}

_write_xl2tpd_conf() {
    mkdir -p /etc/xl2tpd
    # `name` = authname yang xl2tpd kirim ke pppd (`name <x>`, prioritas cmdline).
    # HARUS sama dengan kolom server di /etc/ppp/chap-secrets, kalau tidak pppd
    # tidak pernah meminta CHAP -> log "peer refused to authenticate".
    # Tanpa `require chap`, pppd langsung menawarkan MS-CHAPv2 (bukan MD5 dulu).
    cat >/etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701
access control = no
ipsec saref = no
force userspace = yes

[lns default]
ip range = $L2TP_RANGE
local ip = $L2TP_LOCAL_IP
refuse pap = yes
require authentication = yes
name = l2tpd
hostname = tunn-awg
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF
}

_write_ppp_options() {
    # Jangan set `name` di sini: xl2tpd sudah mengirim `name l2tpd` dgn prioritas lebih tinggi.
    cat >/etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
ms-dns $L2TP_DNS1
ms-dns $L2TP_DNS2
noccp
auth
mtu 1400
mru 1400
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
connect-delay 5000
hide-password
require-mschap-v2
refuse-pap
EOF
    touch /etc/ppp/chap-secrets
    chmod 600 /etc/ppp/chap-secrets
    grep -qE '^# tunn-awg' /etc/ppp/chap-secrets || \
        sed -i '1i # tunn-awg L2TP users\n# client   server   secret   IP addresses' /etc/ppp/chap-secrets
}

_ensure_ppp_modules() {
    modprobe ppp_generic 2>/dev/null || true
    modprobe ppp_async 2>/dev/null || true
    modprobe ppp_mppe 2>/dev/null || true
    mkdir -p /etc/modules-load.d
    printf 'ppp_generic\nppp_async\nppp_mppe\n' > /etc/modules-load.d/tunn-awg.conf
    [[ -c /dev/ppp ]] || mknod /dev/ppp c 108 0 2>/dev/null || true
}

# Kumpulkan semua bukti untuk debugging L2TP/IPsec dalam satu output.
l2tp_diag() {
    echo "===== tunn-awg L2TP diag $(date -Is) ====="
    echo "--- services ---"
    for s in strongswan-starter strongswan xl2tpd; do
        printf '%-20s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
    done
    echo "--- listen 1701 ---"
    ss -lunp 2>/dev/null | grep -E ':1701\b' || echo "(xl2tpd TIDAK listen di 1701)"
    echo "--- ppp kernel ---"
    ls -l /dev/ppp 2>&1
    lsmod | grep -E '^ppp|l2tp' || echo "(modul ppp belum termuat)"
    echo "--- pppd options dryrun (dgn name l2tpd spt yg dikirim xl2tpd) ---"
    pppd name l2tpd file /etc/ppp/options.xl2tpd dryrun 2>&1 | head -20 || true
    echo "--- akun L2TP (chap-secrets) ---"
    awk '/^#/||/^$/ {next} {c=$1; gsub(/^"|"$/,"",c); print "  " c}' /etc/ppp/chap-secrets 2>/dev/null || echo "  (kosong)"
    echo "--- xl2tpd.conf ---"
    sed 's/^/  /' /etc/xl2tpd/xl2tpd.conf 2>/dev/null
    echo "--- chap-secrets (password disamarkan) ---"
    awk '/^#/||/^$/ {print; next} {print $1, $2, "****", $4}' /etc/ppp/chap-secrets 2>/dev/null
    echo "--- ipsec statusall ---"
    ipsec statusall 2>&1 | tail -25
    echo "--- firewall INPUT (500/4500/1701/esp) ---"
    iptables -S INPUT 2>/dev/null | grep -E '500|4500|1701|esp|ah' \
        || echo "(tidak ada rule eksplisit; UFW: $(ufw status 2>/dev/null | head -1))"
    echo "--- sysctl ---"
    sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter 2>/dev/null
    echo "--- log 15 menit terakhir (charon/xl2tpd/pppd) ---"
    journalctl -u strongswan-starter -u strongswan -u xl2tpd -t pppd --since '15 min ago' --no-pager 2>/dev/null | tail -60
    echo "===== end ====="
}

# Nyalakan/matikan verbose log xl2tpd + pppd + charon.
l2tp_debug() {
    case "${1:-status}" in
        on)
            sed -i 's/^ppp debug = .*/ppp debug = yes/' /etc/xl2tpd/xl2tpd.conf
            grep -q '^debug tunnel' /etc/xl2tpd/xl2tpd.conf || \
                sed -i '/^\[global\]/a debug tunnel = yes\ndebug state = yes\ndebug avp = yes' /etc/xl2tpd/xl2tpd.conf
            sed -i 's/charondebug=.*/charondebug="ike 2, knl 1, cfg 1, net 1"/' /etc/ipsec.conf
            ;;
        off)
            sed -i 's/^ppp debug = .*/ppp debug = no/' /etc/xl2tpd/xl2tpd.conf
            sed -i '/^debug tunnel = yes$/d; /^debug state = yes$/d; /^debug avp = yes$/d' /etc/xl2tpd/xl2tpd.conf
            sed -i 's/charondebug=.*/charondebug="ike 1, knl 1, cfg 0"/' /etc/ipsec.conf
            ;;
        status)
            grep -E '^(ppp debug|debug tunnel)' /etc/xl2tpd/xl2tpd.conf
            grep charondebug /etc/ipsec.conf
            return ;;
        *) die "l2tp_debug on|off|status" ;;
    esac
    systemctl restart xl2tpd
    ipsec reload >/dev/null 2>&1 || systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null
    log_ok "Debug L2TP: $1"
}

l2tp_add() {
    local user="$1" pass="${2:-}" expires="${3:-}" quota_gb="${4:-0}"
    [[ "$user" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Username hanya boleh a-zA-Z0-9_-."
    grep -qE "^\"?$user\"?[[:space:]]+l2tpd" /etc/ppp/chap-secrets && die "User $user sudah ada."
    [[ -z "$pass" ]] && pass="$(gen_password)"

    printf '"%s"   l2tpd   "%s"   *\n' "$user" "$pass" >> /etc/ppp/chap-secrets
    chmod 600 /etc/ppp/chap-secrets

    local quota_bytes=0
    [[ "$quota_gb" =~ ^[0-9]+$ && "$quota_gb" -gt 0 ]] && quota_bytes=$(( quota_gb * 1024 * 1024 * 1024 ))
    local exp_sql="NULL"
    [[ -n "$expires" ]] && exp_sql="'$expires'"

    sqlite3 "$TUNN_DB" \
        "INSERT INTO users(type,name,ip,pubkey,created_at,expires_at,quota_bytes,used_bytes,suspended) \
         VALUES('l2tp','$user','','$pass',datetime('now'),$exp_sql,$quota_bytes,0,0);" 2>/dev/null || true

    log_ok "User L2TP '$user' dibuat."
    printf "Username : %s\nPassword : %s\nServer   : %s\nPSK      : %s\n" \
        "$user" "$pass" "$(config_get L2TP_PUBLIC_IP)" "$(config_get IPSEC_PSK)"
}

l2tp_del() {
    local user="$1"
    sed -i "/^\"\?$user\"\?[[:space:]]\+l2tpd/d" /etc/ppp/chap-secrets
    sqlite3 "$TUNN_DB" "DELETE FROM users WHERE type='l2tp' AND name='$user';" 2>/dev/null || true
    log_ok "User L2TP '$user' dihapus."
}

# Password asli dari chap-secrets (kolom 3, tanpa tanda kutip). Kosong bila akun tidak ada.
l2tp_get_pass() {
    local user="$1"
    awk -v u="$user" '
        /^#/ || /^$/ {next}
        { c=$1; gsub(/^"|"$/, "", c);
          if (c==u && $2=="l2tpd") { p=$3; gsub(/^"|"$/, "", p); print p; exit } }' \
        /etc/ppp/chap-secrets 2>/dev/null
}

l2tp_exists() {
    [[ -n "$(l2tp_get_pass "$1")" ]]
}

# Tampilkan kredensial lengkap satu akun (untuk dipasang di MikroTik/klien).
l2tp_show() {
    local user="$1" pass
    pass="$(l2tp_get_pass "$user")"
    [[ -n "$pass" ]] || die "Akun L2TP '$user' tidak ada di /etc/ppp/chap-secrets."
    printf "Username : %s\nPassword : %s\nServer   : %s\nPSK      : %s\n" \
        "$user" "$pass" "$(config_get L2TP_PUBLIC_IP)" "$(config_get IPSEC_PSK)"
}

# Ganti password akun. Kosong = generate acak. Sesi aktif tidak diputus; berlaku di koneksi berikutnya.
l2tp_passwd() {
    local user="$1" pass="${2:-}"
    l2tp_exists "$user" || die "Akun L2TP '$user' tidak ada."
    [[ -z "$pass" ]] && pass="$(gen_password)"
    sed -i "s|^\"\?$user\"\?[[:space:]]\+l2tpd[[:space:]]\+\"\?[^\"[:space:]]*\"\?|\"$user\"   l2tpd   \"$pass\"|" /etc/ppp/chap-secrets
    sqlite3 "$TUNN_DB" "UPDATE users SET pubkey='$pass' WHERE type='l2tp' AND name='$user';" 2>/dev/null || true
    log_ok "Password L2TP '$user' diganti."
    l2tp_show "$user"
}

l2tp_list() {
    sqlite3 -header -column "$TUNN_DB" \
        "SELECT name, COALESCE(expires_at,'-') AS expiry, quota_bytes AS quota, used_bytes AS used, suspended \
         FROM users WHERE type='l2tp' ORDER BY id;" 2>/dev/null \
        || awk '/^#/ || /^$/ {next} {print "- "$1}' /etc/ppp/chap-secrets
}

l2tp_show_psk() {
    printf "PSK   : %s\nServer: %s\n" "$(config_get IPSEC_PSK)" "$(config_get L2TP_PUBLIC_IP)"
}
