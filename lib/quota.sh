#!/usr/bin/env bash
# Traffic accounting: WG via 'wg show transfer', L2TP via ppp counters.
# Called periodically by tunn-awg-quota.timer.

quota_collect() {
    local ts; ts="$(date -Iseconds)"

    # WireGuard: pubkey rx_bytes tx_bytes
    if command -v wg >/dev/null 2>&1 && wg show wg0 >/dev/null 2>&1; then
        while read -r pk rx tx; do
            [[ -z "$pk" ]] && continue
            local total=$(( rx + tx ))
            sqlite3 "$TUNN_DB" \
                "UPDATE users SET used_bytes = $total \
                 WHERE type='wg' AND pubkey='$pk';" 2>/dev/null || true
        done < <(wg show wg0 transfer 2>/dev/null)
    fi

    # L2TP: iterasi ppp interface, ambil rx+tx dari /proc/net/dev, map ke user via ip peer.
    while read -r ppp; do
        [[ -z "$ppp" ]] && continue
        local stats rx tx peer_ip user
        stats="$(awk -v i="${ppp}:" '$1==i {print $2, $10}' /proc/net/dev)"
        [[ -z "$stats" ]] && continue
        rx="${stats%% *}"; tx="${stats##* }"
        peer_ip="$(ip -o -4 addr show "$ppp" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
        # username tidak selalu tersedia; fallback update semua peer aktif berdasarkan IP jika ada mapping.
        # Untuk sederhana: update kolom used_bytes utk baris yang name==ppp label kalau ada tabel ppp_sessions.
        sqlite3 "$TUNN_DB" \
            "INSERT INTO ppp_sessions(iface,peer_ip,rx,tx,seen_at) VALUES('$ppp','$peer_ip',$rx,$tx,'$ts') \
             ON CONFLICT(iface) DO UPDATE SET rx=$rx, tx=$tx, seen_at='$ts';" 2>/dev/null || true
    done < <(ip -o link show 2>/dev/null | awk -F': ' '/ppp[0-9]+/ {print $2}' | cut -d'@' -f1)

    quota_enforce
}

quota_enforce() {
    # Suspend akun WG yang used >= quota (quota > 0).
    while read -r name pk; do
        [[ -z "$name" ]] && continue
        # Hapus peer runtime tanpa hapus dari conf (agar bisa di-restore).
        wg set wg0 peer "$pk" remove 2>/dev/null || true
        sqlite3 "$TUNN_DB" "UPDATE users SET suspended=1 WHERE type='wg' AND name='$name';" 2>/dev/null || true
        _notify "⛔ WG '$name' di-suspend: quota habis."
    done < <(sqlite3 -separator ' ' "$TUNN_DB" \
        "SELECT name,pubkey FROM users \
         WHERE type='wg' AND quota_bytes>0 AND used_bytes>=quota_bytes AND suspended=0;" 2>/dev/null)
}

_notify() {
    local msg="$1"
    # Delegasi ke bot via file drop; bot polling akan menariknya.
    mkdir -p /var/lib/tunn-awg/notify
    printf '%s\n' "$msg" >> "/var/lib/tunn-awg/notify/$(date +%s%N).txt"
}
