"""录制：把数据源收到的每一行原样存成 CSV（t,raw），坏行也存。

存原始行而不是解析结果：回放时重新走一遍解析和推断，回放和实时看到的完全一样；
以后改了解析 / 分析逻辑，旧录制也能直接用新逻辑重放。
"""
from __future__ import annotations

import csv
import time
from pathlib import Path

from .sources import read_recording

RECORDINGS_DIR = Path(__file__).resolve().parent.parent / "recordings"


class Recorder:
    def __init__(self, directory: Path = RECORDINGS_DIR):
        self.directory = directory
        self.path: Path | None = None
        self.count = 0
        self._file = None
        self._writer = None

    @property
    def active(self) -> bool:
        return self._file is not None

    def start(self, tag: str = "") -> Path:
        self.stop()
        self.directory.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d_%H%M%S")
        base = f"rec_{stamp}{'_' + tag if tag else ''}"
        self.path = self.directory / f"{base}.csv"
        n = 2
        while self.path.exists():           # 同一秒内再录一次：加序号，不覆盖
            self.path = self.directory / f"{base}_{n}.csv"
            n += 1
        self._file = open(self.path, "w", newline="", encoding="utf-8")
        self._writer = csv.writer(self._file)
        self._writer.writerow(["t", "raw"])
        self.count = 0
        return self.path

    def write(self, t: float, raw: str) -> None:
        if not self._file:
            return
        self._writer.writerow([f"{t:.3f}", raw])
        self._file.flush()          # 最快每 100ms 一行，直接刷盘，程序被强关也不丢
        self.count += 1

    def stop(self) -> None:
        if self._file:
            self._file.close()
        self._file = self._writer = None

    def status(self) -> dict | None:
        return {"file": self.path.name, "lines": self.count} if self.active else None


def list_recordings(directory: Path = RECORDINGS_DIR) -> list[dict]:
    """[{name, lines, duration, mtime}]，最新的在前。"""
    out = []
    for p in sorted(directory.glob("*.csv"), key=lambda p: p.stat().st_mtime, reverse=True):
        rows = read_recording(p)
        out.append({
            "name": p.name,
            "lines": len(rows),
            "duration": round(rows[-1][0] - rows[0][0], 1) if len(rows) > 1 else 0.0,
            "mtime": p.stat().st_mtime,
        })
    return out
