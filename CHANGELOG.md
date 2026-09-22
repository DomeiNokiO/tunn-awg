# Changelog

Format: versi → tanggal → **Masalah** (gejala yang dilaporkan) → **Akar penyebab** → **Penyelesaian**.

---

## 3.1.0 — 2026-09-23

**Fitur besar: audit/regen WG, whitelist port-forward, watcher stabilitas hub, diagnosa jaringan.**

Konteks dari user:
- Laptop WG bisa akses OLT tapi TIDAK Proxmox (172.18.217.x). HP full-tunnel semua OK.
- Tunnel VPS↔Mikrotik sering "bengong" (putus intermiten).
- Minta whitelist IP per port-forward + web dashboard (v3.2 masuk plan).

### Audit + Regen WG (menjawab isu laptop)
- `wg_audit` (menu 1 → 6, bot: `audit wg`): bandingkan `AllowedIPs` tiap config klien dengan
  baseline `{10.7.0.0/24, 10.10.10.0/24, semua mt_lans}` → tandai peer yang kekurangan subnet.
- `wg_regen NAMA [full|split-lan]` (menu 1 → 7, bot: `regen wg NAMA split-lan`):
  regenerate `.conf` & QR klien tanpa mengubah private key. **Root cause laptop**: config klien
  adalah snapshot saat dibuat; menambah LAN Mikrotik baru tidak memperbarui config lama.

### Whitelist IP per port-forward
- Kolom `port_forwards.allow_from` (comma-sep CIDR; kosong=any).
- Menu 4 → 5 tanya "Whitelist IP/CIDR". Bot: `forward port 9322 ke 10.10.10.2:9322 dari 1.2.3.4/32`.
- `portforward_reapply`: DNAT hanya untuk `-s allow_from`; sisanya DROP di INPUT (guard).

### Stabilitas tunnel L2TP
- `ipsec.conf`: `dpddelay=20`, `dpdtimeout=60`, `dpdaction=restart_by_peer`, `rekey=yes`.
- `strongswan.d/tunn-awg.conf`: `charon.keep_alive=15` (NAT-T ISP CGNAT-friendly).
- `options.xl2tpd`: `lcp-echo-interval=60`, `lcp-echo-failure=5` (5 menit; tidak flap saat jitter).
- Snippet Mikrotik & docs: `keepalive-timeout=60` (dari 30).
- Watcher hub (`tunn-awg-hubwatch.timer` 30 dtk): transisi ON/OFF → notif 🟢/🔴 Telegram + log per hub.
- `hub_uptime_report [jam]` (menu 4 → 15, bot: `uptime hub`): % online 24 jam, transisi, state akhir.

### Diagnosa jaringan mendalam
- `net_diag <ip>` (menu 4 → 17, bot: `diag jaringan 192.166.2.2`): whois hub · `ip route get` ·
  ping · Path-MTU test · mtr · tcpdump 10 paket di ppp jika tunnel-bound.
- Deps baru (opsional): `mtr-tiny`, `traceroute`, `tcpdump`.

### Menu bot diperluas
- Submenu WG: 🔍 Audit AllowedIPs, ♻️ Regen config.
- Submenu Sistem: 📈 Uptime hub 24j, 🩺 Diag jaringan.
- Bantuan NLP diperbarui.

### Rencana v3.2 (web dashboard)
FastAPI + HTMX + Tailwind, reuse lib/*.sh via subprocess, auth via magic-link Telegram atau bcrypt,
TLS nginx+certbot. Fase 3.2.0 read-only → 3.2.5 CRUD lengkap. Detail di
`/memories/session/plan-v3.1-stability-web.md`.

## 3.0.5 — 2026-09-23

**Masalah:** setelah v3.0.4 bot tidak merespon teks natural (ketik "buatkan l2tp NAMA…", "status").
**Akar penyebab:** decorator `@root.message(F.text)` di atas `any_text` hilang saat rombak menu
→ handler NLP tidak pernah terdaftar; callback tombol tetap jalan.
**Penyelesaian:** kembalikan decorator; menu Telegram dirombak jadi berlapis mirror menu CLI
(WG / L2TP / Mode & PF / Hub / Sistem / Bantuan NLP).

## 3.0.4 — 2026-09-18

**Fitur: multi-hub.** Banyak Mikrotik, LAN dikelompokkan per hub. Kasus: Mikrotik A punya OLT,
Mikrotik B punya Mikrotik downstream.

- `lib/mtlan.sh` ditulis ulang: tabel SQLite `mt_hubs(name, ip, label)` + `mt_lans(cidr, hub, note)`.
  Migrasi otomatis dari konfigurasi single-hub v3.0.3 (`MT_HUB_*` di config.env).
- Aturan: IP hub unik (10.10.10.2–99, `auto` = slot kosong berikutnya), label unik, **satu subnet
  hanya boleh milik satu hub** (ditolak bila overlap nama).
- Hook `ip-up`/`ip-down` mencari hub dari DB berdasarkan `PEERNAME`/IP → route LAN otomatis +
  **notif Telegram hub online/offline**.
- Alat cek: `mtlan_list` (status ONLINE/OFFLINE, rx/tx, route aktual per LAN, port-forward yang
  menuju hub), `mtlan_check` (ping semua hub + gateway LAN), `mtlan_whois <ip>` (IP lewat hub
  mana), `mtlan_map` (ringkasan).
- Menu `vpn → 4` dirombak: header peta hub; 7 tambah/ubah hub, 8 hapus hub, 9 tambah LAN ke hub,
  10 hapus LAN, 11 status lengkap, 12 tes semua, 13 cek 1 IP, 14 snippet per hub.
- Bot: tombol **🗺 Hub/LAN Mikrotik** (per hub: Status / Tes / Snippet), NLP `hub NAMA [ip] [label X]`,
  `hapus hub X`, `set lan CIDR hub X [note ...]`, `hub status`/`peta`, `cek hub`, `cek ip 1.2.3.4`.

## 3.0.3 — 2026-09-18

**Fitur:** akses LAN di belakang Mikrotik (OLT, pelanggan) dari VPS, HP (WireGuard), dan
internet (port-forward). Lihat [docs/LAN_MIKROTIK.md](docs/LAN_MIKROTIK.md).

- `lib/mtlan.sh` baru: registrasi subnet LAN (`MT_LAN_SUBNETS`), hub Mikrotik
  (`MT_HUB_NAME`, `MT_HUB_IP`), route otomatis via hook `/etc/ppp/ip-up.d/99-tunn-awg`
  saat hub konek, FORWARD rules bertag `tunn-awg-mtlan`.
- L2TP: IP tunnel **statis** per akun (`l2tp_set_ip`, menu `2 → 11`), argumen ke-5 `l2tp_add`.
- Firewall: `MASQUERADE -o ppp+` (return-path DNAT/HP→LAN lewat tunnel), accept
  `RELATED,ESTABLISHED` di FORWARD.
- **Bugfix:** `nat_apply` sebelumnya menghapus **semua** rule berkomentar `tunn-awg*`
  termasuk port-forward (`tunn-awg-fwd`) → port-forward hilang setiap boot/ganti mode.
  Kini hanya menghapus tag mode dan me-*reapply* port-forward dari DB (`portforward_reapply`).
- Port-forward menambah FORWARD accept ke tujuan (sebelumnya hanya DNAT → paket diblok
  kebijakan default UFW `FORWARD DROP`).
- Menu `4 → 7..10` (hub / LAN), snippet MikroTik + rule `forward in-interface=tunn-awg accept`.
- Bot: `set lan 192.168.88.0/24`, `hub gr3 10.10.10.2`, `lan status`.

## 3.0.2b — 2026-09-18

**Masalah:** setelah 3.0.2, pppd sudah meminta CHAP tetapi `Peer gr3 failed CHAP authentication`.
**Akar penyebab:** akun dibuat dengan password acak (kolom dikosongkan), lalu menu snippet
meminta password **diketik ulang** → tidak sama dengan `chap-secrets`.
**Penyelesaian:** snippet mengambil password asli otomatis; menu `2 → 9` lihat kredensial,
`2 → 10` reset password; bot `password l2tp NAMA`, `snippet NAMA`.
**Bugfix installer:** `install.sh` kini **re-exec** dirinya dari `/opt/tunn-awg` setelah rsync,
sehingga alur update memakai kode terbaru (bukan skrip lama yang sudah dimuat bash).

## 3.0.2 — 2026-09-18

**Masalah:** MikroTik 6.49 l2tp-client `connecting → authenticated → terminating` berulang
tiap ~8 dtk; IPsec `established` lalu hilang; tidak dapat IP.
**Akar penyebab:** xl2tpd `[lns] name = tunn-awg` dikirim ke pppd sebagai `name tunn-awg`
(prioritas command-line, dikirim **sebelum** `file options.xl2tpd`), sementara kolom server di
`/etc/ppp/chap-secrets` = `l2tpd`. pppd tidak menemukan secret untuk `tunn-awg` → **tidak pernah
meminta CHAP** → `peer refused to authenticate`. Log pppd tanpa satu pun baris `CHAP`.
**Penyelesaian:** `name = l2tpd`, hapus `require chap` (langsung MS-CHAPv2), hapus `name`/
`refuse-chap`/`refuse-mschap` di options, `connect-delay 5000`, modul `ppp_*` dipastikan termuat.
Alat baru: `vpn → 2 → 7` Diagnosa L2TP, `2 → 8` Debug verbose, bot `diag l2tp`.
Snippet MikroTik: `profile=default` (IPsec sudah enkripsi; MPPE mubazir), `keepalive-timeout=30`.

## 3.0.1 — 2026-09-17

**Masalah:** bot Telegram tidak merespons apa pun setelah `--update`; speedtest menu kosong.
**Akar penyebab:** `rsync --delete` ke `/opt/tunn-awg` menghapus `bot/venv` (tidak ada di git)
tiap update → service bot gagal start diam-diam. `speedtest` yang ada = wrapper pip
`speedtest-cli` yang tidak mengenal flag Ookla.
**Penyelesaian:** venv dipindah ke `/var/lib/tunn-awg/venv`; `--update` self-heal venv + cetak
**Ringkasan Update**; bot log `Bot started as @…`; 7 pesan bantuan di-escape HTML; wrapper pip
ditimpa binary Ookla; menu 8 jadi sub-menu status/log.

## 3.0.0-hotfix — 2026-09-17

- `install.sh` standalone (`curl -o`) gagal karena `lib/` tidak ada → auto-clone.
- Ubuntu 24.04: prompt `needrestart` bikin installer tampak stuck → dimatikan.
- `ufw` **Breaks** `iptables-persistent` (mutually exclusive di noble) → drop
  iptables-persistent; persistence via `tunn-awg-firewall.service` (re-apply `nat_apply` saat boot).
- Repo apt Ookla belum ada `noble` → binary statis resmi `install.speedtest.net` (arch-aware).
- `--update` tidak menarik kode baru → bootstrap-clone selalu dijalankan pada `--update`.

## 3.0.0 — 2026-09-17

Rilis awal refactor: WireGuard internal, L2TP/IPsec preset RouterOS 6.49, GRE-over-IPsec,
mode Gateway/Tunnel/Hybrid, bot aiogram 3 + NLP, durasi/quota akun, notif online/offline.
