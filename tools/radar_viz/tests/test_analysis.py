from pathlib import Path

import pytest

from radar_viz.analysis import Baseline, Calibration
from radar_viz.model import CONT, STEP, RadarModel, speed
from radar_viz.sim import MovingDisc, Scene, Simulator
from radar_viz.sources import read_recording


def meas(a, d, t=0.0):
    return {"type": "meas", "a": a, "d": d, "t": t}


# ---------------------------------------------------------------- 背景

def test_baseline_uses_nearest_reading_so_edges_do_not_alarm():
    # 物体边缘：146° 在 300 和 1841 之间来回跳（实板数据里出现过）
    hist = [meas(146, d) for d in (1841, 300, 1841, 300, 1841)]
    b = Baseline()
    assert b.capture(hist, 0.0) == 1
    assert b.ref[146] == 300
    assert b.check(146, 300) is None and b.check(146, 1841) is None
    assert b.check(146, 200) is None                 # 只近 100mm，不到门限
    assert b.check(146, 100) == {"b": 300, "delta": 200}


def test_baseline_open_direction_and_nearest_angle():
    hist = [meas(70, None)] * 5 + [meas(70, 2500)] + [meas(44, 1200)] * 3
    b = Baseline()
    b.capture(hist, 0.0)
    assert b.ref[70] is None                         # 多数无回波 → 背景为空
    assert b.check(70, 1500) == {"b": None, "delta": None}
    assert b.check(70, 3500) is None                 # 太远的零星回波不算
    assert b.check(45, 900) == {"b": 1200, "delta": 300}   # STEP 的 45° 借用 CONT 的 44°
    assert b.check(90, 100) is None                  # 背景里没有的方向不判
    assert b.check(44, None) is None


def scene_with(disc=None):
    s = Scene.default()
    s.discs = [disc] if disc else []
    return s


def run(model, sim, until):
    msgs = []
    while True:
        t, line = sim.next()
        msgs += model.feed(t, line)
        if t >= until:
            return msgs


def test_intrusion_detected_once_and_cleared():
    empty = Simulator(scene_with(), mode=CONT, seed=1, dropout=0.0)
    model = RadarModel()
    run(model, empty, until=20)
    model.capture_baseline(20)
    assert run(model, empty, until=40) and not model.intruded

    # 有人站到 120° 方向 600mm 处（背景那里是 1.2m 外的左墙 / 椅子）
    person = MovingDisc(a=(-300, 520), b=(-300, 520), radius=150, period=10)
    sim = Simulator(scene_with(person), mode=CONT, seed=1, dropout=0.0)
    sim._angle, sim._up, sim._beat_start, sim._first = empty._angle, empty._up, empty._beat_start, False
    msgs = run(model, sim, until=60)
    hits = [m for m in msgs if m["type"] == "event" and m["kind"] == "intrusion"]
    assert len(hits) >= 1
    assert all(100 <= h["angle"] <= 140 for h in hits)
    assert len(hits) <= 4                            # 一个人只报一次（每趟扫过最多一次）
    assert model.status(60)["intruded"] > 0

    # 人走开
    sim2 = Simulator(scene_with(), mode=CONT, seed=1, dropout=0.0)
    sim2._angle, sim2._up, sim2._beat_start, sim2._first = sim._angle, sim._up, sim._beat_start, False
    msgs = run(model, sim2, until=80)
    assert any(m["type"] == "event" and m["kind"] == "intrusion_clear" for m in msgs)
    assert not model.intruded


def test_real_recording_has_no_false_intrusions():
    rows = read_recording(Path(__file__).parent / "data" / "real_cont_com7.csv")
    model = RadarModel()
    for t, raw in rows:
        model.feed(t, raw)
    model.capture_baseline(rows[-1][0])
    # 同一段数据再放一遍（时间平移），背景应当覆盖全部读数
    shift = rows[-1][0] - rows[0][0] + 0.1
    msgs = [m for t, raw in rows for m in model.feed(t + shift, raw)]
    assert not [m for m in msgs if m["type"] == "event" and m["kind"] == "intrusion"]


def test_restart_and_clear_reset_intrusions():
    model = RadarModel()
    model.feed(0.0, "A=000 D=1500 L=0")
    model.feed(0.1, "A=002 D=1500 L=0")
    model.capture_baseline(0.1)
    msgs = model.feed(0.2, "A=004 D=0500 L=2")       # 背景里没有 4°，借用 ±3° 内的 2°（1500）
    assert [m["kind"] for m in msgs if m["type"] == "event"] == ["intrusion"]
    model.clear_baseline(0.3)
    assert not model.intruded and model.feed(0.4, "A=006 D=0500 L=2")[-1]["intr"] is None


# ---------------------------------------------------------------- 接近速度

def test_speed_rules():
    assert speed({"d": 1000, "t": 0.0}, 900, 10.0) == -10.0          # 靠近 10mm/s
    assert speed({"d": 1000, "t": 0.0}, 1100, 5.0) == 20.0
    assert speed({"d": 300, "t": 0.0}, 1841, 5.0) is None            # 边缘跳变
    assert speed({"d": 1000, "t": 0.0}, 900, 31.0) is None           # 隔太久
    assert speed({"d": None, "t": 0.0}, 900, 5.0) is None
    assert speed(None, 900, 5.0) is None


def test_speed_sees_person_walking_toward_sensor():
    walker = MovingDisc(a=(0, 1600), b=(0, 400), radius=150, period=200)   # 前 100s 匀速走近，12mm/s
    model, sim = RadarModel(), Simulator(scene_with(walker), mode=STEP, seed=1, dropout=0.0, noise_mm=1)
    run(model, sim, until=60)
    v90 = [m["v"] for m in model.history if m["a"] == 90 and m["v"] is not None]
    assert v90 and all(-16 < v < -8 for v in v90)


# ---------------------------------------------------------------- 标定

def test_calibration_collects_and_fits():
    cal = Calibration()
    # 假设传感器测量值 = 1.02 × 真实值 − 5，CONT 模式，取 90° ±4°
    for true in (300, 600, 1200):
        cal.start(true, 90, 6, CONT)
        cal.offer(meas(80, 999))                     # 范围外：不算
        cal.offer(meas(94, None))                    # 无回波：记 miss
        assert cal.active["miss"] == 1
        for i, a in enumerate((86, 88, 90, 92, 94, 90)):
            cal.offer(meas(a, round(1.02 * true - 5) + (1 if i % 2 else -1)))
        assert cal.active is None
    msg = cal.to_msg()
    assert [p["true"] for p in msg["points"]] == [300, 600, 1200]
    p = msg["points"][1]
    assert p["n"] == 6 and p["err"] == pytest.approx(0.02 * 600 - 5, abs=0.01)
    fit = msg["fit"]
    assert fit["k"] == pytest.approx(1.02, abs=1e-4) and fit["b"] == pytest.approx(-5, abs=0.1)
    assert fit["r2"] > 0.9999
    cal.delete(0)
    assert len(cal.points) == 2


def test_calibration_step_mode_exact_angle_only():
    cal = Calibration()
    cal.start(500, 90, 2, STEP)
    assert not cal.offer(meas(88, 500))
    cal.offer(meas(90, 503))
    cal.offer(meas(90, 507))
    assert cal.points[0]["mean"] == 505 and cal.fit() is None    # 只有一个距离，不拟合
