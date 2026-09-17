"""L2TP handlers."""
from __future__ import annotations

from aiogram import Router, F
from aiogram.filters import Command
from aiogram.types import Message, InlineKeyboardMarkup, InlineKeyboardButton, CallbackQuery

from ..config import Config
from ..db import fetch
from ..shellcall import lib_call

router = Router(name="l2tp")


async def do_create(msg: Message, cfg: Config, name: str, days: int | None, expiry: str | None, quota_bytes: int | None):
    exp = expiry or ""
    if not exp and days:
        exp = f"$(date -I -d '+{days} days')"
    quota_gb = str((quota_bytes or 0) // (1024 ** 3))
    rc, out, err = await lib_call("l2tp_add", name, "", exp, quota_gb, timeout=30)
    if rc != 0:
        await msg.answer(f"❌ Gagal buat L2TP: <pre>{err or out}</pre>", parse_mode="HTML")
        return
    # `l2tp_add` mencetak kredensial pada stdout; kirim langsung ke admin.
    body = out.strip() or "OK"
    await msg.answer(
        f"✅ L2TP <code>{name}</code>\n<pre>{body}</pre>\n"
        f"Server: <code>{cfg.l2tp_ip}</code>\nPSK: <code>{cfg.ipsec_psk}</code>",
        parse_mode="HTML",
    )


async def do_delete(msg: Message, name: str):
    rc, _, err = await lib_call("l2tp_del", name)
    if rc != 0:
        await msg.answer(f"❌ Gagal: <pre>{err}</pre>", parse_mode="HTML")
    else:
        await msg.answer(f"🗑️ L2TP <code>{name}</code> dihapus.", parse_mode="HTML")


async def do_list(msg: Message):
    rows = await fetch(
        "SELECT name,COALESCE(expires_at,'-') e,quota_bytes q,used_bytes u,suspended s "
        "FROM users WHERE type='l2tp' ORDER BY id"
    )
    if not rows:
        await msg.answer("Belum ada akun L2TP.")
        return
    lines = ["<b>Akun L2TP</b>"]
    kb_rows = []
    for r in rows:
        badge = "⛔" if r["s"] else "✅"
        q_gb = r["q"] / (1024 ** 3) if r["q"] else 0
        u_gb = r["u"] / (1024 ** 3) if r["u"] else 0
        lines.append(
            f"{badge} <code>{r['name']}</code> · exp:{r['e']} · {u_gb:.2f}/{q_gb:.2f} GB"
        )
        kb_rows.append([InlineKeyboardButton(text=f"🗑 {r['name']}", callback_data=f"l2:del:{r['name']}")])
    await msg.answer("\n".join(lines), parse_mode="HTML",
                     reply_markup=InlineKeyboardMarkup(inline_keyboard=kb_rows))


@router.message(Command("l2tp_add"))
async def cmd_add(msg: Message, cfg: Config):
    parts = (msg.text or "").split()
    if len(parts) < 2:
        await msg.answer("Format: /l2tp_add <username> [hari] [quotaGB]")
        return
    days = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else None
    qgb = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else None
    await do_create(msg, cfg, parts[1], days, None, qgb * 1024 ** 3 if qgb else None)


@router.message(Command("l2tp_del"))
async def cmd_del(msg: Message):
    parts = (msg.text or "").split()
    if len(parts) < 2:
        await msg.answer("Format: /l2tp_del <username>")
        return
    await do_delete(msg, parts[1])


@router.message(Command("l2tp_list"))
async def cmd_list(msg: Message):
    await do_list(msg)


@router.callback_query(F.data.startswith("l2:"))
async def cb(q: CallbackQuery):
    _, action, name = q.data.split(":", 2)
    if action == "del":
        rc, _, err = await lib_call("l2tp_del", name)
        await q.answer("Dihapus" if rc == 0 else "Gagal", show_alert=True)
        if rc == 0:
            await q.message.answer(f"🗑️ L2TP <code>{name}</code> dihapus.", parse_mode="HTML")
