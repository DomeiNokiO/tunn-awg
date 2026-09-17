# Troubleshooting

## L2TP dari Mikrotik 6.49 tidak konek (kasus paling umum)

**Gejala**: `/interface l2tp-client` state `dialing` atau `disconnected`; `/ip ipsec active-peers` kosong.

**Diagnostik urutan**:

1. **Cek IPsec Phase-1** di VPS:
   ```bash
   journalctl -u strongswan-starter -u strongswan --since '5 min ago' | grep -Ei 'IKE|proposal|auth'
   ```
   Kalau ada `no proposal chosen`: profile IPsec Mikrotik tidak match. Pastikan:
   ```
   /ip ipsec profile print detail
   ```
   `enc-algorithm=aes-128,aes-256`, `hash-algorithm=sha1`, `dh-group=modp2048`.

2. **Cek Phase-2**:
   ```
   /ip ipsec proposal print detail
   ```
   `enc-algorithms=aes-128-cbc,aes-256-cbc`, `auth-algorithms=sha1`, `pfs-group=none`.

3. **PSK match?** — TUNN-AWG PSK ada di `/etc/tunn-awg/config.env` (`IPSEC_PSK`). Copy persis ke Mikrotik (`ipsec-secret` di `/interface l2tp-client`). Case-sensitive, tanpa spasi.

4. **ESP terblokir?**
   ```bash
   iptables -S | grep esp
   ```
   Harus ada `-A INPUT -p esp -j ACCEPT`. Kalau tidak, jalankan `vpn → menu → 4 → hybrid` (atau apapun) untuk memicu `nat_apply` yang menambah rule ESP.

5. **`rp_filter` strict di VPS**:
   ```bash
   sysctl net.ipv4.conf.all.rp_filter
   ```
   Harus `2` (installer set otomatis). Kalau `1`, jalankan `sysctl --system`.

6. **`ip_forward`**:
   ```bash
   sysctl net.ipv4.ip_forward
   ```
   Harus `1`. Kalau `0`, cek `/etc/sysctl.d/99-tunn-awg.conf` dan `sysctl --system`.

7. **Waktu VPS/Mikrotik**: `date` di kedua sisi tidak boleh selisih > 5 menit (IPsec time-sensitive).

8. **NAT-T (`forceencaps=yes`)** sudah diaktifkan installer. Verifikasi:
   ```bash
   grep forceencaps /etc/ipsec.conf
   ```

## L2TP tersambung, tapi ping ke `10.10.10.1` gagal

- Di Mikrotik: `/ip firewall filter` harus accept `in-interface=tunn-awg` untuk chain `input`.
- Di VPS: pastikan mode bukan `tunnel` jika Anda ingin klien di belakang Mikrotik akses internet.

## WireGuard di HP: QR terscan, tapi tidak online

- Cek endpoint di `client.conf` = IP publik VPS yang benar (bukan IP LAN). File config ada di `/etc/tunn-awg/clients/wg/<nama>.conf`.
- Cek UDP 51820 tidak diblok di firewall cloud.
- Jalankan di VPS: `wg show wg0 latest-handshakes` — kalau `0`, paket belum masuk sama sekali (masalah firewall).

## Bot Telegram tidak merespons

```bash
systemctl status tunn-awg-bot
journalctl -u tunn-awg-bot -n 100 --no-pager
```

- `BOT_TOKEN` kosong? Set via `vpn → 8`.
- `ADMIN_IDS` tidak berisi Chat ID Anda? Pesan akan diam-diam ditolak. Cek log audit `/var/log/tunn-awg/bot.log` → grep `denied`.
- Rate-limit tercapai? Log akan tulis `rate limit`.

## `install banyak dependensi`

Instalasi awal memang mengunduh: `wireguard`, `strongswan`, `xl2tpd`, `qrencode`, `python3-venv`, `sqlite3`, `fail2ban`, `ufw`, `iptables-persistent`, dan (opsional) Ookla `speedtest`. Ini one-time. Update selanjutnya (`--update`) tidak mengulang.

**Bandingkan** dengan `hwdsl2/setup-ipsec-vpn` yang dipakai skrip v2.3: itu meng-compile Libreswan dari source di sebagian versi + tarik banyak build-deps → jauh lebih berat dan hasil ciphernya tidak cocok RouterOS 6.

## Iptables saya sudah ada aturan lain, apakah aman?

Ya. Semua rule TUNN-AWG di-tag `-m comment --comment tunn-awg`. Saat `nat_apply` dijalankan lagi, hanya rule dengan tag itu yang di-purge:
```bash
iptables-save | grep tunn-awg
```

## Update strongSwan/xl2tpd merusak config?

Installer tidak menyentuh `/etc/xl2tpd/xl2tpd.conf` dan `/etc/ipsec.conf` saat `--update` **kecuali** template berubah versi mayor. Backup akun L2TP (`/etc/ppp/chap-secrets`) dan PSK tidak diubah.

## Bagaimana rotate PSK?

```bash
# 1. Edit PSK baru
openssl rand -base64 32 > /tmp/newpsk
# 2. Update config + secrets
sed -i "s|IPSEC_PSK=.*|IPSEC_PSK=\"$(cat /tmp/newpsk)\"|" /etc/tunn-awg/config.env
# 3. Regenerate ipsec.secrets (installer helper)
bash -c 'for f in /opt/tunn-awg/lib/*.sh; do . "$f"; done; l2tp_server_init'
# 4. Update di semua Mikrotik client
```

Semua Mikrotik akan disconnect sampai `ipsec-secret` di sisi mereka juga di-update.

## Cek health cepat

```bash
vpn → 5   # status service + resource
```

Atau via bot: kirim `status`.
