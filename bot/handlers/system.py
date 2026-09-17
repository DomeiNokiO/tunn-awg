"""System status, resource, restart service, reboot VPS (confirm)."""
from __future__ import annotations

import asyncio
import shutil

import psutil
from aiogram import Router, F
from aiogram.filters import Command
from aiogram.types import Message, InlineKeyboardMarkup, InlineKeyboardButton, CallbackQuery

from ..config import Config
from ..shellcall import sh

router = Router(name="system")


async def do_status(msg: Message):
    cpu = psutil.cpu_percent(interval=0.5)
    ram = psutil.virtual_memory()
    du = shutil.disk_usage("/")
    up = asyncio.create_subprocess_shell("uptime -p", stdout=asyncio.subprocess.PIPE)
    proc = await up
    out, _ = await proc.communicate()
    uptime = out.decode().strip()

    async def svc(name):
        p = await asyncio.create_subprocess_shell(
            f"systemctl is-active {name}", stdout=asyncio.subprocess.PIPE
        )
        o, _ = await p.communicate()
        return o.decode().strip()

    wg, ipsec, xl2, bot = await asyncio.gather(
        svc("wg-quick@wg0"), svc("strongswan-starter"), svc("xl2tpd"), svc("tunn-awg-bot")
    )
    if ipsec == "unknown":
        ipsec = await svc("strongswan")

    text = (
        "🖥 <b>Status VPS</b>\n"
        f"• CPU: <code>{cpu:.1f}%</code>\n"
        f"• RAM: <code>{ram.percent:.1f}%</code> ({ram.used // 1024**2}/{ram.total // 1024**2} MB)\n"
        f"• Disk: <code>{du.used * 100 // du.total}%</code> ({du.used // 1024**3}/{du.total // 1024**3} GB)\n"
        f"• Uptime: <code>{uptime}</code>\n\n"
        "🛠 <b>Service</b>\n"
        f"• WireGuard : <code>{wg}</code>\n"
        f"• strongSwan: <code>{ipsec}</code>\n"
        f"• xl2tpd    : <code>{xl2}</code>\n"
        f"• Bot       : <code>{bot}</code>"
    )
    await msg.answer(text, parse_mode="HTML")


@router.message(Command("status"))
async def cmd_status(msg: Message):
    await do_status(msg)


@router.message(Command("restart"))
async def cmd_restart(msg: Message):
    parts = (msg.text or "").split()
    if len(parts) < 2:
        await msg.answer("Format: /restart <wg|l2tp|ipsec|bot>")
        return
    await do_restart(msg, parts[1])


async def do_restart(msg: Message, svc: str):
    mapping = {
        "wg": "wg-quick@wg0",
        "wireguard": "wg-quick@wg0",
        "l2tp": "xl2tpd",
        "xl2tpd": "xl2tpd",
        "ipsec": "strongswan-starter",
        "strongswan": "strongswan-starter",
        "bot": "tunn-awg-bot",
    }
    unit = mapping.get(svc.lower())
    if not unit:
        await msg.answer("Service tidak dikenali.")
        return
    rc, out, err = await sh(f"systemctl restart {unit}")
    if rc != 0 and unit == "strongswan-starter":
        rc, out, err = await sh("systemctl restart strongswan")
    await msg.answer(
        f"🔄 Restart <code>{unit}</code>: {'OK' if rc == 0 else 'GAGAL'}\n<pre>{err or out}</pre>",
        parse_mode="HTML",
    )


async def do_reboot_prompt(msg: Message, cfg: Config, uid: int):
    if not cfg.is_owner(uid):
        await msg.answer("🚫 Hanya owner yang boleh reboot VPS.")
        return
    kb = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Ya, reboot", callback_data="sys:reboot:yes"),
        InlineKeyboardButton(text="❌ Batal", callback_data="sys:reboot:no"),
    ]])
    await msg.answer("⚠️ Yakin reboot VPS sekarang?", reply_markup=kb)


@router.callback_query(F.data.startswith("sys:reboot:"))
async def cb_reboot(q: CallbackQuery, cfg: Config, uid: int):
    if not cfg.is_owner(uid):
        await q.answer("Hanya owner.", show_alert=True)
        return
    ans = q.data.split(":")[-1]
    if ans == "yes":
        await q.message.edit_text("🔁 Rebooting…")
        await sh("nohup shutdown -r +1 >/dev/null 2>&1 &")
    else:
        await q.message.edit_text("Dibatalkan.")
    await q.answer()
