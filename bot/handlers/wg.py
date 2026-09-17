"""WireGuard handlers: NLP + slash commands + inline callbacks."""
from __future__ import annotations

from pathlib import Path

from aiogram import Router, F
from aiogram.filters import Command
from aiogram.types import Message, FSInputFile, InlineKeyboardMarkup, InlineKeyboardButton, CallbackQuery

from ..config import CLIENTS_WG
from ..db import fetch
from ..shellcall import lib_call

router = Router(name="wg")


async def do_create(msg: Message, name: str, days: int | None, expiry: str | None, quota_bytes: int | None):
    exp = expiry or ""
    if not exp and days:
        exp = f"$(date -I -d '+{days} days')"
    quota_gb = str((quota_bytes or 0) // (1024 ** 3))
    args = [name, exp, quota_gb]
    rc, out, err = await lib_call("wg_add", *args, timeout=45)
    if rc != 0:
        await msg.answer(f"❌ Gagal buat WG: <pre>{err or out}</pre>", parse_mode="HTML")
        return
    conf = CLIENTS_WG / f"{name}.conf"
    png = CLIENTS_WG / f"{name}.png"
    if conf.exists():
        await msg.answer_document(FSInputFile(conf), caption=f"Config WG <code>{name}</code>", parse_mode="HTML")
    if png.exists():
        await msg.answer_photo(FSInputFile(png), caption=f"QR WG <code>{name}</code>", parse_mode="HTML")


async def do_delete(msg: Message, name: str):
    rc, out, err = await lib_call("wg_del", name)
    if rc != 0:
        await msg.answer(f"❌ Gagal hapus: <pre>{err or out}</pre>", parse_mode="HTML")
    else:
        await msg.answer(f"🗑️ WG <code>{name}</code> dihapus.", parse_mode="HTML")


async def do_list(msg: Message):
    rows = await fetch(
        "SELECT name,ip,COALESCE(expires_at,'-') e,quota_bytes q,used_bytes u,suspended s "
        "FROM users WHERE type='wg' ORDER BY id"
    )
    if not rows:
        await msg.answer("Belum ada akun WireGuard.")
        return
    lines = ["<b>Akun WireGuard</b>"]
    kb_rows = []
    for r in rows:
        badge = "⛔" if r["s"] else "✅"
        q_gb = r["q"] / (1024 ** 3) if r["q"] else 0
        u_gb = r["u"] / (1024 ** 3) if r["u"] else 0
        lines.append(
            f"{badge} <code>{r['name']}</code> {r['ip']} · exp:{r['e']} · {u_gb:.2f}/{q_gb:.2f} GB"
        )
        kb_rows.append([
            InlineKeyboardButton(text=f"📄 {r['name']} conf", callback_data=f"wg:conf:{r['name']}"),
            InlineKeyboardButton(text=f"🗑 {r['name']}", callback_data=f"wg:del:{r['name']}"),
        ])
    await msg.answer("\n".join(lines), parse_mode="HTML",
                     reply_markup=InlineKeyboardMarkup(inline_keyboard=kb_rows))


async def do_qr(msg: Message, name: str):
    conf = CLIENTS_WG / f"{name}.conf"
    png = CLIENTS_WG / f"{name}.png"
    if not conf.exists():
        await msg.answer(f"Config <code>{name}</code> tidak ada.", parse_mode="HTML")
        return
    await msg.answer_document(FSInputFile(conf))
    if png.exists():
        await msg.answer_photo(FSInputFile(png))


@router.message(Command("wg_list"))
async def cmd_list(msg: Message):
    await do_list(msg)


@router.message(Command("wg_add"))
async def cmd_add(msg: Message):
    parts = (msg.text or "").split()
    if len(parts) < 2:
        await msg.answer("Format: /wg_add &lt;nama&gt; [hari] [quotaGB]")
        return
    name = parts[1]
    days = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else None
    qgb = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else None
    qbytes = qgb * 1024 ** 3 if qgb else None
    await do_create(msg, name, days, None, qbytes)


@router.message(Command("wg_del"))
async def cmd_del(msg: Message):
    parts = (msg.text or "").split()
    if len(parts) < 2:
        await msg.answer("Format: /wg_del &lt;nama&gt;")
        return
    await do_delete(msg, parts[1])


@router.callback_query(F.data.startswith("wg:"))
async def cb(q: CallbackQuery):
    _, action, name = q.data.split(":", 2)
    if action == "conf":
        conf = CLIENTS_WG / f"{name}.conf"
        png = CLIENTS_WG / f"{name}.png"
        if conf.exists():
            await q.message.answer_document(FSInputFile(conf))
        if png.exists():
            await q.message.answer_photo(FSInputFile(png))
        await q.answer()
    elif action == "del":
        rc, out, err = await lib_call("wg_del", name)
        await q.answer("Dihapus" if rc == 0 else "Gagal", show_alert=True)
        if rc == 0:
            await q.message.answer(f"🗑️ WG <code>{name}</code> dihapus.", parse_mode="HTML")
