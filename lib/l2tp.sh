#!/usr/bin/env bash
# strongSwan + xl2tpd, preset Mikrotik RouterOS 6.49-friendly.

: "${L2TP_LOCAL_IP:=10.10.10.1}"
: "${L2TP_RANGE:=10.10.10.100-10.10.10.200}"
: "${L2TP_DNS1:=1.1.1.1}"
: "${L2TP_DNS2:=1.0.0.1}"

l2tp_server_init() {
    log_step "Inisialisasi L2TP/IPsec (strongSwan + xl2tpd)"

    local pub_ip psk
    pub_ip="$(detect_public_ip)"
    psk="$(config_get IPSEC_PSK 2>/dev/null)"
    if [[ -z "$psk" ]]; then
        psk="$(gen_psk)"
        config_set IPSEC_PSK "$psk"
    fi
    config_set L2TP_PUBLIC_IP "$pub_ip"

    _write_ipsec_conf "$pub_ip"
    _write_ipsec_secrets "$pub_ip" "$psk"
    _write_xl2tpd_conf
    _write_ppp_options

    # Bersihkan lockfile lama xl2tpd yang bikin start gagal senyap.
    rm -f /var/run/xl2tpd/l2tp-control 2>/dev/null || true
    mkdir -p /var/run/xl2tpd

    systemctl enable --now strongswan-starter >/dev/null 2>&1 \
        || systemctl enable --now strongswan >/dev/null 2>&1 || true
    systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null || true

    systemctl enable --now xl2tpd >/dev/null 2>&1
    systemctl restart xl2tpd

    log_ok "L2TP/IPsec siap. PSK tersimpan di $TUNN_CONFIG (IPSEC_PSK)."
}

_write_ipsec_conf() {
    local pub_ip="$1"
    cat >/etc/ipsec.conf <<EOF
# tunn-awg IPsec - preset Mikrotik RouterOS 6.49 compatible
config setup
    uniqueids=never
    charondebug="ike 1, knl 1, cfg 0"

conn %default
    ikelifetime=8h
    keylife=1h
    rekeymargin=3m
    keyingtries=%forever

conn L2TP-PSK
    keyexchange=ikev1
    authby=secret
    auto=add
    type=transport
    left=%defaultroute
    leftid=$pub_ip
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    ike=aes128-sha1-modp2048,aes256-sha1-modp2048,3des-sha1-modp1024!
    esp=aes128-sha1,aes256-sha1,3des-sha1!
    pfs=no
    forceencaps=yes
    dpddelay=30
    dpdtimeout=120
    dpdaction=clear
    rekey=no

include /etc/ipsec.d/*.conf
EOF
    chmod 644 /etc/ipsec.conf
    mkdir -p /etc/ipsec.d
}

_write_ipsec_secrets() {
    local pub_ip="$1" psk="$2"
    umask 077
    cat >/etc/ipsec.secrets <<EOF
$pub_ip %any : PSK "$psk"
EOF
    chmod 600 /etc/ipsec.secrets
    include_line='include /etc/ipsec.d/*.secrets'
    grep -qxF "$include_line" /etc/ipsec.secrets || echo "$include_line" >> /etc/ipsec.secrets
}

_write_xl2tpd_conf() {
    mkdir -p /etc/xl2tpd
    cat >/etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701
access control = no
ipsec saref = no
force userspace = yes

[lns default]
ip range = $L2TP_RANGE
local ip = $L2TP_LOCAL_IP
require chap = yes
refuse pap = yes
require authentication = yes
name = tunn-awg
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF
}

_write_ppp_options() {
    cat >/etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
ms-dns $L2TP_DNS1
ms-dns $L2TP_DNS2
noccp
auth
mtu 1400
mru 1400
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
hide-password
name l2tpd
require-mschap-v2
refuse-pap
refuse-chap
refuse-mschap
EOF
    touch /etc/ppp/chap-secrets
    chmod 600 /etc/ppp/chap-secrets
    grep -qE '^# tunn-awg' /etc/ppp/chap-secrets || \
        sed -i '1i # tunn-awg L2TP users\n# client   server   secret   IP addresses' /etc/ppp/chap-secrets
}

l2tp_add() {
    local user="$1" pass="${2:-}" expires="${3:-}" quota_gb="${4:-0}"
    [[ "$user" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Username hanya boleh a-zA-Z0-9_-."
    grep -qE "^\"?$user\"?[[:space:]]+l2tpd" /etc/ppp/chap-secrets && die "User $user sudah ada."
    [[ -z "$pass" ]] && pass="$(gen_password)"

    printf '"%s"   l2tpd   "%s"   *\n' "$user" "$pass" >> /etc/ppp/chap-secrets
    chmod 600 /etc/ppp/chap-secrets

    local quota_bytes=0
    [[ "$quota_gb" =~ ^[0-9]+$ && "$quota_gb" -gt 0 ]] && quota_bytes=$(( quota_gb * 1024 * 1024 * 1024 ))
    local exp_sql="NULL"
    [[ -n "$expires" ]] && exp_sql="'$expires'"

    sqlite3 "$TUNN_DB" \
        "INSERT INTO users(type,name,ip,pubkey,created_at,expires_at,quota_bytes,used_bytes,suspended) \
         VALUES('l2tp','$user','','$pass',datetime('now'),$exp_sql,$quota_bytes,0,0);" 2>/dev/null || true

    log_ok "User L2TP '$user' dibuat."
    printf "Username : %s\nPassword : %s\nServer   : %s\nPSK      : %s\n" \
        "$user" "$pass" "$(config_get L2TP_PUBLIC_IP)" "$(config_get IPSEC_PSK)"
}

l2tp_del() {
    local user="$1"
    sed -i "/^\"\?$user\"\?[[:space:]]\+l2tpd/d" /etc/ppp/chap-secrets
    sqlite3 "$TUNN_DB" "DELETE FROM users WHERE type='l2tp' AND name='$user';" 2>/dev/null || true
    log_ok "User L2TP '$user' dihapus."
}

l2tp_list() {
    sqlite3 -header -column "$TUNN_DB" \
        "SELECT name, COALESCE(expires_at,'-') AS expiry, quota_bytes AS quota, used_bytes AS used, suspended \
         FROM users WHERE type='l2tp' ORDER BY id;" 2>/dev/null \
        || awk '/^#/ || /^$/ {next} {print "- "$1}' /etc/ppp/chap-secrets
}

l2tp_show_psk() {
    printf "PSK   : %s\nServer: %s\n" "$(config_get IPSEC_PSK)" "$(config_get L2TP_PUBLIC_IP)"
}
