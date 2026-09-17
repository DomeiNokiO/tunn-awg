# Panduan Instalasi TUNN-AWG

## 1. Prasyarat

| Item | Ketentuan |
|---|---|
| OS VPS | Debian 11 / 12, Ubuntu 20.04 / 22.04 / 24.04 |
| Akses | root (langsung atau via `sudo -i`) |
| IP VPS | **IP publik statis**, tidak di belakang CGNAT/NAT provider |
| Port terbuka | `22/tcp`, `51820/udp` (WireGuard), `500/udp` + `4500/udp` + `1701/udp` (L2TP), protokol IP `50` (ESP) |
| Sumber daya | Minimum 512 MB RAM, 1 vCPU, 5 GB disk |
| DNS | Waktu VPS sync (chrony/systemd-timesyncd), jam wajib benar untuk IPsec |

Jika VPS Anda berada di belakang firewall cloud (AWS SG, GCP, Azure NSG, Oracle Security List, dll.), buka port yang sama di sana **serta izinkan protokol ESP** (IPsec).

Cek IP publik dan interface WAN:
```bash
curl -4 ifconfig.me
ip -4 route show default
```

## 2. Instalasi cepat (one-liner)

Setelah VPS bersih:

```bash
curl -fsSL https://raw.githubusercontent.com/DomeiNokiO/tunn-awg/main/install.sh -o install.sh
sudo bash install.sh
```

Installer akan:

1. Membersihkan lock `apt/dpkg`.
2. Memasang paket minimal (`wireguard`, `strongswan`, `xl2tpd`, `qrencode`, `python3-venv`, `sqlite3`, `fail2ban`, `ufw`, dll).
3. Menyiapkan sysctl + UFW + iptables (**termasuk allow ESP** dan `rp_filter=2`).
4. Menginisialisasi WireGuard (`wg0`) dan L2TP/IPsec dengan preset **Mikrotik RouterOS 6.49-compatible**.
5. Membangun virtualenv Python untuk bot Telegram.
6. Memasang systemd unit + timer (`tunn-awg-bot`, `tunn-awg-expiry.timer`, `tunn-awg-quota.timer`).
7. Menanyakan Bot Token & Chat ID admin (boleh di-skip; isi manual kemudian).

## 3. Flag installer

| Flag | Fungsi |
|---|---|
| `--mode=gateway` | Set mode Gateway (VPS jadi gateway internet klien di belakang Mikrotik) |
| `--mode=tunnel` | Set mode Tunnel-only (tidak menganggu WAN klien) |
| `--mode=hybrid` | **Default**. Mode fleksibel: WAN klien tetap ISP asli, tapi VPS bisa port-forward ke LAN Mikrotik on-demand |
| `--update` | Update repo tanpa menimpa `config.env` dan `data.db` |
| `--no-bot` | Skip instalasi bot Telegram |

## 4. Instalasi dari clone repo

```bash
git clone https://github.com/DomeiNokiO/tunn-awg.git
cd tunn-awg
sudo bash install.sh --mode=hybrid
```

## 5. Verifikasi pasca-instal

```bash
# Service utama
systemctl status wg-quick@wg0 strongswan-starter xl2tpd tunn-awg-bot --no-pager

# Interface WG
wg show wg0

# IPsec
ipsec statusall | head -30

# Firewall
ufw status verbose
iptables -S | grep -E 'esp|tunn-awg'
```

Semua harus `active (running)` dan `iptables` harus memuat `-A INPUT -p esp -j ACCEPT`.

## 6. Setelah instal — buka panel

```bash
vpn
```

Menu utama akan muncul. Buat akun WireGuard/L2TP, atur mode, generate snippet Mikrotik, dan set Bot Telegram dari sini.

## 7. Update

```bash
sudo bash /opt/tunn-awg/install.sh --update
```

Flag `--update` otomatis mengambil kode terbaru dari GitHub, meng-overlay ke
`/opt/tunn-awg`, memperbarui virtualenv bot, dan re-apply konfigurasi. `config.env`,
`data.db`, dan port-forward rules **dipertahankan**. Di akhir akan tampil
**Ringkasan Update** (versi, speedtest, status bot, venv, firewall unit).

Alternatif dari panel: `vpn` → menu **9. Update dari GitHub**.

### Update paksa / recovery (jika `--update` di atas tidak mengubah versi)

Gunakan **path absolut** agar clone tidak nyasar ke direktori lain:

```bash
cd /root
rm -rf /root/tunn-awg /opt/tunn-awg/tunn-awg
git clone https://github.com/DomeiNokiO/tunn-awg.git /root/tunn-awg
sudo bash /root/tunn-awg/install.sh --update
```

Verifikasi:
```bash
head -1 /opt/tunn-awg/VERSION                # versi terbaru
speedtest --version | head -1                # Speedtest by Ookla ...
systemctl is-active tunn-awg-bot             # active
ls /var/lib/tunn-awg/venv/bin/python         # ada
```

## 8. Uninstall

```bash
sudo bash /opt/tunn-awg/uninstall.sh
```

Menu akan menanyakan apakah `/etc/tunn-awg` (config + database + PSK) juga dihapus.

---

Lanjut baca:
- [MIKROTIK.md](MIKROTIK.md) untuk konfigurasi RouterOS 6.49.
- [MODES.md](MODES.md) untuk memilih mode Gateway/Tunnel/Hybrid.
- [BOT.md](BOT.md) untuk daftar perintah bot.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) jika ada kendala.
