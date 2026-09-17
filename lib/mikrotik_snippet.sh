#!/usr/bin/env bash
# Generate Mikrotik RouterOS 6.49 .rsc snippets for L2TP and GRE-over-IPsec.

generate_mikrotik_l2tp_snippet() {
    local vps_ip user pass psk
    vps_ip="$(config_get L2TP_PUBLIC_IP)"
    psk="$(config_get IPSEC_PSK)"
    user="${1:-USERNAME}"
    pass="${2:-}"
    # Ambil password ASLI dari chap-secrets agar tidak mismatch dengan yang diketik manual.
    if [[ -z "$pass" && "$user" != "USERNAME" ]]; then
        pass="$(l2tp_get_pass "$user" 2>/dev/null || true)"
        if [[ -z "$pass" ]]; then
            log_warn "Akun '$user' tidak ada di VPS. Buat dulu: vpn -> 2 -> 1. Snippet memakai placeholder PASSWORD."
            pass="PASSWORD"
        fi
    fi
    [[ -z "$pass" ]] && pass="PASSWORD"

    cat <<EOF
# ============================================================
# Mikrotik RouterOS 6.49 - L2TP/IPsec client ke tunn-awg VPS
# Tempel semua baris di bawah ini ke terminal Winbox/SSH.
# ============================================================

# --- IPsec proposal & profile agar match dengan preset VPS ---
/ip ipsec proposal
set [ find name=default ] enc-algorithms=aes-128-cbc,aes-256-cbc auth-algorithms=sha1 pfs-group=none lifetime=1h

/ip ipsec profile
set [ find name=default ] enc-algorithm=aes-128,aes-256 hash-algorithm=sha1 dh-group=modp2048 lifetime=8h

# --- L2TP client ---
# profile=default: IPsec sudah mengenkripsi tunnel; MPPE (default-encryption) mubazir
# dan di beberapa build ROS 6 memicu "could not negotiate encryption".
/interface l2tp-client
add name=tunn-awg connect-to=$vps_ip user="$user" password="$pass" \\
    use-ipsec=yes ipsec-secret="$psk" \\
    profile=default allow=mschap2 add-default-route=no \\
    keepalive-timeout=30 disabled=no

# --- Firewall: allow return traffic dari tunnel ---
/ip firewall filter
add chain=input in-interface=tunn-awg action=accept comment="tunn-awg L2TP"

# --- MSS clamp agar tidak fragmentasi ---
/ip firewall mangle
add chain=forward out-interface=tunn-awg protocol=tcp tcp-flags=syn \\
    action=change-mss new-mss=1360 tcp-mss=!0-1360 comment="tunn-awg MSS"

# --- (Opsional) Route LAN via tunnel + NAT untuk downstream ---
# /ip route add dst-address=0.0.0.0/0 gateway=tunn-awg distance=1 comment="via tunn-awg"
# /ip firewall nat add chain=srcnat out-interface=tunn-awg action=masquerade
EOF
}

generate_mikrotik_gre_snippet() {
    local vps_ip="${1:-VPS_PUBLIC_IP}" mt_ip="${2:-MT_PUBLIC_IP}" mt_lan="${3:-192.168.88.0/24}" psk="${4:-PSK}"
    local remote_transport="${GRE_REMOTE_TRANSPORT:-10.99.99.2}"
    local local_transport="${GRE_LOCAL_TRANSPORT:-10.99.99.1}"

    cat <<EOF
# ============================================================
# Mikrotik RouterOS 6.49 - GRE-over-IPsec ke tunn-awg VPS
# ============================================================

# --- GRE interface ---
/interface gre
add name=tunn-gre remote-address=$vps_ip local-address=$mt_ip !keepalive \\
    ipsec-secret="$psk" allow-fast-path=no disabled=no

# --- IP transport GRE ---
/ip address
add address=$remote_transport/30 interface=tunn-gre

# --- Route ke tunn-awg loopback (jika dipakai) & default via tunnel bila mode gateway ---
/ip route
add dst-address=$local_transport/32 gateway=tunn-gre

# --- IPsec policy encrypt GRE otomatis dibuat oleh 'ipsec-secret' di GRE interface ---
# --- MSS clamp untuk kestabilan TCP over GRE ---
/ip firewall mangle
add chain=forward out-interface=tunn-gre protocol=tcp tcp-flags=syn \\
    action=change-mss new-mss=1360 tcp-mss=!0-1360 comment="tunn-awg GRE MSS"

# --- Firewall accept GRE ---
/ip firewall filter
add chain=input protocol=gre action=accept comment="tunn-awg GRE"

# --- Contoh mode Gateway: default route + NAT LAN via GRE ---
# /ip route add dst-address=0.0.0.0/0 gateway=$local_transport distance=1 comment="via tunn-awg GRE"
# /ip firewall nat add chain=srcnat src-address=$mt_lan out-interface=tunn-gre action=masquerade
EOF
}
