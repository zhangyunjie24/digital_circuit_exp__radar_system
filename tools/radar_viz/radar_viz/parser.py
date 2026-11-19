"""串口测量行的解析与校验。

FPGA（report_ctrl.v）每次测距完成发一行定长 18 字节的 ASCII：

    A=045 D=0623 L=1\\r\\n        超量程 / 无回波时 D=----

A = 角度（度），D = 距离（mm，0~3999），L = 距离分级（0 = ≥800mm 或超量程 … 4 = <200mm）。
"""
from __future__ import annotations

import re
from dataclasses import dataclass

LINE_RE = re.compile(r"A=(\d{3}) D=(\d{4}|----) L=(\d)")

MAX_DIST_MM = 3999          # ultrasonic.v 计到 4000 即判超量程
STEP_ONLY_ANGLES = (45, 135)  # 奇数角只会出现在 STEP 模式（CONT 步长 2°）


class ParseError(ValueError):
    """一行数据不合法；str(e) 是给人看的原因。"""


@dataclass(frozen=True)
class Measurement:
    angle: int              # 0~180
    dist: int | None        # mm；None = 超量程 / 无回波
    level: int              # 0~4


def band_of(dist: int | None) -> int:
    """距离 → 分级，与 dist_band.v 一致（边界都是整百）。"""
    if dist is None or dist >= 800:
        return 0
    if dist >= 600:
        return 1
    if dist >= 400:
        return 2
    if dist >= 200:
        return 3
    return 4


def parse_line(line: str) -> Measurement:
    """解析一行（行尾的 \\r\\n 可有可无）。不合法时抛 ParseError。

    除了格式，还做一致性检查：模式切换恰好撞在一行发送途中时，FPGA 这一行的后半截会变成
    result_reg 清零后的值（D=0000 L=7），这类行在这里被拦下。
    """
    text = line.strip()
    m = LINE_RE.fullmatch(text)
    if not m:
        raise ParseError(f"格式不符: {text!r}")

    angle = int(m.group(1))
    dist = None if m.group(2) == "----" else int(m.group(2))
    level = int(m.group(3))

    if angle > 180:
        raise ParseError(f"角度超范围: {angle}")
    if angle % 2 and angle not in STEP_ONLY_ANGLES:
        raise ParseError(f"角度不在扫描序列中: {angle}")
    if level > 4:
        raise ParseError(f"分级超范围: L={level}")
    if dist is not None and dist > MAX_DIST_MM:
        raise ParseError(f"距离超范围: {dist}")
    if level != band_of(dist):
        raise ParseError(f"分级与距离不符: D={m.group(2)} L={level}")
    return Measurement(angle, dist, level)


def format_line(m: Measurement) -> str:
    """Measurement → FPGA 同款文本行（含 \\r\\n），模拟器用。"""
    d = "----" if m.dist is None else f"{m.dist:04d}"
    return f"A={m.angle:03d} D={d} L={m.level}\r\n"


class LineAssembler:
    """把串口收到的零散字节拼成行。

    以 \\n 分行、去掉 \\r；非 ASCII 字节替换成 U+FFFD（之后 parse_line 会判为格式不符）。
    缓冲超过 max_len 仍没有换行，说明在收垃圾（比如波特率不对），整段作为一行吐出，避免无限增长。
    """

    def __init__(self, max_len: int = 64):
        self._buf = bytearray()
        self._max_len = max_len

    def feed(self, data: bytes) -> list[str]:
        self._buf.extend(data)
        lines = []
        while True:
            i = self._buf.find(b"\n")
            if i < 0:
                break
            lines.append(self._decode(self._buf[:i]))
            del self._buf[: i + 1]
        if len(self._buf) > self._max_len:
            lines.append(self._decode(self._buf))
            self._buf.clear()
        return lines

    @staticmethod
    def _decode(raw: bytes) -> str:
        return raw.decode("ascii", errors="replace").rstrip("\r")
