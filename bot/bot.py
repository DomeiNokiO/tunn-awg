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
        [InlineKeyboardButton(text="🛡 WireGuard", callback_data="menu:wg"),
         InlineKeyboardButton(text="🔐 L2TP/IPsec", callback_data="menu:l2")],
        [InlineKeyboardButton(text="🔀 Mode • Port-Forward", callback_data="menu:mode"),
         InlineKeyboardButton(text="🗺 Hub/LAN Mikrotik", callback_data="menu:hub_map")],
        [InlineKeyboardButton(text="🖥 Sistem & Ops", callback_data="menu:sys"),
         InlineKeyboardButton(text="🤖 Bantuan NLP", callback_data="menu:help")],
    ]
    return InlineKeyboardMarkup(inline_keyboard=kb)


def _back_row() -> list[InlineKeyboardButton]:
    return [InlineKeyboardButton(text="⬅️ Menu utama", callback_data="menu:main")]


def wg_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📋 List akun WG", callback_data="menu:wg_list")],
        [InlineKeyboardButton(text="➕ Buat akun", callback_data="menu:wg_new"),
         InlineKeyboardButton(text="🗑 Hapus akun", callback_data="menu:wg_del")],
        [InlineKeyboardButton(text="📄 Kirim QR/Config", callback_data="menu:wg_qr")],
        [InlineKeyboardButton(text="🔁 Restart WireGuard", callback_data="menu:rst_wg")],
        _back_row(),
    ])


def l2tp_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📋 List akun L2TP", callback_data="menu:l2_list")],
        [InlineKeyboardButton(text="➕ Buat akun", callback_data="menu:l2_new"),
         InlineKeyboardButton(text="🗑 Hapus akun", callback_data="menu:l2_del")],
        [InlineKeyboardButton(text="🔑 Lihat kredensial", callback_data="menu:l2_cred"),
         InlineKeyboardButton(text="🔧 Reset password", callback_data="menu:l2_pass")],
        [InlineKeyboardButton(text="📌 Set IP statis (hub)", callback_data="menu:l2_setip"),
         InlineKeyboardButton(text="📄 Snippet Mikrotik", callback_data="menu:l2_snippet")],
        [InlineKeyboardButton(text="🩺 Diagnosa L2TP", callback_data="menu:l2_diag"),
         InlineKeyboardButton(text="🔁 Restart L2TP", callback_data="menu:rst_l2")],
        _back_row(),
    ])


def mode_menu_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🌐 Mode Gateway", callback_data="menu:mode_gw"),
         InlineKeyboardButton(text="🔒 Mode Tunnel", callback_data="menu:mode_tn"),
         InlineKeyboardButton(text="🔀 Mode Hybrid", callback_data="menu:mode_hy")],
        [InlineKeyboardButton(text="📋 List Port-Forward", callback_data="menu:pf_list"),
         InlineKeyboardButton(text="➕ Tambah PF", callback_data="menu:pf_new"),
         InlineKeyboardButton(text="🗑 Hapus PF", callback_data="menu:pf_del")],
        [InlineKeyboardButton(text="🗺 Hub/LAN Mikrotik", callback_data="menu:hub_map")],
        _back_row(),
    ])


def sys_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🖥 Status resource", callback_data="menu:status"),
         InlineKeyboardButton(text="⚡ Speedtest", callback_data="menu:speed")],
        [InlineKeyboardButton(text="📦 Backup", callback_data="menu:backup"),
         InlineKeyboardButton(text="🔁 Restart bot", callback_data="menu:rst_bot")],
        [InlineKeyboardButton(text="🔁 Restart strongSwan", callback_data="menu:rst_ipsec"),
         InlineKeyboardButton(text="🔁 Restart L2TP", callback_data="menu:rst_l2")],
        [InlineKeyboardButton(text="⬆️ Update dari GitHub", callback_data="menu:update"),
         InlineKeyboardButton(text="♻️ Reboot VPS", callback_data="menu:reboot")],
        _back_row(),
    ])


_HELP_TEXT = (
    "🤖 <b>Perintah natural</b>\n\n"
    "<b>Akun</b>\n"
    "• <code>buatkan wg budi 30 hari quota 50gb</code>\n"
    "• <code>buatkan l2tp gr3 90 hari</code>\n"
    "• <code>hapus wg budi</code> · <code>hapus l2tp gr3</code>\n"
    "• <code>list wg</code> · <code>list l2tp</code>\n"
    "• <code>qr budi</code> · <code>password l2tp gr3</code> · <code>snippet gr3</code>\n\n"
    "<b>Hub / LAN Mikrotik</b>\n"
    "• <code>hub siteA auto label A</code>\n"
    "• <code>set lan 192.166.2.0/24 hub A note OLT</code>\n"
    "• <code>hub status</code> · <code>cek hub</code> · <code>cek ip 192.166.2.2</code>\n"
    "• <code>hapus hub siteA</code> · <code>hapus lan 192.168.89.0/24</code>\n\n"
    "<b>Port-forward & mode</b>\n"
    "• <code>forward port 8080 ke 192.166.2.2:80</code>\n"
    "• <code>mode hybrid</code>\n\n"
    "<b>Ops</b>\n"
    "• <code>status</code> · <code>speedtest</code> · <code>backup</code>\n"
    "• <code>diag l2tp</code>\n"
    "• <code>restart wg|l2tp|ipsec|bot</code> · <code>reboot vps</code>"
)


async def _hub_map_message(m: Message):
    """Peta hub + tombol aksi per hub."""
    from .shellcall import lib_call, sh
    rc, out, err = await lib_call("mtlan_map")
    text = (out or err or "").strip() or "(belum ada hub — ketik: hub NAMA_AKUN 10.10.10.2 label A)"
    text = text.replace("[ON ]", "🟢").replace("[OFF]", "🔴")
    rc, hubs, _ = await sh("sqlite3 -separator '|' /etc/tunn-awg/data.db \"SELECT name,COALESCE(NULLIF(label,''),name) FROM mt_hubs ORDER BY ip;\"")
    rows = []
    for line in (hubs or "").splitlines():
        if "|" not in line:
            continue
        name, label = line.split("|", 1)
        rows.append([
            InlineKeyboardButton(text=f"📋 {label}", callback_data=f"hub:status:{name}"),
            InlineKeyboardButton(text="🩺 Tes", callback_data=f"hub:check:{name}"),
            InlineKeyboardButton(text="📄 Snippet", callback_data=f"hub:snippet:{name}"),
        ])
    rows.append([InlineKeyboardButton(text="🔍 Tes semua hub & LAN", callback_data="hub:checkall:-")])
    await m.answer(f"🗺 <b>Hub Mikrotik</b>\n<pre>{text}</pre>", parse_mode="HTML",
                   reply_markup=InlineKeyboardMarkup(inline_keyboard=rows))


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
            "Pilih kategori di tombol, atau ketik natural. "
            "Tekan <b>🤖 Bantuan NLP</b> untuk daftar perintah.",
            reply_markup=main_menu(),
        )

    @root.callback_query(F.data.startswith("menu:"))
    async def cb_menu(q: CallbackQuery, cfg: Config, uid: int):
        action = q.data.split(":", 1)[1]
        m = q.message
        # Submenu navigasi
        if action == "main":
            await m.answer("🤖 <b>tunn-awg</b> — pilih kategori:", reply_markup=main_menu()); await q.answer(); return
        if action == "wg":
            await m.answer("🛡 <b>WireGuard</b>", reply_markup=wg_menu()); await q.answer(); return
        if action == "l2":
            await m.answer("🔐 <b>L2TP/IPsec</b>", reply_markup=l2tp_menu()); await q.answer(); return
        if action == "mode":
            from .shellcall import lib_call
            _, cur, _ = await lib_call("mode_get")
            await m.answer(f"🔀 <b>Mode & Port-Forward</b>\nMode aktif: <code>{cur.strip() or '?'}</code>",
                           reply_markup=mode_menu_kb()); await q.answer(); return
        if action == "sys":
            await m.answer("🖥 <b>Sistem & Ops</b>", reply_markup=sys_menu()); await q.answer(); return
        if action == "help":
            await m.answer(_HELP_TEXT, reply_markup=InlineKeyboardMarkup(inline_keyboard=[_back_row()])); await q.answer(); return
        # Aksi cepat
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
        elif action == "rst_ipsec":
            await h_sys.do_restart(m, "ipsec")
        elif action == "rst_bot":
            await h_sys.do_restart(m, "bot")
        elif action == "pf_list":
            await h_pf.do_list(m)
        elif action == "hub_map":
            await _hub_map_message(m)
        elif action == "reboot":
            await h_sys.do_reboot_prompt(m, cfg, uid)
        elif action in ("mode_gw", "mode_tn", "mode_hy"):
            from .shellcall import lib_call
            target = {"mode_gw": "gateway", "mode_tn": "tunnel", "mode_hy": "hybrid"}[action]
            rc, out, err = await lib_call("mode_switch", target)
            await m.answer(f"Mode → <code>{target}</code>\n<pre>{(err or out).strip()[:800]}</pre>", parse_mode="HTML")
        elif action == "backup":
            from .shellcall import lib_call
            from aiogram.types import FSInputFile
            await m.answer("📦 Membackup…")
            rc, out, err = await lib_call("backup_now", timeout=180)
            path = out.strip().splitlines()[-1] if out.strip() else ""
            if path:
                await m.answer_document(FSInputFile(path))
            else:
                await m.answer(f"❌ Backup gagal: <pre>{(err or '-')[:400]}</pre>", parse_mode="HTML")
        elif action == "update":
            if not cfg.is_owner(uid):
                await q.answer("Hanya owner.", show_alert=True); return
            await m.answer("⬆️ Menjalankan <code>install.sh --update</code> di background. Bot akan restart otomatis.", parse_mode="HTML")
            from .shellcall import sh
            await sh("nohup bash /opt/tunn-awg/install.sh --update >/var/log/tunn-awg/update.log 2>&1 &")
        # Prompt inputan (arahkan ke NLP)
        elif action == "wg_new":
            await m.answer("Ketik contoh:\n<code>buatkan wg NAMA 30 hari quota 50gb</code>", parse_mode="HTML")
        elif action == "wg_del":
            await m.answer("Ketik: <code>hapus wg NAMA</code>", parse_mode="HTML")
        elif action == "wg_qr":
            await m.answer("Ketik: <code>qr NAMA</code>", parse_mode="HTML")
        elif action == "l2_new":
            await m.answer("Ketik contoh:\n<code>buatkan l2tp NAMA 30 hari quota 50gb</code>", parse_mode="HTML")
        elif action == "l2_del":
            await m.answer("Ketik: <code>hapus l2tp NAMA</code>", parse_mode="HTML")
        elif action == "l2_cred":
            await m.answer("Ketik: <code>password l2tp NAMA</code> atau <code>kredensial NAMA</code>", parse_mode="HTML")
        elif action == "l2_pass":
            await m.answer("Reset via CLI: <code>vpn → 2 → 10</code> (belum ada intent NLP untuk reset, kirim NAMA baru manual).", parse_mode="HTML")
        elif action == "l2_setip":
            await m.answer("Ketik: <code>hub NAMA_AKUN auto label A</code> — akan set IP statis + tandai hub.", parse_mode="HTML")
        elif action == "l2_snippet":
            await m.answer("Ketik: <code>snippet NAMA</code> — kirim file .rsc.", parse_mode="HTML")
        elif action == "l2_diag":
            await m.answer("🩺 Mengumpulkan diagnosa L2TP…")
            from .shellcall import lib_call
            from aiogram.types import FSInputFile
            import tempfile
            rc, out, err = await lib_call("l2tp_diag", timeout=90)
            with tempfile.NamedTemporaryFile("w", suffix="-l2tp-diag.txt", delete=False, encoding="utf-8") as f:
                f.write(out or err or "(kosong)"); path = f.name
            await m.answer_document(FSInputFile(path), caption="Diagnosa L2TP/IPsec")
        elif action == "pf_new":
            await m.answer("Ketik: <code>forward port 8080 ke 192.166.2.2:80</code>", parse_mode="HTML")
        elif action == "pf_del":
            await m.answer("Ketik: <code>hapus pf ID</code> (belum ada intent — sementara pakai CLI menu 4 → 6).", parse_mode="HTML")
        await q.answer()

    @root.callback_query(F.data.startswith("hub:"))
    async def cb_hub(q: CallbackQuery):
        from .shellcall import lib_call
        import tempfile
        from aiogram.types import FSInputFile
        _, action, name = q.data.split(":", 2)
        m = q.message
        if action == "status":
            rc, out, err = await lib_call("mtlan_list")
            # tampilkan hanya blok hub yang dipilih
            blocks = (out or "").split("\n[")
            sel = next((b for b in blocks if f"akun={name} " in b), None)
            body = ("[" + sel) if sel else (out or err or "-")
            await m.answer(f"<pre>{body.strip()[:3500]}</pre>", parse_mode="HTML")
        elif action == "check":
            rc, out, err = await lib_call("mtlan_check", timeout=60)
            lines = [l for l in (out or "").splitlines() if name in l or l.startswith("     LAN")]
            await m.answer(f"<pre>{(chr(10).join(lines) or out or err).strip()[:3500]}</pre>", parse_mode="HTML")
        elif action == "checkall":
            await m.answer("🩺 Menguji semua hub & LAN…")
            rc, out, err = await lib_call("mtlan_check", timeout=90)
            await m.answer(f"<pre>{(out or err or '-').strip()[:3500]}</pre>", parse_mode="HTML")
        elif action == "snippet":
            rc, out, err = await lib_call("generate_mikrotik_l2tp_snippet", name)
            if rc == 0 and out.strip():
                with tempfile.NamedTemporaryFile("w", suffix=f"-{name}.rsc", delete=False, encoding="utf-8") as f:
                    f.write(out); path = f.name
                await m.answer_document(FSInputFile(path), caption=f"Snippet MikroTik untuk hub <code>{name}</code>", parse_mode="HTML")
            else:
                await m.answer(f"❌ {(err or out).strip()[:300]}")
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
            elif intent.name in ("mtlan_add", "mtlan_del", "mtlan_list", "hub_set", "hub_del", "mtlan_check", "mtlan_check_ip"):
                from .shellcall import lib_call
                if intent.name == "mtlan_list":
                    await _hub_map_message(msg)
                    return
                if intent.name == "mtlan_add":
                    rc, out, err = await lib_call("mtlan_add", p["cidr"], p.get("hub", ""), p.get("note", ""))
                elif intent.name == "mtlan_del":
                    rc, out, err = await lib_call("mtlan_del", p["cidr"])
                elif intent.name == "hub_set":
                    rc, out, err = await lib_call("mtlan_hub_add", p["name"], p.get("ip", "auto"), p.get("label", p["name"]))
                elif intent.name == "hub_del":
                    rc, out, err = await lib_call("mtlan_hub_del", p["name"])
                elif intent.name == "mtlan_check":
                    await msg.answer("🩺 Menguji hub & LAN…")
                    rc, out, err = await lib_call("mtlan_check", timeout=90)
                else:
                    rc, out, err = await lib_call("mtlan_check", p["ip"], timeout=30)
                body = (out or err or "OK").strip()
                await msg.answer(f"{'✅' if rc == 0 else '❌'} <pre>{body[:3000]}</pre>", parse_mode="HTML")
            elif intent.name == "l2tp_cred":
                from .shellcall import lib_call
                rc, out, err = await lib_call("l2tp_show", p["name"])
                if rc != 0:
                    await msg.answer(f"❌ {err or out}".strip()[:400])
                else:
                    await msg.answer(f"🔑 <b>Kredensial L2TP</b>\n<pre>{out.strip()}</pre>", parse_mode="HTML")
            elif intent.name == "snippet":
                from .shellcall import lib_call
                import tempfile
                from aiogram.types import FSInputFile
                rc, out, err = await lib_call("generate_mikrotik_l2tp_snippet", p["name"])
                if rc != 0 or not out.strip():
                    await msg.answer(f"❌ {err or out}".strip()[:400])
                else:
                    with tempfile.NamedTemporaryFile("w", suffix=f"-{p['name']}.rsc", delete=False, encoding="utf-8") as f:
                        f.write(out)
                        path = f.name
                    await msg.answer_document(FSInputFile(path), caption=f"Snippet MikroTik L2TP untuk <code>{p['name']}</code>", parse_mode="HTML")
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
