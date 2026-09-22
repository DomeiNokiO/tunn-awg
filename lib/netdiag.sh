#!/usr/bin/env bash
# Diagnosa jaringan ke satu IP tujuan (mtr / ping / MTU / tcpdump ppp+).

net_diag() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "IP tidak valid."
    echo "===== tunn-awg net_diag $ip $(date -Is) ====="
    echo "--- whois (LAN Mikrotik) ---"
    declare -F mtlan_whois >/dev/null && mtlan_whois "$ip"
    echo "--- ip route get ---"
    ip route get "$ip" 2>&1
    echo "--- ping -c3 ---"
    ping -c3 -W2 "$ip" 2>&1
    echo "--- Path MTU (ping -M do -s 1400) ---"
    ping -c1 -W2 -M do -s 1400 "$ip" 2>&1 | tail -3
    if command -v mtr >/dev/null 2>&1; then
        echo "--- mtr -r -c 5 ---"
        mtr -r -c 5 "$ip" 2>&1
    else
        echo "--- traceroute (mtr belum terpasang) ---"
        command -v traceroute >/dev/null 2>&1 && traceroute -n -m 15 "$ip" 2>&1 | head -20 || echo "(mtr/traceroute belum terpasang)"
    fi
    local dev
    dev="$(ip route get "$ip" 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
    if [[ "$dev" == ppp* ]] && command -v tcpdump >/dev/null 2>&1; then
        echo "--- tcpdump 10 paket di $dev host $ip (timeout 5s) ---"
        timeout 5 tcpdump -n -c 10 -i "$dev" host "$ip" 2>&1 | tail -12 || true
    fi
    echo "===== end ====="
}
