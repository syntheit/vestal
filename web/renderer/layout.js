// The render model's layout rules (docs/reference/render-model.md "Layout"),
// pure: no DOM. A port of the SwiftUI renderer's arithmetic
// (Sources/VestalMac/Render/RenderLayout.swift) so frames match the native UIs.
//
// Text is the one thing the core can't measure, so the caller passes a
// measurer: `measureText(node, maxWidth)` -> { width, height, baseline } for the
// node's text laid out at most `maxWidth` wide (null: unbounded, one line per
// "\n"), honoring `lines`. Everything else is arithmetic.
//
//   const lay = new Layout(root, { measureText });
//   const frames = lay.place(root, { x, y, width, height });   // Map node -> frame
//
// A frame is { x, y, w, h } relative to the parent's border box (the root's is
// relative to the stage).

// MARK: - Node accessors

import { flipLayout } from "./clock.js";

export const DEFAULTS = {
  textSize: 13,
  barSize: [48, 6],
  ringSize: 40,
  sparkSize: [60, 20],
  barsSize: [160, 48],
  stackedBarSize: [60, 8],
  timelineSize: [120, 36],
  imageSize: [48, 48],
};

export function padding(node) {
  const p = node.padding || [0, 0, 0, 0];
  return { t: p[0], r: p[1], b: p[2], l: p[3], h: p[1] + p[3], v: p[0] + p[2] };
}

const isNum = (v) => typeof v === "number";

function clampW(node, w) {
  if (node.maxWidth != null) w = Math.min(w, node.maxWidth);
  if (node.minWidth != null) w = Math.max(w, node.minWidth);
  return Math.max(0, w);
}

function clampH(node, h) {
  if (node.maxHeight != null) h = Math.min(h, node.maxHeight);
  if (node.minHeight != null) h = Math.max(h, node.minHeight);
  return Math.max(0, h);
}

/** Children as the layout sees them: a stack's or grid's, a ring's `center`. */
export function childrenOf(node) {
  if (node.type === "stack" || node.type === "grid") return node.children || [];
  if (node.type === "ring" && node.center) return [node.center];
  return [];
}

export function heatmapColumns(node) {
  const rows = Math.max(node.rows ?? 7, 1);
  const n = (node.cells || []).length;
  return n === 0 ? 0 : Math.ceil(n / rows);
}

/** Column and row of heatmap cell `index`. */
export function heatmapPosition(node, index) {
  const rows = Math.max(node.rows ?? 7, 1);
  if (node.direction === "rows") {
    const columns = Math.max(heatmapColumns(node), 1);
    return { column: index % columns, row: Math.floor(index / columns) };
  }
  return { column: Math.floor(index / rows), row: index % rows };
}

/** Grid cells' row, first column and span, honoring `span`. */
export function gridCells(children, columnCount) {
  const cells = [];
  let row = 0, column = 0;
  for (const child of children) {
    const span = Math.min(Math.max(1, child.span || 1), columnCount);
    if (column + span > columnCount) { row += 1; column = 0; }
    cells.push({ row, column, span });
    column += span;
    if (column >= columnCount) { row += 1; column = 0; }
  }
  return cells;
}

// MARK: - Layout

export class Layout {
  constructor(root, { measureText }) {
    this.measureText = measureText;
    this.meta = new Map(); // node -> { parentAxis, hasBaseline }
    this.memo = new Map(); // node -> { fw, fh: Map, arr: Map, bl: Map }
    this.prepare(root, null);
  }

  prepare(node, parentAxis) {
    const kids = childrenOf(node);
    const axis = node.type === "stack" ? node.axis || "v" : null;
    for (const kid of kids) this.prepare(kid, axis);
    const hasBaseline = node.type === "text" || !this.isKnown(node)
      || ((node.type === "stack" || node.type === "grid") && kids.some((k) => this.meta.get(k).hasBaseline));
    this.meta.set(node, { parentAxis, hasBaseline });
    this.memo.set(node, { fw: undefined, fh: new Map(), arr: new Map(), bl: new Map() });
  }

  isKnown(node) {
    return ["stack", "grid", "text", "icon", "bar", "ring", "spark", "divider", "spacer", "bars",
      "stackedBar", "heatmap", "timeline", "image", "analog", "flip"].includes(node.type);
  }

  // MARK: Box (one node's frame around its content)

  /** Natural content size where the type fixes it; null: ask the content. */
  intrinsic(node) {
    const pa = this.meta.get(node).parentAxis;
    switch (node.type) {
      case "icon": return [node.size ?? DEFAULTS.textSize, node.size ?? DEFAULTS.textSize];
      case "bar": return DEFAULTS.barSize;
      case "spark": return DEFAULTS.sparkSize;
      case "divider": return node.axis === "v" ? [node.thickness ?? 0.5, 0] : [0, node.thickness ?? 0.5];
      case "spacer": return [pa === "h" ? node.min || 0 : 0, pa === "v" ? node.min || 0 : 0];
      case "bars": return DEFAULTS.barsSize;
      case "stackedBar": return DEFAULTS.stackedBarSize;
      case "heatmap": {
        const cols = heatmapColumns(node), rows = node.rows ?? 7, cell = node.cell ?? 8, gap = node.gap ?? 2;
        return [cols * cell + Math.max(0, cols - 1) * gap, rows * cell + Math.max(0, rows - 1) * gap];
      }
      case "timeline": return DEFAULTS.timelineSize;
      case "image": return DEFAULTS.imageSize;
      case "analog": return [node.size ?? 236, node.size ?? 236];
      case "flip": {
        const layout = flipLayout(node.text, node.small, node.size ?? 90, node.smallSize ?? 40);
        return [layout.width, layout.height];
      }
      default: return null;
    }
  }

  textNode(node) {
    // An unknown type draws its plain-text rendition.
    return node.type === "text" ? node : { type: "text", text: node.alt || "", size: DEFAULTS.textSize, color: "subtle" };
  }

  contentWidth(node) {
    if (node.type === "ring") return DEFAULTS.ringSize;
    const fixed = this.intrinsic(node);
    if (fixed) return fixed[0];
    if (node.type === "stack") return this.naturalWidth(node);
    if (node.type === "grid") {
      const widths = this.columnWidths(node, null);
      return widths.reduce((a, b) => a + b, 0) + (node.gap || 0) * Math.max(0, widths.length - 1);
    }
    return this.measureText(this.textNode(node), null).width;
  }

  contentHeight(node, innerW) {
    if (node.type === "ring") return innerW;
    const fixed = this.intrinsic(node);
    if (fixed) return fixed[1];
    if (node.type === "stack") return this.arrange(node, innerW, null).height;
    if (node.type === "grid") return this.arrangeGrid(node, innerW).height;
    return this.measureText(this.textNode(node), innerW).height;
  }

  /** A node's width for a proposal (null: none): exact for a number. */
  boxWidth(node, proposed) {
    if (isNum(node.width)) return clampW(node, node.width);
    if (proposed != null) return proposed;
    return clampW(node, this.contentWidth(node) + padding(node).h);
  }

  boxHeight(node, proposed, width) {
    if (isNum(node.height)) return clampH(node, node.height);
    if (proposed != null) return proposed;
    const p = padding(node);
    return clampH(node, this.contentHeight(node, Math.max(0, width - p.h)) + p.v);
  }

  /** Natural width, border-box. */
  fitWidth(node) {
    const m = this.memo.get(node);
    if (m.fw === undefined) m.fw = this.boxWidth(node, null);
    return m.fw;
  }

  /** Width for an offer: a number is exact; fit is natural capped by the offer. */
  offeredWidth(node, offer) {
    return isNum(node.width) ? this.fitWidth(node) : Math.min(this.fitWidth(node), offer);
  }

  /** Height for a width, border-box. */
  fitHeight(node, width) {
    const m = this.memo.get(node);
    let h = m.fh.get(width);
    if (h === undefined) { h = this.boxHeight(node, null, width); m.fh.set(width, h); }
    return h;
  }

  /** First baseline at that width, from the node's top; null without one. */
  baseline(node, width) {
    if (!this.meta.get(node).hasBaseline) return null;
    const m = this.memo.get(node);
    if (m.bl.has(width)) return m.bl.get(width);
    const p = padding(node);
    const boxH = this.fitHeight(node, width);
    const iw = Math.max(0, width - p.h), ih = Math.max(0, boxH - p.v);
    let inner = null;
    if (node.type === "stack") inner = this.arrange(node, iw, ih).baseline;
    else if (node.type === "grid") inner = this.arrangeGrid(node, iw).baseline;
    else {
      const t = this.textNode(node);
      const mt = this.measureText(t, iw);
      inner = (ih - mt.height) / 2 + mt.baseline;
    }
    const b = inner == null ? null : p.t + inner;
    m.bl.set(width, b);
    return b;
  }

  // MARK: Stack

  gapBefore(stack, i) {
    return i === 0 ? 0 : (stack.children[i].spaceBefore ?? stack.gap ?? 0);
  }

  alignOf(stack, child) {
    return child.alignSelf || stack.align || "start";
  }

  naturalWidth(stack) {
    const kids = stack.children || [];
    if ((stack.axis || "v") === "h") {
      let total = 0;
      kids.forEach((k, i) => { total += this.gapBefore(stack, i) + this.fitWidth(k); });
      return total;
    }
    return kids.reduce((m, k) => Math.max(m, this.fitWidth(k)), 0);
  }

  /** Frames of a stack's children in a content box `width` wide and `height` tall (null while measuring). */
  arrange(stack, width, height) {
    const memo = this.memo.get(stack).arr;
    const key = `${width}|${height}`;
    let a = memo.get(key);
    if (!a) {
      a = (stack.axis || "v") === "h" ? this.arrangeRow(stack, width, height) : this.arrangeColumn(stack, width, height);
      memo.set(key, a);
    }
    return a;
  }

  arrangeRow(stack, width, height) {
    const kids = stack.children || [];
    const n = kids.length;
    if (n === 0) return { frames: [], height: 0, baseline: null };
    const widths = new Array(n).fill(0);
    const fills = [];
    let used = 0;
    kids.forEach((child, i) => {
      used += this.gapBefore(stack, i);
      if (child.width === "fill") fills.push(i);
      else { widths[i] = this.offeredWidth(child, width); used += widths[i]; }
    });
    let remaining = width - used;
    if (fills.length) {
      const share = Math.max(0, remaining) / fills.length;
      for (const i of fills) { widths[i] = clampW(kids[i], share); remaining -= widths[i]; }
    } else if (remaining < 0) {
      // Overflow: texts with a line limit give way, down to their minimum.
      const shrinkable = kids.map((_, i) => i).filter((i) => kids[i].type === "text" && kids[i].lines != null && kids[i].width == null);
      const minimum = (i) => (kids[i].size ?? DEFAULTS.textSize) + padding(kids[i]).h;
      const capacity = shrinkable.map((i) => Math.max(0, widths[i] - minimum(i)));
      const total = capacity.reduce((a, b) => a + b, 0);
      if (total > 0) {
        const deficit = Math.min(-remaining, total);
        shrinkable.forEach((i, k) => { widths[i] -= deficit * capacity[k] / total; });
        remaining += deficit;
      }
    }

    const heights = kids.map((c, i) => this.fitHeight(c, widths[i]));
    const baselines = kids.map((c, i) => this.baseline(c, widths[i]));
    const align = (c) => this.alignOf(stack, c);
    const stretches = (i) => kids[i].height === "fill" || align(kids[i]) === "stretch";
    let ascent = 0, descent = 0, tallest = 0;
    for (let i = 0; i < n; i++) {
      if (align(kids[i]) === "baseline" && baselines[i] != null) {
        ascent = Math.max(ascent, baselines[i]);
        descent = Math.max(descent, heights[i] - baselines[i]);
      } else tallest = Math.max(tallest, heights[i]);
    }
    const natural = Math.max(tallest, ascent + descent);
    const rowHeight = height ?? natural;

    const frames = [];
    let x = 0, extraGap = 0;
    if (!fills.length && remaining > 0) {
      switch (stack.justify || "start") {
        case "center": x = remaining / 2; break;
        case "end": x = remaining; break;
        case "between": extraGap = n > 1 ? remaining / (n - 1) : 0; break;
        default: break;
      }
    }
    let baseline = null;
    kids.forEach((child, i) => {
      if (i > 0) x += this.gapBefore(stack, i) + extraGap;
      let h = heights[i];
      if (stretches(i)) h = clampH(child, rowHeight);
      let y;
      switch (align(child)) {
        case "center": y = (rowHeight - h) / 2; break;
        case "end": y = rowHeight - h; break;
        case "baseline":
          y = baselines[i] != null ? ascent - baselines[i] + Math.max(0, (rowHeight - natural) / 2) : (rowHeight - h) / 2;
          break;
        default: y = 0;
      }
      if (baseline == null && baselines[i] != null) baseline = y + baselines[i];
      frames.push({ x, y, w: widths[i], h });
      x += widths[i];
    });
    return { frames, height: natural, baseline };
  }

  arrangeColumn(stack, width, height) {
    const kids = stack.children || [];
    const n = kids.length;
    if (n === 0) return { frames: [], height: 0, baseline: null };
    const widths = new Array(n).fill(0), heights = new Array(n).fill(0);
    const fills = [];
    let used = 0;
    kids.forEach((child, i) => {
      used += this.gapBefore(stack, i);
      widths[i] = child.width === "fill" || this.alignOf(stack, child) === "stretch"
        ? clampW(child, width) : this.offeredWidth(child, width);
      if (child.height === "fill" && height != null) fills.push(i);
      else { heights[i] = this.fitHeight(child, widths[i]); used += heights[i]; }
    });
    let remaining = (height ?? used) - used;
    if (fills.length) {
      const share = Math.max(0, remaining) / fills.length;
      for (const i of fills) { heights[i] = clampH(kids[i], share); remaining -= heights[i]; }
    }
    let y = 0, extraGap = 0;
    if (!fills.length && remaining > 0) {
      switch (stack.justify || "start") {
        case "center": y = remaining / 2; break;
        case "end": y = remaining; break;
        case "between": extraGap = n > 1 ? remaining / (n - 1) : 0; break;
        default: break;
      }
    }
    const frames = [];
    let baseline = null;
    kids.forEach((child, i) => {
      if (i > 0) y += this.gapBefore(stack, i) + extraGap;
      let x;
      switch (this.alignOf(stack, child)) {
        case "center": x = (width - widths[i]) / 2; break;
        case "end": x = width - widths[i]; break;
        default: x = 0;
      }
      if (baseline == null) { const b = this.baseline(child, widths[i]); if (b != null) baseline = y + b; }
      frames.push({ x, y, w: widths[i], h: heights[i] });
      y += heights[i];
    });
    return { frames, height: y, baseline };
  }

  // MARK: Grid

  gridColumns(grid) {
    return grid.columns && grid.columns.length ? grid.columns : [{ width: "fit" }];
  }

  columnWidths(grid, width) {
    const columns = this.gridColumns(grid);
    const kids = grid.children || [];
    const cells = gridCells(kids, columns.length);
    const widest = new Array(columns.length).fill(0);
    kids.forEach((child, i) => {
      if (cells[i].span === 1) widest[cells[i].column] = Math.max(widest[cells[i].column], this.fitWidth(child));
    });
    const widths = new Array(columns.length).fill(0);
    const fills = [];
    let used = (grid.gap || 0) * Math.max(0, columns.length - 1);
    columns.forEach((col, i) => {
      if (isNum(col.width)) { widths[i] = col.width; used += col.width; }
      else if (col.width === "fill") {
        if (width == null) widths[i] = widest[i]; else fills.push(i);
      } else { widths[i] = widest[i]; used += widest[i]; }
    });
    if (width != null && fills.length) {
      const share = Math.max(0, width - used) / fills.length;
      for (const i of fills) widths[i] = share;
    }
    return widths;
  }

  arrangeGrid(grid, width) {
    const memo = this.memo.get(grid).arr;
    const key = `g${width}`;
    let a = memo.get(key);
    if (a) return a;
    const columns = this.gridColumns(grid);
    const kids = grid.children || [];
    const gap = grid.gap || 0, rowGap = grid.rowGap || 0;
    const widths = this.columnWidths(grid, width);
    const cells = gridCells(kids, columns.length);
    const xs = [];
    let x = 0;
    for (const w of widths) { xs.push(x); x += w + gap; }

    const n = kids.length;
    const frames = kids.map(() => ({ x: 0, y: 0, w: 0, h: 0 }));
    const rowHeights = new Map();
    const cellHeights = new Array(n).fill(0);
    const baselines = new Array(n).fill(null);
    kids.forEach((child, i) => {
      const cell = cells[i];
      let cellWidth = gap * (cell.span - 1);
      for (let c = cell.column; c < cell.column + cell.span; c++) cellWidth += widths[c];
      const w = child.width === "fill" || child.alignSelf === "stretch" ? clampW(child, cellWidth) : this.offeredWidth(child, cellWidth);
      const h = this.fitHeight(child, w);
      cellHeights[i] = h;
      baselines[i] = this.baseline(child, w);
      if (child.height !== "fill") rowHeights.set(cell.row, Math.max(rowHeights.get(cell.row) ?? 0, h));
      let align;
      switch (child.alignSelf) {
        case "center": align = "center"; break;
        case "end": align = "end"; break;
        case "start": case "stretch": case "baseline": align = "start"; break;
        default: align = columns[cell.column].align || "start";
      }
      const offset = align === "center" ? (cellWidth - w) / 2 : align === "end" ? cellWidth - w : 0;
      frames[i] = { x: xs[cell.column] + offset, y: 0, w, h };
    });
    kids.forEach((child, i) => {
      const cell = cells[i];
      if (child.height === "fill" && !rowHeights.has(cell.row)) {
        let m = 0, any = false;
        cells.forEach((c, j) => { if (c.row === cell.row) { m = Math.max(m, cellHeights[j]); any = true; } });
        rowHeights.set(cell.row, any ? m : cellHeights[i]);
      }
    });
    const rows = cells.reduce((m, c) => Math.max(m, c.row), -1) + 1;
    const ys = [];
    let y = 0;
    for (let row = 0; row < rows; row++) {
      ys.push(y);
      y += (rowHeights.get(row) ?? 0) + (row < rows - 1 ? rowGap : 0);
    }
    let baseline = null;
    kids.forEach((child, i) => {
      const cell = cells[i];
      const rowHeight = rowHeights.get(cell.row) ?? cellHeights[i];
      if (child.height === "fill") frames[i].h = clampH(child, rowHeight);
      frames[i].y = ys[cell.row] + (rowHeight - frames[i].h) / 2;
      if (baseline == null && baselines[i] != null) baseline = frames[i].y + baselines[i];
    });
    a = { frames, height: y, baseline };
    memo.set(key, a);
    return a;
  }

  // MARK: Placement

  /** The frames of a node's children inside its content box (innerW x innerH), relative to the content origin. */
  childFrames(node, innerW, innerH) {
    if (node.type === "stack") return this.arrange(node, innerW, innerH).frames;
    if (node.type === "grid") return this.arrangeGrid(node, innerW).frames;
    if (node.type === "ring" && node.center) {
      const c = node.center;
      const w = c.width === "fill" ? clampW(c, innerW) : this.offeredWidth(c, innerW);
      const h = c.height === "fill" ? clampH(c, innerH) : this.fitHeight(c, w);
      return [{ x: (innerW - w) / 2, y: (innerH - h) / 2, w, h }];
    }
    return [];
  }

  /**
   * Places `node` in `frame` ({x,y,w,h}) and everything below it; returns a
   * Map node -> frame, each relative to its parent's border box.
   */
  place(node, frame, out = new Map()) {
    out.set(node, frame);
    const p = padding(node);
    const iw = Math.max(0, frame.w - p.h), ih = Math.max(0, frame.h - p.v);
    const kids = childrenOf(node);
    if (kids.length) {
      const frames = this.childFrames(node, iw, ih);
      kids.forEach((kid, i) => this.place(kid, { ...frames[i], x: frames[i].x + p.l, y: frames[i].y + p.t }, out));
    }
    return out;
  }

  /** The root's frame on a stage: `min(maxWidth, stage width)` wide, centered, top-aligned when too tall. */
  rootFrame(root, stageW, stageH) {
    let w;
    w = isNum(root.width) ? clampW(root, root.width) : clampW(root, stageW);
    let h;
    if (isNum(root.height)) h = root.height;
    else if (root.height === "fill") h = stageH;
    else h = this.fitHeight(root, w);
    h = clampH(root, h);
    const y = h > stageH ? 0 : (stageH - h) / 2;
    return { x: (stageW - w) / 2, y, w, h };
  }
}

/** The popup card's frame: `min(width, stage)` wide, fit tall (at most the stage), centered. */
export function popupFrame(layout, node, popupWidth, stageW, stageH) {
  const w = Math.min(popupWidth, stageW);
  const h = Math.min(layout.fitHeight(node, w), stageH);
  return { x: (stageW - w) / 2, y: (stageH - h) / 2, w, h };
}
