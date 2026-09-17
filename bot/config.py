"""Config loader for the tunn-awg Telegram bot."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Iterable

from dotenv import dotenv_values

ETC = Path(os.environ.get("TUNN_ETC", "/etc/tunn-awg"))
CONFIG_FILE = ETC / "config.env"
DB_FILE = ETC / "data.db"
NOTIFY_DIR = Path("/var/lib/tunn-awg/notify")
LOG_FILE = Path("/var/log/tunn-awg/bot.log")
CLIENTS_WG = ETC / "clients" / "wg"


def _parse_ids(raw: str) -> list[int]:
    out: list[int] = []
    for tok in (raw or "").replace(";", ",").split(","):
        tok = tok.strip()
        if tok.isdigit():
            out.append(int(tok))
    return out


class Config:
    def __init__(self, values: dict[str, str]):
        self._v = values
        self.token = values.get("BOT_TOKEN", "").strip()
        self.admin_ids: list[int] = _parse_ids(values.get("ADMIN_IDS", ""))
        owner_raw = values.get("OWNER_ID", "").strip()
        self.owner_id: int | None = int(owner_raw) if owner_raw.isdigit() else (
            self.admin_ids[0] if self.admin_ids else None
        )
        self.grace_days = int(values.get("GRACE_DAYS", "3") or 3)
        self.rate_limit = int(values.get("RATE_LIMIT_PER_MIN", "20") or 20)
        self.llm_key = values.get("LLM_API_KEY", "").strip()
        self.llm_endpoint = values.get("LLM_ENDPOINT", "").strip()
        self.llm_model = values.get("LLM_MODEL", "").strip()
        self.wg_endpoint = values.get("WG_SERVER_ENDPOINT", "")
        self.l2tp_ip = values.get("L2TP_PUBLIC_IP", "")
        self.ipsec_psk = values.get("IPSEC_PSK", "")

    def is_admin(self, uid: int) -> bool:
        return uid in self.admin_ids

    def is_owner(self, uid: int) -> bool:
        return self.owner_id is not None and uid == self.owner_id

    def raw(self, key: str, default: str = "") -> str:
        return self._v.get(key, default)


def load() -> Config:
    values = dict(dotenv_values(CONFIG_FILE)) if CONFIG_FILE.exists() else {}
    return Config(values)


def admins_of(cfg: Config) -> Iterable[int]:
    return cfg.admin_ids
