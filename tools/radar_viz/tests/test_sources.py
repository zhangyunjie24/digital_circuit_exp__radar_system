import asyncio
import time

import pytest
from aiohttp.test_utils import TestClient, TestServer

from radar_viz.model import CONT, STEP, RadarModel
from radar_viz.recording import Recorder, list_recordings
from radar_viz.server import make_app
from radar_viz.sim import Simulator
from radar_viz.sources import ReplaySource, SerialSource, read_recording


class FakeSerial:
    """按顺序吐出预设的字节块；吐完后抛出 error（模拟拔掉），或一直返回空。"""

    def __init__(self, chunks, error=None):
        self.chunks = list(chunks)
        self.error = error
        self.closed = False

    @property
    def in_waiting(self):
        return len(self.chunks[0]) if self.chunks else 0

    def read(self, n):
        if self.chunks:
            return self.chunks.pop(0)
        if self.error:
            raise self.error
        time.sleep(0.01)
        return b""

    def close(self):
        self.closed = True


def collect(agen, n, timeout=3):
    async def go():
        out = []
        async for item in agen:
            out.append(item)
            if len(out) == n:
                break
        await agen.aclose()
        return out
    return asyncio.run(asyncio.wait_for(go(), timeout))


def test_serial_assembles_lines_and_closes():
    fake = FakeSerial([b"A=045 D=06", b"23 L=1\r\nA=090 D=", b"---- L=0\r\n"])
    src = SerialSource("COM9", opener=lambda port, baud: fake)
    out = collect(src.lines(), 2)
    assert [line for _, line in out] == ["A=045 D=0623 L=1", "A=090 D=---- L=0"]
    deadline = time.time() + 1
    while not fake.closed and time.time() < deadline:
        time.sleep(0.01)
    assert fake.closed


def test_serial_error_propagates():
    fake = FakeSerial([b"A=045 D=0623 L=1\r\n"], error=OSError("device gone"))
    src = SerialSource("COM9", opener=lambda port, baud: fake)

    async def go():
        got = []
        with pytest.raises(OSError, match="device gone"):
            async for item in src.lines():
                got.append(item)
        return got
    assert len(asyncio.run(asyncio.wait_for(go(), 3))) == 1


def test_serial_open_failure():
    def opener(port, baud):
        raise PermissionError("could not open port 'COM9'")
    src = SerialSource("COM9", opener=opener)

    async def go():
        async for _ in src.lines():
            pass
    with pytest.raises(PermissionError):
        asyncio.run(asyncio.wait_for(go(), 3))


def make_recording(tmp_path, mode, seconds, **kw):
    sim = Simulator(mode=mode, seed=5, **kw)
    rec = Recorder(tmp_path)
    rec.start("fixture")
    lines = []
    while True:
        t, line = sim.next()
        if t > seconds:
            break
        rec.write(1_700_000_000 + t, line.rstrip("\r\n"))
        lines.append((t, line))
    rec.stop()
    return rec.path, lines


def test_recorder_never_overwrites(tmp_path):
    rec = Recorder(tmp_path)
    paths = []
    for _ in range(3):              # 同一秒内连录三次
        paths.append(rec.start("x"))
        rec.write(1.0, "A=000 D=0500 L=2")
        rec.stop()
    assert len(set(paths)) == 3 and all(p.exists() for p in paths)


def test_recorder_roundtrip_and_listing(tmp_path):
    path, lines = make_recording(tmp_path, STEP, 20, corrupt=0.2)
    rows = read_recording(path)
    assert [r for _, r in rows] == [line.rstrip("\r\n") for _, line in lines]
    (info,) = list_recordings(tmp_path)
    assert info["name"] == path.name and info["lines"] == len(lines)
    assert abs(info["duration"] - (lines[-1][0] - lines[0][0])) < 0.01


def test_replay_fast_gives_same_inference_as_live(tmp_path):
    # 录一段：CONT 跑一会儿 → 按键切换 → 断电重开
    sim = Simulator(mode=CONT, seed=2, dropout=0.0)
    rec = Recorder(tmp_path)
    rec.start()
    live = RadarModel()
    live_events = []

    def step_until(t_end):
        while True:
            t, line = sim.next()
            rec.write(t, line.rstrip("\r\n"))
            live_events.extend(m for m in live.feed(t, line) if m["type"] == "event")
            if t >= t_end:
                return t
    t = step_until(5)
    sim.switch_mode(t + 0.3)
    t = step_until(t + 9)
    sim.power_cycle(t + 0.1)
    step_until(t + 10)
    rec.stop()

    src = ReplaySource(rec.path, speed=40)
    replay = RadarModel()

    async def go():
        evs = []
        async for t, line in src.lines():
            evs.extend(m for m in replay.feed(t, line) if m["type"] == "event")
        return evs
    started = time.time()
    replay_events = asyncio.run(asyncio.wait_for(go(), 10))
    assert time.time() - started < 2          # 约 25s 的数据 40 倍速放完
    strip = lambda evs: [(e["kind"], e.get("reason"), e.get("mode")) for e in evs]
    assert strip(replay_events) == strip(live_events)
    assert [e["reason"] for e in replay_events if e["kind"] == "restart"] == ["start", "switch", "power"]
    assert replay.mode == STEP


def test_server_replay_and_record_flow(tmp_path):
    path, _ = make_recording(tmp_path, CONT, 3, dropout=0.0)

    async def go():
        client = TestClient(TestServer(make_app(recordings_dir=tmp_path)))
        await client.start_server()
        try:
            ws = await client.ws_connect("/ws")
            first = [await ws.receive_json() for _ in range(4)]
            assert [m["type"] for m in first] == ["source", "lists", "snapshot", "calib"]
            assert first[1]["recordings"][0]["name"] == path.name

            await ws.send_json({"cmd": "record", "on": True})     # 没有数据源：拒绝
            assert (await ws.receive_json())["type"] == "error"

            await ws.send_json({"cmd": "connect", "source": "replay", "file": "../" + path.name, "speed": 20})
            seen = []
            while True:
                m = await asyncio.wait_for(ws.receive_json(), 3)
                seen.append(m)
                if m["type"] == "source" and m["name"] is None:
                    break
            types = [m["type"] for m in seen]
            assert types[0] == "source" and seen[0]["name"] == "replay"
            assert types.count("meas") >= 25
            assert any(m["type"] == "notice" and "结束" in m["msg"] for m in seen)

            await ws.send_json({"cmd": "connect", "source": "sim", "mode": STEP})
            await ws.send_json({"cmd": "record", "on": True})
            await ws.send_json({"cmd": "disconnect"})
            notices = []
            while len(notices) < 2:
                m = await asyncio.wait_for(ws.receive_json(), 3)
                if m["type"] == "notice":
                    notices.append(m["msg"])
            assert "开始录制" in notices[0] and "录制已保存" in notices[1]
            assert len(list(tmp_path.glob("rec_*_sim.csv"))) == 1
            await ws.close()
        finally:
            await client.close()

    asyncio.run(go())
