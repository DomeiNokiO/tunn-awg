#!/usr/bin/env bash
# WireGuard server bootstrap + peer manager (internal, no third-party installer).

: "${WG_IFACE:=wg0}"
: "${WG_PORT:=51820}"
: "${WG_NET:=10.7.0.0/24}"
: "${WG_SERVER_IP:=10.7.0.1}"
: "${WG_DIR:=/etc/wireguard}"
: "${WG_CLIENTS:=/etc/tunn-awg/clients/wg}"

wg_server_init() {
    log_step "Inisialisasi WireGuard server"
    mkdir -p "$WG_DIR" "$WG_CLIENTS"
    chmod 700 "$WG_DIR"

    if [[ -f "$WG_DIR/$WG_IFACE.conf" ]]; then
        log_info "wg0.conf sudah ada — dilewati."
        return
    fi

    local priv pub wan pub_ip
    priv="$(wg genkey)"
    pub="$(printf "%s" "$priv" | wg pubkey)"
    wan="$(detect_wan_iface)"
    pub_ip="$(detect_public_ip)"

    umask 077
    cat >"$WG_DIR/$WG_IFACE.conf" <<EOF
# tunn-awg WireGuard server
[Interface]
Address = $WG_SERVER_IP/24
ListenPort = $WG_PORT
PrivateKey = $priv
# Mode-aware post-up handled by firewall.sh; keep this minimal & idempotent
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
EOF

    config_set WG_SERVER_PUBKEY "$pub"
    config_set WG_SERVER_ENDPOINT "${pub_ip}:${WG_PORT}"
    config_set WG_WAN_IFACE "$wan"

    systemctl enable --now "wg-quick@$WG_IFACE" >/dev/null 2>&1 || \
        systemctl restart "wg-quick@$WG_IFACE"
    log_ok "WireGuard aktif pada $pub_ip:$WG_PORT."
}

_wg_next_ip() {
    local used ip
    used="$(grep -E '^AllowedIPs' "$WG_DIR/$WG_IFACE.conf" 2>/dev/null | grep -oE '10\.7\.0\.[0-9]+' || true)"
    for i in $(seq 2 254); do
        ip="10.7.0.$i"
        grep -qxF "$ip" <<<"$used" || { echo "$ip"; return; }
    done
    die "Alokasi IP WireGuard habis."
}

wg_add() {
    local name="$1" expires="${2:-}" quota_gb="${3:-0}"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Nama hanya boleh a-zA-Z0-9_-."
    grep -qE "^### Client $name\$" "$WG_DIR/$WG_IFACE.conf" 2>/dev/null && die "Client $name sudah ada."

    local priv pub psk ip endpoint server_pub
    priv="$(wg genkey)"; pub="$(printf "%s" "$priv" | wg pubkey)"; psk="$(wg genpsk)"
    ip="$(_wg_next_ip)"
    endpoint="$(config_get WG_SERVER_ENDPOINT)"
    server_pub="$(config_get WG_SERVER_PUBKEY)"

    cat >>"$WG_DIR/$WG_IFACE.conf" <<EOF

### Client $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $ip/32
EOF

    mkdir -p "$WG_CLIENTS"
    umask 077
    cat >"$WG_CLIENTS/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/24
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    qrencode -o "$WG_CLIENTS/$name.png" < "$WG_CLIENTS/$name.conf"
    wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") 2>/dev/null || systemctl restart "wg-quick@$WG_IFACE"

    local quota_bytes=0
    [[ "$quota_gb" =~ ^[0-9]+$ && "$quota_gb" -gt 0 ]] && quota_bytes=$(( quota_gb * 1024 * 1024 * 1024 ))
    local exp_sql="NULL"
    [[ -n "$expires" ]] && exp_sql="'$expires'"

    sqlite3 "$TUNN_DB" \
        "INSERT INTO users(type,name,ip,pubkey,created_at,expires_at,quota_bytes,used_bytes,suspended) \
         VALUES('wg','$name','$ip','$pub',datetime('now'),$exp_sql,$quota_bytes,0,0);" 2>/dev/null || true

    log_ok "Client WG '$name' dibuat. Config: $WG_CLIENTS/$name.conf  QR: $WG_CLIENTS/$name.png"
    qrencode -t ansiutf8 < "$WG_CLIENTS/$name.conf"
}

wg_del() {
    local name="$1"
    grep -qE "^### Client $name\$" "$WG_DIR/$WG_IFACE.conf" 2>/dev/null || die "Client $name tidak ditemukan."

    # Ambil pubkey untuk runtime remove.
    local pub
    pub="$(awk -v n="### Client $name" '
        $0==n {found=1; next}
        found && /^PublicKey/ {print $3; exit}' "$WG_DIR/$WG_IFACE.conf")"

    # Hapus blok peer (### Client <name> sampai baris kosong berikutnya).
    sed -i "/^### Client $name\$/,/^\$/d" "$WG_DIR/$WG_IFACE.conf"

    [[ -n "$pub" ]] && wg set "$WG_IFACE" peer "$pub" remove 2>/dev/null || true
    rm -f "$WG_CLIENTS/$name.conf" "$WG_CLIENTS/$name.png"
    sqlite3 "$TUNN_DB" "DELETE FROM users WHERE type='wg' AND name='$name';" 2>/dev/null || true
    log_ok "Client WG '$name' dihapus."
}

wg_list() {
    sqlite3 -header -column "$TUNN_DB" \
        "SELECT name, ip, COALESCE(expires_at,'-') AS expiry, quota_bytes AS quota, used_bytes AS used, suspended \
         FROM users WHERE type='wg' ORDER BY id;" 2>/dev/null \
        || grep -E '^### Client' "$WG_DIR/$WG_IFACE.conf" 2>/dev/null | awk '{print "- "$3}'
}

wg_qr() {
    local name="$1"
    local f="$WG_CLIENTS/$name.conf"
    [[ -f "$f" ]] || die "Config $name tidak ada di $WG_CLIENTS."
    qrencode -t ansiutf8 < "$f"
    echo
    echo "PNG: $WG_CLIENTS/$name.png"
    echo "Conf: $f"
}

# AllowedIPs yang seharusnya dipakai untuk profile split-lan.
_wg_expected_split() {
    local expected="10.7.0.0/24 10.10.10.0/24"
    if declare -F mtlan_get_subnets >/dev/null 2>&1; then
        for c in $(mtlan_get_subnets); do expected="$expected $c"; done
    fi
    echo "$expected" | xargs -n1 | sort -u | xargs
}

# Cek AllowedIPs setiap config klien vs {WG, L2TP, all mt_lans}. Tampilkan yang kurang.
wg_audit() {
    local exp; exp="$(_wg_expected_split)"
    printf 'Baseline (split-lan): %s\n' "$exp"
    echo "0.0.0.0/0 dianggap full-tunnel (sudah cover semua)."
    echo
    local ok=0 warn=0
    for f in "$WG_CLIENTS"/*.conf; do
        [[ -e "$f" ]] || { echo "(belum ada config klien)"; return; }
        local name; name="$(basename "$f" .conf)"
        local ai; ai="$(awk -F' *= *' '/^\[Peer\]/{p=1} p && /^AllowedIPs/{print $2; exit}' "$f")"
        if [[ "$ai" == *"0.0.0.0/0"* ]]; then
            printf '  ✅ %-20s FULL  (0.0.0.0/0)\n' "$name"
            ok=$((ok+1)); continue
        fi
        local missing=""
        for e in $exp; do [[ "$ai" != *"$e"* ]] && missing="$missing $e"; done
        if [[ -z "$missing" ]]; then
            printf '  ✅ %-20s SPLIT-LAN lengkap\n' "$name"
            ok=$((ok+1))
        else
            printf '  ⚠️  %-20s kurang subnet:%s\n' "$name" "$missing"
            printf '      AllowedIPs sekarang: %s\n' "$ai"
            warn=$((warn+1))
        fi
    done
    echo
    printf 'Total: %d OK, %d perlu regen.\n' "$ok" "$warn"
    (( warn > 0 )) && echo "Perbaiki: vpn -> 1 -> 7 (regenerate) atau bot: 'regen wg NAMA split-lan'."
}

# Regenerate config klien dengan AllowedIPs profile baru (private key existing dipertahankan).
wg_regen() {
    local name="$1" profile="${2:-split-lan}"
    local f="$WG_CLIENTS/$name.conf"
    [[ -f "$f" ]] || die "Config klien '$name' tidak ada di $WG_CLIENTS."
    grep -qE "^### Client $name\$" "$WG_DIR/$WG_IFACE.conf" || die "Peer '$name' tidak ada di server conf."

    local allowed
    case "$profile" in
        full|"")     allowed="0.0.0.0/0" ;;
        split-lan)   allowed="$(_wg_expected_split | tr ' ' ',' | sed 's/,/, /g')" ;;
        *)           die "Profile tidak dikenal: $profile (pakai full atau split-lan)" ;;
    esac

    local priv addr dns endpoint server_pub psk
    priv="$(awk -F' *= *' '/^PrivateKey/{print $2; exit}' "$f")"
    addr="$(awk -F' *= *' '/^Address/{print $2; exit}' "$f")"
    dns="$(awk -F' *= *'  '/^DNS/{print $2; exit}' "$f")"
    endpoint="$(config_get WG_SERVER_ENDPOINT)"
    server_pub="$(config_get WG_SERVER_PUBKEY)"
    psk="$(awk -F' *= *' '/^PresharedKey/{print $2; exit}' "$f")"

    umask 077
    cat >"$f" <<EOF
[Interface]
PrivateKey = $priv
Address = $addr
DNS = ${dns:-1.1.1.1, 1.0.0.1}

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = $endpoint
AllowedIPs = $allowed
PersistentKeepalive = 25
EOF
    qrencode -o "$WG_CLIENTS/$name.png" < "$f"
    log_ok "Config '$name' regenerated ($profile). Import ulang di klien."
    echo "Conf: $f"
    echo "PNG : $WG_CLIENTS/$name.png"
    echo "AllowedIPs: $allowed"
}
