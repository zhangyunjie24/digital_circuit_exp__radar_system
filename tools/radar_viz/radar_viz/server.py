"""aiohttp 服务：提供静态页面，并通过 WebSocket 把模型消息实时推给浏览器。

前端 → 后端的命令（JSON，字段 cmd）：
    {"cmd": "list"}                                         刷新串口 / 录制文件列表
    {"cmd": "connect", "source": "sim", "mode": "STEP"|"CONT"}
    {"cmd": "connect", "source": "serial", "port": "COM7"}
    {"cmd": "connect", "source": "replay", "file": "rec_xxx.csv", "speed": 4}
    {"cmd": "disconnect"}
    {"cmd": "record", "on": true|false}                     录制当前数据源收到的原始行
    {"cmd": "sim", "action": "switch"|"power"}              只对模拟器有效
    {"cmd": "reset"}                                        清空模型（统计、历史）
    {"cmd": "baseline", "action": "capture"|"clear"}        入侵检测的背景
    {"cmd": "calib", "action": "start", "true_mm": 500, "angle": 90, "count": 10}
    {"cmd": "calib", "action": "cancel"|"clear"} / {"cmd": "calib", "action": "delete", "index": 0}
后端 → 前端：model.py 产生的 meas / bad / event / status / stats / snapshot，另加
    {"type": "source", "name": "sim"|"serial"|"replay"|null, "detail": ...}
    {"type": "lists", "ports": [...], "recordings": [...]}
    {"type": "notice", "msg": ...} / {"type": "error", "msg": ...}
    {"type": "calib", "active": {...}|null, "points": [...], "fit": {...}|null}   标定状态（analysis.py）
status 消息在模型的字段之外再带 speed（时钟流速）和 recording（{file, lines} 或 null）。
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from pathlib import Path

from aiohttp import WSMsgType, web

from .analysis import Calibration
from .model import CONT, STEP, RadarModel
from .recording import RECORDINGS_DIR, Recorder, list_recordings
from .sim import Simulator
from .sources import ReplaySource, SerialSource, SimSource, list_ports

STATIC = Path(__file__).parent / "static"
log = logging.getLogger("radar_viz")


def explain(e: Exception) -> str:
    """把常见的串口异常翻译成能照着处理的提示。"""
    text = str(e)
    if "PermissionError" in text or "拒绝访问" in text or "Access is denied" in text:
        return f"{text}\n→ 端口被占用：关掉串口助手等其他占用该口的程序"
    if "FileNotFoundError" in text or "系统找不到" in text:
        return f"{text}\n→ 端口不存在：点 ↻ 刷新列表"
    if "信号灯超时" in text or "semaphore" in text.lower() or "WinError 121" in text:
        return f"{text}\n→ 连不上蓝牙设备：确认板子已上电、HC-06 指示灯在闪，且没有被手机等其他设备连着"
    return text


class Hub:
    """持有模型、当前数据源、录制器和所有前端连接。"""

    def __init__(self, recordings_dir: Path = RECORDINGS_DIR):
        self.model = RadarModel()
        self.recorder = Recorder(recordings_dir)
        self.calib = Calibration()              # 换数据源也保留：标定可能要跨几次连接做完
        self.recordings_dir = recordings_dir
        self.clients: set[web.WebSocketResponse] = set()
        self.source = None
        self._task: asyncio.Task | None = None

    def now(self) -> float:
        return self.source.now() if self.source else time.time()

    def status(self) -> dict:
        s = self.model.status(self.now())
        s["speed"] = self.source.speed if self.source else 1.0
        s["recording"] = self.recorder.status()
        return s

    def snapshot(self) -> dict:
        snap = self.model.snapshot(self.now())
        snap["status"] = self.status()
        return snap

    def lists(self) -> dict:
        try:
            ports = list_ports()
        except Exception as e:      # pyserial 枚举失败不该影响其他功能
            log.warning("list_ports failed: %s", e)
            ports = []
        return {"type": "lists", "ports": ports, "recordings": list_recordings(self.recordings_dir)}

    # ---- 数据源 ----

    async def connect(self, source) -> None:
        await self.disconnect(announce=False)
        self.model.reset()
        self.source = source
        self._task = asyncio.create_task(self._pump(source))
        await self.broadcast(self._source_msg())
        await self.broadcast(self.snapshot())

    async def disconnect(self, announce: bool = True) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._task = None
        await self._ended(announce)

    async def _ended(self, announce: bool) -> None:
        self.source = None
        if self.recorder.active:
            name = self.recorder.path.name
            self.recorder.stop()
            if announce:
                await self.broadcast({"type": "notice", "msg": f"录制已保存：{name}"})
                await self.broadcast(self.lists())
        if announce:
            await self.broadcast(self._source_msg())
            await self.broadcast(self.status())

    async def _pump(self, source) -> None:
        try:
            async for t, line in source.lines():
                self.recorder.write(t, line)
                for msg in self.model.feed(t, line):
                    await self.broadcast(msg)
                    if msg["type"] == "meas" and self.calib.offer(msg):
                        await self.broadcast(self.calib.to_msg())
        except asyncio.CancelledError:
            raise
        except Exception as e:      # 串口打不开 / 被拔掉：报给前端，数据源置空
            log.warning("source failed: %s", e)
            await self.broadcast({"type": "error", "msg": "数据源出错：" + explain(e)})
        else:
            await self.broadcast({"type": "notice", "msg": f"{source.detail} 结束"})
        self._task = None
        await self._ended(announce=True)

    def _source_msg(self) -> dict:
        s = self.source
        return {"type": "source", "name": s.name if s else None, "detail": s.detail if s else None}

    # ---- 推送 ----

    async def broadcast(self, msg: dict) -> None:
        if not self.clients:
            return
        text = json.dumps(msg, ensure_ascii=False)
        for ws in list(self.clients):
            try:
                await ws.send_str(text)
            except (ConnectionResetError, RuntimeError):
                self.clients.discard(ws)

    async def ticker(self) -> None:
        stats_seq = None
        while True:
            await asyncio.sleep(1.0)
            for msg in self.model.tick(self.now()):
                await self.broadcast(msg)
            await self.broadcast(self.status())
            if self.model.seq != stats_seq:         # 有新测量才重发统计（每秒最多一次）
                stats_seq = self.model.seq
                await self.broadcast(self.model.stats_msg())

    # ---- 命令 ----

    async def handle(self, ws: web.WebSocketResponse, req: dict) -> None:
        cmd = req.get("cmd")
        if cmd == "list":
            await ws.send_json(self.lists())
        elif cmd == "connect":
            src = self._make_source(req)
            if isinstance(src, str):
                await ws.send_json({"type": "error", "msg": src})
            else:
                await self.connect(src)
        elif cmd == "disconnect":
            await self.disconnect()
        elif cmd == "record":
            await self._record(ws, bool(req.get("on")))
        elif cmd == "sim":
            if not isinstance(self.source, SimSource):
                await ws.send_json({"type": "error", "msg": "当前数据源不是模拟器"})
            elif req.get("action") == "switch":
                self.source.switch_mode()
            elif req.get("action") == "power":
                self.source.power_cycle()
        elif cmd == "baseline":
            now = self.now()
            if req.get("action") == "capture":
                if not self.model.history:
                    await ws.send_json({"type": "error", "msg": "还没有测量数据，先连上数据源扫一圈"})
                    return
                msgs = self.model.capture_baseline(now)
            else:
                msgs = self.model.clear_baseline(now)
            for m in msgs:
                await self.broadcast(m)
            await self.broadcast({"type": "baseline", **self.model.baseline.to_dict()})
            await self.broadcast(self.status())
        elif cmd == "calib":
            await self._calib(ws, req)
        elif cmd == "reset":
            self.model.reset()
            await self.broadcast(self.snapshot())
        else:
            await ws.send_json({"type": "error", "msg": f"未知命令: {req}"})

    def _make_source(self, req: dict):
        """按命令建数据源；参数不对时返回错误文字。"""
        kind = req.get("source")
        if kind == "sim":
            mode = req.get("mode") if req.get("mode") in (STEP, CONT) else STEP
            return SimSource(Simulator(mode=mode))
        if kind == "serial":
            port = str(req.get("port") or "").strip()
            return SerialSource(port) if port else "没有选择串口"
        if kind == "replay":
            path = self.recordings_dir / Path(str(req.get("file") or "")).name   # 只允许录制目录里的文件
            if not path.is_file():
                return f"找不到录制文件：{path.name}"
            try:
                speed = float(req.get("speed") or 1)
            except (TypeError, ValueError):
                speed = 1.0
            return ReplaySource(path, speed)
        return f"未知数据源：{kind}"

    async def _calib(self, ws, req: dict) -> None:
        action = req.get("action")
        if action == "start":
            try:
                true_mm, angle = int(req["true_mm"]), int(req.get("angle", 90))
                count = int(req.get("count", 10))
            except (KeyError, TypeError, ValueError):
                await ws.send_json({"type": "error", "msg": "标定参数不对：真实距离、角度、次数都要是整数"})
                return
            if not (20 <= true_mm <= 4000 and 0 <= angle <= 180 and 1 <= count <= 200):
                await ws.send_json({"type": "error", "msg": "标定参数超范围：距离 20~4000mm，角度 0~180，次数 1~200"})
                return
            self.calib.start(true_mm, angle, count, self.model.mode)
        elif action == "cancel":
            self.calib.cancel()
        elif action == "delete":
            self.calib.delete(int(req.get("index", -1)))
        elif action == "clear":
            self.calib.clear()
        await self.broadcast(self.calib.to_msg())

    async def _record(self, ws, on: bool) -> None:
        if on:
            if not self.source or isinstance(self.source, ReplaySource):
                await ws.send_json({"type": "error", "msg": "先连接串口或模拟器再录制"})
                return
            tag = self.source.port if isinstance(self.source, SerialSource) else self.source.name
            self.recorder.start(tag)
            await self.broadcast({"type": "notice", "msg": f"开始录制：{self.recorder.path.name}"})
        elif self.recorder.active:
            name = self.recorder.path.name
            self.recorder.stop()
            await self.broadcast({"type": "notice", "msg": f"录制已保存：{name}"})
            await self.broadcast(self.lists())
        await self.broadcast(self.status())


HUB = web.AppKey("hub", Hub)
TICKER = web.AppKey("ticker", asyncio.Task)


async def ws_handler(request: web.Request) -> web.WebSocketResponse:
    hub = request.app[HUB]
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(request)
    hub.clients.add(ws)
    await ws.send_json(hub._source_msg())
    await ws.send_str(json.dumps(hub.lists(), ensure_ascii=False))
    await ws.send_str(json.dumps(hub.snapshot(), ensure_ascii=False))
    await ws.send_json(hub.calib.to_msg())
    try:
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            try:
                req = json.loads(msg.data)
            except json.JSONDecodeError:
                continue
            await hub.handle(ws, req)
    finally:
        hub.clients.discard(ws)
    return ws


async def index(request: web.Request) -> web.FileResponse:
    return web.FileResponse(STATIC / "index.html")


def make_app(initial_source=None, recordings_dir: Path = RECORDINGS_DIR) -> web.Application:
    app = web.Application()
    hub = Hub(recordings_dir)
    app[HUB] = hub

    async def on_startup(app):
        app[TICKER] = asyncio.create_task(hub.ticker())
        if initial_source:
            await hub.connect(initial_source)

    async def on_cleanup(app):
        app[TICKER].cancel()
        await hub.disconnect(announce=False)

    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)
    app.router.add_static("/static", STATIC)
    return app
