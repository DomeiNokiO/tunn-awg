# Bot Telegram TUNN-AWG

Bot menggunakan **aiogram 3 async** — resilient terhadap network flap, throttling built-in,
dan mengerti perintah bahasa Indonesia natural ala AI-agent (regex/keyword lokal, tanpa
LLM eksternal secara default).

## Setup

1. Buat bot di [@BotFather](https://t.me/BotFather), catat Bot Token.
2. Cari Chat ID Anda di [@userinfobot](https://t.me/userinfobot).
3. Buka `vpn → 8`, isi Token & Admin ID.
   - `ADMIN_IDS` boleh lebih dari satu, dipisah koma: `12345,67890`.
   - `OWNER_ID` = akun yang boleh reboot VPS (default = admin pertama).
4. Bot auto restart dan siap menerima perintah.

## Perintah bahasa natural (NLP)

Ketik ke bot seperti ngobrol:

| Contoh perintah | Aksi |
|---|---|
| `buatkan wg budi 30 hari quota 50gb` | Buat akun WG `budi`, expired 30 hari, quota 50 GB |
| `bikin l2tp joko expired 2026-12-31 quota 100gb` | Buat akun L2TP dengan tanggal expired eksplisit |
| `hapus wg budi` / `del l2tp joko` | Hapus akun |
| `list wg` / `daftar l2tp` | Lihat semua akun |
| `qr budi` | Kirim ulang file config + QR |
| `forward port 8080 ke 192.168.88.10:80` | Buat DNAT (mode Hybrid) |
| `mode gateway` / `mode tunnel` / `mode hybrid` | Ganti mode operasi |
| `status` / `sysinfo` / `resource` | CPU, RAM, disk, uptime, status service |
| `speedtest` | Ookla speedtest + kirim link share hasil |
| `restart wg` / `restart l2tp` / `restart ipsec` | Restart service |
| `backup` | Buat tar.gz + kirim ke chat |
| `reboot vps` | Konfirmasi reboot (khusus owner) |

Jika perintah tidak dipahami, bot menampilkan inline menu utama sebagai fallback.

## Perintah slash klasik (opsional)

| Command | Aksi |
|---|---|
| `/start`, `/menu`, `/help` | Menu utama |
| `/wg_add <nama> [hari] [quotaGB]` | Buat akun WG |
| `/wg_del <nama>` | Hapus akun WG |
| `/wg_list` | Daftar WG |
| `/l2tp_add <user> [hari] [quotaGB]` | Buat akun L2TP |
| `/l2tp_del <user>` | Hapus akun L2TP |
| `/l2tp_list` | Daftar L2TP |
| `/pf_add <vps_port> <ip:port> [tcp\|udp]` | Tambah port-forward |
| `/pf_del <id>` | Hapus port-forward |
| `/pf_list` | Lihat port-forward |
| `/status` | Ringkasan VPS |
| `/speedtest` | Ookla speedtest |
| `/restart <wg\|l2tp\|ipsec\|bot>` | Restart service |

## Fitur otomatis

- **Notifikasi online/offline** per peer WG (window 180 dtk) dan jumlah peer L2TP aktif.
- **Quota enforcement** — polling 5 menit; melebihi quota → peer di-suspend + notif.
- **Expiry enforcement** — cek harian 03:00. Peringatan H-3, suspend saat expired, hapus setelah `GRACE_DAYS` (default 3).
- **Rate-limit** — default 20 pesan/menit per admin (bisa diubah di `RATE_LIMIT_PER_MIN`).
- **Audit log** — `/var/log/tunn-awg/bot.log`.

## Opsional: integrasi LLM

Kalau butuh pemahaman yang lebih luas (mis. perintah nyeleneh), isi di `config.env`:

```
LLM_API_KEY="sk-..."
LLM_ENDPOINT="https://api.openai.com/v1/chat/completions"
LLM_MODEL="gpt-4o-mini"
```

Bot akan fallback ke LLM saat regex lokal tidak match. Kalau kosong, tetap jalan 100% offline.

## Log & debug

```bash
journalctl -u tunn-awg-bot -f
tail -f /var/log/tunn-awg/bot.log
```
