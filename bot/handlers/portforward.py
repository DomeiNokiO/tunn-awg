"""Port-forward manager (hybrid mode)."""
from __future__ import annotations

from aiogram import Router
from aiogram.filters import Command
from aiogram.types import Message

from ..shellcall import lib_call

router = Router(name="portforward")


async def do_add(msg: Message, vps_port: int, dest: str, proto: str = "tcp"):
    rc, out, err = await lib_call("portforward_add", proto, str(vps_port), dest)
    if rc != 0:
        await msg.answer(f"❌ Gagal: <pre>{err or out}</pre>", parse_mode="HTML")
    else:
        await msg.answer(f"✅ Forward {proto}/{vps_port} → {dest}")


async def do_list(msg: Message):
    rc, out, _ = await lib_call("portforward_list")
    body = out.strip() or "(kosong)"
    await msg.answer(f"<b>Port Forwards</b>\n<pre>{body}</pre>", parse_mode="HTML")


@router.message(Command("pf_add"))
async def cmd_add(msg: Message):
    parts = (msg.text or "").split()
    if len(parts) < 3:
        await msg.answer("Format: /pf_add &lt;vps_port&gt; &lt;ip:port&gt; [tcp|udp]")
        return
    proto = parts[3] if len(parts) > 3 else "tcp"
    await do_add(msg, int(parts[1]), parts[2], proto)


@router.message(Command("pf_list"))
async def cmd_list(msg: Message):
    await do_list(msg)


@router.message(Command("pf_del"))
async def cmd_del(msg: Message):
    parts = (msg.text or "").split()
    if len(parts) < 2 or not parts[1].isdigit():
        await msg.answer("Format: /pf_del &lt;id&gt;")
        return
    rc, out, err = await lib_call("portforward_del", parts[1])
    await msg.answer("✅ Dihapus" if rc == 0 else f"❌ {err or out}")
