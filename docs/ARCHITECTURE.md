# Arsitektur TUNN-AWG

## Komponen

```mermaid
flowchart TB
    subgraph VPS
      direction TB
      IN[install.sh<br/>orchestrator]
      LIB[/lib/*.sh<br/>common · deps · firewall · wireguard · l2tp · gre_ipsec · mode · quota · expiry · backup · db · mikrotik_snippet/]
      WG[wg-quick@wg0]
      SS[strongSwan]
      X2[xl2tpd]
      BOT[tunn-awg-bot<br/>aiogram 3 async]
      DB[(SQLite<br/>/etc/tunn-awg/data.db)]
      TIM[systemd timers<br/>expiry · quota]
      MENU[/usr/local/bin/vpn<br/>CLI]
      IPT[iptables + UFW<br/>+ ESP allow]
    end
    TG[(Telegram API)]
    MT[Mikrotik 6.49]
    HP[Klien WG - HP]

    IN --> LIB
    LIB --> WG & SS & X2 & IPT
    LIB --> DB
    BOT <--> TG
    BOT <--> DB
    BOT --> LIB
    TIM --> LIB
    MENU --> LIB

    HP -. WG 51820/UDP .-> WG
    MT  -. L2TP+IPsec 500/4500/ESP .-> SS
    MT  -. GRE + IPsec .-> SS
```

## Alur data per mode

Lihat [MODES.md](MODES.md) untuk diagram Gateway / Tunnel / Hybrid.

## Layout filesystem

```
/opt/tunn-awg/                # sumber (git repo)
├── install.sh
├── lib/*.sh                  # dipanggil via `source` oleh installer, menu, timer, bot
├── bot/                      # Python package, dijalankan via `python -m bot.bot`
├── menu/vpn                  # dipasang ke /usr/local/bin/vpn
├── systemd/                  # dipasang ke /etc/systemd/system/
└── docs/

/etc/tunn-awg/                # data operasional (persisten, tidak di-git)
├── config.env                # BOT_TOKEN, ADMIN_IDS, PSK, endpoint, mode
├── data.db                   # SQLite: users, ppp_sessions, port_forwards, audit, peer_state
├── mode.state                # 'gateway' / 'tunnel' / 'hybrid'
└── clients/wg/               # <nama>.conf + <nama>.png per peer

/var/lib/tunn-awg/
├── backup/                   # tar.gz retensi 7
└── notify/                   # drop-directory notifikasi lib → bot

/var/log/tunn-awg/
├── bot.log                   # audit
└── notify.log                # watcher errors

/etc/systemd/system/
├── tunn-awg-bot.service
├── tunn-awg-expiry.service + .timer   (daily 03:00)
├── tunn-awg-quota.service  + .timer   (every 5 min)
└── tunn-awg-gre.service                (opsional; ada bila GRE setup dijalankan)
```

## Sinkronisasi antar komponen

- **Installer/menu → Bot**: via SQLite. Bot membaca ulang `data.db` per query (WAL mode → aman untuk concurrent read).
- **Lib → Bot notifikasi**: drop-file di `/var/lib/tunn-awg/notify/*.txt`. Bot watcher (loop 30 dtk) menariknya dan mem-broadcast ke semua `ADMIN_IDS`.
- **Bot → Lib**: bot memanggil `bash -c 'source lib/*.sh; wg_add ...'` via `shellcall.py`. Argumen di-quote (`shlex`) untuk hindari command injection.

## Keamanan by-design

- File `config.env` `0600`, hanya root.
- Bot handler mem-validasi input dari NLP sebelum meneruskan ke `lib_call` (regex `[A-Za-z0-9_-]+` untuk nama, IP:PORT untuk destination, dsb.).
- Rate-limit per admin di middleware (token bucket 20 req/menit default).
- Owner-only untuk aksi destruktif (reboot).
- Audit log append-only.
