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
    local proto="${1:-tcp}" vps_port="$2" dst="$3" allow_from="${4:-}"
    [[ "$proto" =~ ^(tcp|udp)$ ]] || die "Protokol harus tcp/udp."
    [[ "$vps_port" =~ ^[0-9]+$ ]] || die "Port VPS harus angka."
    [[ "$dst" =~ ^[0-9.]+:[0-9]+$ ]] || die "Tujuan harus format IP:PORT."
    if [[ -n "$allow_from" ]]; then
        for x in ${allow_from//,/ }; do
            [[ "$x" =~ ^[0-9.]+(/[0-9]+)?$ ]] || die "Whitelist tidak valid: $x (contoh 1.2.3.4 atau 10.0.0.0/8)"
        done
    fi

    _pf_ensure_schema
    sqlite3 "$TUNN_DB" \
        "INSERT INTO port_forwards(proto,vps_port,dest,allow_from,created_at) VALUES('$proto',$vps_port,'$dst','$allow_from',datetime('now'));" \
        2>/dev/null || true
    portforward_reapply
    log_ok "Port-forward $proto/$vps_port -> $dst${allow_from:+ (whitelist: $allow_from)} aktif."
}

portforward_del() {
    local id="$1"
    _pf_ensure_schema
    local row proto port dst
    row="$(sqlite3 -separator '|' "$TUNN_DB" "SELECT proto,vps_port,dest FROM port_forwards WHERE id=$id;" 2>/dev/null)"
    [[ -z "$row" ]] && die "ID port-forward tidak ditemukan."
    IFS='|' read -r proto port dst <<<"$row"
    sqlite3 "$TUNN_DB" "DELETE FROM port_forwards WHERE id=$id;" 2>/dev/null || true
    portforward_reapply
    log_ok "Port-forward id=$id dihapus."
}

portforward_show() {
    local id="$1"
    _pf_ensure_schema
    sqlite3 -header -column "$TUNN_DB" \
        "SELECT id, proto, vps_port AS 'VPS_PORT', dest AS 'DEST', COALESCE(NULLIF(allow_from,''),'*any*') AS 'WHITELIST', created_at FROM port_forwards WHERE id=$id;" \
        2>/dev/null || die "ID tidak ditemukan."
}

portforward_list() {
    _pf_ensure_schema
    sqlite3 -header -column "$TUNN_DB" \
        "SELECT id, proto, vps_port AS 'VPS_PORT', dest AS 'DEST', COALESCE(NULLIF(allow_from,''),'*any*') AS 'WHITELIST', created_at FROM port_forwards ORDER BY id;" 2>/dev/null \
        || echo "(kosong)"
}

_pf_ensure_schema() {
    local cols; cols="$(sqlite3 "$TUNN_DB" "PRAGMA table_info(port_forwards);" 2>/dev/null | awk -F'|' '{print $2}')"
    if ! grep -qx allow_from <<<"$cols"; then
        sqlite3 "$TUNN_DB" "ALTER TABLE port_forwards ADD COLUMN allow_from TEXT DEFAULT '';" 2>/dev/null || true
    fi
}

# Pasang ulang SEMUA rule PF dari DB (dipanggil nat_apply). Idempotent.
portforward_reapply() {
    local wan; wan="$(detect_wan_iface)"
    [[ -z "$wan" ]] && return 0
    _pf_ensure_schema
    # Bersihkan rule tunn-awg-fwd lama.
    iptables-save | grep -vE -- '--comment "?tunn-awg-fwd(-guard)?"?( |$)' | iptables-restore 2>/dev/null || true

    while IFS='|' read -r proto port dst allow_from; do
        [[ -z "$proto" ]] && continue
        local dip="${dst%%:*}" dport="${dst##*:}"
        if [[ -n "$allow_from" ]]; then
            for src in ${allow_from//,/ }; do
                iptables -t nat -A PREROUTING -i "$wan" -p "$proto" --dport "$port" -s "$src" \
                    -m comment --comment tunn-awg-fwd -j DNAT --to-destination "$dst"
            done
            # Tolak sumber di luar whitelist agar port tidak bocor.
            iptables -A INPUT -i "$wan" -p "$proto" --dport "$port" \
                -m comment --comment tunn-awg-fwd-guard -j DROP
        else
            iptables -t nat -A PREROUTING -i "$wan" -p "$proto" --dport "$port" \
                -m comment --comment tunn-awg-fwd -j DNAT --to-destination "$dst"
        fi
        iptables -I FORWARD -d "$dip" -p "$proto" --dport "$dport" \
            -m comment --comment tunn-awg-fwd -j ACCEPT
    done < <(sqlite3 -separator '|' "$TUNN_DB" "SELECT proto,vps_port,dest,COALESCE(allow_from,'') FROM port_forwards ORDER BY id;" 2>/dev/null)
    persist_iptables
}
