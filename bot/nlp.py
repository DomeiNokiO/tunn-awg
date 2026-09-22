"""Regex+keyword intent parser (Bahasa Indonesia + English). No LLM required.

Returns dict {intent, params}. Fallback intent: 'menu'.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass
class Intent:
    name: str
    params: dict = field(default_factory=dict)


NAME_RE = r"[A-Za-z0-9_-]+"

_PATTERNS: list[tuple[str, str]] = [
    # create wg/l2tp — nama boleh setelah spasi atau setelah kata "nama/user/username"
    (
        rf"(?:buat(?:kan)?|bikin|create|add|new|tambah)\s+(?:akun\s+)?(?P<type>wg|wireguard|l2tp)\s+"
        rf"(?:(?:nama|user(?:name)?)\s+)?(?P<name>{NAME_RE})"
        rf"(?:.*?(?:(?P<days>\d+)\s*hari|expired?\s*(?P<date>\d{{4}}-\d{{2}}-\d{{2}})))?"
        rf"(?:.*?quota\s+(?P<quota>\d+)\s*(?P<unit>gb|mb|g|m)?)?",
        "create",
    ),
    # delete
    (
        rf"(?:hapus|delete|remove|del)\s+(?P<type>wg|wireguard|l2tp)\s+(?P<name>{NAME_RE})",
        "delete",
    ),
    # list
    (r"(?:list|daftar|show|tampilkan)\s+(?P<type>wg|wireguard|l2tp)", "list"),
    # get qr
    (rf"(?:qr|kode\s*qr|konfigurasi)\s+(?:wg|wireguard)?\s*(?P<name>{NAME_RE})", "qr"),
    # port forward + whitelist
    (
        r"(?:forward|expose|dnat)\s+port\s+(?P<vps_port>\d+)\s+(?:ke|to)\s+(?P<dest>\d+\.\d+\.\d+\.\d+:\d+)(?:\s+(?P<proto>tcp|udp))?(?:\s+(?:dari|from|whitelist|hanya)\s+(?P<allow>[\d./,\s]+))?",
        "portforward",
    ),
    # WG audit / regen
    (r"(?:audit|periksa|check)\s+(?:wg|wireguard|allowedips)", "wg_audit"),
    (rf"(?:regen(?:erate)?|regenerasi|refresh)\s+(?:config\s+)?(?:wg|wireguard)\s+(?P<name>{NAME_RE})(?:\s+(?P<profile>full|split-lan))?", "wg_regen"),
    # uptime hub / stability
    (r"(?:uptime|stabilitas|stability)(?:\s+hub)?", "hub_uptime"),
    # diag jaringan per IP
    (r"(?:diag(?:nosa|nose)?|cek|check)\s+(?:jaringan|net(?:work)?)\s+(?P<ip>\d+\.\d+\.\d+\.\d+)", "net_diag"),
    # mode switch
    (r"(?:mode|ganti\s+mode)\s+(?P<mode>gateway|tunnel|hybrid)", "mode"),
    # LAN mikrotik & hub (urutan penting: list/check SEBELUM hub_set)
    (r"(?:lan|hub)\s+(?:status|list|info|map|peta)|(?:status|list|info|peta|map)\s+(?:lan|hub)|^(?:peta|map)$", "mtlan_list"),
    (r"(?:cek|tes|test|ping|check)\s+(?:semua\s+)?hub\b(?!\s+\S)|(?:cek|tes|test|check)\s+lan\b(?!\s+\d)", "mtlan_check"),
    (r"(?:cek|tes|test|ping|check|lewat\s+mana|whois)\s+(?:ip\s+)?(?P<ip>\d+\.\d+\.\d+\.\d+)\b", "mtlan_check_ip"),
    (r"(?:set|tambah|add|daftar(?:kan)?)\s+lan(?:\s+mikrotik)?\s+(?P<cidr>\d+\.\d+\.\d+\.\d+/\d+)(?:\s+(?:hub|ke|->)\s+(?P<hub>[A-Za-z0-9_-]+))?(?:\s+(?:note|catatan)\s+(?P<note>.+))?", "mtlan_add"),
    (r"(?:hapus|del(?:ete)?|remove)\s+lan(?:\s+mikrotik)?\s+(?P<cidr>\d+\.\d+\.\d+\.\d+/\d+)", "mtlan_del"),
    (rf"(?:hapus|del(?:ete)?|remove)\s+hub\s+(?P<name>{NAME_RE})", "hub_del"),
    (rf"(?:set\s+)?hub(?:\s+mikrotik)?(?:\s+l2tp)?\s+(?P<name>{NAME_RE})(?:\s+(?P<ip>10\.10\.10\.\d+|auto))?(?:\s+(?:label\s+)?(?P<label>{NAME_RE}))?", "hub_set"),
    # diag l2tp
    (r"(?:diag(?:nosa|nose)?|cek|check|debug)\s+(?:l2tp|ipsec)", "diag_l2tp"),
    # kredensial l2tp
    (rf"(?:password|pass|pw|kredensial|credential|cred|akun)\s+(?:l2tp\s+)?(?P<name>{NAME_RE})", "l2tp_cred"),
    # snippet mikrotik
    (rf"(?:snippet|script|rsc|konfig(?:urasi)?\s+mikrotik)\s+(?:mikrotik\s+)?(?:l2tp\s+)?(?P<name>{NAME_RE})", "snippet"),
    # status
    (r"(?:status|kondisi|resource|cpu|ram|info\s*system|sysinfo)", "status"),
    # speedtest
    (r"(?:speedtest|speed\s*test|test\s+kecepatan|cek\s+speed)", "speedtest"),
    # restart
    (r"(?:restart|reload)\s+(?P<svc>wg|wireguard|l2tp|ipsec|strongswan|bot|xl2tpd)", "restart"),
    # backup
    (r"(?:backup|cadangkan|arsipkan)", "backup"),
    # reboot vps
    (r"(?:reboot|restart)\s+(?:vps|server)", "reboot"),
    # help / menu
    (r"(?:help|bantuan|menu|/start)", "menu"),
]

_COMPILED = [(re.compile(p, re.I | re.S), n) for p, n in _PATTERNS]


def parse(text: str) -> Intent:
    text = text.strip()
    if not text:
        return Intent("menu")
    for rx, name in _COMPILED:
        m = rx.search(text)
        if not m:
            continue
        params = {k: v for k, v in m.groupdict().items() if v is not None}
        if "type" in params:
            params["type"] = "wg" if params["type"].lower().startswith("w") else "l2tp"
        if "quota" in params:
            unit = (params.pop("unit", "gb") or "gb").lower()
            n = int(params["quota"])
            params["quota_bytes"] = n * 1024 * 1024 * (1024 if unit.startswith("g") else 1)
        if "days" in params:
            params["days"] = int(params["days"])
        return Intent(name, params)
    return Intent("menu")
