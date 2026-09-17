#!/usr/bin/env bash
# tunn-awg uninstall — matikan service + hapus konfig (opsional purge data).
set -u

read -rp "Hapus juga /etc/tunn-awg (config + DB)? [y/N]: " purge
purge="${purge,,}"

systemctl disable --now tunn-awg-bot tunn-awg-expiry.timer tunn-awg-quota.timer \
    tunn-awg-notify.service tunn-awg-gre.service tunn-awg-firewall.service 2>/dev/null || true
systemctl disable --now wg-quick@wg0 xl2tpd strongswan-starter strongswan 2>/dev/null || true

rm -f /etc/systemd/system/tunn-awg-*.service /etc/systemd/system/tunn-awg-*.timer
systemctl daemon-reload

rm -f /usr/local/bin/vpn
rm -rf /opt/tunn-awg
rm -f /etc/sysctl.d/99-tunn-awg.conf

# Hapus IPsec + L2TP config (tetapi biarkan paket terpasang; user hapus manual jika mau).
rm -f /etc/ipsec.conf /etc/ipsec.secrets
rm -rf /etc/ipsec.d/gre-mt.* /etc/ipsec.d/*.tunn-awg
rm -f /etc/xl2tpd/xl2tpd.conf /etc/ppp/options.xl2tpd
sed -i '/^# tunn-awg/,/^\s*$/d' /etc/ppp/chap-secrets 2>/dev/null || true

# Bersihkan iptables tunn-awg rules.
iptables-save | grep -v 'tunn-awg' | iptables-restore
netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4

if [[ "$purge" == "y" ]]; then
    rm -rf /etc/tunn-awg /var/lib/tunn-awg /var/log/tunn-awg
    echo "Data & log tunn-awg dihapus."
fi

echo "Uninstall selesai."
