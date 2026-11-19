"""数据源：统一接口

    async lines()  异步产出 (t, 一行文本)，t 是该源的时间（秒）
    now()          该源的"当前时间"，与 t 同一时基（模型的超时判断、前端的点龄都按它算）
    speed          时间流速（回放可以快放；其他源恒为 1）
    name / detail  给前端显示
"""
from __future__ import annotations

import asyncio
import csv
import re
import sys
import threading
import time
from collections.abc import AsyncIterator, Callable
from pathlib import Path

from .parser import LineAssembler
from .sim import Simulator


class SimSource:
    name = "sim"
    detail = "模拟器"
    speed = 1.0

    def __init__(self, sim: Simulator | None = None):
        self.sim = sim or Simulator()
        self._t0 = time.time()
        self._wake: asyncio.Event | None = None

    def now(self) -> float:
        return time.time()

    async def lines(self) -> AsyncIterator[tuple[float, str]]:
        self._wake = asyncio.Event()
        while True:
            # 在 yield 处挂起期间发生的切换已经作用到 sim 上了，先清掉标志再算下一行
            self._wake.clear()
            t, line = self.sim.next()
            delay = self._t0 + t - time.time()
            try:
                # 等待期间若切换了模式 / 断电，这一行作废，按新状态重新算下一行
                await asyncio.wait_for(self._wake.wait(), max(delay, 0))
                continue
            except TimeoutError:
                pass
            yield self._t0 + t, line

    def switch_mode(self) -> None:
        self.sim.switch_mode(time.time() - self._t0)
        self._poke()

    def power_cycle(self, off_s: float = 1.0) -> None:
        self.sim.power_cycle(time.time() - self._t0, off_s)
        self._poke()

    def _poke(self) -> None:
        if self._wake:
            self._wake.set()


# ---------------------------------------------------------------- 串口

class SerialSource:
    """真串口（HC-06 蓝牙 SPP 或 USB 转 RS232），9600 8N1。

    pyserial 是阻塞读，放在独立线程里；线程把拼好的行经 call_soon_threadsafe 送进 asyncio 队列。
    蓝牙 COM 口在 open 时才去连 HC-06，可能要好几秒，也在线程里做。
    """
    name = "serial"
    speed = 1.0

    def __init__(self, port: str, baud: int = 9600, opener: Callable | None = None):
        self.port = port
        self.baud = baud
        self.detail = f"串口 {port}"
        self._opener = opener       # 测试时注入假串口；默认 serial.serial_for_url

    def now(self) -> float:
        return time.time()

    async def lines(self) -> AsyncIterator[tuple[float, str]]:
        loop = asyncio.get_running_loop()
        queue: asyncio.Queue = asyncio.Queue()
        stop = threading.Event()

        def put(item) -> None:
            try:
                loop.call_soon_threadsafe(queue.put_nowait, item)
            except RuntimeError:    # 事件循环已关闭
                pass

        def worker() -> None:
            try:
                if self._opener:
                    ser = self._opener(self.port, self.baud)
                else:
                    import serial
                    ser = serial.serial_for_url(self.port, self.baud, timeout=0.2)
                try:
                    asm = LineAssembler()
                    while not stop.is_set():
                        data = ser.read(ser.in_waiting or 1)    # 有数据立即返回，没有最多等 0.2s
                        if data:
                            t = time.time()
                            for line in asm.feed(data):
                                put((t, line))
                finally:
                    ser.close()
            except Exception as e:  # 打不开 / 拔掉：交给 lines() 抛出
                put(e)

        threading.Thread(target=worker, name=f"serial-{self.port}", daemon=True).start()
        try:
            while True:
                item = await queue.get()
                if isinstance(item, Exception):
                    raise item
                yield item
        finally:
            stop.set()


def list_ports() -> list[dict]:
    """可用串口列表：[{device, desc, usable}]，推荐的（HC-05/06）排在前面。

    Windows 上每个蓝牙配对会生成两个 COM 口：传出端口（hwid 里带设备 MAC）才能用来连设备，
    传入端口（MAC 全 0）用不了。pyserial 给的中文描述在 Windows 上常是乱码，这里自己生成。
    """
    from serial.tools import list_ports as lp

    out = []
    for p in lp.comports():
        hwid = p.hwid or ""
        usable = True
        if "BTHENUM" in hwid:
            m = re.search(r"&([0-9A-Fa-f]{12})_", hwid)
            mac = m.group(1).lower() if m else ""
            if not mac or mac == "0" * 12:
                desc, usable = "蓝牙传入端口（不可用）", False
            else:
                desc = f"蓝牙 · {_bt_name(mac) or mac.upper()}"
        else:
            d = p.description or ""
            desc = d if d and "�" not in d else "串口"
        out.append({"device": p.device, "desc": desc, "usable": usable})

    def rank(p):
        hc = bool(re.search(r"HC-0[56]", p["desc"], re.I))
        num = int(re.sub(r"\D", "", p["device"]) or 0)
        return (not p["usable"], not hc, num)
    return sorted(out, key=rank)


def _bt_name(mac: str) -> str | None:
    """从注册表读已配对蓝牙设备的名字（只在 Windows 上有）。"""
    if sys.platform != "win32":
        return None
    try:
        import winreg
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                             "SYSTEM\\CurrentControlSet\\Services\\BTHPORT\\Parameters\\Devices\\" + mac)
        value, _ = winreg.QueryValueEx(key, "Name")
        return bytes(value).rstrip(b"\0").decode("utf-8", "replace") or None
    except OSError:
        return None


# ---------------------------------------------------------------- 回放

class ReplaySource:
    """回放录制文件（recording.py 写的 CSV：t,raw）。

    行与行之间的时间间隔按原样保留（模型靠间隔判断切换 / 重新上电），只是整体可以快放：
    产出的 t 是"回放时钟"，now() 也走回放时钟，所以推断和点龄都和实时一样。
    """
    name = "replay"

    def __init__(self, path: str | Path, speed: float = 1.0):
        self.path = Path(path)
        self.speed = max(0.1, float(speed))
        self.detail = f"回放 {self.path.name}" + (f" · {self.speed:g}×" if self.speed != 1 else "")
        self._wall0 = time.time()

    def now(self) -> float:
        return self._wall0 + (time.time() - self._wall0) * self.speed

    async def lines(self) -> AsyncIterator[tuple[float, str]]:
        rows = read_recording(self.path)
        if not rows:
            return
        self._wall0 = time.time()
        rec0 = rows[0][0]
        for t_rec, raw in rows:
            t = self._wall0 + (t_rec - rec0)
            delay = (t - self.now()) / self.speed
            if delay > 0:
                await asyncio.sleep(delay)
            yield t, raw


def read_recording(path: str | Path) -> list[tuple[float, str]]:
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.reader(f):
            if len(row) != 2 or row[0] == "t":
                continue
            try:
                rows.append((float(row[0]), row[1]))
            except ValueError:
                continue
    return rows
