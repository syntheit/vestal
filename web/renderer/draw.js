// The drawn node types (bar, ring, spark, divider, bars, stackedBar, heatmap,
// timeline) as SVG markup, after the SwiftUI renderer's Canvas code
// (Sources/VestalMac/Render/RenderNodeView.swift, RenderCharts.swift). Pure:
// strings in, strings out.
//
// `env` supplies { pal, px, theme, textWidth(node, text) }: `pal.css(spec,
// fallback)` / `pal.rgba(...)` resolve colours, `px` is device pixels per point
// (segment widths snap to it), `textWidth` measures a label for the timeline.

import { heatmapPosition } from "./layout.js";
import { cssColor, withAlpha } from "./color.js";
import { fontShorthand } from "./text.js";
import { analogSVG, ringGeometry, ringMarksSVG } from "./clock.js";

const f = (n) => Math.round(n * 1000) / 1000;
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
export const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

const rect = (x, y, w, h, r, fill) =>
  `<rect x="${f(x)}" y="${f(y)}" width="${f(w)}" height="${f(h)}" rx="${f(r)}" ry="${f(r)}" fill="${fill}"/>`;

let clipSerial = 0;

// MARK: - bar

export function barSVG(n, w, h, env) {
  const { pal, px } = env;
  const color = pal.css(n.color, "accent");
  const track = n.trackColor ? pal.css(n.trackColor) : cssColor(withAlpha(pal.rgba(n.color, "accent"), 0.15));
  const overlay = n.overlayColor ? pal.css(n.overlayColor) : "rgba(255,255,255,0.2)";
  const radius = Math.min(n.radius ?? 2, h / 2);
  const seg = (fraction, c) => {
    const v = clamp(fraction, 0, 1);
    return v > 0 ? rect(0, 0, Math.round(w * v * px) / px, h, radius, c) : "";
  };
  let out = seg(1, track);
  if (n.overlay != null && n.overlayPosition === "below") out += seg(n.overlay, overlay);
  out += seg(n.value ?? 0, color);
  if (n.overlay != null && n.overlayPosition !== "below") out += seg(n.overlay, overlay);
  return out;
}

// MARK: - ring

/** Points of an arc `from`...`to` radians (clockwise on screen) as an SVG path. */
export function arcPath(cx, cy, r, from, to) {
  const x0 = cx + r * Math.cos(from), y0 = cy + r * Math.sin(from);
  const x1 = cx + r * Math.cos(to), y1 = cy + r * Math.sin(to);
  const large = to - from > Math.PI ? 1 : 0;
  return `M${f(x0)} ${f(y0)}A${f(r)} ${f(r)} 0 ${large} 1 ${f(x1)} ${f(y1)}`;
}

export function ringSVG(n, w, h, env) {
  const { pal } = env;
  const side = Math.min(w, h);
  if (side <= 0) return "";
  const thickness = n.thickness ?? 6;
  const color = pal.css(n.color, "accent");
  const track = n.trackColor ? pal.css(n.trackColor) : cssColor(withAlpha(pal.rgba(n.color, "accent"), 0.15));
  const cx = w / 2, cy = h / 2;
  const geometry = ringGeometry(side, n);
  const r = geometry.radius, sweep = geometry.sweep;
  // 90 degrees points straight down, so the gap is centered at the bottom
  // (a full circle starts at the top).
  const start = geometry.start;
  const arc = (fraction, c) => {
    const span = sweep * fraction;
    if (span <= 0) return "";
    // A full circle can't be one SVG arc (start and end are the same point).
    if (span >= 2 * Math.PI - 1e-6) {
      return `<circle cx="${f(cx)}" cy="${f(cy)}" r="${f(r)}" fill="none" stroke="${c}" stroke-width="${f(thickness)}"/>`;
    }
    const d = arcPath(cx, cy, r, start, start + span);
    return `<path d="${d}" fill="none" stroke="${c}" stroke-width="${f(thickness)}" stroke-linecap="round"/>`;
  };
  const marks = n.ticks > 0 || n.dot || (n.labels && n.labels.length) ? ringMarksSVG(n, geometry, cx, cy, env) : "";
  return arc(1, track) + arc(clamp(n.value ?? 0, 0, 1), color) + marks;
}

// MARK: - spark

export function sparkPoints(values, min, max, w, h, strokeWidth, dot) {
  const inset = strokeWidth / 2 + (dot ? strokeWidth : 0);
  const pw = Math.max(0, w - 2 * inset), ph = Math.max(0, h - 2 * inset);
  const lo = min ?? Math.min(...values), hi = max ?? Math.max(...values);
  return values.map((v, i) => {
    const t = hi > lo ? (clamp(v, lo, hi) - lo) / (hi - lo) : 0.5;
    return [inset + (pw * i) / (values.length - 1), inset + ph * (1 - t)];
  });
}

export function sparkSVG(n, w, h, env) {
  const values = n.values || [];
  if (values.length < 2 || w <= 0 || h <= 0) return "";
  const { pal } = env;
  const sw = n.strokeWidth ?? 1.5;
  const color = pal.css(n.color, "accent");
  const pts = sparkPoints(values, n.min, n.max, w, h, sw, !!n.dot);
  const line = pts.map(([x, y]) => `${f(x)},${f(y)}`).join(" ");
  let out = "";
  if (n.fill) {
    const area = `${f(pts[0][0])},${f(h)} ${line} ${f(pts[pts.length - 1][0])},${f(h)}`;
    out += `<polygon points="${area}" fill="${pal.css(n.fill)}"/>`;
  }
  out += `<polyline points="${line}" fill="none" stroke="${color}" stroke-width="${f(sw)}" stroke-linecap="round" stroke-linejoin="round"/>`;
  if (n.dot) {
    const [x, y] = pts[pts.length - 1];
    out += `<circle cx="${f(x)}" cy="${f(y)}" r="${f(sw * 1.5)}" fill="${color}"/>`;
  }
  return out;
}

// MARK: - divider

export function dividerSVG(n, w, h, env) {
  const t = n.thickness ?? 0.5;
  const c = env.pal.css(n.color, "dim");
  return n.axis === "v" ? rect((w - t) / 2, 0, t, h, 0, c) : rect(0, (h - t) / 2, w, t, 0, c);
}

// MARK: - bars

export function barsSVG(n, w, h, env) {
  const values = n.values || [];
  const count = values.length;
  if (!count || w <= 0 || h <= 0) return "";
  const gap = n.gap ?? 3;
  const bw = n.barWidth ?? Math.max(0, (w - gap * (count - 1)) / count);
  const top = (n.max ?? 1) > 0 ? n.max ?? 1 : 1;
  let out = "";
  values.forEach((v, i) => {
    const fraction = clamp(v / top, 0, 1);
    if (fraction <= 0) return;
    const bh = Math.max(1, h * fraction);
    const color = env.pal.css((n.colors || [])[i], "accent");
    out += rect(i * (bw + gap), h - bh, bw, bh, Math.min(2, bw / 2, bh / 2), color);
  });
  return out;
}

// MARK: - stackedBar

export function stackedBarSVG(n, w, h, env) {
  if (w <= 0 || h <= 0) return "";
  const radius = Math.min(n.radius ?? 4, h / 2, w / 2);
  const id = `vr-clip-${++clipSerial}`;
  let out = `<clipPath id="${id}">${rect(0, 0, w, h, radius, "#000")}</clipPath>`;
  out += rect(0, 0, w, h, radius, env.pal.css(n.trackColor || "track"));
  let x = 0, segs = "";
  for (const s of n.segments || []) {
    const sw = w * clamp(s.value, 0, 1);
    if (sw <= 0) continue;
    segs += rect(x, 0, sw, h, 0, env.pal.css(s.color));
    x += sw;
  }
  return out + `<g clip-path="url(#${id})">${segs}</g>`;
}

// MARK: - heatmap

export function heatmapSVG(n, w, h, env) {
  const cell = n.cell ?? 8, gap = n.gap ?? 2;
  const radius = Math.min(n.radius ?? 2, cell / 2);
  const track = env.pal.css(n.trackColor || "track");
  let out = "";
  (n.cells || []).forEach((spec, i) => {
    const { column, row } = heatmapPosition(n, i);
    out += rect(column * (cell + gap), row * (cell + gap), cell, cell, radius, spec ? env.pal.css(spec) : track);
  });
  return out;
}

// MARK: - timeline

export const TIMELINE_LABEL_HEIGHT = 12;

/** The tick labels that are drawn: each must clear the previous by 4. Pure given widths. */
export function visibleTicks(ticks, width, textWidth) {
  const out = [];
  let right = -Infinity;
  for (const t of ticks) {
    if (!t.label) continue;
    const mw = textWidth(t.label);
    let left = t.at * width - mw / 2;
    left = Math.min(Math.max(left, 0), Math.max(0, width - mw));
    if (left < right + 4) continue;
    out.push({ label: t.label, left, width: mw });
    right = left + mw;
  }
  return out;
}

/** An item label cut with an ellipsis to fit `room`; null when nothing fits. */
export function fitLabel(label, room, textWidth) {
  let chars = [...label];
  let text = label;
  let mw = textWidth(text);
  while (mw > room && chars.length > 1) {
    chars.pop();
    text = chars.join("").trimEnd() + "…";
    mw = textWidth(text);
  }
  return mw <= room ? text : null;
}

export function timelineSVG(n, w, h, env) {
  if (w <= 0 || h <= 0) return "";
  const { pal, theme } = env;
  const ticks = n.ticks || [];
  const axisY = ticks.length === 0 ? h : Math.max(0, h - TIMELINE_LABEL_HEIGHT);
  const area = Math.max(0, axisY - 2);
  const lanes = Math.max(n.lanes ?? 1, 1);
  const laneGap = 2;
  const laneHeight = Math.max(1, (area - laneGap * (lanes - 1)) / lanes);
  const font = (size, weight) => fontShorthand({ size, weight, font: "sans" }, theme);
  const itemFont = font(10, 500), tickFont = font(9, 400);
  const itemWidth = (s) => env.textWidth({ size: 10, weight: 500, font: "sans" }, s);
  const tickWidth = (s) => env.textWidth({ size: 9, weight: 400, font: "sans" }, s);
  let out = "";
  const grid = pal.css("dim@0.3");
  for (const t of ticks) {
    const x = Math.round(t.at * w) + 0.25;
    out += rect(x - 0.25, 0, 0.5, area, 0, grid);
  }
  for (const item of n.items || []) {
    const x0 = item.start * w;
    const top = (item.lane || 0) * (laneHeight + laneGap);
    const color = pal.css(item.color);
    if (item.end == null) {
      const r = Math.min(laneHeight / 2, 4);
      out += `<circle cx="${f(x0)}" cy="${f(top + laneHeight / 2)}" r="${f(r)}" fill="${color}"/>`;
      continue;
    }
    const bw = Math.max(item.end * w - x0, 3);
    out += rect(x0, top, bw, laneHeight, Math.min(3, laneHeight / 2, bw / 2), color);
    const room = bw - 12;
    if (item.label && laneHeight >= 12 && room >= 14) {
      const text = fitLabel(item.label, room, itemWidth);
      if (text) {
        out += `<text x="${f(x0 + 6)}" y="${f(top + laneHeight / 2)}" dominant-baseline="central" style="font:${esc(itemFont)}" fill="${pal.css("bg")}">${esc(text)}</text>`;
      }
    }
  }
  if (n.now != null) {
    out += rect(n.now * w - 0.75, 0, 1.5, area, 0, pal.css(n.nowColor || "accent"));
  }
  const dim = pal.css("dim");
  for (const t of visibleTicks(ticks, w, tickWidth)) {
    out += `<text x="${f(t.left)}" y="${f(axisY + TIMELINE_LABEL_HEIGHT / 2)}" dominant-baseline="central" style="font:${esc(tickFont)}" fill="${dim}">${esc(t.label)}</text>`;
  }
  return out;
}

export const DRAWERS = {
  bar: barSVG, ring: ringSVG, spark: sparkSVG, divider: dividerSVG, bars: barsSVG,
  stackedBar: stackedBarSVG, heatmap: heatmapSVG, timeline: timelineSVG, analog: analogSVG,
};
