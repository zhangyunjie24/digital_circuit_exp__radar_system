"""启动：python -m radar_viz [--sim STEP|CONT | --serial COM7 | --replay 文件 [--speed 4]] [--http-port 8765] [--no-browser]
也可以不带数据源启动，在页面顶栏选择。"""
from __future__ import annotations

import argparse
import logging
import socket
import webbrowser

from aiohttp import web

from .model import CONT, STEP
from .server import make_app
from .sim import Simulator
from .sources import ReplaySource, SerialSource, SimSource


def main() -> None:
    ap = argparse.ArgumentParser(prog="radar_viz", description="雷达报警系统电脑端")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--sim", choices=[STEP, CONT], help="启动后直接接上模拟器")
    src.add_argument("--serial", metavar="PORT", help="启动后直接打开串口，如 COM7")
    src.add_argument("--replay", metavar="FILE", help="启动后直接回放录制文件")
    ap.add_argument("--speed", type=float, default=1.0, help="回放倍速（默认 1）")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--http-port", type=int, default=8765)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("aiohttp.access").setLevel(logging.WARNING)
    source = None
    if args.sim:
        source = SimSource(Simulator(mode=args.sim))
    elif args.serial:
        source = SerialSource(args.serial)
    elif args.replay:
        source = ReplaySource(args.replay, args.speed)

    url = f"http://{args.host}:{args.http_port}/"
    if port_in_use(args.host, args.http_port):
        print(f"端口 {args.http_port} 已被占用：多半是已经开着一个 radar_viz，直接打开 {url} 即可；")
        print(f"要再开一个，请换端口，例如 --http-port {args.http_port + 1}")
        raise SystemExit(1)
    if not args.no_browser:
        webbrowser.open(url)
    print(f"radar_viz 运行在 {url}  （Ctrl+C 退出）")
    web.run_app(make_app(source), host=args.host, port=args.http_port, print=None)


def port_in_use(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex((host, port)) == 0


if __name__ == "__main__":
    main()
