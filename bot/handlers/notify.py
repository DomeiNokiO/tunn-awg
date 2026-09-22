"""Watcher peer online/offline + drain notify drop directory."""
from __future__ import annotations

import asyncio
import time
from pathlib import Path

from aiogram import Bot

from ..config import NOTIFY_DIR, Config
from ..db import execute, fetch
from ..shellcall import sh

import os
WG_ONLINE_WINDOW = int(os.environ.get("TUNN_WG_ONLINE_WINDOW", "240"))  # dtk; naikkan bila HP idle sering false-offline


async def watcher_loop(bot: Bot, cfg: Config):
    NOTIFY_DIR.mkdir(parents=True, exist_ok=True)
    while True:
        try:
            await _drain_drops(bot, cfg)
            await _check_wg(bot, cfg)
            await _check_l2tp(bot, cfg)
        except Exception as exc:  # pragma: no cover
            _write_log(f"watcher error: {exc}")
        await asyncio.sleep(30)


async def _drain_drops(bot: Bot, cfg: Config):
    for f in sorted(NOTIFY_DIR.glob("*.txt")):
        try:
            text = f.read_text(errors="replace").strip()
        except OSError:
            continue
        if text:
            await _broadcast(bot, cfg, text)
        f.unlink(missing_ok=True)


async def _check_wg(bot: Bot, cfg: Config):
    rc, out, _ = await sh("wg show wg0 latest-handshakes 2>/dev/null")
    if rc != 0:
        return
    now = int(time.time())
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        pk, ts = parts[0], int(parts[1])
        online = 1 if ts and (now - ts) < WG_ONLINE_WINDOW else 0
        prev = await fetch("SELECT online FROM peer_state WHERE key=?", f"wg:{pk}")
        prev_v = prev[0]["online"] if prev else None
        if prev_v != online:
            await execute(
                "INSERT INTO peer_state(key,online,last_change) VALUES(?,?,datetime('now')) "
                "ON CONFLICT(key) DO UPDATE SET online=excluded.online, last_change=excluded.last_change",
                f"wg:{pk}", online,
            )
            name_row = await fetch("SELECT name FROM users WHERE type='wg' AND pubkey=?", pk)
            name = name_row[0]["name"] if name_row else pk[:8]
            emoji = "🟢" if online else "🔴"
            state = "online" if online else "offline"
            await _broadcast(bot, cfg, f"{emoji} WG <code>{name}</code> {state}")


async def _check_l2tp(bot: Bot, cfg: Config):
    rc, out, _ = await sh("ip -o link show type ppp 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1")
    ifaces = [x for x in out.strip().splitlines() if x]
    key = "l2tp:count"
    prev = await fetch("SELECT online FROM peer_state WHERE key=?", key)
    current = len(ifaces)
    prev_v = prev[0]["online"] if prev else -1
    if prev_v != current:
        await execute(
            "INSERT INTO peer_state(key,online,last_change) VALUES(?,?,datetime('now')) "
            "ON CONFLICT(key) DO UPDATE SET online=excluded.online, last_change=excluded.last_change",
            key, current,
        )
        if prev_v >= 0:
            await _broadcast(bot, cfg, f"📡 L2TP peer aktif: <b>{current}</b> (sebelumnya {prev_v})")


async def _broadcast(bot: Bot, cfg: Config, text: str):
    for uid in cfg.admin_ids:
        try:
            await bot.send_message(uid, text, parse_mode="HTML")
        except Exception:  # pragma: no cover
            pass


def _write_log(msg: str):
    try:
        Path("/var/log/tunn-awg").mkdir(parents=True, exist_ok=True)
        with open("/var/log/tunn-awg/notify.log", "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except OSError:
        pass
