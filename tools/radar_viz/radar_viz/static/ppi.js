// 雷达 PPI（平面位置显示）：半圆扫描图，Canvas 2D 逐帧绘制。
//
// 坐标与点阵 / LCD 一致：传感器在底边中点，0° 指向右，90° 指向正前方（上）。
// 距离分级由半径决定（200/400/600/800 的分级环直接画出来），颜色只是加强，不是唯一线索。
import { LEVELS, THRESHOLDS, token, withAlpha } from './bands.js';

const DEG = Math.PI / 180;
const TRAIL_DEG = 34;          // 扫描线余辉宽度
const PING_MS = 900;           // 新测量点的扩散圈时长
const GRID_STEP = { 1000: 200, 2000: 500, 4000: 1000 };
const INTRUDE = '#f87171';     // 入侵标记（与 5 个分级色区分：靠形状——径向条 + 脉动圈——和事件文字识别）

export function fmtSpeed(v) {
  if (v == null) return '—';
  const s = `${v > 0 ? '+' : ''}${Math.round(v)} mm/s`;
  return Math.abs(v) < 5 ? `${s}（静止）` : `${s}（${v < 0 ? '靠近' : '远离'}）`;
}

export class PPI {
  constructor(canvas, tip, state) {
    this.cv = canvas;
    this.ctx = canvas.getContext('2d');
    this.tip = tip;
    this.state = state;
    this.range = 2000;
    this.disp = 0;             // 屏幕上扫描线的角度（平滑追随实际角度）
    this.hits = [];            // 本帧画出的点，供悬停查找
    this.hoverPos = null;
    this.prevTs = performance.now();
    this.c = {
      surface: token('--surface'), grid: token('--grid'), grid2: token('--grid-2'),
      text2: token('--text-2'), text3: token('--text-3'), accent: token('--accent'),
      mono: token('--mono'),
    };

    new ResizeObserver(() => this.resize()).observe(canvas.parentElement);
    this.resize();
    canvas.addEventListener('pointermove', (e) => {
      const r = canvas.getBoundingClientRect();
      this.hoverPos = { x: e.clientX - r.left, y: e.clientY - r.top };
    });
    canvas.addEventListener('pointerleave', () => { this.hoverPos = null; this.tip.hidden = true; });
    requestAnimationFrame((ts) => this.frame(ts));
  }

  setRange(mm) { this.range = mm; this.onRange?.(); }

  resize() {
    const dpr = window.devicePixelRatio || 1;
    const w = this.cv.clientWidth, h = this.cv.clientHeight;
    this.cv.width = Math.round(w * dpr);
    this.cv.height = Math.round(h * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.w = w; this.h = h;
    const padX = 40, padTop = 30, padBottom = 30;
    this.cx = w / 2;
    this.cy = h - padBottom;
    this.R = Math.max(40, Math.min(w / 2 - padX, this.cy - padTop));
  }

  // 角度（度）+ 半径（px）→ 画布坐标
  pt(a, r) { return [this.cx + r * Math.cos(a * DEG), this.cy - r * Math.sin(a * DEG)]; }
  rOf(mm) { return Math.min(mm, this.range) / this.range * this.R; }

  frame(ts) {
    const dt = Math.min(0.1, (ts - this.prevTs) / 1000);
    this.prevTs = ts;
    const target = this.state.cur ? this.state.cur.a : 0;
    this.disp += (target - this.disp) * (1 - Math.exp(-dt * 7));
    this.draw(ts);
    this.updateTip();
    requestAnimationFrame((t) => this.frame(t));
  }

  draw(ts) {
    const { ctx, w, h } = this;
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = this.c.surface;
    ctx.fillRect(0, 0, w, h);

    this.drawZones();
    this.drawGrid();
    this.drawTrail();
    this.hits = [];
    this.drawBaseline();
    if (this.state.mode === 'STEP') this.drawSectors(); else this.drawContour();
    this.drawIntrusions(ts);
    this.drawPings(ts);
    this.drawSweep();
    this.drawEmpty();
  }

  // 分级区：很淡的底色环 + 分级边界虚线
  drawZones() {
    const { ctx, cx, cy } = this;
    const edges = [this.range, ...THRESHOLDS, 0];       // level 0 在最外
    for (let lv = 0; lv < 5; lv++) {
      const ro = this.rOf(edges[lv]), ri = this.rOf(edges[lv + 1]);
      if (ro <= ri) continue;
      ctx.beginPath();
      ctx.arc(cx, cy, ro, Math.PI, 2 * Math.PI);
      ctx.arc(cx, cy, ri, 2 * Math.PI, Math.PI, true);
      ctx.closePath();
      ctx.fillStyle = withAlpha(LEVELS[lv].color, lv === 0 ? 0.025 : 0.045);
      ctx.fill();
    }
    ctx.save();
    ctx.setLineDash([3, 5]);
    ctx.lineWidth = 1;
    THRESHOLDS.forEach((mm, i) => {
      if (mm >= this.range) return;
      ctx.strokeStyle = withAlpha(LEVELS[i + 1].color, 0.35);
      ctx.beginPath();
      ctx.arc(cx, cy, this.rOf(mm), Math.PI, 2 * Math.PI);
      ctx.stroke();
    });
    ctx.restore();
  }

  drawGrid() {
    const { ctx, cx, cy, R } = this;
    ctx.lineWidth = 1;
    // 方位线：每 15° 一根，45° 的倍数（STEP 的 5 个方向）加重
    for (let a = 0; a <= 180; a += 15) {
      const major = a % 45 === 0;
      ctx.strokeStyle = major ? this.c.grid2 : this.c.grid;
      const [x, y] = this.pt(a, R);
      ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(x, y); ctx.stroke();
      if (major) {
        const [lx, ly] = this.pt(a, R + 16);
        ctx.fillStyle = this.c.text2;
        ctx.font = `12px ${this.c.mono}`;
        ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.fillText(`${a}°`, lx, ly);
      }
    }
    // 距离环
    const step = GRID_STEP[this.range] || this.range / 4;
    ctx.font = `11px ${this.c.mono}`;
    ctx.textBaseline = 'top';
    for (let mm = step; mm <= this.range; mm += step) {
      const r = this.rOf(mm);
      ctx.strokeStyle = mm === this.range ? this.c.grid2 : this.c.grid;
      ctx.beginPath(); ctx.arc(cx, cy, r, Math.PI, 2 * Math.PI); ctx.stroke();
      ctx.fillStyle = this.c.text3;
      ctx.textAlign = 'center';
      const label = mm >= 1000 ? `${mm / 1000} m` : `${mm / 10} cm`;
      ctx.fillText(label, cx + r, cy + 8);
    }
    // 底边
    ctx.strokeStyle = this.c.grid2;
    ctx.beginPath(); ctx.moveTo(cx - R, cy); ctx.lineTo(cx + R, cy); ctx.stroke();
    ctx.fillStyle = this.c.accent;
    ctx.beginPath(); ctx.arc(cx, cy, 3.5, 0, 2 * Math.PI); ctx.fill();
  }

  // 扫描线余辉：沿运动反方向的一串淡出的细扇形
  drawTrail() {
    if (!this.state.cur) return;
    const { ctx, cx, cy, R } = this;
    const dir = this.state.dir || 1;
    const slices = 24, step = TRAIL_DEG / slices;
    for (let i = 0; i < slices; i++) {
      const a1 = this.disp - dir * i * step, a2 = this.disp - dir * (i + 1) * step;
      const lo = Math.max(0, Math.min(a1, a2)), hi = Math.min(180, Math.max(a1, a2));
      if (hi <= lo) continue;
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.arc(cx, cy, R, -hi * DEG, -lo * DEG);
      ctx.closePath();
      ctx.fillStyle = withAlpha(this.c.accent, 0.16 * (1 - i / slices) ** 1.6);
      ctx.fill();
    }
  }

  drawSweep() {
    if (!this.state.cur) return;
    const { ctx, cx, cy, R } = this;
    const [x, y] = this.pt(this.disp, R);
    const g = ctx.createLinearGradient(cx, cy, x, y);
    g.addColorStop(0, withAlpha(this.c.accent, 0.15));
    g.addColorStop(1, withAlpha(this.c.accent, 0.95));
    ctx.save();
    ctx.shadowColor = this.c.accent;
    ctx.shadowBlur = 12;
    ctx.strokeStyle = g;
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(x, y); ctx.stroke();
    ctx.restore();
  }

  // 背景：记录背景时每个方向的距离，画成一圈细虚线（方向多 = 轮廓，少 = 每个方向一小段弧）
  drawBaseline() {
    const ref = this.state.baseline;
    if (!ref || !ref.size) return;
    const { ctx, cx, cy } = this;
    const list = [...ref.entries()].sort((p, q) => p[0] - q[0]);
    ctx.save();
    ctx.strokeStyle = withAlpha('#c9d6d2', 0.45);
    ctx.lineWidth = 1;
    ctx.setLineDash([3, 4]);
    if (list.length > 12) {
      ctx.beginPath();
      let pen = false;
      for (let i = 0; i < list.length; i++) {
        const [a, d] = list[i];
        const prevD = i > 0 ? list[i - 1][1] : null;
        const gap = i > 0 && (a - list[i - 1][0] > 4 || prevD == null || Math.abs(d - prevD) > 250);
        if (d == null || d > this.range) { pen = false; continue; }
        const [x, y] = this.pt(a, this.rOf(d));
        if (!pen || gap) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        pen = true;
      }
      ctx.stroke();
    } else {
      for (const [a, d] of list) {
        if (d == null || d > this.range) continue;
        const lo = Math.max(0, a - 20), hi = Math.min(180, a + 20);
        ctx.beginPath(); ctx.arc(cx, cy, this.rOf(d), -hi * DEG, -lo * DEG); ctx.stroke();
      }
    }
    ctx.restore();
  }

  // 入侵：从测到的距离到背景距离画一条径向粗条（"比背景近了这么多"），再加一个脉动圈
  drawIntrusions(ts) {
    const { ctx } = this;
    const pulse = 0.5 + 0.5 * Math.sin(ts / 180);
    for (const [a, e] of this.state.table) {
      if (!e.intr || e.d == null) continue;
      const r0 = this.rOf(e.d), r1 = e.intr.b == null ? this.R : this.rOf(e.intr.b);
      ctx.save();
      ctx.lineCap = 'round';
      ctx.strokeStyle = withAlpha(INTRUDE, 0.28);
      ctx.lineWidth = 3;
      ctx.beginPath(); ctx.moveTo(...this.pt(a, r0)); ctx.lineTo(...this.pt(a, r1)); ctx.stroke();
      const [x, y] = this.pt(a, r0);
      ctx.strokeStyle = withAlpha(INTRUDE, 0.5 + 0.5 * pulse);
      ctx.lineWidth = 2;
      ctx.beginPath(); ctx.arc(x, y, 7 + 3 * pulse, 0, 2 * Math.PI); ctx.stroke();
      ctx.restore();
    }
  }

  // 越旧越淡：一整圈（STEP 16s / CONT 约 18s）之后降到 35%
  fade(entry) {
    const age = this.state.serverNow() - entry.t;
    const hold = this.state.mode === 'STEP' ? 16 : 18;
    return 1 - 0.65 * Math.min(1, Math.max(0, age) / hold);
  }

  entries() {
    return [...this.state.table.entries()].map(([a, e]) => ({ a: +a, ...e })).sort((p, q) => p.a - q.a);
  }

  // STEP：每个方向一个 ±22.5° 的扇区，弧线画在测得的距离上（对应点阵上的一条角度线）
  drawSectors() {
    const { ctx, cx, cy } = this;
    for (const e of this.entries()) {
      const f = this.fade(e);
      const lo = Math.max(0, e.a - 22.5), hi = Math.min(180, e.a + 22.5);
      if (e.d == null) { this.drawOor(e, f); continue; }
      const color = LEVELS[e.l].color, r = this.rOf(e.d);
      const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, r);
      g.addColorStop(0, withAlpha(color, 0.02));
      g.addColorStop(1, withAlpha(color, 0.20 * f));
      ctx.beginPath(); ctx.moveTo(cx, cy);
      ctx.arc(cx, cy, r, -hi * DEG, -lo * DEG);
      ctx.closePath();
      ctx.fillStyle = g; ctx.fill();

      ctx.save();
      ctx.shadowColor = color; ctx.shadowBlur = 10 * f;
      ctx.strokeStyle = withAlpha(color, f);
      ctx.lineWidth = 3; ctx.lineCap = 'round';
      ctx.beginPath(); ctx.arc(cx, cy, r, -(hi - 1.5) * DEG, -(lo + 1.5) * DEG); ctx.stroke();
      ctx.restore();
      this.drawBlip(e, f, e.d > this.range);
    }
  }

  // CONT：相邻 2° 的点连成轮廓（距离跳变大于 250mm 的不连），再画点
  drawContour() {
    const { ctx } = this;
    const list = this.entries();
    ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    for (let i = 1; i < list.length; i++) {
      const p = list[i - 1], q = list[i];
      if (q.a - p.a !== 2 || p.d == null || q.d == null || Math.abs(p.d - q.d) > 250) continue;
      if (p.d > this.range && q.d > this.range) continue;
      const lv = Math.max(p.l, q.l);
      ctx.strokeStyle = withAlpha(LEVELS[lv].color, 0.55 * Math.min(this.fade(p), this.fade(q)));
      ctx.beginPath();
      ctx.moveTo(...this.pt(p.a, this.rOf(p.d)));
      ctx.lineTo(...this.pt(q.a, this.rOf(q.d)));
      ctx.stroke();
    }
    for (const e of list) {
      const f = this.fade(e);
      if (e.d == null) this.drawOor(e, f); else this.drawBlip(e, f, e.d > this.range);
    }
  }

  // 测量点：分级越高点越大（颜色之外的第二编码）；超出当前量程的画成边缘空心点
  drawBlip(e, f, clipped) {
    const { ctx } = this;
    const [x, y] = this.pt(e.a, this.rOf(e.d));
    const color = LEVELS[e.l].color;
    const size = 2.6 + e.l * 0.7;
    ctx.save();
    if (clipped) {
      ctx.strokeStyle = withAlpha(color, f);
      ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.arc(x, y, size + 1, 0, 2 * Math.PI); ctx.stroke();
    } else {
      const fresh = this.state.serverNow() - e.t < 2;
      ctx.shadowColor = color; ctx.shadowBlur = fresh ? 12 : 4;
      ctx.fillStyle = withAlpha(color, f);
      ctx.beginPath(); ctx.arc(x, y, size, 0, 2 * Math.PI); ctx.fill();
    }
    ctx.restore();
    this.hits.push({ x, y, e });
  }

  // 超量程 / 无回波：外圈上一小段虚刻度
  drawOor(e, f) {
    const { ctx, R } = this;
    const [x1, y1] = this.pt(e.a, R + 3), [x2, y2] = this.pt(e.a, R + 9);
    ctx.strokeStyle = withAlpha('#8fa39e', 0.8 * f);
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
    this.hits.push({ x: (x1 + x2) / 2, y: (y1 + y2) / 2, e });
  }

  drawPings(ts) {
    const { ctx } = this;
    const pings = this.state.pings;
    for (let i = pings.length - 1; i >= 0; i--) {
      const p = pings[i], k = (ts - p.born) / PING_MS;
      if (k >= 1 || p.d == null) { if (k >= 1) pings.splice(i, 1); continue; }
      const [x, y] = this.pt(p.a, this.rOf(p.d));
      ctx.strokeStyle = withAlpha(LEVELS[p.l].color, 0.9 * (1 - k));
      ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.arc(x, y, 4 + 18 * Math.sqrt(k), 0, 2 * Math.PI); ctx.stroke();
    }
  }

  drawEmpty() {
    if (this.state.cur) return;
    const { ctx, cx, cy, R } = this;
    ctx.fillStyle = this.c.text3;
    ctx.font = `14px ${token('--font')}`;
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(this.state.hasSource ? '等待数据…' : '未连接数据源', cx, cy - R * 0.45);
  }

  updateTip() {
    const p = this.hoverPos;
    if (!p) return;
    let best = null, bestD = 14 * 14;
    for (const h of this.hits) {
      const d = (h.x - p.x) ** 2 + (h.y - p.y) ** 2;
      if (d < bestD) { bestD = d; best = h; }
    }
    if (!best) { this.tip.hidden = true; return; }
    const e = best.e, lv = LEVELS[e.l];
    const age = Math.max(0, this.state.serverNow() - e.t);
    this.tip.innerHTML =
      `<div class="t-head"><span class="swatch" style="background:${e.d == null ? 'transparent' : lv.color}"></span>` +
      `${e.a}° · ${e.d == null ? '超量程' : e.d + ' mm'}</div>` +
      `<div class="t-sub">L${e.l} ${lv.name}（${lv.range}）· ${age < 60 ? age.toFixed(1) + ' s' : Math.round(age / 60) + ' min'} 前</div>` +
      (e.v != null ? `<div class="t-sub">接近速度 ${fmtSpeed(e.v)}</div>` : '') +
      (e.intr ? `<div class="t-sub t-intr">⚠ 入侵：${e.intr.b == null ? '背景无回波' : `比背景（${e.intr.b} mm）近 ${e.intr.delta} mm`}</div>` : '');
    this.tip.hidden = false;
    const tw = this.tip.offsetWidth, th = this.tip.offsetHeight;
    let x = p.x + 14, y = p.y - th - 10;
    if (x + tw > this.w) x = p.x - tw - 14;
    if (y < 0) y = p.y + 14;
    this.tip.style.left = `${x}px`;
    this.tip.style.top = `${y}px`;
  }
}
