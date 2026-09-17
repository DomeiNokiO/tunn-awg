"""Speedtest via Ookla CLI, returns share URL."""
from __future__ import annotations

import json

from aiogram import Router
from aiogram.filters import Command
from aiogram.types import Message

from ..shellcall import sh

router = Router(name="speedtest")


async def do_speedtest(msg: Message):
    rc_v, out_v, _ = await sh("speedtest --version 2>/dev/null", timeout=5)
    if rc_v != 0 or "ookla" not in out_v.lower():
        await _fallback_speedtest_cli(msg)
        return

    await msg.answer("⏳ Menjalankan speedtest Ookla…")
    rc, out, err = await sh(
        "speedtest --accept-license --accept-gdpr -f json",
        timeout=120,
    )
    if rc != 0 or not out.strip():
        await msg.answer(f"❌ Speedtest gagal.\n<pre>{(err or out)[:500]}</pre>", parse_mode="HTML")
        return
    try:
        data = json.loads(out.strip().splitlines()[-1])
    except (ValueError, IndexError):
        await msg.answer("❌ Output speedtest tidak bisa diparsing.")
        return
    down = data.get("download", {}).get("bandwidth", 0) * 8 / 1_000_000
    up = data.get("upload", {}).get("bandwidth", 0) * 8 / 1_000_000
    ping = data.get("ping", {}).get("latency", 0)
    isp = data.get("isp", "-")
    srv = data.get("server", {}).get("name", "-")
    url = data.get("result", {}).get("url", "")
    text = (
        "⚡ <b>Hasil Speedtest</b>\n"
        f"• ISP: <code>{isp}</code>\n"
        f"• Server: <code>{srv}</code>\n"
        f"• Ping: <code>{ping:.1f} ms</code>\n"
        f"• Download: <code>{down:.2f} Mbps</code>\n"
        f"• Upload: <code>{up:.2f} Mbps</code>\n"
    )
    if url:
        text += f"\n🔗 <a href='{url}'>{url}</a>"
    await msg.answer(text, parse_mode="HTML", disable_web_page_preview=False)


async def _fallback_speedtest_cli(msg: Message):
    rc, out, _ = await sh("command -v speedtest-cli", timeout=3)
    if rc != 0:
        await msg.answer(
            "⚠️ Ookla Speedtest belum terpasang di VPS.\n"
            "Jalankan di server: <code>vpn</code> → menu 6 (auto-retry install), "
            "atau: <code>bash /opt/tunn-awg/install.sh --update</code>",
            parse_mode="HTML",
        )
        return
    await msg.answer("⏳ Ookla tidak ada — pakai <code>speedtest-cli</code> (Python)…", parse_mode="HTML")
    rc, out, err = await sh("speedtest-cli --simple", timeout=120)
    if rc != 0:
        await msg.answer(f"❌ speedtest-cli gagal:\n<pre>{(err or out)[:500]}</pre>", parse_mode="HTML")
        return
    await msg.answer(f"⚡ <b>Hasil (speedtest-cli)</b>\n<pre>{out.strip()}</pre>", parse_mode="HTML")


@router.message(Command("speedtest"))
async def cmd(msg: Message):
    await do_speedtest(msg)
