#!/usr/bin/env bash
# LAN di belakang Mikrotik: registrasi subnet + hub peer + route/forward otomatis.
#
# Konsep:
#   MT_LAN_SUBNETS  CIDR (comma-sep) LAN di belakang Mikrotik, mis. 192.168.88.0/24
#   MT_HUB_NAME     nama akun L2TP milik Mikrotik (hub) — WAJIB punya IP statis
#   MT_HUB_IP       IP tunnel statis hub, mis. 10.10.10.2 (di luar pool 100-200)
#
# Alur paket:
#   HP (WG 10.7.0.x) / internet (DNAT) -> VPS -> route MT_LAN via MT_HUB_IP (ppp+) -> Mikrotik -> OLT
#   Return path aman karena VPS MASQUERADE keluar ppp+ (OLT membalas ke 10.10.10.1 yang Mikrotik kenal).

: "${WG_SUBNET:=10.7.0.0/24}"
: "${L2TP_SUBNET:=10.10.10.0/24}"

mtlan_get_subnets() {
    config_get MT_LAN_SUBNETS 2>/dev/null | tr ',' ' ' | xargs 2>/dev/null || true
}

mtlan_add() {
    local cidr="$1"
    [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || die "CIDR tidak valid: $cidr (contoh 192.168.88.0/24)"
    local cur; cur="$(config_get MT_LAN_SUBNETS 2>/dev/null || true)"
    if [[ ",$cur," == *",$cidr,"* ]]; then
        log_warn "$cidr sudah terdaftar."
    elif [[ -z "$cur" ]]; then
        config_set MT_LAN_SUBNETS "$cidr"
    else
        config_set MT_LAN_SUBNETS "$cur,$cidr"
    fi
    mtlan_apply_routes
    log_ok "LAN Mikrotik $cidr terdaftar."
}

mtlan_del() {
    local cidr="$1"
    local cur; cur="$(config_get MT_LAN_SUBNETS 2>/dev/null || true)"
    [[ -z "$cur" ]] && { log_warn "Tidak ada LAN terdaftar."; return; }
    local new; new="$(echo ",$cur," | sed "s|,$cidr,|,|" | sed 's|^,||; s|,$||')"
    config_set MT_LAN_SUBNETS "$new"
    ip route del "$cidr" 2>/dev/null || true
    _mtlan_forward_del "$cidr"
    log_ok "LAN Mikrotik $cidr dihapus."
}

mtlan_list() {
    echo "LAN Mikrotik   : $(mtlan_get_subnets || echo '(kosong)')"
    echo "Hub akun L2TP  : $(config_get MT_HUB_NAME 2>/dev/null || echo '-')"
    echo "Hub IP tunnel  : $(config_get MT_HUB_IP 2>/dev/null || echo '-')"
    echo "Route aktif    :"
    for c in $(mtlan_get_subnets); do
        printf '  %-20s %s\n' "$c" "$(ip route show "$c" 2>/dev/null || echo '(belum ada — hub belum konek?)')"
    done
}

# Tandai akun L2TP sebagai hub Mikrotik dan beri IP statis.
mtlan_set_hub() {
    local name="$1" ip="${2:-10.10.10.2}"
    l2tp_exists "$name" || die "Akun L2TP '$name' tidak ada. Buat dulu: vpn -> 2 -> 1."
    [[ "$ip" =~ ^10\.10\.10\.([2-9]|[1-9][0-9])$ ]] || die "IP hub harus 10.10.10.2 - 10.10.10.99 (di luar pool dinamis)."
    l2tp_set_ip "$name" "$ip"
    config_set MT_HUB_NAME "$name"
    config_set MT_HUB_IP "$ip"
    mtlan_apply_routes
    log_ok "Hub Mikrotik = akun '$name' @ $ip. Reconnect l2tp-client di Mikrotik agar IP statis berlaku."
}

# Pasang route ke semua LAN via hub (jika hub sedang konek) + FORWARD rules.
mtlan_apply_routes() {
    local hub_ip; hub_ip="$(config_get MT_HUB_IP 2>/dev/null || true)"
    for cidr in $(mtlan_get_subnets); do
        if [[ -n "$hub_ip" ]] && ip route get "$hub_ip" 2>/dev/null | grep -q 'dev ppp'; then
            ip route replace "$cidr" via "$hub_ip" 2>/dev/null || true
        fi
        _mtlan_forward_add "$cidr"
    done
}

_mtlan_forward_add() {
    local cidr="$1"
    for src in "$WG_SUBNET" "$L2TP_SUBNET"; do
        iptables -C FORWARD -s "$src" -d "$cidr" -m comment --comment tunn-awg-mtlan -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD -s "$src" -d "$cidr" -m comment --comment tunn-awg-mtlan -j ACCEPT
        iptables -C FORWARD -s "$cidr" -d "$src" -m comment --comment tunn-awg-mtlan -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD -s "$cidr" -d "$src" -m comment --comment tunn-awg-mtlan -j ACCEPT
    done
    # DNAT dari internet -> LAN Mikrotik
    iptables -C FORWARD -d "$cidr" -m conntrack --ctstate DNAT -m comment --comment tunn-awg-mtlan -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD -d "$cidr" -m conntrack --ctstate DNAT -m comment --comment tunn-awg-mtlan -j ACCEPT
    persist_iptables
}

_mtlan_forward_del() {
    local cidr="$1"
    iptables -S FORWARD 2>/dev/null | grep 'tunn-awg-mtlan' | grep -F -- "$cidr" | sed 's/^-A/-D/' \
        | while read -r rule; do
            # shellcheck disable=SC2086
            iptables $rule 2>/dev/null || true
        done
    persist_iptables
}

# Hook pppd: saat hub konek, tambahkan route LAN via IP peer-nya. Dipanggil oleh
# /etc/ppp/ip-up (Debian) dengan env PPP_IFACE, PPP_REMOTE, PEERNAME.
install_ppp_iproute_hook() {
    mkdir -p /etc/ppp/ip-up.d
    cat >/etc/ppp/ip-up.d/99-tunn-awg <<'EOF'
#!/bin/sh
CFG=/etc/tunn-awg/config.env
[ -r "$CFG" ] || exit 0
. "$CFG"
[ -n "${MT_LAN_SUBNETS:-}" ] || exit 0
[ -n "${MT_HUB_NAME:-}" ] || exit 0
# Cocokkan berdasarkan nama akun (PEERNAME) ATAU IP statis hub.
if [ "${PEERNAME:-}" = "$MT_HUB_NAME" ] || [ "${PPP_REMOTE:-}" = "${MT_HUB_IP:-x}" ]; then
    for cidr in $(echo "$MT_LAN_SUBNETS" | tr ',' ' '); do
        ip route replace "$cidr" via "$PPP_REMOTE" dev "$PPP_IFACE" 2>/dev/null || true
    done
    logger -t tunn-awg "hub $PEERNAME up on $PPP_IFACE ($PPP_REMOTE): route LAN dipasang"
fi
exit 0
EOF
    chmod 755 /etc/ppp/ip-up.d/99-tunn-awg
}
