"""Async SQLite helpers."""
from __future__ import annotations

import aiosqlite
from pathlib import Path

from .config import DB_FILE


async def fetch(sql: str, *args) -> list[aiosqlite.Row]:
    async with aiosqlite.connect(DB_FILE) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute(sql, args)
        rows = await cur.fetchall()
        await cur.close()
        return rows


async def execute(sql: str, *args) -> None:
    async with aiosqlite.connect(DB_FILE) as db:
        await db.execute(sql, args)
        await db.commit()


async def scalar(sql: str, *args):
    rows = await fetch(sql, *args)
    if not rows:
        return None
    return rows[0][0]
