# radar_viz — 雷达报警系统电脑端

解析 FPGA 串口发来的测量行（`A=045 D=0623 L=1\r\n`，9600 8N1，经 HC-06 蓝牙或 RS232），
推断扫描状态，并在浏览器里实时可视化。

```
数据源(串口 / 回放 / 模拟器) → 解析(parser) → 状态模型(model) → aiohttp + WebSocket → 浏览器
```

## 进度

| 步骤 | 内容 | 状态 |
|---|---|---|
| 1 | `parser` + `model` + 模拟器 + 测试 | ✅ |
| 2 | 后端服务 + 页面骨架 + PPI 主图 + 状态面板 | ✅ |
| 3 | 串口源 + 录制回放 | ✅ 实板 HC-06 → COM7 已收到并录制 |
| 4 | 瀑布图、点云、各角度统计、距离直方图 | ✅ |
| 5 | 入侵检测、接近速度、精度标定 | ✅（精度标定待实板实测） |

## 安装 / 运行 / 测试

```
pip install -r requirements.txt
python tools/radar_viz/run.py              # 在 radar_system 目录下运行；自动打开 http://127.0.0.1:8765/，在顶栏选数据源
python tools/radar_viz/run.py --serial COM7              # 直接打开串口
python tools/radar_viz/run.py --sim CONT                 # 直接接模拟器（STEP / CONT）
python tools/radar_viz/run.py --replay 文件.csv --speed 4 # 直接回放
python -m radar_viz ...                   # 或者在本目录下运行，参数相同
python -m pytest -q
```

页面：PPI 扫描图（STEP 画 45° 扇区、CONT 画 2° 轮廓；虚线环是 200/400/600/800mm 分级边界，量程 1/2/4m 可切）、
当前测量、板上 16 个 LED 和蜂鸣器的镜像（可开声音）、事件列表、最近测量表；下面一排分析图：
- **瀑布图**：横轴角度、每行一个单程（最新在上），颜色 = 距离（单色相，近亮远暗）。移动的物体会留下斜线 / 移动的色块。
- **点云**：最近 1500 个点换算成平面坐标叠加，几圈下来就是房间轮廓；量程跟扫描图一起切。
- **各角度距离**：累计均值 ±σ（σ 大的地方要么有东西在动、要么是物体边缘），最近一次按分级着色；下方细条是无回波率。
- **距离分布**：每 100mm 一格，格子正好落在分级边界上，所以按分级着色；超量程单独一根。

深色单主题：分级色在深色底上校验过
（相邻两级 CVD ΔE ≥ 13.6，正常视觉 ΔE ≥ 18.3），分级同时由半径、点的大小和文字标签表示，不只靠颜色。

## 分析功能

- **入侵检测**：扫描图右上角"记录背景"——**先保证没人在扫描范围里**，扫一两圈后点它。之后某个方向比背景近
  150mm 以上（背景无回波的方向：出现 3m 以内的回波）就判为入侵：顶栏变红、扫描图上画出"比背景近了多少"的
  红色径向条、事件列表记一条；开了"声音"会响三声提示。相距 10° 以内的入侵角度算同一个目标，只报一次。
  背景取每个方向最近 8 次读数里**最近的**距离：物体边缘处读数会在两个值之间跳，取最近值可以避免误报
  （用实板录制数据验证过：同一段数据当背景再放一遍，零误报）。
- **接近速度**：同一角度相邻两次测量的距离变化率（负 = 靠近）。STEP 模式要 8~16 秒才回到同一角度，CONT 是
  0~18 秒，所以只能看出"在慢慢走近"这类趋势；两次距离差超过 1m 的不算（多半是边缘跳变）。
- **精度标定**：对准一个已知距离的目标（墙、书本），填真实距离、角度、次数后"开始采集"。STEP 只取该角度，
  CONT 取 ±4° 内。采 3~5 个不同距离后自动做最小二乘：测量值 = k × 真实值 + b，并给出平均 / 最大误差；
  图上画的是误差（测量 − 真实）±σ，可以"导出 CSV"放进实验报告。

## 接板子（HC-06 蓝牙）

1. Windows 蓝牙设置里先配对 HC-06（配对码一般是 1234），配对后会多出两个 COM 口。
2. 顶栏数据源列表里选 **"COMx · 蓝牙 · HC-06"**（程序会从注册表读设备名，并把它排在最前、默认选中）；
   标着"蓝牙传入端口（不可用）"的是 Windows 给的另一个口，不能用来连设备。
3. 点"连接"。蓝牙串口在打开时才去连 HC-06，要几秒；连不上（约 5 秒后报"信号灯超时"）一般是板子没上电、
   或 HC-06 正被手机等其他设备连着。端口被串口助手占用时会提示"拒绝访问"。
4. 连上后板子 SW7=1 开始扫描，就会收到数据。"录制"把收到的原始行存到 `recordings/`（已加进 .gitignore），
   之后在数据源列表的"回放"里选它，可以 1/2/4/8 倍速重放。

## 模块

- `parser.py`：行解析与校验（格式、角度序列、距离范围、L 与 D 的分级一致性），`LineAssembler` 把串口字节拼成行。
- `model.py`：`RadarModel`。FPGA 不发事件行，模式 / 方向 / 重新开始都由角度序列和时间间隔推断（规则见文件头注释）。
- `sim.py`：按 `scan_engine.v` 的节拍生成测量行；场景是一个带门、柱子、椅子和一个来回走动的人的房间。
- `sources.py`：数据源（模拟器 / 串口 / 回放），异步产出 `(t, 行文本)`；`list_ports()` 生成串口列表。
  串口读在独立线程里做；回放保留原始行间隔、整体按倍速快放，`now()` 走回放时钟，所以推断结果和实时一致。
- `analysis.py`：背景差分（`Baseline`）和精度标定（`Calibration`）。
- `recording.py`：录制成 CSV（`t,raw`，原始行、坏行也存），回放时重新解析。
- `server.py` / `__main__.py`：aiohttp 静态页面 + `/ws`；前端命令见 `server.py` 文件头。
- `static/`：`app.js`（状态与面板）、`ppi.js`（扫描图）、`charts.js`（四张分析图）、`bands.js`（分级常量）、`style.css`。全部手写 Canvas，无第三方前端库，离线可用。
- `tests/data/real_cont_com7.csv`：实板 CONT 录制（10s，108 行），回归测试用。

## 消息格式（后端 → 前端，JSON）

| type | 字段 |
|---|---|
| `meas` | `seq t a d l mode dir pass v intr`；`d=null` 表示超量程；`v` 接近速度 mm/s（可为 null）；`intr` 入侵 `{b, delta}` 或 null |
| `bad` | `t raw reason`：被丢弃的行 |
| `event` | `t kind ...`：`restart`(reason=start/power/switch, mode)、`mode`(mode, prev)、`sweep`(passes, end)、`resync`(prev, angle)、`link`(state=up/idle)、`intrusion`(angle, d, b, delta)、`intrusion_clear`、`baseline`(angles) |
| `status` | `t link rate lines errors mode intruded speed recording` |
| `stats` | `angles{角度: n mean std oor}`、`hist{bin counts oor}`：每秒一次（有新测量时） |
| `snapshot` | `t mode dir pass table stats history log status`（`stats` 同上）：前端连上时的全量状态（`log` = 最近 50 条 event/bad） |
| `source` | `name detail`：当前数据源（sim / serial / replay），`name=null` 表示未连接 |
| `lists` | `ports recordings`：串口列表 `[{device desc usable}]`、录制列表 `[{name lines duration mtime}]` |
| `notice` | `msg`：提示（录制开始 / 保存、回放结束等） |
| `baseline` | `t ref{角度: 距离或 null}`：当前背景（快照里也带） |
| `calib` | `active points fit`：标定进度、各标定点、拟合结果 |
| `error` | `msg` |
