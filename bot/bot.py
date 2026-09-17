"""tunn-awg Telegram bot — aiogram 3 async, NLP-first, multi-admin."""
from __future__ import annotations

import asyncio
import logging

from aiogram import Bot, Dispatcher, F, Router
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.filters import Command
from aiogram.types import (
    Message,
    InlineKeyboardMarkup,
    InlineKeyboardButton,
    CallbackQuery,
)

from .auth import AuthMiddleware
from .config import Config, load
from . import nlp
from .handlers import wg as h_wg
from .handlers import l2tp as h_l2tp
from .handlers import system as h_sys
from .handlers import speedtest as h_speed
from .handlers import portforward as h_pf
from .handlers.notify import watcher_loop

log = logging.getLogger("tunn-awg-bot")


def main_menu() -> InlineKeyboardMarkup:
    kb = [
        [InlineKeyboardButton(text="➕ Buat WG", callback_data="menu:wg_new"),
         InlineKeyboardButton(text="➕ Buat L2TP", callback_data="menu:l2_new")],
        [InlineKeyboardButton(text="📋 List WG", callback_data="menu:wg_list"),
         InlineKeyboardButton(text="📋 List L2TP", callback_data="menu:l2_list")],
        [InlineKeyboardButton(text="🖥 Status", callback_data="menu:status"),
         InlineKeyboardButton(text="⚡ Speedtest", callback_data="menu:speed")],
        [InlineKeyboardButton(text="🔁 Restart WG", callback_data="menu:rst_wg"),
         InlineKeyboardButton(text="🔁 Restart L2TP", callback_data="menu:rst_l2")],
        [InlineKeyboardButton(text="🔀 Port Forward", callback_data="menu:pf_list"),
         InlineKeyboardButton(text="♻️ Reboot VPS", callback_data="menu:reboot")],
    ]
    return InlineKeyboardMarkup(inline_keyboard=kb)


def build() -> tuple[Bot, Dispatcher, Config]:
    cfg = load()
    if not cfg.token or not cfg.admin_ids:
        raise SystemExit("BOT_TOKEN / ADMIN_IDS belum diisi di /etc/tunn-awg/config.env")

    bot = Bot(cfg.token, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    dp = Dispatcher()
    auth = AuthMiddleware(cfg)
    dp.message.middleware(auth)
    dp.callback_query.middleware(auth)

    dp.include_router(h_wg.router)
    dp.include_router(h_l2tp.router)
    dp.include_router(h_sys.router)
    dp.include_router(h_speed.router)
    dp.include_router(h_pf.router)

    root = Router(name="root")

    @root.message(Command("start", "menu", "help"))
    async def start(msg: Message):
        await msg.answer(
            "🤖 <b>tunn-awg</b> — panel VPN\n"
            "Ketik natural: <i>buatkan wg budi 30 hari quota 50gb</i>, "
            "<i>hapus l2tp joko</i>, <i>status</i>, <i>speedtest</i>, "
            "<i>forward port 8080 ke 192.168.88.10:80</i>",
            reply_markup=main_menu(),
        )

    @root.callback_query(F.data.startswith("menu:"))
    async def cb_menu(q: CallbackQuery, cfg: Config, uid: int):
        action = q.data.split(":", 1)[1]
        m = q.message
        if action == "wg_list":
            await h_wg.do_list(m)
        elif action == "l2_list":
            await h_l2tp.do_list(m)
        elif action == "status":
            await h_sys.do_status(m)
        elif action == "speed":
            await h_speed.do_speedtest(m)
        elif action == "rst_wg":
            await h_sys.do_restart(m, "wg")
        elif action == "rst_l2":
            await h_sys.do_restart(m, "l2tp")
        elif action == "pf_list":
            await h_pf.do_list(m)
        elif action == "reboot":
            await h_sys.do_reboot_prompt(m, cfg, uid)
        elif action == "wg_new":
            await m.answer("Ketik: <code>buatkan wg NAMA 30 hari quota 50gb</code>")
        elif action == "l2_new":
            await m.answer("Ketik: <code>buatkan l2tp NAMA 30 hari quota 50gb</code>")
        await q.answer()

    @root.message(F.text)
    async def any_text(msg: Message, cfg: Config, uid: int):
        intent = nlp.parse(msg.text or "")
        p = intent.params
        try:
            if intent.name == "create":
                if p["type"] == "wg":
                    await h_wg.do_create(msg, p["name"], p.get("days"), p.get("date"), p.get("quota_bytes"))
                else:
                    await h_l2tp.do_create(msg, cfg, p["name"], p.get("days"), p.get("date"), p.get("quota_bytes"))
            elif intent.name == "delete":
                if p["type"] == "wg":
                    await h_wg.do_delete(msg, p["name"])
                else:
                    await h_l2tp.do_delete(msg, p["name"])
            elif intent.name == "list":
                if p["type"] == "wg":
                    await h_wg.do_list(msg)
                else:
                    await h_l2tp.do_list(msg)
            elif intent.name == "qr":
                await h_wg.do_qr(msg, p["name"])
            elif intent.name == "portforward":
                await h_pf.do_add(msg, int(p["vps_port"]), p["dest"], p.get("proto", "tcp"))
            elif intent.name == "mode":
                from .shellcall import lib_call
                rc, out, err = await lib_call("mode_switch", p["mode"])
                await msg.answer(f"Mode: <pre>{err or out}</pre>", parse_mode="HTML")
            elif intent.name == "status":
                await h_sys.do_status(msg)
            elif intent.name == "diag_l2tp":
                from .shellcall import lib_call
                import tempfile
                from aiogram.types import FSInputFile
                await msg.answer("🩺 Mengumpulkan diagnosa L2TP…")
                rc, out, err = await lib_call("l2tp_diag", timeout=90)
                with tempfile.NamedTemporaryFile("w", suffix="-l2tp-diag.txt", delete=False, encoding="utf-8") as f:
                    f.write(out or err or "(kosong)")
                    path = f.name
                await msg.answer_document(FSInputFile(path), caption="Diagnosa L2TP/IPsec")
            elif intent.name == "speedtest":
                await h_speed.do_speedtest(msg)
            elif intent.name == "restart":
                await h_sys.do_restart(msg, p["svc"])
            elif intent.name == "backup":
                from .shellcall import lib_call
                await msg.answer("📦 Membackup…")
                rc, out, err = await lib_call("backup_now", timeout=180)
                path = out.strip().splitlines()[-1] if out.strip() else ""
                if path:
                    from aiogram.types import FSInputFile
                    await msg.answer_document(FSInputFile(path))
                else:
                    await msg.answer(f"❌ Backup gagal: {err[:200]}")
            elif intent.name == "reboot":
                await h_sys.do_reboot_prompt(msg, cfg, uid)
            else:
                await msg.answer("Belum paham. Coba:", reply_markup=main_menu())
        except KeyError as exc:
            await msg.answer(f"Parameter kurang: {exc}. Contoh: <code>buatkan wg budi 30 hari</code>", parse_mode="HTML")

    dp.include_router(root)
    return bot, dp, cfg


async def _run():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    bot, dp, cfg = build()

    # Verifikasi token lebih awal supaya error tampil jelas di journalctl (bukan crash-loop diam).
    try:
        me = await bot.get_me()
    except Exception as exc:  # noqa: BLE001
        log.error("BOT_TOKEN tidak valid / Telegram tidak terjangkau: %s", exc)
        await bot.session.close()
        raise SystemExit(1)
    log.info("Bot started as @%s (id=%s); admins=%s owner=%s",
             me.username, me.id, cfg.admin_ids, cfg.owner_id)

    asyncio.create_task(watcher_loop(bot, cfg))
    await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())


def main():
    asyncio.run(_run())


if __name__ == "__main__":
    main()
