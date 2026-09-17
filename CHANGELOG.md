# Changelog

Format: versi → tanggal → **Masalah** (gejala yang dilaporkan) → **Akar penyebab** → **Penyelesaian**.

---

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
