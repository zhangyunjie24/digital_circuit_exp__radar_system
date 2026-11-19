// 前端主程序：WebSocket 收后端消息 → 更新 state → 刷新各面板；扫描图由 ppi.js 自己逐帧画。
import { LEVELS } from './bands.js';
import { PPI, fmtSpeed } from './ppi.js';
import { Analysis, AngleStats, CalibChart, Cloud, Histogram, RAMP_CSS, Waterfall, startRendering } from './charts.js';

const $ = (id) => document.getElementById(id);
const TABLE_ROWS = 14;
const MAX_EVENTS = 60;

// ---------------- 状态 ----------------
const state = {
  table: new Map(),       // 角度 → {d, l, t, v, intr}
  baseline: new Map(),    // 角度 → 背景距离（null = 背景无回波）；空 = 未记录
  cur: null,              // 最近一次 meas
  mode: null, dir: 0, pass: 0,
  pings: [],
  hasSource: false,
  // 数据源时钟：每次 status / snapshot 对一次表，之间按流速外推（回放快放时流速 > 1）
  sync: { t: Date.now() / 1000, wall: Date.now() / 1000, speed: 1 },
  serverNow() { return this.sync.t + (Date.now() / 1000 - this.sync.wall) * this.sync.speed; },
};
const rows = [];          // 表格用的最近测量

const ppi = new PPI($('ppi'), $('ppi-tip'), state);

const analysis = new Analysis();
new Waterfall($('wf-wrap'), analysis);
new Cloud($('cloud-wrap'), analysis, () => ppi.range);
new AngleStats($('stats-wrap'), analysis);
new Histogram($('hist-wrap'), analysis);
new CalibChart($('calib-wrap'), analysis);
document.querySelector('.grad').style.background = RAMP_CSS;
startRendering(analysis);
ppi.onRange = () => analysis.touch();     // 点云跟着扫描图的量程走

// ---------------- 存储小工具（隐私模式下可能不可用） ----------------
const store = {
  get(k, d) { try { return localStorage.getItem(k) ?? d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* 忽略 */ } },
};

// ---------------- WebSocket ----------------
let ws = null, retry = 0;

function connectWs() {
  ws = new WebSocket(`ws://${location.host}/ws`);
  ws.onopen = () => { retry = 0; $('conn-banner').hidden = true; };
  ws.onmessage = (ev) => handle(JSON.parse(ev.data));
  ws.onclose = () => {
    $('conn-banner').hidden = false;
    setTimeout(connectWs, Math.min(5000, 500 * 2 ** retry++));
  };
}

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function handle(m) {
  switch (m.type) {
    case 'snapshot': onSnapshot(m); break;
    case 'meas': onMeas(m); break;
    case 'event': onEvent(m); break;
    case 'bad': logEvent(m); break;
    case 'status': onStatus(m); break;
    case 'source': onSource(m); break;
    case 'lists': onLists(m); break;
    case 'stats': onStats(m); break;
    case 'baseline': onBaseline(m); break;
    case 'calib': onCalib(m); break;
    case 'notice': addEvent(Date.now() / 1000, 'notice', esc(m.msg)); break;
    case 'error': addEvent(Date.now() / 1000, 'error', esc(m.msg)); break;
  }
}

// ---------------- 消息处理 ----------------
function onSnapshot(m) {
  state.table = new Map(Object.entries(m.table).map(([a, v]) => [+a, v]));
  state.mode = m.mode; state.dir = m.dir; state.pass = m.pass;
  state.cur = m.history.length ? m.history[m.history.length - 1] : null;
  rows.length = 0;
  rows.push(...m.history.slice(-TABLE_ROWS).reverse());
  clearEvents();
  replaying = true;
  m.log.forEach(logEvent);
  replaying = false;
  onBaseline(m.baseline);
  analysis.table = state.table;
  analysis.reset(m.history);
  onStats(m.stats);
  onStatus(m.status);
  renderNow(); renderTable();
}

function onMeas(m) {
  state.table.set(m.a, { d: m.d, l: m.l, t: m.t, v: m.v, intr: m.intr });
  state.cur = m;
  state.mode = m.mode; state.dir = m.dir; state.pass = m.pass;
  state.pings.push({ a: m.a, d: m.d, l: m.l, born: performance.now() });
  rows.unshift(m);
  if (rows.length > TABLE_ROWS) rows.length = TABLE_ROWS;
  analysis.add(m);
  renderNow(); renderTable();
}

function onEvent(m) {
  if (m.kind === 'restart') {          // 与 FPGA 一样：重新开始时清空各方向；瀑布图另起一行
    state.table.clear();
    analysis.newRun();
  }
  logEvent(m);
}

let replaying = false;     // 快照里补放旧事件时不响警报

// event / bad → 事件列表里的一条（kind 决定圆点颜色）；sweep 只用于计数，不进列表
function logEvent(m) {
  let kind = m.kind, html;
  if (m.type === 'bad') {
    kind = 'bad';
    html = `丢弃坏行 <code>${esc(m.raw)}</code>：${esc(m.reason)}`;
  } else if (m.kind === 'restart') {
    const why = { start: '开始接收', power: '重新上电', switch: '按键切换模式' }[m.reason] || m.reason;
    html = `${why} · ${m.mode ?? '模式待定'}，扫描从 0° 重新开始`;
  } else if (m.kind === 'mode') {
    html = `识别出扫描模式：<b>${m.mode}</b>${m.prev ? `（原 ${m.prev}）` : ''}`;
  } else if (m.kind === 'resync') {
    html = `角度不连续 ${m.prev}° → ${m.angle}°（可能丢行）`;
  } else if (m.kind === 'intrusion') {
    html = `⚠ 入侵 ${m.angle}°：${m.d} mm` +
      (m.b == null ? '（背景这里无回波）' : `，比背景（${m.b} mm）近 ${m.delta} mm`);
    if (!replaying) alertSound();
  } else if (m.kind === 'intrusion_clear') {
    kind = 'clear';
    html = '入侵解除：各方向都回到背景距离';
  } else if (m.kind === 'baseline') {
    html = m.angles ? `已记录背景：${m.angles} 个方向` : '已清除背景，入侵检测关闭';
  } else if (m.kind === 'link') {
    kind = m.state;
    html = m.state === 'idle' ? '超过 3 s 没有数据（SW7 关闭或链路中断）' : '开始收到数据';
  } else {
    return;
  }
  addEvent(m.t, kind, html);
}

function onStatus(s) {
  state.sync = { t: s.t, wall: Date.now() / 1000, speed: s.speed ?? 1 };
  const link = $('pill-link');
  link.dataset.state = state.hasSource ? s.link : 'none';
  link.querySelector('span').textContent =
    !state.hasSource ? '未连接' : { up: '接收中', idle: '无数据', none: '等待数据' }[s.link];
  $('pill-rate').textContent = `${s.rate.toFixed(1)} 行/s`;
  const err = $('pill-err');
  err.textContent = `坏行 ${s.errors}`;
  err.dataset.state = s.errors ? 'err' : '';
  $('meas-count').textContent = `共 ${s.lines} 行`;
  const intr = $('pill-intr');
  intr.hidden = !state.baseline.size;
  intr.dataset.state = s.intruded ? 'intr' : 'clear';
  intr.querySelector('span').textContent = s.intruded ? `入侵 · ${s.intruded} 个方向` : '无入侵';
  const rec = $('btn-record');
  rec.dataset.on = s.recording ? '1' : '0';
  rec.querySelector('span').textContent = s.recording ? `停止录制 · ${s.recording.lines} 行` : '录制';
  rec.title = s.recording ? `正在录制到 recordings/${s.recording.file}` : '把收到的原始行存到 recordings/ 目录';
  renderAge();
}

function onStats(m) {
  analysis.setStats(m);
  const n = m.hist.counts.reduce((a, b) => a + b, 0) + m.hist.oor;
  $('hist-sub').textContent = `累计 ${n} 次 · 每格 ${m.hist.bin} mm`;
}

function onSource(m) {
  state.hasSource = !!m.name;
  $('btn-connect').textContent = m.name ? '断开' : '连接';
  $('btn-connect').classList.toggle('danger', !!m.name);
  $('sim-tools').hidden = m.name !== 'sim';
  $('src-pick').hidden = !!m.name;
  $('btn-record').hidden = !m.name || m.name === 'replay';
  $('src-label').hidden = !m.name;
  $('src-label').textContent = m.detail || m.name || '';
  if (!m.name) { $('pill-link').dataset.state = 'none'; $('pill-link').querySelector('span').textContent = '未连接'; }
}

// ---------------- 数据源列表 ----------------
// 选项值：sim:STEP / sim:CONT / serial:COM7 / replay:rec_xxx.csv
function onLists(m) {
  const sel = $('src-select');
  const prev = sel.value || store.get('radar.source', '');
  const opt = (value, text, disabled = false) =>
    `<option value="${esc(value)}"${disabled ? ' disabled' : ''}>${esc(text)}</option>`;
  const ports = m.ports.length
    ? m.ports.map((p) => opt(`serial:${p.device}`, `${p.device} · ${p.desc}`, !p.usable)).join('')
    : opt('', '（没有找到串口）', true);
  const recs = m.recordings.length
    ? m.recordings.map((r) => opt(`replay:${r.name}`, `${r.name} · ${fmtDur(r.duration)} · ${r.lines} 行`)).join('')
    : opt('', '（还没有录制）', true);
  sel.innerHTML =
    `<optgroup label="串口">${ports}</optgroup>` +
    `<optgroup label="模拟器">${opt('sim:STEP', '模拟器 · STEP')}${opt('sim:CONT', '模拟器 · CONT')}</optgroup>` +
    `<optgroup label="回放">${recs}</optgroup>`;
  // 优先保留之前的选择；否则选第一个可用串口（列表已把 HC-05/06 排在最前），没有就选模拟器
  const usable = [...sel.options].filter((o) => !o.disabled && o.value);
  const keep = usable.find((o) => o.value === prev);
  sel.value = (keep || usable.find((o) => o.value.startsWith('serial:')) || usable.find((o) => o.value === 'sim:CONT')).value;
  onPick();
}

function onPick() {
  $('speed-select').hidden = !$('src-select').value.startsWith('replay:');
}

function fmtDur(sec) {
  return sec < 60 ? `${Math.round(sec)} s` : `${Math.floor(sec / 60)} min ${Math.round(sec % 60)} s`;
}

// ---------------- 当前测量面板 ----------------
const levelBar = $('level-bar');
LEVELS.forEach((lv) => {
  const s = document.createElement('span');
  s.style.background = lv.color;
  s.title = `${lv.name} ${lv.range}`;
  levelBar.appendChild(s);
});

function renderNow() {
  const m = state.cur;
  const chip = $('mode-chip');
  if (state.mode) { chip.dataset.mode = state.mode; chip.textContent = state.mode === 'STEP' ? 'STEP · 步进' : 'CONT · 连续'; }
  else { delete chip.dataset.mode; chip.textContent = '模式待定'; }

  if (!m) {
    $('v-angle').textContent = '—'; $('v-dist').textContent = '—';
    $('v-dir').textContent = '—'; $('v-age').textContent = '—';
    $('level-name').textContent = '无数据';
    $('level-swatch').style.background = 'transparent';
    [...levelBar.children].forEach((s) => s.className = '');
    setAlarm(null);
    return;
  }
  $('v-angle').textContent = m.a;
  $('v-dir').textContent = (state.dir > 0 ? '↺ 向 180° 转' : state.dir < 0 ? '↻ 向 0° 转' : '方向待定') +
    (state.pass ? ` · 第 ${state.pass + 1} 程` : '');
  $('v-dist').textContent = m.d == null ? '----' : m.d;
  $('v-dist-unit').textContent = m.d == null ? '超量程' : 'mm';
  const lv = LEVELS[m.l];
  $('level-name').textContent = `L${m.l} ${lv.name} · ${lv.range}`;
  $('level-swatch').style.background = lv.color;
  [...levelBar.children].forEach((s, i) => s.className = i === m.l ? 'on' : i < m.l ? 'past' : '');
  setAlarm(m.l);
  renderAge();
  const sp = $('v-speed');
  sp.textContent = fmtSpeed(m.v);
  sp.dataset.state = m.v != null && m.v <= -50 ? 'near' : '';
  renderIntr(m);
}

function renderIntr(m) {
  const el = $('v-intr');
  el.dataset.state = '';
  if (!state.baseline.size) { el.textContent = '未记录背景'; return; }
  if (!m) { el.textContent = '—'; return; }
  if (m.intr) {
    el.textContent = m.intr.b == null ? '⚠ 入侵（背景无回波）' : `⚠ 入侵：近 ${m.intr.delta} mm`;
    el.dataset.state = 'intr';
  } else {
    el.textContent = '正常';
  }
}

// ---------------- 背景 / 入侵 ----------------
function onBaseline(b) {
  state.baseline = new Map(Object.entries(b.ref || {}).map(([a, d]) => [+a, d]));
  const has = state.baseline.size > 0;
  $('bl-text').textContent = has ? `背景：${state.baseline.size} 个方向 · ${fmtTime(b.t)}` : '未记录背景';
  $('btn-bl').textContent = has ? '重新记录' : '记录背景';
  $('btn-bl-clear').hidden = !has;
  $('pill-intr').hidden = !has;
  renderIntr(state.cur);
}
$('btn-bl').addEventListener('click', () => send({ cmd: 'baseline', action: 'capture' }));
$('btn-bl-clear').addEventListener('click', () => send({ cmd: 'baseline', action: 'clear' }));

// 入侵提示音：开了"声音"才响；三声短促的 880Hz，和蜂鸣器的 1.95kHz 区分开
function alertSound() {
  if (!$('sound-toggle').checked) return;
  const ctx = new AudioContext();
  [0, 0.18, 0.36].forEach((t0) => {
    const osc = ctx.createOscillator(), g = ctx.createGain();
    osc.frequency.value = 880;
    g.gain.setValueAtTime(0.0001, ctx.currentTime + t0);
    g.gain.exponentialRampToValueAtTime(0.12, ctx.currentTime + t0 + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + t0 + 0.12);
    osc.connect(g).connect(ctx.destination);
    osc.start(ctx.currentTime + t0);
    osc.stop(ctx.currentTime + t0 + 0.13);
  });
  setTimeout(() => ctx.close(), 800);
}

// ---------------- 精度标定 ----------------
let calib = null;

function onCalib(m) {
  calib = m;
  analysis.setCalib(m);
  const act = m.active;
  $('calib-form').hidden = !!act;
  $('calib-progress').hidden = !act;
  if (act) {
    $('calib-bar').style.width = `${(100 * act.got.length) / act.need}%`;
    $('calib-ptext').textContent =
      `${act.true} mm @ ${act.angle}°${act.tol ? ` ±${act.tol}°` : ''}：${act.got.length}/${act.need}` +
      (act.miss ? `（无回波 ${act.miss}）` : '') +
      (act.got.length ? ` · 最近 ${act.got[act.got.length - 1]} mm` : '');
  }
  const body = $('calib-body');
  body.replaceChildren(...m.points.map((p, i) => {
    const tr = document.createElement('tr');
    [p.true, p.mean, `${p.err > 0 ? '+' : ''}${p.err}`, p.std, p.n, `${p.angle}°`].forEach((v) => {
      const td = document.createElement('td');
      td.className = 'num';
      td.textContent = v;
      tr.append(td);
    });
    const td = document.createElement('td');
    const del = document.createElement('button');
    del.className = 'btn small ghost';
    del.textContent = '删除';
    del.addEventListener('click', () => send({ cmd: 'calib', action: 'delete', index: i }));
    td.append(del);
    tr.append(td);
    return tr;
  }));
  if (!m.points.length) body.innerHTML = '<tr><td colspan="7" class="muted">还没有标定点：填好真实距离后点"开始采集"</td></tr>';
  const f = m.fit, fitEl = $('calib-fit');
  fitEl.replaceChildren();
  if (f) {
    const line1 = document.createElement('div');
    line1.textContent = `拟合：测量值 = ${f.k} × 真实值 ${f.b >= 0 ? '+' : '−'} ${Math.abs(f.b)} mm，R² = ${f.r2}`;
    const line2 = document.createElement('div');
    line2.className = 'muted';
    line2.textContent = `各点平均绝对误差 ${f.mean_abs_err} mm，最大 ${f.max_abs_err} mm；比例误差 ${((f.k - 1) * 100).toFixed(2)}%`;
    fitEl.append(line1, line2);
  } else if (m.points.length === 1) {
    fitEl.textContent = '再采一个不同距离的点就能拟合。';
  }
}

$('calib-form').addEventListener('submit', (e) => {
  e.preventDefault();
  send({
    cmd: 'calib', action: 'start',
    true_mm: +$('calib-true').value, angle: +$('calib-angle').value, count: +$('calib-count').value,
  });
});
$('calib-cancel').addEventListener('click', () => send({ cmd: 'calib', action: 'cancel' }));
$('calib-clear').addEventListener('click', () => {
  if (calib && calib.points.length && confirm('清空全部标定点？')) send({ cmd: 'calib', action: 'clear' });
});
$('calib-export').addEventListener('click', () => {
  if (!calib || !calib.points.length) return;
  const lines = ['true_mm,mean_mm,err_mm,std_mm,n,angle_deg,min_mm,max_mm'];
  calib.points.forEach((p) => lines.push([p.true, p.mean, p.err, p.std, p.n, p.angle, p.min, p.max].join(',')));
  const f = calib.fit;
  if (f) lines.push(`# fit: measured = ${f.k} * true + ${f.b}, R2 = ${f.r2}`);
  const blob = new Blob([lines.join('\r\n') + '\r\n'], { type: 'text/csv' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `calibration_${new Date().toISOString().slice(0, 19).replace(/[-:T]/g, '')}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
});

function renderAge() {
  if (!state.cur) return;
  const age = Math.max(0, state.serverNow() - state.cur.t);
  $('v-age').textContent = age < 1 ? '刚刚' : `${age.toFixed(0)} s 前`;
}

// ---------------- 声光报警（还原 alarm_ctrl.v / buzzer_ctrl.v） ----------------
// LD15~12 红、LD11~8 黄、LD7~4 绿、LD3~0 蓝
const LED_GROUPS = ['--led-red', '--led-yellow', '--led-green', '--led-blue'];
const leds = [];
for (let i = 15; i >= 0; i--) {
  const el = document.createElement('span');
  el.className = 'led';
  el.style.setProperty('--c', `var(${LED_GROUPS[3 - (i >> 2)]})`);
  el.title = `LD${i}`;
  $('leds').appendChild(el);
  leds[i] = el;
}
// band → [亮哪些 LD, 是否闪]
const LED_RULE = [
  [[0, 1, 2, 3], false],
  [[4, 5, 6, 7], true],
  [[8, 9, 10, 11], true],
  [[12, 13, 14, 15], true],
  [[...Array(16).keys()], true],
];
// 蜂鸣器：周期 ms（每周期前 100ms 响）；0 = 不响，-1 = 常响
const BUZZ_PERIOD = [0, 1000, 500, 250, -1];
const BUZZ_TEXT = ['静音', '1 次/秒', '2 次/秒', '4 次/秒', '常响'];
let alarmLevel = null;

function setAlarm(level) {
  alarmLevel = level;
  leds.forEach((el) => el.className = 'led');
  if (level != null) {
    const [ids, blink] = LED_RULE[level];
    ids.forEach((i) => leds[i].classList.add(blink ? 'blink' : 'on'));
  }
  $('bz-text').textContent = level == null ? '静音' : BUZZ_TEXT[level];
}

// 2Hz 闪烁 + 蜂鸣节奏：所有 LED 共用一个相位，和板子一样整齐
let audio = null;
setInterval(() => {
  const now = performance.now();
  document.body.dataset.blink = (now % 500) < 250 ? '1' : '0';
  const p = alarmLevel == null ? 0 : BUZZ_PERIOD[alarmLevel];
  const on = p === -1 || (p > 0 && now % p < 100);
  $('bz-icon').classList.toggle('on', on);
  if (audio) audio.gain.gain.setTargetAtTime(on ? 0.05 : 0, audio.ctx.currentTime, 0.004);
}, 20);

$('sound-toggle').addEventListener('change', (e) => {
  if (e.target.checked && !audio) {
    const ctx = new AudioContext();
    const osc = ctx.createOscillator(), gain = ctx.createGain();
    osc.frequency.value = 1950;          // 与板上约 1.95kHz 的音调相同
    gain.gain.value = 0;
    osc.connect(gain).connect(ctx.destination);
    osc.start();
    audio = { ctx, gain };
  } else if (!e.target.checked && audio) {
    audio.ctx.close();
    audio = null;
  }
});

// ---------------- 事件列表 ----------------
function addEvent(t, kind, html) {
  const list = $('ev-list');
  list.querySelector('.ev-empty')?.remove();
  const li = document.createElement('li');
  li.dataset.kind = kind;
  li.innerHTML = `<span class="ev-t">${fmtTime(t)}</span><span class="ev-dot"></span><span class="ev-msg">${html}</span>`;
  list.prepend(li);
  while (list.children.length > MAX_EVENTS) list.lastChild.remove();
}
function clearEvents() { $('ev-list').innerHTML = '<li class="ev-empty">暂无事件</li>'; }
$('btn-clear-ev').addEventListener('click', clearEvents);
clearEvents();

// ---------------- 表格 ----------------
function renderTable() {
  $('meas-body').innerHTML = rows.map((m) => {
    const lv = LEVELS[m.l];
    return `<tr><td>${fmtTime(m.t, true)}</td><td class="num">${m.a}°</td>` +
      `<td class="num">${m.d == null ? '----' : m.d}</td>` +
      `<td class="lv"><span class="swatch${m.d == null ? ' oor' : ''}" style="${m.d == null ? '' : `background:${lv.color}`}"></span>L${m.l} ${m.d == null ? '超量程' : lv.name}</td>` +
      `<td>${m.mode ?? '—'}</td><td class="num">${m.pass + 1}</td></tr>`;
  }).join('') || '<tr><td colspan="6" class="muted">暂无数据</td></tr>';
}

// ---------------- 图例 / 量程 / 顶栏按钮 ----------------
$('legend').innerHTML = LEVELS.map((lv, i) =>
  `<li><span class="swatch" style="background:${lv.color}"></span>L${i} ${lv.name} <span class="muted">${lv.range}</span></li>`).join('') +
  '<li><span class="swatch oor"></span>超量程 <span class="muted">外圈刻度</span></li>';

function setRange(mm) {
  ppi.setRange(mm);
  document.querySelectorAll('#range-seg button').forEach((b) => b.setAttribute('aria-pressed', String(+b.dataset.range === mm)));
  store.set('radar.range', String(mm));
}
document.querySelectorAll('#range-seg button').forEach((b) => b.addEventListener('click', () => setRange(+b.dataset.range)));
setRange(+store.get('radar.range', '2000') || 2000);

$('btn-connect').addEventListener('click', () => {
  if (state.hasSource) { send({ cmd: 'disconnect' }); return; }
  const value = $('src-select').value;
  if (!value) return;
  store.set('radar.source', value);
  const i = value.indexOf(':');
  const source = value.slice(0, i), arg = value.slice(i + 1);
  if (source === 'sim') send({ cmd: 'connect', source, mode: arg });
  else if (source === 'serial') {
    addEvent(Date.now() / 1000, 'notice', `正在打开 ${esc(arg)}…（蓝牙串口首次连接可能要几秒）`);
    send({ cmd: 'connect', source, port: arg });
  } else send({ cmd: 'connect', source, file: arg, speed: +$('speed-select').value });
});
$('src-select').addEventListener('change', onPick);
$('btn-refresh').addEventListener('click', () => send({ cmd: 'list' }));
$('btn-record').addEventListener('click', () => send({ cmd: 'record', on: $('btn-record').dataset.on !== '1' }));
$('btn-switch').addEventListener('click', () => send({ cmd: 'sim', action: 'switch' }));
$('btn-power').addEventListener('click', () => send({ cmd: 'sim', action: 'power' }));

// ---------------- 工具 ----------------
function fmtTime(t, ms = false) {
  const d = new Date(t * 1000);
  const s = d.toLocaleTimeString('zh-CN', { hour12: false });
  return ms ? `${s}.${String(d.getMilliseconds()).padStart(3, '0').slice(0, 1)}` : s;
}
function esc(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

setInterval(renderAge, 1000);
renderNow(); renderTable();
connectWs();
