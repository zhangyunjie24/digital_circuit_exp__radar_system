"""模拟器：按 FPGA 的扫描节拍和输出格式生成测量行，不接板子也能开发 / 演示。

坐标：传感器在原点，0° 指向 +x（右），90° 指向 +y（正前方），单位 mm，与点阵 / LCD 的角度方向一致。

节拍与 scan_engine.v 相同：
    STEP：每档 2000ms，稳定 500ms 后测距，步长 45°
    CONT：每档 100ms，稳定 20ms 后测距，步长 2°；重新开始后的第一档 500ms（480ms 时测距）
角度在 0~180 之间反弹。
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from .model import CONT, STEP, STEP_SIZE, other_mode
from .parser import MAX_DIST_MM, Measurement, band_of, format_line

Point = tuple[float, float]


@dataclass
class MovingDisc:
    """在 a、b 两点间来回匀速移动的圆柱（比如走动的人）。"""
    a: Point
    b: Point
    radius: float
    period: float           # s，走一个来回

    def center(self, t: float) -> Point:
        phase = (t % self.period) / self.period
        f = 1 - abs(2 * phase - 1)      # 0 → 1 → 0
        return (self.a[0] + f * (self.b[0] - self.a[0]), self.a[1] + f * (self.b[1] - self.a[1]))


@dataclass
class Scene:
    segments: list[tuple[Point, Point]] = field(default_factory=list)
    discs: list[MovingDisc] = field(default_factory=list)
    beam_half_deg: float = 7.5      # HC-SR04 波束约 15°：取波束内最近的回波

    @staticmethod
    def default() -> Scene:
        def box(cx, cy, h):
            c = [(cx - h, cy - h), (cx + h, cy - h), (cx + h, cy + h), (cx - h, cy + h)]
            return [(c[i], c[(i + 1) % 4]) for i in range(4)]

        walls = [
            ((-1200, -100), (-1200, 1800)),     # 左墙
            ((-1200, 1800), (200, 1800)),       # 后墙（200~900 是门，门外无回波）
            ((900, 1800), (1500, 1800)),
            ((1500, 1800), (1500, -100)),       # 右墙
        ]
        return Scene(
            segments=walls + box(700, 800, 150) + box(-500, 450, 80),   # 柱子、椅子
            discs=[MovingDisc(a=(-700, 1400), b=(-150, 250), radius=150, period=24.0)],
        )

    def range_at(self, angle_deg: float, t: float) -> float | None:
        """波束内最近的回波距离（mm）；没有回波返回 None。"""
        hits = [self._ray(angle_deg + k * self.beam_half_deg, t) for k in (-1, -0.5, 0, 0.5, 1)]
        hits = [h for h in hits if h is not None]
        return min(hits) if hits else None

    def _ray(self, angle_deg: float, t: float) -> float | None:
        dx, dy = math.cos(math.radians(angle_deg)), math.sin(math.radians(angle_deg))
        best = None
        for (px, py), (qx, qy) in self.segments:
            ex, ey = qx - px, qy - py
            denom = dx * ey - dy * ex
            if abs(denom) < 1e-9:
                continue
            r = (px * ey - py * ex) / denom     # 沿射线的距离
            s = (px * dy - py * dx) / denom     # 在线段上的位置
            if r > 0 and 0 <= s <= 1 and (best is None or r < best):
                best = r
        for disc in self.discs:
            cx, cy = disc.center(t)
            proj = cx * dx + cy * dy
            perp2 = cx * cx + cy * cy - proj * proj
            if proj > 0 and perp2 <= disc.radius ** 2:
                r = proj - math.sqrt(disc.radius ** 2 - perp2)
                if r > 0 and (best is None or r < best):
                    best = r
        return best


class Simulator:
    """逐行产生 (t, 文本行)，t 是模拟时间（秒）。"""

    def __init__(self, scene: Scene | None = None, mode: str = STEP, seed: int | None = None,
                 noise_mm: float = 3.0, dropout: float = 0.01, corrupt: float = 0.0):
        self.scene = scene or Scene.default()
        self.noise_mm = noise_mm
        self.dropout = dropout      # 偶发无回波的概率
        self.corrupt = corrupt      # 模拟"切换撞上发送"的坏行概率（D=0000 L=7）
        self._rng = random.Random(seed)
        self.restart(0.0, mode)

    def restart(self, t: float, mode: str | None = None, delay: float = 0.0) -> None:
        """t + delay 时刻从 0° 重新开始扫描。"""
        if mode:
            self.mode = mode
        self._angle = 0
        self._up = True
        self._beat_start = t + delay
        self._first = True

    def switch_mode(self, t: float) -> None:
        """模拟按键切换：立即回 0°，模式取反。"""
        self.restart(t, other_mode(self.mode))

    def power_cycle(self, t: float, off_s: float = 1.0) -> None:
        """模拟 SW7 关 off_s 秒再打开：自检 2s + 待机 2s 后以 STEP 开始。"""
        self.restart(t, STEP, delay=off_s + 4.0)

    def next(self) -> tuple[float, str]:
        if self.mode == STEP:
            settle, beat = 0.5, 2.0
        else:
            settle, beat = (0.48, 0.5) if self._first else (0.02, 0.1)
        t = self._beat_start + settle
        line = self._measure(t, self._angle)

        self._beat_start += beat
        self._first = False
        self._up = self._angle < 180 if self._up else self._angle == 0
        self._angle += STEP_SIZE[self.mode] * (1 if self._up else -1)
        return t, line

    def _measure(self, t: float, angle: int) -> str:
        r = self.scene.range_at(angle, t)
        if r is None or self._rng.random() < self.dropout:
            dist = None
        else:
            dist = max(20, round(r + self._rng.gauss(0, self.noise_mm)))
            if dist > MAX_DIST_MM:
                dist = None
        line = format_line(Measurement(angle, dist, band_of(dist)))
        if self._rng.random() < self.corrupt:
            line = line[:8] + "0000 L=7\r\n"
        return line
