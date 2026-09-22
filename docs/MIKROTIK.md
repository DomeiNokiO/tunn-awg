# Konfigurasi Mikrotik RouterOS 6.49 untuk TUNN-AWG

Dokumen ini berisi snippet siap-tempel untuk RouterOS 6.49. Dua opsi:

- **L2TP/IPsec** — paling gampang dipahami, cocok jika VPS hanya untuk satu Mikrotik.
- **GRE-over-IPsec** — lebih stabil untuk site-to-site ala ISP, MTU lebih terprediksi.

Kedua snippet bisa juga di-generate otomatis dari menu:
```
vpn → 2 → 6   (untuk L2TP)
vpn → 3       (untuk GRE-over-IPsec, wizard interaktif)
```

## Prasyarat di Mikrotik

- WAN interface Mikrotik bisa mencapai IP publik VPS di UDP 500/4500/1701 dan protokol ESP.
- Waktu Mikrotik ter-sync (`/system ntp client set enabled=yes primary-ntp=id.pool.ntp.org`).
- Punya PSK dari VPS: `vpn → 2 → 4` atau lihat file `/etc/tunn-awg/config.env` field `IPSEC_PSK`.

---

## Opsi 1 — L2TP/IPsec client

Ganti placeholder:
- `VPS_IP` → IP publik VPS
- `USERNAME` / `PASSWORD` → akun yang dibuat di `vpn → 2 → 1`
- `PSK` → nilai `IPSEC_PSK`

```rsc
# --- IPsec proposal & profile agar MATCH dengan preset VPS ---
/ip ipsec proposal
set [ find name=default ] \
    enc-algorithms=aes-128-cbc,aes-256-cbc \
    auth-algorithms=sha1 \
    pfs-group=none \
    lifetime=1h

/ip ipsec profile
set [ find name=default ] \
    enc-algorithm=aes-128,aes-256 \
    hash-algorithm=sha1 \
    dh-group=modp2048 \
    lifetime=8h

# --- L2TP client ---
# profile=default cukup: IPsec sudah mengenkripsi; MPPE (default-encryption) mubazir.
/interface l2tp-client
add name=tunn-awg \
    connect-to=VPS_IP \
    user="USERNAME" \
    password="PASSWORD" \
    use-ipsec=yes \
    ipsec-secret="PSK" \
    profile=default \
    allow=mschap2 \
    add-default-route=no \
    keepalive-timeout=60 \
    disabled=no

# --- Firewall: izinkan traffic dari tunnel ---
/ip firewall filter
add chain=input in-interface=tunn-awg action=accept comment="tunn-awg L2TP"

# --- MSS clamp (wajib untuk L2TP agar tidak fragment) ---
/ip firewall mangle
add chain=forward out-interface=tunn-awg protocol=tcp tcp-flags=syn \
    action=change-mss new-mss=1360 tcp-mss=!0-1360 comment="tunn-awg MSS"
```

Cek koneksi:
```
/ip ipsec active-peers print
/interface l2tp-client print
/ping 10.10.10.1
```

`active-peers` harus `state=established` dan `l2tp-client` harus `running=yes`.

---

## Opsi 2 — GRE-over-IPsec (site-to-site)

Ganti placeholder:
- `VPS_IP`, `MT_IP` → IP publik VPS dan Mikrotik
- `PSK` → nilai `GRE_PSK` (dibuat oleh wizard `vpn → 3`)
- `MT_LAN` → subnet LAN Mikrotik (mis. `192.168.88.0/24`)

```rsc
/interface gre
add name=tunn-gre \
    remote-address=VPS_IP \
    local-address=MT_IP \
    !keepalive \
    ipsec-secret="PSK" \
    allow-fast-path=no \
    disabled=no

/ip address
add address=10.99.99.2/30 interface=tunn-gre

/ip firewall filter
add chain=input protocol=gre action=accept comment="tunn-awg GRE"

/ip firewall mangle
add chain=forward out-interface=tunn-gre protocol=tcp tcp-flags=syn \
    action=change-mss new-mss=1360 tcp-mss=!0-1360
```

`ipsec-secret` pada interface GRE otomatis membuat entry `/ip ipsec peer` + `/ip ipsec policy` di RouterOS 6.x — tidak perlu buat manual.

---

## Konfigurasi berbasis mode

### Mode Gateway — Mikrotik pakai VPS sebagai gateway internet

Tambahkan setelah tunnel up:

```rsc
/ip route
add dst-address=0.0.0.0/0 gateway=tunn-awg distance=1 comment="via tunn-awg"
# atau kalau pakai GRE:
# add dst-address=0.0.0.0/0 gateway=10.99.99.1 distance=1

/ip firewall nat
add chain=srcnat out-interface=tunn-awg action=masquerade comment="tunn-awg NAT"
```

Distance `1` membuat route ini prioritas di atas default WAN ISP asli. Ubah ke `2` bila mau failover manual.

### Mode Tunnel — hanya untuk manajemen

Jangan tambah default route. Cukup rute spesifik ke `10.10.10.0/24` (yang otomatis ada saat L2TP up).

### Mode Hybrid — default: WAN klien tidak diubah, VPS DNAT port ke LAN

Di sisi Mikrotik cukup pastikan input dari `tunn-awg` di-ACCEPT dan LAN bisa dijangkau dari tunnel (biasanya sudah otomatis dengan rule di atas). Sisi DNAT dilakukan di VPS lewat menu `vpn → 4 → 5`:

```
vpn → 4 → 5
Protokol : tcp
Port VPS : 8080
Tujuan   : 192.168.88.10:80
```

`192.168.88.10:80` bisa panel OLT, ONU, IP camera, dll. Setelah rule aktif: `http://VPS_IP:8080` sampai ke perangkat tersebut.

---

## Troubleshooting singkat khusus Mikrotik

| Gejala | Cek |
|---|---|
| `Phase 1 no proposal chosen` | Profile IPsec Mikrotik pakai enc `aes-128,aes-256`, hash `sha1`, DH `modp2048` |
| `Phase 2 no proposal chosen` | Proposal `pfs-group=none`, enc `aes-128-cbc,aes-256-cbc`, auth `sha1` |
| `initiator did not match to responder id` | Bila VPS multi-IP, set `leftid` di `/etc/ipsec.conf` = IP publik utama (installer sudah lakukan ini) |
| L2TP-client `dialing` terus | `use-ipsec=yes` + `ipsec-secret` **persis** sama dengan PSK VPS |
| Terkoneksi tapi ping mati | Cek `/ip firewall filter` chain `input` accept dari `tunn-awg`, dan MSS clamp aktif |

Detail lebih dalam: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
