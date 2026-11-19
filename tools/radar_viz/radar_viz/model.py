"""雷达状态模型：把一行行测量数据变成前端要画的状态。

FPGA 只发测量行、没有事件行，所以模式、扫描方向、重新开始都在这里推断：

- 模式：45°/135° 只有 STEP 会出现，非 45 的倍数只有 CONT 会出现；0/90/180 两种模式都有，
  再看和上一行的角度差（2 → CONT，45 → STEP）。
- 方向：按 FPGA 的反弹规则（scan_engine.v：到 180 往回、到 0 往上）预测下一行的角度。
- 重新开始：不在预测上、却回到了 0° →
    间隔 > RESTART_GAP：重新上电（SW7 关了又开；自检 2s + 待机 2s，之后默认 STEP）；
    间隔符合切换后的时序：按键切换了模式（FPGA 切换时舵机回 0°，从头开始，模式取反）；
    正好扫回 0° 时切换的，这一行看不出来，下一行步长对不上时补判。
  和 FPGA 一样，重新开始时清空各方向的当前距离（点阵 / LCD 也是这时清空的）。
- 其他对不上的情况（丢了几行）只记一个 resync 事件，按新数据继续跟踪。

feed() / tick() 返回要推给前端的消息（dict，可直接 json 序列化），格式见 README。
"""
from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass

from .analysis import Baseline
from .parser import STEP_ONLY_ANGLES, Measurement, ParseError, parse_line

STEP, CONT = "STEP", "CONT"
STEP_SIZE = {STEP: 45, CONT: 2}

RESTART_GAP = 4.3       # s；重新上电后第一次测距距上一行 ≥ 4.5s（自检 2s + 待机 2s + 0.5s）；STEP 丢一行是 4s
IDLE_AFTER = 3.0        # s；超过这么久没收到任何数据，链路记为 idle（SW7=0 或断链）
RATE_WINDOW = 10.0      # s；行速率统计窗口
HISTORY_LEN = 3000      # CONT 每 100ms 一行，约 5 分钟
LOG_LEN = 50            # 快照里带的最近事件 / 坏行数
HIST_BIN = 100          # 距离直方图：每格 100mm，0~4000mm 共 40 格，超量程单独计
HIST_BINS = 40
SPEED_MAX_DT = 30.0     # s；同一角度两次测量相隔太久就不算速度
SPEED_MAX_JUMP = 1000   # mm；距离跳变太大多半是边缘在两个目标间跳，不是物体在动
INTRUDE_MERGE_DEG = 10  # 相距 10° 以内的闯入角度算同一个目标，只报一次


def other_mode(mode: str) -> str:
    return CONT if mode == STEP else STEP


def classify(angle: int) -> str | None:
    """单看角度能确定的模式；0/90/180 两种模式都会出现，返回 None。"""
    if angle in STEP_ONLY_ANGLES:
        return STEP
    if angle % 45:
        return CONT
    return None


def expected_next(angle: int, direction: int, step: int) -> int:
    """FPGA 的下一个角度：到 180 往回、到 0 往上，其他沿原方向。"""
    if angle >= 180:
        direction = -1
    elif angle <= 0:
        direction = 1
    return angle + direction * step


def speed(prev: dict | None, dist: int | None, t: float) -> float | None:
    """同一角度相邻两次测量的距离变化率（mm/s，负 = 靠近）；条件不够时返回 None。"""
    if not prev or prev["d"] is None or dist is None:
        return None
    dt = t - prev["t"]
    if not 0 < dt <= SPEED_MAX_DT or abs(dist - prev["d"]) > SPEED_MAX_JUMP:
        return None
    return round((dist - prev["d"]) / dt, 1)


@dataclass
class AngleStats:
    """单个角度的累计统计（Welford 在线均值 / 方差），只统计有效距离。"""
    n: int = 0
    mean: float = 0.0
    m2: float = 0.0
    oor: int = 0

    def add(self, dist: int | None) -> None:
        if dist is None:
            self.oor += 1
            return
        self.n += 1
        delta = dist - self.mean
        self.mean += delta / self.n
        self.m2 += delta * (dist - self.mean)

    @property
    def std(self) -> float:
        return math.sqrt(self.m2 / (self.n - 1)) if self.n > 1 else 0.0

    def to_dict(self) -> dict:
        return {"n": self.n, "mean": round(self.mean, 1), "std": round(self.std, 1), "oor": self.oor}


class RadarModel:
    def __init__(self, history_len: int = HISTORY_LEN):
        self.history: deque[dict] = deque(maxlen=history_len)
        self.log: deque[dict] = deque(maxlen=LOG_LEN)   # 最近的 event / bad（不含 sweep）
        self.reset()

    def reset(self) -> None:
        """全部清空（换数据源时用）。"""
        self.mode: str | None = None
        self.direction = 0          # 上一步的方向 +1/-1，0 = 未知
        self.passes = 0             # 本次重新开始以来走完的单程数
        self.last: Measurement | None = None
        self.last_t: float | None = None
        self.table: dict[int, dict] = {}        # 角度 → 最近一次 {d, l, t, v, intr}
        self.baseline = Baseline()
        self.intruded: dict[int, float] = {}    # 当前判为闯入的角度 → 时刻
        self.stats: dict[int, AngleStats] = {}  # 角度 → 累计统计（重新开始也不清）
        self.hist = [0] * HIST_BINS
        self.hist_oor = 0
        self.history.clear()
        self.log.clear()
        self.seq = 0
        self.lines = 0
        self.errors = 0
        self.link = "none"          # none / up / idle
        self._last_rx: float | None = None
        self._rx_times: deque[float] = deque()

    # ---- 输入 ----

    def feed(self, t: float, raw: str) -> list[dict]:
        """收到一行（t = 收到时刻，秒）。返回要推给前端的消息。"""
        return self._logged(self._feed(t, raw))

    def _feed(self, t: float, raw: str) -> list[dict]:
        msgs: list[dict] = []
        self.lines += 1
        self._last_rx = t
        self._rx_times.append(t)
        if self.link != "up":
            self.link = "up"
            msgs.append(self._event(t, "link", state="up"))

        try:
            m = parse_line(raw)
        except ParseError as e:
            self.errors += 1
            msgs.append({"type": "bad", "t": t, "raw": raw, "reason": str(e)})
            return msgs

        msgs.extend(self._track(t, m))

        prev = self.table.get(m.angle)          # 重新开始时 table 已清空 → 不算速度
        v = speed(prev, m.dist, t)
        intr = self.baseline.check(m.angle, m.dist)
        msgs.extend(self._intrusion(t, m, intr))

        self.last, self.last_t = m, t
        self.seq += 1
        self.table[m.angle] = {"d": m.dist, "l": m.level, "t": t, "v": v, "intr": intr}
        self.stats.setdefault(m.angle, AngleStats()).add(m.dist)
        if m.dist is None:
            self.hist_oor += 1
        else:
            self.hist[min(HIST_BINS - 1, m.dist // HIST_BIN)] += 1
        meas = {
            "type": "meas", "seq": self.seq, "t": t,
            "a": m.angle, "d": m.dist, "l": m.level,
            "mode": self.mode, "dir": self.direction, "pass": self.passes,
            "v": v, "intr": intr,
        }
        self.history.append(meas)
        msgs.append(meas)
        return msgs

    def tick(self, t: float) -> list[dict]:
        """定时调用（比如每秒），检查链路是否断了。"""
        if self.link == "up" and t - self._last_rx > IDLE_AFTER:
            self.link = "idle"
            return self._logged([self._event(t, "link", state="idle")])
        return []

    # ---- 输出 ----

    def status(self, t: float) -> dict:
        while self._rx_times and self._rx_times[0] < t - RATE_WINDOW:
            self._rx_times.popleft()
        n = len(self._rx_times)
        span = t - self._rx_times[0] if n else 0.0
        rate = n / max(span, 1.0) if self.link == "up" else 0.0
        return {
            "type": "status", "t": t, "link": self.link, "rate": round(rate, 2),
            "lines": self.lines, "errors": self.errors, "mode": self.mode,
            "intruded": len(self.intruded),
        }

    def stats_msg(self) -> dict:
        """累计统计：每个角度的均值 / 标准差 / 无回波次数，以及距离直方图。"""
        return {
            "type": "stats",
            "angles": {str(a): s.to_dict() for a, s in sorted(self.stats.items())},
            "hist": {"bin": HIST_BIN, "counts": list(self.hist), "oor": self.hist_oor},
        }

    def snapshot(self, t: float) -> dict:
        """前端刚连上（或刷新）时发的全量状态。"""
        return {
            "type": "snapshot", "t": t,
            "mode": self.mode, "dir": self.direction, "pass": self.passes,
            "table": {str(a): v for a, v in sorted(self.table.items())},
            "stats": self.stats_msg(),
            "history": list(self.history),
            "log": list(self.log),
            "baseline": self.baseline.to_dict(),
            "status": self.status(t),
        }

    # ---- 背景 / 闯入 ----

    def capture_baseline(self, t: float) -> list[dict]:
        n = self.baseline.capture(self.history, t)
        self.intruded.clear()
        return self._logged([self._event(t, "baseline", angles=n)])

    def clear_baseline(self, t: float) -> list[dict]:
        self.baseline.clear()
        self.intruded.clear()
        return self._logged([self._event(t, "baseline", angles=0)])

    def _intrusion(self, t: float, m: Measurement, intr: dict | None) -> list[dict]:
        """闯入开始（附近 10° 内没有正在闯入的角度）报一次；全部解除再报一次。"""
        if intr:
            fresh = not any(abs(a - m.angle) <= INTRUDE_MERGE_DEG for a in self.intruded)
            self.intruded[m.angle] = t
            if fresh:
                return [self._event(t, "intrusion", angle=m.angle, d=m.dist, b=intr["b"], delta=intr["delta"])]
        elif self.intruded.pop(m.angle, None) is not None and not self.intruded:
            return [self._event(t, "intrusion_clear")]
        return []

    def _logged(self, msgs: list[dict]) -> list[dict]:
        self.log.extend(m for m in msgs if m["type"] == "bad" or (m["type"] == "event" and m["kind"] != "sweep"))
        return msgs

    # ---- 推断 ----

    def _track(self, t: float, m: Measurement) -> list[dict]:
        ev: list[dict] = []
        last = self.last

        if last is None:
            self._restart(t, m, "start", classify(m.angle), ev)
            return ev
        if m.angle == 0 and t - self.last_t > RESTART_GAP:
            self._restart(t, m, "power", STEP, ev)
            return ev

        delta = m.angle - last.angle
        evidence = classify(m.angle) or {2: CONT, 45: STEP}.get(abs(delta))

        if self._is_expected(last.angle, m.angle):
            pass
        elif m.angle == 0 and self.mode is not None and self._gap_fits_switch(t - self.last_t):
            self._restart(t, m, "switch", other_mode(self.mode), ev)
            return ev
        elif last.angle == 0 and self.mode is not None and evidence == other_mode(self.mode):
            # 正好扫回 0° 时按了切换：那一行本身看不出来，这一行才对不上。补判为切换，
            # 上一行（0°）已经属于新的一轮，保留
            zero = self.table.get(0)
            self._restart(self.last_t, last, "switch", evidence, ev)
            self.table[0] = zero
            return ev
        else:
            ev.append(self._event(t, "resync", prev=last.angle, angle=m.angle))

        if evidence and evidence != self.mode:
            ev.append(self._event(t, "mode", mode=evidence, prev=self.mode))
            self.mode = evidence

        if delta:
            self.direction = 1 if delta > 0 else -1
            if m.angle in (0, 180):
                self.passes += 1
                ev.append(self._event(t, "sweep", passes=self.passes, end=m.angle))
        return ev

    def _is_expected(self, prev: int, angle: int) -> bool:
        if self.mode is None:
            return abs(angle - prev) in STEP_SIZE.values()
        step = STEP_SIZE[self.mode]
        if self.direction == 0 and prev not in (0, 180):
            return abs(angle - prev) == step
        return angle == expected_next(prev, self.direction, step)

    def _gap_fits_switch(self, gap: float) -> bool:
        """按键切换后，新一轮第一次测距在按键后 480/500ms，所以与上一行的间隔：
        CONT → 至少 0.48s（正常 0.1s，丢一行 0.2s）；STEP → 0.5~2.5s（丢一行就是 4s）。
        用它区分"切换"和"丢了几行恰好落在 0°"。"""
        if self.mode == CONT:
            return gap > 0.4
        return gap < 3.0

    def _restart(self, t: float, m: Measurement, reason: str, mode: str | None, ev: list[dict]) -> None:
        self.mode = mode
        self.direction = 1 if m.angle == 0 else 0
        self.passes = 0
        self.table.clear()
        self.intruded.clear()
        ev.append(self._event(t, "restart", reason=reason, mode=mode))

    @staticmethod
    def _event(t: float, kind: str, **info) -> dict:
        return {"type": "event", "t": t, "kind": kind, **info}
