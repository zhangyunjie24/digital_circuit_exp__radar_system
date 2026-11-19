import asyncio
import json

from radar_viz.model import CONT, STEP, RadarModel
from radar_viz.sim import Simulator
from radar_viz.sources import SimSource


def run(model, sim, until=None, count=None):
    """把模拟器的行喂给模型，直到模拟时间 ≥ until 或喂够 count 行。返回所有消息。"""
    msgs = []
    n = 0
    while True:
        t, line = sim.next()
        msgs += model.feed(t, line)
        n += 1
        if (until is not None and t >= until) or (count is not None and n >= count):
            return msgs


def run_until_angle(model, sim, angle, direction):
    """喂到某个角度、且是沿 direction 方向到达的那一行为止。"""
    msgs = []
    while True:
        msgs += run(model, sim, count=1)
        if model.last.angle == angle and model.direction == direction:
            return msgs


def events(msgs, kind=None):
    return [m for m in msgs if m["type"] == "event" and (kind is None or m["kind"] == kind)]


def quiet_sim(mode=STEP, **kw):
    return Simulator(mode=mode, seed=1, dropout=0.0, **kw)


def test_step_steady():
    model, sim = RadarModel(), quiet_sim(STEP)
    msgs = run(model, sim, until=40)
    assert model.mode == STEP
    assert set(model.table) == {0, 45, 90, 135, 180}
    assert model.errors == 0
    assert events(msgs, "resync") == []
    angles = [m["a"] for m in msgs if m["type"] == "meas"][:10]
    assert angles == [0, 45, 90, 135, 180, 135, 90, 45, 0, 45]
    assert [e["end"] for e in events(msgs, "sweep")][:3] == [180, 0, 180]


def test_cont_steady():
    model, sim = RadarModel(), quiet_sim(CONT)
    msgs = run(model, sim, until=30)
    assert model.mode == CONT
    assert set(model.table) == set(range(0, 181, 2))
    assert events(msgs, "resync") == []
    assert [e["reason"] for e in events(msgs, "restart")] == ["start"]
    # 首次进入：0° 时还不确定模式，到 2° 才确定
    assert events(msgs, "mode")[0]["mode"] == CONT


def test_switch_mid_sweep():
    model, sim = RadarModel(), quiet_sim(STEP)
    run_until_angle(model, sim, 90, 1)
    sim.switch_mode(model.last_t + 0.7)
    msgs = run(model, sim, count=1)
    (restart,) = events(msgs, "restart")
    assert restart["reason"] == "switch" and restart["mode"] == CONT
    assert set(model.table) == {0}          # 旧的方向数据清掉了
    msgs = run(model, sim, until=model.last_t + 20)
    assert model.mode == CONT
    assert events(msgs, "resync") == [] and events(msgs, "restart") == []


def test_switch_cont_to_step_mid_sweep():
    model, sim = RadarModel(), quiet_sim(CONT)
    run_until_angle(model, sim, 120, 1)
    sim.switch_mode(model.last_t + 0.05)
    msgs = run(model, sim, count=3)
    assert [e["reason"] for e in events(msgs, "restart")] == ["switch"]
    assert model.mode == STEP and set(model.table) == {0, 45, 90}


def test_switch_just_before_zero_detected_late():
    # CONT 扫回到 2° 后按切换：STEP 新一轮的 0° 恰好就是 CONT 预期的下一个角度，到 45° 才认出来
    model, sim = RadarModel(), quiet_sim(CONT)
    run(model, sim, until=10)
    run_until_angle(model, sim, 2, -1)
    sim.switch_mode(model.last_t + 0.05)
    msgs = run(model, sim, count=2)
    (restart,) = events(msgs, "restart")
    assert restart["reason"] == "switch" and restart["mode"] == STEP
    assert model.mode == STEP and set(model.table) == {0, 45}
    msgs = run(model, sim, count=10)
    assert events(msgs, "resync") == [] and events(msgs, "restart") == []


def test_power_cycle_goes_back_to_step():
    model, sim = RadarModel(), quiet_sim(CONT)
    run(model, sim, until=5)
    sim.power_cycle(model.last_t + 0.05, off_s=2)
    msgs = run(model, sim, count=3)
    (restart,) = events(msgs, "restart")
    assert restart["reason"] == "power" and restart["mode"] == STEP
    assert model.mode == STEP


def test_corrupt_lines_rejected_without_false_restart():
    model, sim = RadarModel(), Simulator(mode=CONT, seed=7, dropout=0.0, corrupt=0.05)
    msgs = run(model, sim, until=120)
    bad = [m for m in msgs if m["type"] == "bad"]
    assert bad and model.errors == len(bad)
    assert all("L=7" in m["raw"] for m in bad)
    assert [e["reason"] for e in events(msgs, "restart")] == ["start"]
    assert model.mode == CONT
    assert all(v["l"] <= 4 for v in model.table.values())


def test_corrupt_lines_step_no_false_restart():
    model, sim = RadarModel(), Simulator(mode=STEP, seed=3, dropout=0.0, corrupt=0.15)
    msgs = run(model, sim, until=400)
    assert model.errors > 0
    assert [e["reason"] for e in events(msgs, "restart")] == ["start"]


def test_link_idle_and_back():
    model, sim = RadarModel(), quiet_sim(STEP)
    run(model, sim, count=3)
    assert model.tick(model.last_t + 2.5) == []
    (ev,) = model.tick(model.last_t + 3.5)
    assert ev["kind"] == "link" and ev["state"] == "idle"
    assert model.status(model.last_t + 3.5)["rate"] == 0
    msgs = run(model, sim, count=1)
    assert events(msgs, "link")[0]["state"] == "up"


def test_stats_and_snapshot_serializable():
    model, sim = RadarModel(), quiet_sim(STEP, noise_mm=3.0)
    run(model, sim, until=200)
    s = model.stats[0]                      # 0° 正对右墙，1500mm 处
    assert abs(s.mean - 1500) < 5 and 1 < s.std < 6
    snap = model.snapshot(model.last_t)
    json.dumps(snap)
    assert snap["status"]["rate"] > 0.4     # STEP 每 2s 一行
    assert set(snap["table"]) == {"0", "45", "90", "135", "180"}


def test_sim_source_realtime():
    async def go():
        src = SimSource(Simulator(mode=CONT, seed=1, dropout=0.0))
        out = []
        async for t, line in src.lines():
            out.append((t, line))
            if len(out) == 1:
                src.switch_mode()           # 立即切换：重新从 0° 开始，换成 STEP
            if len(out) == 2:
                return out

    (t1, l1), (t2, l2) = asyncio.run(asyncio.wait_for(go(), 5))
    assert l1.startswith("A=000") and l2.startswith("A=000")
    assert 0.45 < t2 - t1 < 0.6             # STEP 第一档 500ms 后测距


def test_snapshot_carries_recent_log():
    model, sim = RadarModel(), Simulator(mode=STEP, seed=3, dropout=0.0, corrupt=0.3)
    run(model, sim, until=60)
    model.tick(model.last_t + 5)
    log = model.snapshot(model.last_t + 5)["log"]
    kinds = {m.get("kind", m["type"]) for m in log}
    assert {"restart", "bad", "link"} <= kinds and "sweep" not in kinds


def test_histogram_counts_every_measurement():
    model, sim = RadarModel(), Simulator(mode=CONT, seed=4, dropout=0.05)
    run(model, sim, until=30)
    st = model.stats_msg()
    meas = [m for m in model.history]
    assert sum(st["hist"]["counts"]) + st["hist"]["oor"] == len(meas)
    assert st["hist"]["oor"] == sum(1 for m in meas if m["d"] is None)
    assert st["angles"]["0"]["n"] > 0


def test_real_board_recording():
    # 2026-10-15 实板 CONT 模式录制（HC-06 → COM7）：约 10s、108 行，含蓝牙时间抖动（75~129ms）
    from pathlib import Path
    from radar_viz.sources import read_recording
    rows = read_recording(Path(__file__).parent / "data" / "real_cont_com7.csv")
    model = RadarModel()
    msgs = [m for t, raw in rows for m in model.feed(t, raw)]
    assert len(rows) == 108 and model.errors == 0
    assert model.mode == CONT
    assert [e["reason"] for e in events(msgs, "restart")] == ["start"]
    assert events(msgs, "resync") == []
    assert [e["end"] for e in events(msgs, "sweep")] == [180]     # 144° 起步，到 180° 折返，录到 2° 为止
