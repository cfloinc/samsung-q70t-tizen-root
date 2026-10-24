#!/usr/bin/env python3
"""Resilient SDB foothold command runner for the Q70T.

Usage: uv run python foreshell.py '<tv command>' [capture-timeout-seconds]

Runs the command through the SVE-2025-50109 injection foothold with automatic
recovery from the TV's intermittent sdb wedges (kill-server / reconnect loop).
"""
import os
import subprocess
import sys
import time
from pathlib import Path

TV = os.environ.get("TV_IP", "192.0.2.10")  # your TV


def recover_sdb() -> None:
    sdb = str(Path.home() / "tizen-studio/tools/sdb")
    subprocess.run([sdb, "kill-server"], capture_output=True)
    time.sleep(2)
    subprocess.run([sdb, "start-server"], capture_output=True)
    for _ in range(15):
        result = subprocess.run(
            [sdb, "connect", f"{TV}:26101"], capture_output=True, text=True
        )
        if "connected to" in result.stdout:
            return
        time.sleep(4)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    command = sys.argv[1]
    timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0

    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
    from samsung_tv_root.sdb import SdbClient, find_sdb

    for attempt in range(3):
        try:
            client = SdbClient(find_sdb(), TV, timeout=20)
            client.connect()
            client.require_device()
            client.require_shell_injection()
            result = client.capture(command, timeout=timeout)
            print(result.output.rstrip())
            return 0
        except Exception as error:
            print(
                f"[attempt {attempt + 1} failed: {error}]",
                file=sys.stderr,
            )
            recover_sdb()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
