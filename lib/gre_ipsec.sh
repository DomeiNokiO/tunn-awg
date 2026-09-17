#!/usr/bin/env bash
# GRE-over-IPsec site-to-site (VPS <-> Mikrotik) wizard.

: "${GRE_TRANSPORT_NET:=10.99.99.0/30}"
: "${GRE_LOCAL_TRANSPORT:=10.99.99.1}"
: "${GRE_REMOTE_TRANSPORT:=10.99.99.2}"
: "${GRE_IF:=gre-mt}"

gre_ipsec_setup() {
    log_step "Wizard GRE-over-IPsec (site-to-site VPS <-> Mikrotik)"

    local vps_ip mt_ip mt_lan psk
    vps_ip="$(detect_public_ip)"
    read -rp "IP publik Mikrotik: " mt_ip
    [[ "$mt_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "IP tidak valid."
    read -rp "Subnet LAN di belakang Mikrotik (mis. 192.168.88.0/24): " mt_lan
    [[ "$mt_lan" =~ ^[0-9./]+$ ]] || die "Subnet tidak valid."
    psk="$(config_get GRE_PSK 2>/dev/null)"
    if [[ -z "$psk" ]]; then
        psk="$(gen_psk)"
        config_set GRE_PSK "$psk"
    fi
    config_set MT_PUBLIC_IP "$mt_ip"
    config_set MT_LAN "$mt_lan"

    _gre_iface_up "$vps_ip" "$mt_ip" "$mt_lan"
    _gre_ipsec_conn "$vps_ip" "$mt_ip"

    # Persist GRE iface via systemd oneshot yang idempotent.
    _gre_systemd_persist "$vps_ip" "$mt_ip" "$mt_lan"

    log_ok "GRE up. Transport: $GRE_LOCAL_TRANSPORT <-> $GRE_REMOTE_TRANSPORT"
    echo
    log_info "Snippet Mikrotik (paste ke terminal Winbox):"
    echo "-----------------8<-----------------"
    generate_mikrotik_gre_snippet "$vps_ip" "$mt_ip" "$mt_lan" "$psk"
    echo "-----------------8<-----------------"
}

_gre_iface_up() {
    local vps_ip="$1" mt_ip="$2" mt_lan="$3"
    ip tunnel del "$GRE_IF" 2>/dev/null || true
    ip tunnel add "$GRE_IF" mode gre remote "$mt_ip" local "$vps_ip" ttl 255
    ip addr add "${GRE_LOCAL_TRANSPORT}/30" dev "$GRE_IF"
    ip link set "$GRE_IF" up mtu 1400
    ip route replace "$mt_lan" via "$GRE_REMOTE_TRANSPORT" dev "$GRE_IF"
}

_gre_ipsec_conn() {
    local vps_ip="$1" mt_ip="$2"
    cat >/etc/ipsec.d/gre-mt.conf <<EOF
conn GRE-MT
    keyexchange=ikev1
    authby=secret
    auto=start
    type=transport
    left=$vps_ip
    leftid=$vps_ip
    leftprotoport=gre
    right=$mt_ip
    rightid=$mt_ip
    rightprotoport=gre
    ike=aes128-sha1-modp2048,aes256-sha256-modp2048!
    esp=aes128-sha1,aes256-sha256!
    pfs=no
    dpddelay=30
    dpdtimeout=120
    dpdaction=restart
EOF
    umask 077
    cat >/etc/ipsec.d/gre-mt.secrets <<EOF
$(detect_public_ip) $(config_get MT_PUBLIC_IP) : PSK "$(config_get GRE_PSK)"
EOF
    chmod 600 /etc/ipsec.d/gre-mt.secrets
    ipsec reload >/dev/null 2>&1 || systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null
    ipsec up GRE-MT >/dev/null 2>&1 || true
}

_gre_systemd_persist() {
    local vps_ip="$1" mt_ip="$2" mt_lan="$3"
    cat >/etc/systemd/system/tunn-awg-gre.service <<EOF
[Unit]
Description=tunn-awg GRE interface (Mikrotik)
After=network-online.target strongswan-starter.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'ip tunnel add $GRE_IF mode gre remote $mt_ip local $vps_ip ttl 255 2>/dev/null; \
    ip addr add ${GRE_LOCAL_TRANSPORT}/30 dev $GRE_IF 2>/dev/null; \
    ip link set $GRE_IF up mtu 1400; \
    ip route replace $mt_lan via $GRE_REMOTE_TRANSPORT dev $GRE_IF'
ExecStop=/bin/bash -c 'ip tunnel del $GRE_IF 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now tunn-awg-gre.service >/dev/null 2>&1
}
