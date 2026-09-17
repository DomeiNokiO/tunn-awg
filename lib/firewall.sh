#!/usr/bin/env bash
# Firewall + sysctl + NAT rules for WG/L2TP + mode toggle.

: "${WG_SUBNET:=10.7.0.0/24}"
: "${L2TP_SUBNET:=10.10.10.0/24}"
: "${SYSCTL_FILE:=/etc/sysctl.d/99-tunn-awg.conf}"

# Simpan rule iptables ke source-of-truth kita sendiri (/etc/iptables/rules.v4),
# tidak bergantung pada paket netfilter-persistent yang sering berebut dgn ufw.
# Restore saat boot dilakukan oleh tunn-awg-firewall.service.
persist_iptables() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
}

sysctl_apply() {
    log_step "Menerapkan sysctl hardening + forwarding"
    cat >"$SYSCTL_FILE" <<'EOF'
# tunn-awg: forwarding + IPsec-friendly RP filter + no redirects
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
# Higher backlog for VPN concurrency
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
EOF
    sysctl --system >/dev/null
    log_ok "sysctl diterapkan."
}

ufw_setup() {
    log_step "Konfigurasi UFW"
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 22/tcp comment 'SSH' >/dev/null
    ufw allow 51820/udp comment 'WireGuard' >/dev/null
    ufw allow 500/udp comment 'IKE' >/dev/null
    ufw allow 4500/udp comment 'IPsec NAT-T' >/dev/null
    ufw allow 1701/udp comment 'L2TP' >/dev/null
    ufw --force enable >/dev/null
    log_ok "UFW aktif."
}

iptables_ipsec_esp() {
    # UFW tidak dukung proto ESP/AH langsung — buka via iptables.
    iptables -C INPUT -p esp -j ACCEPT 2>/dev/null || iptables -I INPUT -p esp -j ACCEPT
    iptables -C INPUT -p ah  -j ACCEPT 2>/dev/null || iptables -I INPUT -p ah  -j ACCEPT
}

nat_apply() {
    local mode wan
    mode="$(mode_get)"
    wan="$(detect_wan_iface)"
    [[ -z "$wan" ]] && { log_warn "WAN interface tidak terdeteksi, NAT dilewati."; return; }

    log_step "Menerapkan NAT untuk mode: $mode (WAN: $wan)"

    # Bersihkan HANYA rule mode (tag persis 'tunn-awg'); port-forward (tunn-awg-fwd)
    # dan LAN Mikrotik (tunn-awg-mtlan) di-reapply di bawah dari sumbernya masing-masing.
    iptables-save | grep -vE -- '--comment "?tunn-awg"?( |$)' | iptables-restore

    iptables_ipsec_esp

    # Return-path untuk trafik yang masuk ke LAN Mikrotik lewat tunnel L2TP (DNAT dari
    # internet, atau HP via WG): SNAT ke IP tunnel VPS supaya balasan kembali lewat tunnel.
    iptables -t nat -A POSTROUTING -o 'ppp+' -m comment --comment tunn-awg -j MASQUERADE
    iptables -I FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment tunn-awg -j ACCEPT

    case "$mode" in
        gateway)
            iptables -t nat -A POSTROUTING -s "$WG_SUBNET"   -o "$wan" -m comment --comment tunn-awg -j MASQUERADE
            iptables -t nat -A POSTROUTING -s "$L2TP_SUBNET" -o "$wan" -m comment --comment tunn-awg -j MASQUERADE
            iptables -A FORWARD -s "$WG_SUBNET"   -j ACCEPT -m comment --comment tunn-awg
            iptables -A FORWARD -s "$L2TP_SUBNET" -j ACCEPT -m comment --comment tunn-awg
            iptables -A FORWARD -d "$WG_SUBNET"   -j ACCEPT -m comment --comment tunn-awg
            iptables -A FORWARD -d "$L2TP_SUBNET" -j ACCEPT -m comment --comment tunn-awg
            ;;
        tunnel)
            iptables -A FORWARD -s "$WG_SUBNET"   -d "$WG_SUBNET"   -j ACCEPT -m comment --comment tunn-awg
            iptables -A FORWARD -s "$L2TP_SUBNET" -d "$L2TP_SUBNET" -j ACCEPT -m comment --comment tunn-awg
            ;;
        hybrid)
            iptables -A FORWARD -s "$WG_SUBNET"   -j ACCEPT -m comment --comment tunn-awg
            iptables -A FORWARD -s "$L2TP_SUBNET" -j ACCEPT -m comment --comment tunn-awg
            iptables -A FORWARD -d "$WG_SUBNET"   -j ACCEPT -m comment --comment tunn-awg
            iptables -A FORWARD -d "$L2TP_SUBNET" -j ACCEPT -m comment --comment tunn-awg
            # DNAT rules ditambah runtime oleh port-forward manager; SNAT wajib untuk return path.
            iptables -t nat -A POSTROUTING -s "$WG_SUBNET"   -m comment --comment tunn-awg -j MASQUERADE
            iptables -t nat -A POSTROUTING -s "$L2TP_SUBNET" -m comment --comment tunn-awg -j MASQUERADE
            ;;
    esac

    # Re-apply dari sumber persisten (DB & config.env).
    declare -F portforward_reapply >/dev/null && portforward_reapply
    declare -F mtlan_apply_routes  >/dev/null && mtlan_apply_routes

    persist_iptables
    log_ok "NAT/Forward diterapkan (mode $mode)."
}

firewall_setup() {
    sysctl_apply
    ufw_setup
    nat_apply
}
