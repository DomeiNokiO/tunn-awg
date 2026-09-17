#!/usr/bin/env bash
# LAN di belakang Mikrotik — MULTI-HUB.
#
# Setiap Mikrotik = satu "hub": akun L2TP + IP tunnel statis (10.10.10.2-99) + label.
# Setiap subnet LAN ditautkan ke hub pemiliknya. Subnet antar hub TIDAK boleh overlap.
#
#   mt_hubs(name PK = akun L2TP, ip UNIQUE, label)
#   mt_lans(cidr PK, hub -> mt_hubs.name, note)
#
# Alur paket: HP (WG) / internet (DNAT) -> VPS -> route <cidr> via <hub ip> (ppp) -> Mikrotik -> LAN.
# Return path aman: VPS MASQUERADE keluar ppp+ (LAN membalas ke 10.10.10.1).

: "${WG_SUBNET:=10.7.0.0/24}"
: "${L2TP_SUBNET:=10.10.10.0/24}"

_mtdb() { sqlite3 "$TUNN_DB" "$@" 2>/dev/null; }

mtlan_db_init() {
    sqlite3 "$TUNN_DB" >/dev/null 2>&1 <<'EOF'
CREATE TABLE IF NOT EXISTS mt_hubs (
    name  TEXT PRIMARY KEY,
    ip    TEXT NOT NULL UNIQUE,
    label TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS mt_lans (
    cidr TEXT PRIMARY KEY,
    hub  TEXT NOT NULL REFERENCES mt_hubs(name) ON DELETE CASCADE,
    note TEXT DEFAULT ''
);
EOF
    _mtlan_migrate_legacy
}

# v3.0.3 menyimpan single hub di config.env; pindahkan ke DB sekali saja.
_mtlan_migrate_legacy() {
    local hn hip lans
    hn="$(config_get MT_HUB_NAME 2>/dev/null || true)"
    hip="$(config_get MT_HUB_IP 2>/dev/null || true)"
    lans="$(config_get MT_LAN_SUBNETS 2>/dev/null || true)"
    [[ -z "$hn" || -z "$hip" ]] && return 0
    _mtdb "INSERT OR IGNORE INTO mt_hubs(name,ip,label) VALUES('$hn','$hip','$hn');"
    for c in ${lans//,/ }; do
        _mtdb "INSERT OR IGNORE INTO mt_lans(cidr,hub) VALUES('$c','$hn');"
    done
    sed -i '/^MT_HUB_NAME=/d; /^MT_HUB_IP=/d; /^MT_LAN_SUBNETS=/d' "$TUNN_CONFIG" 2>/dev/null || true
    log_info "Migrasi hub lama '$hn' ($hip) ke DB multi-hub selesai."
}

# Resolve nama-atau-label -> nama akun. Kosong bila tidak ada.
_mtlan_resolve_hub() {
    _mtdb "SELECT name FROM mt_hubs WHERE name='$1' OR label='$1' LIMIT 1;"
}

# ---------- HUB ----------
mtlan_hub_add() {
    local name="$1" ip="${2:-}" label="${3:-$1}"
    l2tp_exists "$name" || die "Akun L2TP '$name' tidak ada. Buat dulu: vpn -> 2 -> 1."
    [[ -z "$ip" || "$ip" == "auto" ]] && ip="$(mtlan_next_hub_ip)"
    [[ "$ip" =~ ^10\.10\.10\.([2-9]|[1-9][0-9])$ ]] || die "IP hub harus 10.10.10.2 - 10.10.10.99."
    local used; used="$(_mtdb "SELECT name FROM mt_hubs WHERE ip='$ip' AND name<>'$name';")"
    [[ -n "$used" ]] && die "IP $ip sudah dipakai hub '$used'."
    local dup; dup="$(_mtdb "SELECT name FROM mt_hubs WHERE label='$label' AND name<>'$name';")"
    [[ -n "$dup" ]] && die "Label '$label' sudah dipakai hub '$dup'."
    l2tp_set_ip "$name" "$ip"
    _mtdb "INSERT INTO mt_hubs(name,ip,label) VALUES('$name','$ip','$label')
           ON CONFLICT(name) DO UPDATE SET ip=excluded.ip, label=excluded.label;"
    mtlan_apply_routes
    log_ok "Hub '$label' = akun '$name' @ $ip. Reconnect l2tp-client di Mikrotik agar IP statis berlaku."
}

mtlan_hub_del() {
    local name; name="$(_mtlan_resolve_hub "$1")"
    [[ -n "$name" ]] || die "Hub '$1' tidak ada."
    for c in $(_mtdb "SELECT cidr FROM mt_lans WHERE hub='$name';"); do
        ip route del "$c" 2>/dev/null || true
        _mtlan_forward_del "$c"
    done
    _mtdb "DELETE FROM mt_lans WHERE hub='$name'; DELETE FROM mt_hubs WHERE name='$name';"
    l2tp_set_ip "$name" "*" >/dev/null 2>&1 || true
    log_ok "Hub '$name' dan LAN-nya dihapus (akun L2TP tetap ada, IP kembali dinamis)."
}

mtlan_next_hub_ip() {
    local i
    for i in $(seq 2 99); do
        [[ -z "$(_mtdb "SELECT 1 FROM mt_hubs WHERE ip='10.10.10.$i';")" ]] && { echo "10.10.10.$i"; return; }
    done
    die "Slot IP hub habis."
}

mtlan_hub_count() { _mtdb "SELECT COUNT(*) FROM mt_hubs;"; }

# ---------- LAN ----------
mtlan_add() {
    local cidr="$1" hub="${2:-}" note="${3:-}"
    [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || die "CIDR tidak valid: $cidr (contoh 192.168.88.0/24)"
    if [[ -z "$hub" ]]; then
        local n; n="$(mtlan_hub_count)"
        [[ "$n" == "1" ]] && hub="$(_mtdb "SELECT name FROM mt_hubs;")"
        [[ -z "$hub" ]] && die "Ada ${n:-0} hub; sebutkan hub pemilik. Contoh: set lan $cidr hub A"
    fi
    local resolved; resolved="$(_mtlan_resolve_hub "$hub")"
    [[ -n "$resolved" ]] || die "Hub '$hub' tidak ada. Daftarkan dulu (vpn -> 4 -> 7)."
    hub="$resolved"
    local owner; owner="$(_mtdb "SELECT hub FROM mt_lans WHERE cidr='$cidr';")"
    if [[ -n "$owner" && "$owner" != "$hub" ]]; then
        die "$cidr sudah milik hub '$owner'. Subnet antar site tidak boleh sama."
    fi
    _mtdb "INSERT INTO mt_lans(cidr,hub,note) VALUES('$cidr','$hub','$note')
           ON CONFLICT(cidr) DO UPDATE SET hub=excluded.hub,
           note=CASE WHEN excluded.note<>'' THEN excluded.note ELSE mt_lans.note END;"
    mtlan_apply_routes
    log_ok "LAN $cidr -> hub '$hub'${note:+ ($note)}."
}

mtlan_del() {
    local cidr="$1"
    [[ -n "$(_mtdb "SELECT 1 FROM mt_lans WHERE cidr='$cidr';")" ]] || { log_warn "$cidr tidak terdaftar."; return; }
    _mtdb "DELETE FROM mt_lans WHERE cidr='$cidr';"
    ip route del "$cidr" 2>/dev/null || true
    _mtlan_forward_del "$cidr"
    log_ok "LAN $cidr dihapus."
}

# Semua subnet (untuk AllowedIPs split-lan, dll).
mtlan_get_subnets() { _mtdb "SELECT cidr FROM mt_lans ORDER BY cidr;" | xargs 2>/dev/null || true; }

# ---------- STATUS / CEK ----------
_mtlan_hub_iface() {
    ip -o route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | grep '^ppp' || true
}

_hr() { command -v numfmt >/dev/null 2>&1 && numfmt --to=iec "${1:-0}" 2>/dev/null || echo "${1:-0}"; }

# Ringkasan per hub: status, LAN, route aktual, port-forward yang mengarah ke hub/LAN-nya.
mtlan_list() {
    local n; n="$(mtlan_hub_count)"
    [[ -z "$n" || "$n" == "0" ]] && { echo "(belum ada hub — daftarkan: vpn -> 4 -> 7)"; return; }
    local name ip label iface st rx tx
    while IFS='|' read -r name ip label; do
        [[ -z "$name" ]] && continue
        iface="$(_mtlan_hub_iface "$ip")"
        if [[ -n "$iface" ]]; then
            read -r rx tx < <(awk -v i="${iface}:" '$1==i {print $2, $10}' /proc/net/dev)
            st="ONLINE  $iface  rx=$(_hr "$rx") tx=$(_hr "$tx")"
        else
            st="OFFLINE"
        fi
        printf '\n[%s]  akun=%s  ip=%s  %s\n' "$label" "$name" "$ip" "$st"
        local c note r
        while IFS='|' read -r c note; do
            [[ -z "$c" ]] && continue
            r="$(ip route show "$c" 2>/dev/null)"
            printf '   LAN %-20s %-16s %s\n' "$c" "${note:+($note)}" "${r:+route: $r}"
            [[ -z "$r" ]] && printf '   %-24s %s\n' "" "(route belum ada — hub offline?)"
        done < <(_mtdb -separator '|' "SELECT cidr,COALESCE(note,'') FROM mt_lans WHERE hub='$name' ORDER BY cidr;")
        [[ -z "$(_mtdb "SELECT 1 FROM mt_lans WHERE hub='$name' LIMIT 1;")" ]] && echo "   (belum ada LAN — vpn -> 4 -> 9)"
        local pf; pf="$(_mtlan_pf_for_hub "$name")"
        [[ -n "$pf" ]] && { echo "   Port-forward:"; echo "$pf" | sed 's/^/     /'; }
    done < <(_mtdb -separator '|' "SELECT name,ip,COALESCE(NULLIF(label,''),name) FROM mt_hubs ORDER BY ip;")
    echo
}

_mtlan_pf_for_hub() {
    local hub="$1" ip cidrs
    ip="$(_mtdb "SELECT ip FROM mt_hubs WHERE name='$hub';")"
    cidrs="$(_mtdb "SELECT cidr FROM mt_lans WHERE hub='$hub';" | xargs)"
    _mtdb -separator '|' "SELECT id,proto,vps_port,dest FROM port_forwards ORDER BY id;" \
    | while IFS='|' read -r id proto port dest; do
        local dip="${dest%%:*}"
        if [[ "$dip" == "$ip" ]] || _mtlan_ip_in_any "$dip" "$cidrs"; then
            printf 'id=%s  %s/%s -> %s\n' "$id" "$proto" "$port" "$dest"
        fi
    done
}

# ip dalam salah satu cidr? (python ipaddress agar netmask benar)
_mtlan_ip_in_any() {
    local ip="$1" cidrs="$2"
    [[ -z "$cidrs" ]] && return 1
    # shellcheck disable=SC2086
    python3 - "$ip" $cidrs <<'PY' 2>/dev/null
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ip in ipaddress.ip_network(c, strict=False) for c in sys.argv[2:]) else 1)
PY
}

# IP ini lewat hub mana?
mtlan_whois() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "IP tidak valid."
    local hit; hit="$(_mtdb "SELECT name FROM mt_hubs WHERE ip='$ip';")"
    if [[ -n "$hit" ]]; then echo "$ip = IP tunnel hub '$hit'"; return; fi
    while IFS='|' read -r cidr hub hip; do
        if _mtlan_ip_in_any "$ip" "$cidr"; then
            local st; st="$([[ -n "$(_mtlan_hub_iface "$hip")" ]] && echo ONLINE || echo OFFLINE)"
            echo "$ip termasuk $cidr -> hub '$hub' ($hip) $st"
            return
        fi
    done < <(_mtdb -separator '|' "SELECT l.cidr,h.name,h.ip FROM mt_lans l JOIN mt_hubs h ON h.name=l.hub;")
    echo "$ip tidak termasuk LAN terdaftar mana pun (VPS akan mengirimnya ke internet)."
}

_mtlan_first_host() {
    python3 -c "import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1],strict=False); print(next(n.hosts()))" "$1" 2>/dev/null
}

# Tes konektivitas: semua hub + gateway (.1) tiap LAN; atau 1 IP spesifik.
mtlan_check() {
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        mtlan_whois "$target"
        printf 'ping %-16s ' "$target"; ping -c2 -W2 "$target" >/dev/null 2>&1 && echo OK || echo GAGAL
        return
    fi
    local name ip label
    while IFS='|' read -r name ip label; do
        [[ -z "$name" ]] && continue
        printf '[%s] hub %-14s ' "$label" "$ip"; ping -c1 -W2 "$ip" >/dev/null 2>&1 && echo OK || echo "GAGAL (offline?)"
        for c in $(_mtdb "SELECT cidr FROM mt_lans WHERE hub='$name';"); do
            local gw; gw="$(_mtlan_first_host "$c")"
            [[ -z "$gw" ]] && continue
            printf '     LAN %-18s gw %-14s ' "$c" "$gw"; ping -c1 -W2 "$gw" >/dev/null 2>&1 && echo OK || echo GAGAL
        done
    done < <(_mtdb -separator '|' "SELECT name,ip,COALESCE(NULLIF(label,''),name) FROM mt_hubs ORDER BY ip;")
}

# Peta ringkas satu baris per hub.
mtlan_map() {
    local name ip label st
    while IFS='|' read -r name ip label; do
        [[ -z "$name" ]] && continue
        st="$([[ -n "$(_mtlan_hub_iface "$ip")" ]] && echo "[ON ]" || echo "[OFF]")"
        printf '%s %s (%s @ %s): %s\n' "$st" "$label" "$name" "$ip" \
            "$(_mtdb "SELECT COALESCE(GROUP_CONCAT(cidr,', '),'-') FROM mt_lans WHERE hub='$name';")"
    done < <(_mtdb -separator '|' "SELECT name,ip,COALESCE(NULLIF(label,''),name) FROM mt_hubs ORDER BY ip;")
}

# ---------- ROUTE / FORWARD ----------
mtlan_apply_routes() {
    local cidr hub ip
    while IFS='|' read -r cidr hub ip; do
        [[ -z "$cidr" ]] && continue
        if [[ -n "$(_mtlan_hub_iface "$ip")" ]]; then
            ip route replace "$cidr" via "$ip" 2>/dev/null || true
        fi
        _mtlan_forward_add "$cidr"
    done < <(_mtdb -separator '|' "SELECT l.cidr,h.name,h.ip FROM mt_lans l JOIN mt_hubs h ON h.name=l.hub;")
}

_mtlan_forward_add() {
    local cidr="$1" src
    for src in "$WG_SUBNET" "$L2TP_SUBNET"; do
        iptables -C FORWARD -s "$src" -d "$cidr" -m comment --comment tunn-awg-mtlan -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD -s "$src" -d "$cidr" -m comment --comment tunn-awg-mtlan -j ACCEPT
        iptables -C FORWARD -s "$cidr" -d "$src" -m comment --comment tunn-awg-mtlan -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD -s "$cidr" -d "$src" -m comment --comment tunn-awg-mtlan -j ACCEPT
    done
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

# Hook pppd (env: PPP_IFACE, PPP_REMOTE, PEERNAME): route LAN saat hub konek + notif bot.
install_ppp_iproute_hook() {
    mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d /var/lib/tunn-awg/notify
    cat >/etc/ppp/ip-up.d/99-tunn-awg <<'EOF'
#!/bin/sh
DB=/etc/tunn-awg/data.db
[ -r "$DB" ] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0
HUB=$(sqlite3 "$DB" "SELECT name FROM mt_hubs WHERE name='${PEERNAME:-}' OR ip='${PPP_REMOTE:-}' LIMIT 1;" 2>/dev/null)
[ -n "$HUB" ] || exit 0
for cidr in $(sqlite3 "$DB" "SELECT cidr FROM mt_lans WHERE hub='$HUB';" 2>/dev/null); do
    ip route replace "$cidr" via "$PPP_REMOTE" dev "$PPP_IFACE" 2>/dev/null || true
done
logger -t tunn-awg "hub $HUB up on $PPP_IFACE ($PPP_REMOTE): route LAN dipasang"
mkdir -p /var/lib/tunn-awg/notify
printf '🟢 Hub Mikrotik <b>%s</b> online (%s, %s)\n' "$HUB" "$PPP_IFACE" "$PPP_REMOTE" > "/var/lib/tunn-awg/notify/$(date +%s%N).txt"
exit 0
EOF
    chmod 755 /etc/ppp/ip-up.d/99-tunn-awg

    cat >/etc/ppp/ip-down.d/99-tunn-awg <<'EOF'
#!/bin/sh
DB=/etc/tunn-awg/data.db
[ -r "$DB" ] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0
HUB=$(sqlite3 "$DB" "SELECT name FROM mt_hubs WHERE name='${PEERNAME:-}' OR ip='${PPP_REMOTE:-}' LIMIT 1;" 2>/dev/null)
[ -n "$HUB" ] || exit 0
logger -t tunn-awg "hub $HUB down ($PPP_IFACE)"
mkdir -p /var/lib/tunn-awg/notify
printf '🔴 Hub Mikrotik <b>%s</b> offline (%s)\n' "$HUB" "$PPP_IFACE" > "/var/lib/tunn-awg/notify/$(date +%s%N).txt"
exit 0
EOF
    chmod 755 /etc/ppp/ip-down.d/99-tunn-awg
}
