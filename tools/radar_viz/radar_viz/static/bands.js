// 距离分级：与 FPGA dist_band.v 一致。颜色取 style.css 里的 --b0~--b4。
const css = getComputedStyle(document.documentElement);

export const LEVELS = [
  { name: '安全', range: '≥ 800 mm', color: css.getPropertyValue('--b0').trim() },
  { name: '提示', range: '600–800',  color: css.getPropertyValue('--b1').trim() },
  { name: '注意', range: '400–600',  color: css.getPropertyValue('--b2').trim() },
  { name: '警告', range: '200–400',  color: css.getPropertyValue('--b3').trim() },
  { name: '危险', range: '< 200',    color: css.getPropertyValue('--b4').trim() },
];

// 分级边界（mm）：THRESHOLDS[i] 是 level i 与 i+1 的分界
export const THRESHOLDS = [800, 600, 400, 200];

export const token = (name) => css.getPropertyValue(name).trim();

export function withAlpha(hex, a) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${n >> 16}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
}
