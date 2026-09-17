# TUNN-AWG

**Master installer + manager VPN (WireGuard + L2TP/IPsec + GRE-over-IPsec) untuk VPS,
dengan fokus interoperabilitas ke Mikrotik RouterOS 6.49 dan bot Telegram bergaya AI-agent.**

![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen)
![license](https://img.shields.io/badge/license-MIT-blue)
![os](https://img.shields.io/badge/OS-Debian%2011%2F12%20%7C%20Ubuntu%2020.04%2F22.04%2F24.04-orange)

---

## Kenapa TUNN-AWG?

- **L2TP/IPsec siap-terkoneksi ke Mikrotik 6.49** — preset cipher `aes128-sha1-modp2048`,
  `pfs=no`, `forceencaps=yes`, plus rule ESP eksplisit di firewall. Tanpa perlu tebak-tebakan
  proposal.
- **GRE-over-IPsec** opsional untuk tunnel site-to-site VPS ↔ Mikrotik ala ISP.
- **Tiga mode operasi** yang bisa di-toggle kapan saja:
  - **Gateway** – seluruh traffic klien di belakang Mikrotik keluar via IP publik VPS.
  - **Tunnel** – hanya tunnel manajemen; internet klien tetap lewat WAN ISP asli.
  - **Hybrid** – default; internet klien tidak diganggu, tapi VPS bisa **DNAT port** ke IP
    LAN di belakang Mikrotik (mis. panel OLT ter-expose lewat IP publik VPS).
- **Bot Telegram bergaya AI-agent** — pahami perintah bahasa Indonesia natural:
  *"buatkan wg budi 30 hari quota 50gb"*, *"hapus l2tp joko"*, *"speedtest"*, *"status"*,
  *"forward port 8080 ke 192.168.88.10:80"*.
- **Durasi akun + quota bandwidth** dengan auto-suspend + grace-delete.
- **Notifikasi online/offline** per peer, **speedtest Ookla dengan URL share**, multi-admin,
  rate-limit, audit log.
- **Idempotent updater** (`git pull && bash install.sh --update`) — tidak menimpa
  `config.env` maupun database.

---

## Cepat: instalasi satu-baris

Jalankan sebagai `root` di VPS bersih:

```bash
curl -fsSL https://raw.githubusercontent.com/DomeiNokiO/tunn-awg/main/install.sh -o install.sh
sudo bash install.sh
```

Setelah selesai, ketik `vpn` di terminal untuk membuka panel.

Detail langkah, prasyarat, dan flag: baca [docs/INSTALL.md](docs/INSTALL.md).

---

## Fitur

| Kategori | Fitur |
|---|---|
| WireGuard | Installer internal (tanpa `git.io`), add/del/list peer, QR PNG + ANSI, expiry, quota |
| L2TP/IPsec | strongSwan + xl2tpd, preset Mikrotik-6.49, generator PSK, multi-user |
| GRE/IPsec | Wizard site-to-site + `.rsc` siap-tempel untuk Mikrotik |
| Mode | Gateway / Tunnel / Hybrid + manager DNAT port-forward |
| Bot | aiogram 3 async, NLP intent (id/en), inline menu fallback, multi-admin, rate-limit |
| Manajemen | Durasi akun (suspend + grace-delete), quota bandwidth per peer, notif online/offline |
| Ops | Speedtest Ookla (URL share), backup tar.gz + retensi, `journalctl` friendly |
| Keamanan | Fail2ban, sysctl hardening, UFW/iptables preset, audit log admin |

---

## Dokumentasi

- [docs/INSTALL.md](docs/INSTALL.md) — panduan instalasi lengkap
- [docs/MIKROTIK.md](docs/MIKROTIK.md) — snippet RouterOS 6.49 (L2TP client, GRE, IPsec proposal, NAT, mangle MSS)
- [docs/MODES.md](docs/MODES.md) — kapan pakai Gateway/Tunnel/Hybrid
- [docs/BOT.md](docs/BOT.md) — daftar command bot + contoh NLP
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — kasus umum + fix
- [docs/SECURITY.md](docs/SECURITY.md) — hardening
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — diagram alur A/B/H

---

## Lisensi

MIT — lihat [LICENSE](LICENSE).
