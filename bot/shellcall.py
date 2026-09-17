"""Wrapper untuk memanggil lib/*.sh dari bot dengan aman."""
from __future__ import annotations

import asyncio
import shlex
from pathlib import Path

LIB_DIR = Path("/opt/tunn-awg/lib")


async def sh(cmd: str, timeout: int = 60) -> tuple[int, str, str]:
    proc = await asyncio.create_subprocess_shell(
        cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        return 124, "", "timeout"
    return proc.returncode or 0, out.decode(errors="replace"), err.decode(errors="replace")


async def lib_call(func: str, *args: str, timeout: int = 60) -> tuple[int, str, str]:
    """Source semua lib/*.sh lalu panggil fungsi tertentu."""
    quoted = " ".join(shlex.quote(a) for a in args)
    cmd = (
        f"bash -c 'set -e; "
        f"for f in {LIB_DIR}/*.sh; do . \"$f\"; done; "
        f"{func} {quoted}'"
    )
    return await sh(cmd, timeout=timeout)
