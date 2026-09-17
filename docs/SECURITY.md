# Keamanan (Hardening)

## Dasar (otomatis oleh installer)

- **UFW default deny incoming**, allow outgoing.
- **fail2ban** aktif untuk `sshd` bawaan Debian/Ubuntu.
- **sysctl**:
  - `net.ipv4.ip_forward=1`
  - `net.ipv4.conf.all.rp_filter=2` (loose — IPsec-friendly)
  - `net.ipv4.conf.all.accept_redirects=0`
  - `net.ipv4.conf.all.send_redirects=0`
  - `net.ipv4.tcp_syncookies=1`
- **iptables** ESP/AH allowed; NAT/FORWARD rules bertag `tunn-awg` sehingga tidak menabrak rule lain.
- File PSK (`/etc/ipsec.secrets`, `/etc/tunn-awg/config.env`) mode `0600`.

## Rekomendasi tambahan

### 1. SSH key-only

```bash
# Pastikan sudah upload key
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh
```

### 2. Fail2ban jail untuk L2TP brute force

`/etc/fail2ban/jail.d/xl2tpd.conf`:

```ini
[xl2tpd]
enabled = true
filter  = xl2tpd
port    = 1701
protocol = udp
logpath = /var/log/syslog
maxretry = 5
findtime = 600
bantime = 3600
```

`/etc/fail2ban/filter.d/xl2tpd.conf`:
```ini
[Definition]
failregex = xl2tpd\[.*\]: Maximum retries exceeded for tunnel .* Closing\. \(host <HOST>\)
ignoreregex =
```

Restart:
```bash
systemctl restart fail2ban
fail2ban-client status xl2tpd
```

### 3. Rotasi PSK berkala

Lihat [TROUBLESHOOTING.md](TROUBLESHOOTING.md#bagaimana-rotate-psk). Disarankan 3–6 bulan sekali, atau setelah ada admin resign.

### 4. Batasi source IP untuk port-forward Hybrid

Port yang di-forward = pintu terbuka dari internet. Batasi:

```bash
# Contoh: hanya IP kantor yang boleh akses OLT panel via VPS
iptables -I FORWARD -p tcp --dport 8080 ! -s 202.10.10.10 -j DROP -m comment --comment tunn-awg-guard
```

Atau di Mikrotik:
```
/ip firewall filter
add chain=forward dst-address=192.168.88.10 dst-port=80 protocol=tcp \
    src-address=!202.10.10.10 action=drop comment="restrict OLT"
```

### 5. Kernel updates

```bash
apt update && apt upgrade -y
reboot
```

Reboot cepat via bot: `reboot vps` (owner-only, konfirmasi tombol).

### 6. Backup

- Backup manual: `vpn → 7` (tar.gz ke `/var/lib/tunn-awg/backup/`, retensi 7).
- Kirim ke storage remote via `POST_BACKUP_CMD` di `config.env`. Contoh rclone:
  ```
  POST_BACKUP_CMD="rclone copy $BACKUP_FILE gdrive:vpn-backup/"
  ```

### 7. Audit log admin

Setiap perintah bot ditulis ke `/var/log/tunn-awg/bot.log`:
```
2026-09-17T22:12:04 uid=123456 ok msg='buatkan wg budi 30 hari'
2026-09-17T22:12:11 uid=999 denied cb='menu:reboot'
```

Rotate log:
```bash
cat > /etc/logrotate.d/tunn-awg <<'EOF'
/var/log/tunn-awg/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
```

### 8. Cipher L2TP: naikkan jika Mikrotik semua sudah RouterOS 7

Kalau tidak ada lagi Mikrotik 6.x, edit `/etc/ipsec.conf`:
```
ike=aes256-sha256-modp2048!
esp=aes256-sha256!
```
lalu di RouterOS 7 sesuaikan `/ip ipsec profile` dan `proposal`.

### 9. Nonaktifkan protokol yang tidak dipakai

Kalau Anda tidak butuh L2TP, matikan:
```bash
systemctl disable --now xl2tpd
ufw delete allow 1701/udp
```

### 10. Monitoring

- `journalctl -u tunn-awg-bot -f`
- Bot: `status` command → resource + uptime service.
- `wg show wg0` → handshake terakhir per peer.
