"""分析：背景差分（入侵检测）与测距精度标定。

背景差分
    "记录背景"时，每个角度取最近 BASE_SAMPLES 次读数里**最近的**距离作为背景。不用均值 / 中位数：
    物体边缘处 HC-SR04 会在两个距离之间来回跳（实测 144°~150° 在 300 和 1841 之间交替），
    取最小值后，只有比背景里出现过的最近距离还近 INTRUDE_MM 以上，才算有东西闯进来。
    背景是"无回波"的方向（比如门外），之后测到 OPEN_MAX_MM 以内的回波也算闯入。

精度标定
    对着一个已知距离的目标（墙、书本），按"开始采集"后收集指定角度的 N 次有效读数，
    得到均值、标准差、误差；多个距离之后做最小二乘：测量值 = k × 真实值 + b。
    STEP 模式只取该角度；CONT 舵机不停，取 ±CONT_TOL 度内的读数（波束约 15°，对着的是同一个目标）。
"""
from __future__ import annotations

import math
from collections import defaultdict
from collections.abc import Iterable

BASE_SAMPLES = 8        # 每个角度取最近几次读数作背景
INTRUDE_MM = 150        # 比背景近这么多才算闯入
OPEN_MAX_MM = 3000      # 背景无回波的方向：出现这个距离以内的回波算闯入
NEAR_DEG = 3            # 背景里没有这个角度时，借用 ±3° 内最近的角度（STEP 的 45/135 用 CONT 的 44/46）
CONT_TOL = 4            # CONT 模式标定取的角度范围（±度）


class Baseline:
    def __init__(self):
        self.ref: dict[int, int | None] = {}    # 角度 → 背景距离（None = 背景无回波）
        self.t: float | None = None

    def __bool__(self) -> bool:
        return bool(self.ref)

    def capture(self, history: Iterable[dict], t: float) -> int:
        """从测量历史（旧 → 新）里取每个角度最近 BASE_SAMPLES 次。返回记录到的方向数。"""
        samples: dict[int, list] = defaultdict(list)
        for m in reversed(list(history)):
            if len(samples[m["a"]]) < BASE_SAMPLES:
                samples[m["a"]].append(m["d"])
        ref = {}
        for a, ds in samples.items():
            valid = [d for d in ds if d is not None]
            ref[a] = min(valid) if 2 * len(valid) >= len(ds) else None    # 多数是无回波 → 背景为空
        self.ref, self.t = ref, t
        return len(ref)

    def clear(self) -> None:
        self.ref, self.t = {}, None

    def lookup(self, angle: int) -> tuple[bool, int | None]:
        if angle in self.ref:
            return True, self.ref[angle]
        near = [a for a in self.ref if abs(a - angle) <= NEAR_DEG]
        if not near:
            return False, None
        return True, self.ref[min(near, key=lambda a: abs(a - angle))]

    def check(self, angle: int, dist: int | None) -> dict | None:
        """闯入时返回 {b: 背景距离或 None, delta: 近了多少 mm 或 None}，否则 None。"""
        if not self.ref or dist is None:
            return None
        found, b = self.lookup(angle)
        if not found:
            return None
        if b is None:
            return {"b": None, "delta": None} if dist <= OPEN_MAX_MM else None
        delta = b - dist
        return {"b": b, "delta": delta} if delta > INTRUDE_MM else None

    def to_dict(self) -> dict:
        return {"t": self.t, "ref": {str(a): d for a, d in sorted(self.ref.items())}}


class Calibration:
    def __init__(self):
        self.points: list[dict] = []
        self.active: dict | None = None

    def start(self, true_mm: int, angle: int, count: int, mode: str | None) -> None:
        self.active = {
            "true": int(true_mm), "angle": int(angle), "need": max(1, int(count)),
            "tol": 0 if mode == "STEP" else CONT_TOL, "got": [], "miss": 0,
        }

    def cancel(self) -> None:
        self.active = None

    def delete(self, index: int) -> None:
        if 0 <= index < len(self.points):
            del self.points[index]

    def clear(self) -> None:
        self.points.clear()
        self.active = None

    def offer(self, meas: dict) -> bool:
        """喂一条 meas；采集状态有变化时返回 True。"""
        act = self.active
        if not act or abs(meas["a"] - act["angle"]) > act["tol"]:
            return False
        if meas["d"] is None:
            act["miss"] += 1
            return True
        act["got"].append(meas["d"])
        if len(act["got"]) >= act["need"]:
            self.points.append(summarize(act["true"], act["got"], act["angle"]))
            self.points.sort(key=lambda p: p["true"])
            self.active = None
        return True

    def fit(self) -> dict | None:
        """最小二乘：测量均值 = k × 真实值 + b。至少两个不同的真实距离。"""
        pts = self.points
        if len({p["true"] for p in pts}) < 2:
            return None
        xs, ys = [p["true"] for p in pts], [p["mean"] for p in pts]
        n = len(xs)
        mx, my = sum(xs) / n, sum(ys) / n
        sxx = sum((x - mx) ** 2 for x in xs)
        sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
        k = sxy / sxx
        b = my - k * mx
        ss_tot = sum((y - my) ** 2 for y in ys)
        ss_res = sum((y - (k * x + b)) ** 2 for x, y in zip(xs, ys))
        return {
            "k": round(k, 5), "b": round(b, 2),
            "r2": round(1 - ss_res / ss_tot, 6) if ss_tot else 1.0,
            "max_abs_err": round(max(abs(p["err"]) for p in pts), 1),
            "mean_abs_err": round(sum(abs(p["err"]) for p in pts) / n, 1),
        }

    def to_msg(self) -> dict:
        return {"type": "calib", "active": self.active, "points": self.points, "fit": self.fit()}


def summarize(true_mm: int, samples: list[int], angle: int) -> dict:
    n = len(samples)
    mean = sum(samples) / n
    std = math.sqrt(sum((s - mean) ** 2 for s in samples) / (n - 1)) if n > 1 else 0.0
    return {
        "true": true_mm, "angle": angle, "n": n,
        "mean": round(mean, 1), "std": round(std, 1), "err": round(mean - true_mm, 1),
        "min": min(samples), "max": max(samples),
    }
