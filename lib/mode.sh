#!/usr/bin/env bash
# Set/get operating mode (gateway | tunnel | hybrid) and re-apply firewall.

mode_switch() {
    local m="${1:-}"
    if [[ -z "$m" ]]; then
        echo "Mode saat ini: $(mode_get)"
        echo "Pilih:"
        echo "  1) gateway  - VPS jadi gateway internet klien di belakang Mikrotik"
        echo "  2) tunnel   - Hanya tunnel manajemen, WAN klien tidak diubah"
        echo "  3) hybrid   - Default; port-forward VPS -> LAN Mikrotik on-demand"
        read -rp "Pilihan [1-3]: " opt
        case "$opt" in
            1) m=gateway ;;
            2) m=tunnel ;;
            3) m=hybrid ;;
            *) log_warn "Batal."; return 1 ;;
        esac
    fi
    mode_set "$m"
    nat_apply
    log_ok "Mode disetel ke: $m"
}

portforward_add() {
    local proto="${1:-tcp}" vps_port="$2" dst="$3"
    [[ "$proto" =~ ^(tcp|udp)$ ]] || die "Protokol harus tcp/udp."
    [[ "$vps_port" =~ ^[0-9]+$ ]] || die "Port VPS harus angka."
    [[ "$dst" =~ ^[0-9.]+:[0-9]+$ ]] || die "Tujuan harus format IP:PORT."

    local wan
    wan="$(detect_wan_iface)"
    iptables -t nat -C PREROUTING  -i "$wan" -p "$proto" --dport "$vps_port" -m comment --comment "tunn-awg-fwd" -j DNAT --to-destination "$dst" 2>/dev/null \
        || iptables -t nat -A PREROUTING  -i "$wan" -p "$proto" --dport "$vps_port" -m comment --comment "tunn-awg-fwd" -j DNAT --to-destination "$dst"
    iptables -C FORWARD -d "${dst%%:*}" -p "$proto" --dport "${dst##*:}" -m comment --comment "tunn-awg-fwd" -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD -d "${dst%%:*}" -p "$proto" --dport "${dst##*:}" -m comment --comment "tunn-awg-fwd" -j ACCEPT
    persist_iptables
    sqlite3 "$TUNN_DB" \
        "INSERT INTO port_forwards(proto,vps_port,dest,created_at) VALUES('$proto',$vps_port,'$dst',datetime('now'));" \
        2>/dev/null || true
    log_ok "Port-forward $proto/$vps_port -> $dst aktif."
}

portforward_del() {
    local id="$1"
    local row proto port dst
    row="$(sqlite3 -separator '|' "$TUNN_DB" "SELECT proto,vps_port,dest FROM port_forwards WHERE id=$id;" 2>/dev/null)"
    [[ -z "$row" ]] && die "ID port-forward tidak ditemukan."
    IFS='|' read -r proto port dst <<<"$row"
    local wan; wan="$(detect_wan_iface)"
    iptables -t nat -D PREROUTING -i "$wan" -p "$proto" --dport "$port" -m comment --comment "tunn-awg-fwd" -j DNAT --to-destination "$dst" 2>/dev/null || true
    iptables -D FORWARD -d "${dst%%:*}" -p "$proto" --dport "${dst##*:}" -m comment --comment "tunn-awg-fwd" -j ACCEPT 2>/dev/null || true
    sqlite3 "$TUNN_DB" "DELETE FROM port_forwards WHERE id=$id;" 2>/dev/null || true
    persist_iptables
    log_ok "Port-forward id=$id dihapus."
}

portforward_list() {
    sqlite3 -header -column "$TUNN_DB" \
        "SELECT id, proto, vps_port AS 'VPS_PORT', dest AS 'DEST', created_at FROM port_forwards ORDER BY id;" 2>/dev/null \
        || echo "(kosong)"
}

# Pasang ulang semua DNAT dari DB (dipanggil nat_apply saat boot / ganti mode).
portforward_reapply() {
    local wan; wan="$(detect_wan_iface)"
    [[ -z "$wan" ]] && return 0
    while IFS='|' read -r proto port dst; do
        [[ -z "$proto" ]] && continue
        iptables -t nat -C PREROUTING -i "$wan" -p "$proto" --dport "$port" -m comment --comment "tunn-awg-fwd" -j DNAT --to-destination "$dst" 2>/dev/null \
            || iptables -t nat -A PREROUTING -i "$wan" -p "$proto" --dport "$port" -m comment --comment "tunn-awg-fwd" -j DNAT --to-destination "$dst"
        iptables -C FORWARD -d "${dst%%:*}" -p "$proto" --dport "${dst##*:}" -m comment --comment "tunn-awg-fwd" -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD -d "${dst%%:*}" -p "$proto" --dport "${dst##*:}" -m comment --comment "tunn-awg-fwd" -j ACCEPT
    done < <(sqlite3 -separator '|' "$TUNN_DB" "SELECT proto,vps_port,dest FROM port_forwards;" 2>/dev/null)
}
