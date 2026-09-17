"""Multi-admin whitelist + token-bucket rate limiter + audit log."""
from __future__ import annotations

import time
from collections import defaultdict, deque
from pathlib import Path

from aiogram import BaseMiddleware
from aiogram.types import TelegramObject, Message, CallbackQuery

from .config import Config, LOG_FILE


class AuthMiddleware(BaseMiddleware):
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._buckets: dict[int, deque[float]] = defaultdict(deque)
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

    async def __call__(self, handler, event: TelegramObject, data: dict):
        uid = _extract_uid(event)
        if uid is None:
            return
        if not self.cfg.is_admin(uid):
            self._audit(uid, "denied", _describe(event))
            return await _reply(event, "🚫 Akses ditolak.")
        if not self._allow(uid):
            return await _reply(event, "⏳ Rate limit tercapai, coba lagi sebentar.")
        self._audit(uid, "ok", _describe(event))
        data["cfg"] = self.cfg
        data["uid"] = uid
        return await handler(event, data)

    def _allow(self, uid: int) -> bool:
        now = time.time()
        bucket = self._buckets[uid]
        while bucket and now - bucket[0] > 60:
            bucket.popleft()
        if len(bucket) >= self.cfg.rate_limit:
            return False
        bucket.append(now)
        return True

    def _audit(self, uid: int, verdict: str, what: str):
        try:
            with LOG_FILE.open("a", encoding="utf-8") as f:
                f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} uid={uid} {verdict} {what}\n")
        except OSError:
            pass


def _extract_uid(event: TelegramObject) -> int | None:
    if isinstance(event, Message) and event.from_user:
        return event.from_user.id
    if isinstance(event, CallbackQuery) and event.from_user:
        return event.from_user.id
    return None


def _describe(event: TelegramObject) -> str:
    if isinstance(event, Message):
        return f"msg={(event.text or event.caption or '')[:80]!r}"
    if isinstance(event, CallbackQuery):
        return f"cb={event.data!r}"
    return type(event).__name__


async def _reply(event: TelegramObject, text: str):
    if isinstance(event, Message):
        await event.reply(text)
    elif isinstance(event, CallbackQuery):
        await event.answer(text, show_alert=True)
