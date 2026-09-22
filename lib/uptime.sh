#!/usr/bin/env bash
# Watcher hub Mikrotik: transisi ON/OFF -> notif Telegram + log per hub.
# Dipanggil setiap 30 detik oleh tunn-awg-hubwatch.timer.

: "${TUNN_UPTIME_DIR:=/var/lib/tunn-awg/uptime}"

hub_watch_run() {
    mkdir -p "$TUNN_UPTIME_DIR" /var/lib/tunn-awg/notify
    local name ip label prev_state cur_state
    while IFS='|' read -r name ip label; do
        [[ -z "$name" ]] && continue
        if [[ -n "$(_mtlan_hub_iface "$ip")" ]]; then cur_state="up"; else cur_state="down"; fi
        prev_state="$(cat "$TUNN_UPTIME_DIR/$name.state" 2>/dev/null || echo unknown)"
        printf '%s %s\n' "$(date -Iseconds)" "$cur_state" >> "$TUNN_UPTIME_DIR/$name.log"
        if [[ "$prev_state" != "$cur_state" && "$prev_state" != "unknown" ]]; then
            local emoji msg
            [[ "$cur_state" == "up" ]] && emoji="🟢" || emoji="🔴"
            msg="$emoji Hub Mikrotik <b>$label</b> ($name @ $ip) → <b>$cur_state</b>"
            printf '%s\n' "$msg" > "/var/lib/tunn-awg/notify/hub-$name-$(date +%s).txt"
            logger -t tunn-awg "hubwatch: $name $prev_state -> $cur_state"
        fi
        echo "$cur_state" > "$TUNN_UPTIME_DIR/$name.state"
    done < <(sqlite3 -separator '|' "$TUNN_DB" "SELECT name,ip,COALESCE(NULLIF(label,''),name) FROM mt_hubs ORDER BY ip;" 2>/dev/null)
}

# Laporan uptime N jam terakhir (default 24) per hub.
hub_uptime_report() {
    local hours="${1:-24}"
    local since_epoch; since_epoch=$(( $(date +%s) - hours*3600 ))
    local name ip label
    while IFS='|' read -r name ip label; do
        [[ -z "$name" ]] && continue
        local log="$TUNN_UPTIME_DIR/$name.log"
        if [[ ! -s "$log" ]]; then
            printf '[%s] %s @ %s : (belum ada data)\n' "$label" "$name" "$ip"
            continue
        fi
        awk -v since="$since_epoch" -v label="$label" -v name="$name" -v ip="$ip" '
            function ts(s,    cmd,r) { cmd="date -d\"" s "\" +%s"; cmd | getline r; close(cmd); return r+0 }
            BEGIN { last_t=0; last_s=""; up_secs=0; total_secs=0; trans=0 }
            {
                t=ts($1); s=$2
                if (t < since) { last_t=t; last_s=s; next }
                if (last_t==0) { last_t=t; last_s=s; next }
                dt = t - last_t
                total_secs += dt
                if (last_s == "up") up_secs += dt
                if (last_s != s) trans++
                last_t=t; last_s=s
            }
            END {
                if (total_secs == 0) { printf "[%s] %s @ %s : belum cukup data\n", label, name, ip; exit }
                pct = up_secs*100.0/total_secs
                printf "[%s] %s @ %s : ONLINE %.1f%%  transisi=%d  data=%dm  state_akhir=%s\n",
                       label, name, ip, pct, trans, int(total_secs/60), last_s
            }' "$log"
    done < <(sqlite3 -separator '|' "$TUNN_DB" "SELECT name,ip,COALESCE(NULLIF(label,''),name) FROM mt_hubs ORDER BY ip;" 2>/dev/null)
}

hub_uptime_reset() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        rm -f "$TUNN_UPTIME_DIR"/*.log "$TUNN_UPTIME_DIR"/*.state 2>/dev/null || true
        log_ok "Semua log uptime hub dihapus."
    else
        rm -f "$TUNN_UPTIME_DIR/$name.log" "$TUNN_UPTIME_DIR/$name.state" 2>/dev/null || true
        log_ok "Log uptime hub '$name' dihapus."
    fi
}
