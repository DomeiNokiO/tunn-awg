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
vpn        # -> 8 -> 3 (Status & log bot)
# atau manual:
systemctl status tunn-awg-bot
journalctl -u tunn-awg-bot -n 100 --no-pager
```

Urutan cek:

1. **Venv hilang** — log berisi `No such file or directory: /var/lib/tunn-awg/venv/bin/python`.
   Jalankan `sudo bash /opt/tunn-awg/install.sh --update` (venv dibuat ulang otomatis).
   Instalasi lama (< v3.0.1) menyimpan venv di `/opt/tunn-awg/bot/venv` yang terhapus tiap update; v3.0.1 memindahkannya ke `/var/lib/tunn-awg/venv`.
2. **Token salah** — log berisi `BOT_TOKEN tidak valid`. Set ulang via `vpn -> 8 -> 1`.
3. **`BOT_TOKEN / ADMIN_IDS belum diisi`** — isi via `vpn -> 8 -> 1`.
4. **Chat ID Anda tidak ada di `ADMIN_IDS`** — pesan ditolak diam-diam. Cek `/var/log/tunn-awg/bot.log` → grep `denied`, lalu tambahkan ID Anda.
5. **Rate-limit tercapai** — tunggu 1 menit atau naikkan `RATE_LIMIT_PER_MIN`.

Bila bot jalan normal, `journalctl` akan berisi baris `Bot started as @NamaBot`.

## `speedtest --version` menampilkan `speedtest-cli 2.1.3`

Itu paket Python `speedtest-cli` (dari pip/apt), **bukan** Ookla. Ia tidak mengenal flag `--accept-license` sehingga menu 6 versi lama tampak kosong. Jalankan `sudo bash /opt/tunn-awg/install.sh --update` — installer akan menimpa wrapper tersebut dengan binary statis Ookla di `/usr/local/bin/speedtest`. Verifikasi: `speedtest --version` → `Speedtest by Ookla 1.2.0`.

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
