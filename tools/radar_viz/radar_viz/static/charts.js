// 分析图：瀑布图（B-scope）、点云、每角度统计、距离直方图。全部手写 Canvas，与扫描图同一套颜色 token。
//
// 数据：Analysis 收 meas（按单程分行、攒点云）和后端每秒一次的 stats；图在共用的 rAF 循环里按需重画。
import { LEVELS, THRESHOLDS, token, withAlpha } from './bands.js';

const DEG = Math.PI / 180;
const MAX_ROWS = 40;          // 瀑布图保留的单程数
const MAX_CLOUD = 1500;       // 点云保留的点数
const OOR_GRAY = '#8fa39e';

// 距离的顺序色阶（单色相，近 = 亮、远 = 暗）。与 5 个分级色区分开：这里表示连续的距离大小。
const RAMP = ['#cde2fb', '#9ec5f4', '#6da7ec', '#3987e5', '#256abf', '#184f95'];
export const RAMP_CSS = `linear-gradient(90deg, ${RAMP.join(', ')})`;
const MEAN = '#6da7ec';

function hexRgb(h) { const n = parseInt(h.slice(1), 16); return [n >> 16, (n >> 8) & 255, n & 255]; }
const RAMP_RGB = RAMP.map(hexRgb);
function rampColor(d) {
  const t = Math.sqrt(Math.min(d, 4000) / 4000) * (RAMP.length - 1);   // sqrt：近处分辨得更细
  const i = Math.min(RAMP.length - 2, Math.floor(t)), f = t - i;
  const c = RAMP_RGB[i].map((v, k) => Math.round(v + (RAMP_RGB[i + 1][k] - v) * f));
  return `rgb(${c[0]}, ${c[1]}, ${c[2]})`;
}
function bandOf(d) {
  if (d == null || d >= 800) return 0;
  return d >= 600 ? 1 : d >= 400 ? 2 : d >= 200 ? 3 : 4;
}
function niceStep(max, target) {
  const raw = max / target, p = 10 ** Math.floor(Math.log10(raw));
  return [1, 2, 2.5, 5, 10].map((k) => k * p).find((s) => s >= raw);
}
const fmtM = (mm) => (mm >= 1000 ? `${+(mm / 1000).toFixed(1)} m` : `${mm / 10} cm`);
const fmtClock = (t) => new Date(t * 1000).toLocaleTimeString('zh-CN', { hour12: false });

const C = {
  surface: token('--surface'), grid: token('--grid'), grid2: token('--grid-2'),
  text1: token('--text-1'), text2: token('--text-2'), text3: token('--text-3'),
  accent: token('--accent'), mono: token('--mono'),
};

// ------------------------------------------------------------ 数据

export class Analysis {
  constructor() {
    this.passes = [];       // [{t0, mode, pass, cells: Map(角度 → meas)}]，最新在后
    this.cloud = [];        // [{x, y, ...meas}]，最新在后
    this.stats = null;      // 后端 stats 消息
    this.calib = null;      // 后端 calib 消息
    this.table = new Map(); // 每个角度最近一次（由 app 传入 state.table）
    this.cur = null;
    this.charts = [];
    this._newRow = true;
  }

  reset(history) {
    this.passes = []; this.cloud = []; this._newRow = true;
    history.forEach((m) => this.add(m));
    this.touch();
  }

  newRun() { this._newRow = true; }

  add(m) {
    let row = this.passes[this.passes.length - 1];
    if (this._newRow || !row || row.pass !== m.pass) {
      row = { t0: m.t, mode: m.mode, pass: m.pass, cells: new Map() };
      this.passes.push(row);
      if (this.passes.length > MAX_ROWS) this.passes.shift();
      this._newRow = false;
    }
    row.cells.set(m.a, m);
    row.mode = m.mode || row.mode;
    if (m.d != null) {
      this.cloud.push({ x: m.d * Math.cos(m.a * DEG), y: m.d * Math.sin(m.a * DEG), ...m });
      if (this.cloud.length > MAX_CLOUD) this.cloud.splice(0, this.cloud.length - MAX_CLOUD);
    }
    this.cur = m;
    this.touch();
  }

  setStats(s) { this.stats = s; this.touch(); }
  setCalib(c) { this.calib = c; this.touch(); }
  touch() { this.charts.forEach((c) => { c.dirty = true; }); }
}

// ------------------------------------------------------------ 图的公共部分

class CanvasChart {
  constructor(wrap, data) {
    this.wrap = wrap;
    this.cv = wrap.querySelector('canvas');
    this.ctx = this.cv.getContext('2d');
    this.tip = wrap.querySelector('.tip');
    this.data = data;
    this.hover = null;
    this.dirty = true;
    data.charts.push(this);
    new ResizeObserver(() => this.resize()).observe(wrap);
    this.resize();
    this.cv.addEventListener('pointermove', (e) => {
      const r = this.cv.getBoundingClientRect();
      this.hover = { x: e.clientX - r.left, y: e.clientY - r.top };
      this.dirty = true;
    });
    this.cv.addEventListener('pointerleave', () => { this.hover = null; this.tip.hidden = true; this.dirty = true; });
  }

  resize() {
    const dpr = window.devicePixelRatio || 1;
    this.w = this.cv.clientWidth; this.h = this.cv.clientHeight;
    this.cv.width = Math.round(this.w * dpr); this.cv.height = Math.round(this.h * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.dirty = true;
  }

  render() {
    if (!this.dirty || !this.w) return;
    this.dirty = false;
    const { ctx } = this;
    ctx.clearRect(0, 0, this.w, this.h);
    ctx.fillStyle = C.surface;
    ctx.fillRect(0, 0, this.w, this.h);
    const tip = this.draw();
    this.showTip(tip);
  }

  // tip = {x, y, rows: [{value, label, key?: {type:'line'|'dot'|'box', color}}]}；文字一律 textContent
  showTip(tip) {
    if (!tip || !this.hover) { this.tip.hidden = true; return; }
    this.tip.replaceChildren(...tip.rows.map((r) => {
      const row = document.createElement('div');
      row.className = 'tr';
      if (r.key) {
        const k = document.createElement('i');
        k.className = `k-${r.key.type}`;
        k.style.background = r.key.color;
        row.append(k);
      }
      const v = document.createElement('b'); v.textContent = r.value;
      const l = document.createElement('span'); l.textContent = r.label;
      row.append(v, l);
      return row;
    }));
    this.tip.hidden = false;
    const tw = this.tip.offsetWidth, th = this.tip.offsetHeight;
    let x = tip.x + 14, y = tip.y - th - 10;
    if (x + tw > this.w) x = tip.x - tw - 14;
    if (y < 0) y = tip.y + 14;
    this.tip.style.left = `${Math.max(0, x)}px`;
    this.tip.style.top = `${y}px`;
  }

  text(str, x, y, { align = 'left', base = 'middle', color = C.text3, size = 11, font = C.mono } = {}) {
    const { ctx } = this;
    ctx.fillStyle = color; ctx.font = `${size}px ${font}`;
    ctx.textAlign = align; ctx.textBaseline = base;
    ctx.fillText(str, x, y);
  }

  hline(x0, x1, y, color = C.grid) {
    const { ctx } = this;
    ctx.strokeStyle = color; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(x0, Math.round(y) + 0.5); ctx.lineTo(x1, Math.round(y) + 0.5); ctx.stroke();
  }

  vline(x, y0, y1, color = C.grid) {
    const { ctx } = this;
    ctx.strokeStyle = color; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(Math.round(x) + 0.5, y0); ctx.lineTo(Math.round(x) + 0.5, y1); ctx.stroke();
  }

  // 角度横轴：0/45/90/135/180
  angleAxis(X, y, y0) {
    for (let a = 0; a <= 180; a += 45) {
      if (y0 != null) this.vline(X(a), y0, y, C.grid);
      this.text(`${a}°`, X(a), y + 11, { align: a === 0 ? 'left' : a === 180 ? 'right' : 'center' });
    }
  }
}

// ------------------------------------------------------------ 瀑布图（B-scope）
// 横轴角度、纵轴时间（每行一个单程，最新在上），颜色 = 距离。移动的物体会留下斜线。

export class Waterfall extends CanvasChart {
  draw() {
    const { ctx, w, h } = this;
    const L = 64, R = 8, T = 6, B = 22;
    const pw = w - L - R, ph = h - T - B;
    const rows = this.data.passes.slice(-MAX_ROWS).reverse();     // rows[0] = 最新
    const rh = ph / Math.max(12, rows.length);           // 行少时先粗一些，满 40 行后固定
    const X = (a) => L + (a / 180) * pw;
    this.angleAxis(X, h - B + 2, T);

    if (!rows.length) {
      this.text('等待数据…', L + pw / 2, T + ph / 2, { align: 'center', font: token('--font'), size: 13 });
      return null;
    }
    let hit = null;
    rows.forEach((row, i) => {
      const y = T + i * rh;
      const half = row.mode === 'STEP' ? 22.5 : 1;
      for (const m of row.cells.values()) {
        const x0 = Math.round(X(Math.max(0, m.a - half))), x1 = Math.round(X(Math.min(180, m.a + half)));
        ctx.fillStyle = m.d == null ? withAlpha(OOR_GRAY, 0.10) : rampColor(m.d);
        ctx.fillRect(x0, y, Math.max(1, x1 - x0), Math.max(1, rh - 1));
        const hv = this.hover;
        if (hv && hv.y >= y && hv.y < y + rh && hv.x >= x0 && hv.x < x1) hit = { m, row, x0, x1, y };
      }
      if (i % 5 === 0) this.text(fmtClock(row.t0), L - 8, y + rh / 2, { align: 'right', size: 10 });
    });

    // 当前位置：最新一行上的当前格加描边
    const cur = this.data.cur;
    if (cur && rows[0].cells.get(cur.a) === cur) {
      const half = rows[0].mode === 'STEP' ? 22.5 : 1;
      ctx.strokeStyle = C.accent; ctx.lineWidth = 2;
      ctx.strokeRect(X(Math.max(0, cur.a - half)) - 1, T - 1, X(Math.min(180, cur.a + half)) - X(Math.max(0, cur.a - half)) + 2, rh + 1);
    }
    if (!hit) return null;
    ctx.strokeStyle = C.text1; ctx.lineWidth = 1.5;
    ctx.strokeRect(hit.x0, hit.y, hit.x1 - hit.x0, rh - 1);
    const { m } = hit;
    return {
      x: this.hover.x, y: this.hover.y, rows: [
        { value: m.d == null ? '无回波' : `${m.d} mm`, label: `${m.a}°`, key: { type: 'box', color: m.d == null ? OOR_GRAY : rampColor(m.d) } },
        { value: `L${m.l} ${LEVELS[m.l].name}`, label: `${fmtClock(m.t)} · ${m.mode ?? ''}` },
      ],
    };
  }
}

// ------------------------------------------------------------ 点云
// 最近 MAX_CLOUD 个有效点换算成平面坐标叠在一起：几圈下来就是房间的轮廓。越新越亮。

export class Cloud extends CanvasChart {
  constructor(wrap, data, getRange) { super(wrap, data); this.getRange = getRange; }

  draw() {
    const { ctx, w, h } = this;
    const L = 34, R = 10, T = 10, B = 22;
    const range = this.getRange();
    const s = Math.min((w - L - R) / (2 * range), (h - T - B) / range);
    const ox = L + (w - L - R) / 2, oy = h - B;
    const P = (x, y) => [ox + x * s, oy - y * s];

    const step = niceStep(range, 4);
    for (let v = step; v <= range + 1; v += step) {
      const [, y] = P(0, v);
      this.hline(ox - range * s, ox + range * s, y);
      this.text(fmtM(v), L - 6, y, { align: 'right', size: 10 });
    }
    for (let v = -range; v <= range + 1; v += step) {
      const [x] = P(v, 0);
      this.vline(x, oy - range * s, oy);
      this.text(v === 0 ? '0' : fmtM(Math.abs(v)), x, oy + 11, { align: 'center', size: 10 });
    }
    ctx.strokeStyle = C.grid2; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.arc(ox, oy, range * s, Math.PI, 2 * Math.PI); ctx.stroke();
    this.hline(ox - range * s, ox + range * s, oy, C.grid2);

    const pts = this.data.cloud;
    const n = pts.length;
    let best = null, bestD = 12 * 12;
    const lastRow = this.data.passes[this.data.passes.length - 1];
    pts.forEach((p, i) => {
      if (p.d > range) return;
      const [x, y] = P(p.x, p.y);
      const k = n > 1 ? i / (n - 1) : 1;
      ctx.fillStyle = withAlpha(C.accent, 0.10 + 0.75 * k * k);
      ctx.beginPath(); ctx.arc(x, y, 2, 0, 2 * Math.PI); ctx.fill();
      if (this.hover) {
        const d = (x - this.hover.x) ** 2 + (y - this.hover.y) ** 2;
        if (d < bestD) { bestD = d; best = { p, x, y }; }
      }
    });
    // 本单程的点：大一号、带底色描边
    if (lastRow) {
      for (const m of lastRow.cells.values()) {
        if (m.d == null || m.d > range) continue;
        const [x, y] = P(m.d * Math.cos(m.a * DEG), m.d * Math.sin(m.a * DEG));
        ctx.beginPath(); ctx.arc(x, y, 4, 0, 2 * Math.PI);
        ctx.fillStyle = C.accent; ctx.fill();
        ctx.strokeStyle = C.surface; ctx.lineWidth = 2; ctx.stroke();
      }
    }
    ctx.fillStyle = C.text2;
    ctx.beginPath(); ctx.arc(ox, oy, 3, 0, 2 * Math.PI); ctx.fill();

    if (!n) this.text('等待数据…', ox, oy - range * s / 2, { align: 'center', font: token('--font'), size: 13 });
    if (!best) return null;
    ctx.strokeStyle = C.text1; ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.arc(best.x, best.y, 6, 0, 2 * Math.PI); ctx.stroke();
    const { p } = best;
    return {
      x: best.x, y: best.y, rows: [
        { value: `${p.d} mm`, label: `${p.a}° · ${fmtClock(p.t)}`, key: { type: 'dot', color: C.accent } },
        { value: `x ${Math.round(p.x)}  y ${Math.round(p.y)}`, label: 'mm' },
      ],
    };
  }
}

// ------------------------------------------------------------ 每角度统计
// 均值折线 + ±σ 带（累计），最近一次的点按分级着色；下方细条是无回波率（单独一行，不做双纵轴）。

export class AngleStats extends CanvasChart {
  draw() {
    const { ctx, w, h } = this;
    const L = 52, R = 10, T = 10, STRIP = 14, B = 22 + STRIP + 12;
    const pw = w - L - R, ph = h - T - B;
    const X = (a) => L + (a / 180) * pw;
    const angles = this.data.stats ? this.data.stats.angles : {};
    const list = Object.entries(angles).map(([a, s]) => ({ a: +a, ...s })).sort((p, q) => p.a - q.a);
    const valid = list.filter((s) => s.n > 0);

    const top = Math.max(1000, ...valid.map((s) => s.mean + s.std));
    const ystep = niceStep(Math.min(top, 4000), 4);
    const ymax = Math.min(4000, Math.ceil(top / ystep) * ystep);
    const Y = (d) => T + ph - (Math.min(d, ymax) / ymax) * ph;

    for (let v = 0; v <= ymax; v += ystep) {
      this.hline(L, L + pw, Y(v), v === 0 ? C.grid2 : C.grid);
      this.text(v === 0 ? '0' : fmtM(v), L - 6, Y(v), { align: 'right', size: 10 });
    }
    THRESHOLDS.forEach((mm, i) => { if (mm < ymax) this.hline(L, L + pw, Y(mm), withAlpha(LEVELS[i + 1].color, 0.3)); });
    this.angleAxis(X, h - 22 + 2, null);

    // 无回波率细条
    const sy = T + ph + 8;
    this.hline(L, L + pw, sy + STRIP, C.grid);
    this.text('无回波', L - 6, sy + STRIP / 2, { align: 'right', size: 10 });
    const cellW = list.length > 12 ? Math.max(1.5, (2 / 180) * pw - 1) : Math.min(24, (45 / 180) * pw - 2);
    for (const s of list) {
      const rate = s.oor / (s.n + s.oor);
      if (!rate) continue;
      ctx.fillStyle = withAlpha(OOR_GRAY, 0.75);
      ctx.fillRect(X(s.a) - cellW / 2, sy + STRIP * (1 - rate), cellW, STRIP * rate);
    }

    if (!valid.length) {
      this.text('等待数据…', L + pw / 2, T + ph / 2, { align: 'center', font: token('--font'), size: 13 });
      return null;
    }

    // ±σ 带与均值线：相邻角度间隔超过该模式步长时断开
    const runs = [];
    const gapMax = valid.length > 12 ? 4 : 45;
    valid.forEach((s, i) => {
      if (i === 0 || s.a - valid[i - 1].a > gapMax) runs.push([]);
      runs[runs.length - 1].push(s);
    });
    for (const run of runs) {
      ctx.beginPath();
      run.forEach((s, i) => (i ? ctx.lineTo : ctx.moveTo).call(ctx, X(s.a), Y(s.mean + s.std)));
      [...run].reverse().forEach((s) => ctx.lineTo(X(s.a), Y(Math.max(0, s.mean - s.std))));
      ctx.closePath();
      ctx.fillStyle = withAlpha(MEAN, 0.16); ctx.fill();
      ctx.beginPath();
      run.forEach((s, i) => (i ? ctx.lineTo : ctx.moveTo).call(ctx, X(s.a), Y(s.mean)));
      ctx.strokeStyle = MEAN; ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
      ctx.stroke();
    }
    // 最近一次
    const dotR = valid.length > 12 ? 2.5 : 4;
    for (const [a, e] of this.data.table) {
      if (e.d == null) continue;
      ctx.beginPath(); ctx.arc(X(a), Y(e.d), dotR, 0, 2 * Math.PI);
      ctx.fillStyle = LEVELS[e.l].color; ctx.fill();
      ctx.strokeStyle = C.surface; ctx.lineWidth = 2; ctx.stroke();
    }

    // 十字线：吸附到最近的有数据的角度
    if (!this.hover || this.hover.x < L || this.hover.x > L + pw) return null;
    const ha = ((this.hover.x - L) / pw) * 180;
    const s = list.reduce((b, c) => (Math.abs(c.a - ha) < Math.abs(b.a - ha) ? c : b));
    this.vline(X(s.a), T, sy + STRIP, C.text3);
    const latest = this.data.table.get(s.a);
    const rows = [];
    if (s.n) {
      rows.push({ value: `${Math.round(s.mean)} mm`, label: `均值 · ${s.a}°`, key: { type: 'line', color: MEAN } });
      rows.push({ value: `±${Math.round(s.std)} mm`, label: `标准差（${s.n} 次）` });
    } else {
      rows.push({ value: `${s.a}°`, label: '没有有效距离' });
    }
    if (latest) {
      rows.push({
        value: latest.d == null ? '无回波' : `${latest.d} mm`, label: '最近一次',
        key: latest.d == null ? undefined : { type: 'dot', color: LEVELS[latest.l].color },
      });
    }
    rows.push({ value: `${Math.round((100 * s.oor) / (s.n + s.oor))}%`, label: '无回波率' });
    return { x: X(s.a), y: this.hover.y, rows };
  }
}

// ------------------------------------------------------------ 距离直方图
// 每 100mm 一格（0~4m），分格正好落在分级边界上，所以每根柱子按所属分级着色；超量程单独一根。

export class Histogram extends CanvasChart {
  draw() {
    const { ctx, w, h } = this;
    const L = 40, R = 8, T = 10, B = 22;
    const pw = w - L - R, ph = h - T - B;
    const hist = this.data.stats ? this.data.stats.hist : null;
    if (!hist || !(hist.counts.some(Boolean) || hist.oor)) {
      this.text('等待数据…', L + pw / 2, T + ph / 2, { align: 'center', font: token('--font'), size: 13 });
      return null;
    }
    const counts = hist.counts, slots = counts.length + 2;         // 40 格 + 空一格 + 超量程
    const total = counts.reduce((a, b) => a + b, 0) + hist.oor;
    const max = Math.max(...counts, hist.oor);
    const ystep = niceStep(max, 3), ymax = Math.ceil(max / ystep) * ystep;
    const Y = (v) => T + ph - (v / ymax) * ph;
    for (let v = 0; v <= ymax; v += ystep) {
      this.hline(L, L + pw, Y(v), v === 0 ? C.grid2 : C.grid);
      this.text(String(v), L - 6, Y(v), { align: 'right', size: 10 });
    }
    const slotW = pw / slots, barW = Math.max(1, Math.min(24, slotW - 2));
    const SX = (i) => L + i * slotW + (slotW - barW) / 2;
    for (let m = 0; m <= 3; m++) this.text(`${m} m`, L + (m * 10) * slotW, h - B + 13, { align: m === 0 ? 'left' : 'center', size: 10 });
    this.text('无回波', L + pw, h - B + 13, { align: 'right', size: 10 });

    const bars = counts.map((c, i) => ({ c, i, lo: i * hist.bin, color: LEVELS[bandOf(i * hist.bin)].color }));
    bars.push({ c: hist.oor, i: slots - 1, lo: null, color: OOR_GRAY });
    let hit = null;
    for (const b of bars) {
      const x = SX(b.i);
      if (this.hover && this.hover.x >= L + b.i * slotW && this.hover.x < L + (b.i + 1) * slotW && this.hover.y > T && this.hover.y < T + ph) hit = b;
      if (!b.c) continue;
      const y = Y(b.c), bh = T + ph - y;
      const r = Math.min(4, barW / 2, bh);
      ctx.fillStyle = hit === b ? withAlpha(b.color, 1) : withAlpha(b.color, 0.85);
      ctx.beginPath();
      ctx.moveTo(x, T + ph); ctx.lineTo(x, y + r);
      ctx.arcTo(x, y, x + r, y, r); ctx.lineTo(x + barW - r, y);
      ctx.arcTo(x + barW, y, x + barW, y + r, r); ctx.lineTo(x + barW, T + ph);
      ctx.closePath(); ctx.fill();
    }
    if (!hit) return null;
    const lv = hit.lo == null ? null : LEVELS[bandOf(hit.lo)];
    return {
      x: SX(hit.i) + barW / 2, y: this.hover.y, rows: [
        { value: `${hit.c} 次`, label: `${total ? Math.round((100 * hit.c) / total) : 0}%`, key: { type: 'box', color: hit.color } },
        { value: hit.lo == null ? '超量程 / 无回波' : `${hit.lo}–${hit.lo + hist.bin} mm`, label: lv ? lv.name : '' },
      ],
    };
  }
}

// ------------------------------------------------------------ 精度标定
// 横轴真实距离、纵轴误差（测量均值 − 真实），竖线 ±σ；拟合直线换算成误差 = (k−1)·x + b 画出来。
// 画误差而不是"测量对真实"：误差只有几 mm，放在 0~2m 的对角线图上根本看不出来。

export class CalibChart extends CanvasChart {
  draw() {
    const { ctx, w, h } = this;
    const L = 52, R = 12, T = 10, B = 24;
    const pw = w - L - R, ph = h - T - B;
    const cal = this.data.calib;
    const pts = cal ? cal.points : [];
    const fit = cal ? cal.fit : null;

    const xmaxRaw = Math.max(1000, ...pts.map((p) => p.true * 1.15));
    const xstep = niceStep(xmaxRaw, 5), xmax = Math.ceil(xmaxRaw / xstep) * xstep;
    const emax0 = Math.max(20, ...pts.map((p) => Math.abs(p.err) + p.std));
    const estep = niceStep(emax0, 2), emax = Math.ceil(emax0 / estep) * estep;
    const X = (v) => L + (v / xmax) * pw;
    const Y = (e) => T + ph / 2 - (e / emax) * (ph / 2);

    for (let e = -emax; e <= emax + 1e-9; e += estep) {
      this.hline(L, L + pw, Y(e), Math.abs(e) < 1e-9 ? C.grid2 : C.grid);
      this.text(`${e > 0 ? '+' : ''}${+e.toFixed(1)}`, L - 6, Y(e), { align: 'right', size: 10 });
    }
    for (let v = 0; v <= xmax + 1e-9; v += xstep) {
      this.vline(X(v), T, T + ph, C.grid);
      this.text(fmtM(v) === '0 cm' ? '0' : fmtM(v), X(v), h - B + 13, { align: v === 0 ? 'left' : 'center', size: 10 });
    }

    if (!pts.length) {
      this.text('还没有标定点', L + pw / 2, T + ph / 2 - 18, { align: 'center', font: token('--font'), size: 13 });
      return null;
    }
    if (fit) {
      ctx.save();
      ctx.beginPath(); ctx.rect(L, T, pw, ph); ctx.clip();
      ctx.strokeStyle = C.accent; ctx.lineWidth = 2; ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(X(0), Y(fit.b));
      ctx.lineTo(X(xmax), Y((fit.k - 1) * xmax + fit.b));
      ctx.stroke();
      ctx.restore();
    }
    let best = null, bestD = 24 * 24;
    for (const p of pts) {
      const x = X(p.true), y = Y(p.err);
      ctx.strokeStyle = MEAN; ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.moveTo(x, Y(p.err - p.std)); ctx.lineTo(x, Y(p.err + p.std)); ctx.stroke();
      ctx.beginPath(); ctx.arc(x, y, 4.5, 0, 2 * Math.PI);
      ctx.fillStyle = MEAN; ctx.fill();
      ctx.strokeStyle = C.surface; ctx.lineWidth = 2; ctx.stroke();
      if (this.hover) {
        const d = (x - this.hover.x) ** 2 + (y - this.hover.y) ** 2;
        if (d < bestD) { bestD = d; best = { p, x, y }; }
      }
    }
    if (!best) return null;
    const { p } = best;
    return {
      x: best.x, y: best.y, rows: [
        { value: `${p.err > 0 ? '+' : ''}${p.err} mm`, label: `误差 · 真实 ${p.true} mm`, key: { type: 'dot', color: MEAN } },
        { value: `${p.mean} ± ${p.std} mm`, label: `均值 ± σ（${p.n} 次，${p.min}~${p.max}）` },
      ],
    };
  }
}

export function startRendering(analysis) {
  const loop = () => { analysis.charts.forEach((c) => c.render()); requestAnimationFrame(loop); };
  requestAnimationFrame(loop);
}
