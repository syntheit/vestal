// node --test web/renderer/*.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { Layout, gridCells, heatmapPosition, heatmapColumns, popupFrame } from "./layout.js";
import { wrapLines } from "./text.js";

// A fixed-pitch fake: every character is size/2 wide, a line is 1.2 * size tall.
const measureText = (node, maxWidth) => {
  const size = node.size ?? 13;
  const w = (s) => s.length * size * 0.5;
  const lh = size * 1.2;
  if (maxWidth == null) {
    const parts = String(node.text).split("\n");
    return { width: Math.max(...parts.map(w)), height: lh * parts.length, baseline: size, lineHeight: lh };
  }
  const { lines } = wrapLines(node.text, maxWidth, w, node.lines ?? null);
  return { width: Math.min(Math.max(...lines.map(w)), maxWidth), height: lh * lines.length, baseline: size, lineHeight: lh };
};

const t = (id, text, extra = {}) => ({ id, type: "text", text, size: 10, ...extra });
const stack = (id, axis, children, extra = {}) => ({ id, type: "stack", axis, children, ...extra });
const place = (root, w, h) => {
  const lay = new Layout(root, { measureText });
  const frames = lay.place(root, lay.rootFrame(root, w, h));
  return { lay, frames, f: (n) => frames.get(n) };
};

test("a fit row places children with the gap, centred across", () => {
  const a = t("a", "abcd"), b = t("b", "ef", { size: 20 });
  const row = stack("r", "h", [a, b], { gap: 7, align: "center" });
  const { f } = place(row, 500, 300);
  // a: 4 * 5 = 20 wide, 12 tall; b: 2 * 10 = 20 wide, 24 tall. Row: 47 x 24.
  assert.equal(f(row).w, 500); // an unsized root takes the stage width
  assert.equal(f(row).h, 24);
  assert.deepEqual([f(a).x, f(a).y, f(a).w, f(a).h], [0, 6, 20, 12]);
  assert.deepEqual([f(b).x, f(b).y, f(b).w, f(b).h], [27, 0, 20, 24]);
});

test("fill children share the leftover, fixed ones are exact, spaceBefore replaces the gap", () => {
  const fixed = { id: "f", type: "spacer", width: 40, height: 10 };
  const fill1 = { id: "g1", type: "spacer", width: "fill", height: 10 };
  const fill2 = { id: "g2", type: "spacer", width: "fill", height: 10 };
  const after = { id: "s", type: "spacer", width: 10, height: 10, spaceBefore: 0 };
  const row = stack("r", "h", [fixed, fill1, fill2, after], { gap: 10, width: 200 });
  const { f } = place(row, 500, 300);
  // used: 40 + gaps (10 + 10 + 0) + 10 = 70; the two fills split 130.
  assert.equal(f(fill1).w, 65);
  assert.equal(f(fill2).w, 65);
  assert.equal(f(fill1).x, 50);
  assert.equal(f(after).x, 190);
});

test("a column: stretch makes a child as wide as the stack, end aligns right", () => {
  const a = t("a", "xx"), b = t("b", "yyyy", { alignSelf: "stretch" }), c = t("c", "z", { alignSelf: "end" });
  const col = stack("c", "v", [a, b, c], { gap: 4, width: 100 });
  const { f } = place(col, 500, 500);
  assert.equal(f(b).w, 100);
  assert.equal(f(c).x, 95);
  assert.equal(f(a).y, 0);
  assert.equal(f(b).y, 12 + 4);
});

test("the root is centred, capped by maxWidth, padded inside", () => {
  const child = t("a", "hello");
  const root = stack("main", "v", [child], { maxWidth: 200, padding: [10, 20, 10, 20], width: "fill" });
  const { f } = place(root, 600, 400);
  assert.deepEqual(f(root), { x: 200, y: 400 / 2 - (12 + 20) / 2, w: 200, h: 32 });
  assert.deepEqual([f(child).x, f(child).y], [20, 10]);
});

test("content taller than the window is top-aligned and cut at the bottom", () => {
  const root = stack("m", "v", [{ id: "s", type: "spacer", height: 900, width: 10 }]);
  const { f } = place(root, 300, 400);
  assert.equal(f(root).y, 0);
  assert.equal(f(root).h, 900);
});

test("text wraps to the offered width and lines caps it", () => {
  const long = t("a", "aa bb cc dd ee", { width: 30 }); // 6 chars per line: "aa bb", "cc dd", "ee"
  const col = stack("c", "v", [long]);
  const { f } = place(col, 300, 300);
  assert.equal(f(long).h, 36);
  const capped = t("b", "aa bb cc dd ee", { width: 30, lines: 2 });
  const { f: g } = place(stack("c2", "v", [capped]), 300, 300);
  assert.equal(g(capped).h, 24);
});

test("an overflowing row squeezes truncating texts, down to their size", () => {
  const a = t("a", "abcdefghij", { lines: 1 }); // 50 wide
  const b = { id: "b", type: "spacer", width: 80, height: 5 };
  const row = stack("r", "h", [a, b], { width: 100 });
  const { f } = place(row, 500, 100);
  assert.equal(f(a).w, 20); // 100 - 80
  assert.equal(f(b).x, 20);
});

test("baseline alignment lines up first baselines", () => {
  const small = t("s", "ab", { size: 10 }), big = t("g", "ab", { size: 30 });
  const row = stack("r", "h", [small, big], { align: "baseline" });
  const { f } = place(row, 300, 300);
  // baselines are `size` below each text's top
  assert.equal(f(small).y + 10, f(big).y + 30);
});

test("a grid: fixed, fit and fill columns, spans, the row as tall as its tallest cell", () => {
  const cells = [t("a", "ab"), t("b", "cdef"), t("c", "gh"), t("d", "ij", { span: 1, size: 20 }), t("e", "kl"), t("f", "mn")];
  const grid = { id: "g", type: "grid", gap: 5, rowGap: 3, columns: [{ width: 30 }, { width: "fit" }, { width: "fill", align: "end" }], children: cells };
  const { f } = place(grid, 200, 200);
  // widths: 30, widest of (cdef=20, ij=20 -> wait col1 holds b and e): fit = 20, fill = 200 - 30 - 20 - 10 = 140
  assert.equal(f(cells[1]).x, 35);
  assert.equal(f(cells[2]).x, 60 + 140 - 10); // end aligned, 2 chars * 5 = 10 wide
  // row 0 is 12 tall, row 1 is 24 tall (the size 20 text), cells centred vertically
  assert.equal(f(cells[3]).y, 12 + 3);
  assert.equal(f(cells[4]).y, 12 + 3 + (24 - 12) / 2);
});

test("grid spans share columns and a span never widens a fit column", () => {
  assert.deepEqual(gridCells([{ span: 2 }, { span: 1 }, { span: 3 }, { span: 1 }], 3), [
    { row: 0, column: 0, span: 2 }, { row: 0, column: 2, span: 1 },
    { row: 1, column: 0, span: 3 }, { row: 2, column: 0, span: 1 },
  ]);
});

test("box size: min/max clamp, padding is inside, fixed sizes win", () => {
  const box = { id: "b", type: "spacer", width: 10, height: 10, padding: [1, 2, 3, 4], minWidth: 30, maxHeight: 5 };
  const lay = new Layout(box, { measureText });
  assert.equal(lay.fitWidth(box), 30);
  assert.equal(lay.fitHeight(box, 30), 5);
  const text = t("t", "abcd", { padding: [2, 3, 2, 3], maxWidth: 20 });
  const lay2 = new Layout(text, { measureText });
  assert.equal(lay2.fitWidth(text), 20);
  assert.equal(lay2.fitHeight(text, 26), 12 + 4);
});

test("ring: centred child, square by default", () => {
  const center = t("c", "50%");
  const ring = { id: "r", type: "ring", width: 80, center, value: 0.5 };
  const { f } = place(stack("s", "v", [ring], { align: "start" }), 300, 300);
  assert.equal(f(ring).w, 80);
  assert.equal(f(ring).h, 80);
  assert.deepEqual([f(center).x, f(center).w], [(80 - 15) / 2, 15]);
});

test("heatmap geometry", () => {
  const h = { type: "heatmap", cells: new Array(10).fill(null), rows: 4 };
  assert.equal(heatmapColumns(h), 3);
  assert.deepEqual(heatmapPosition(h, 5), { column: 1, row: 1 });
  assert.deepEqual(heatmapPosition({ ...h, direction: "rows" }, 5), { column: 2, row: 1 });
  const lay = new Layout(h, { measureText });
  assert.equal(lay.fitWidth(h), 3 * 8 + 2 * 2);
  assert.equal(lay.fitHeight(h, 28), 4 * 8 + 3 * 2);
});

test("popup card frame is centred and capped by the stage", () => {
  const body = stack("p", "v", [t("a", "hello")]);
  const lay = new Layout(body, { measureText });
  assert.deepEqual(popupFrame(lay, body, 100, 400, 300), { x: 150, y: 144, w: 100, h: 12 });
  assert.equal(popupFrame(lay, body, 900, 400, 300).w, 400);
});

test("wrapLines breaks long words and reports truncation", () => {
  const w = (s) => s.length;
  assert.deepEqual(wrapLines("abcdefgh", 3, w).lines, ["abc", "def", "gh"]);
  const r = wrapLines("a b c d e f", 3, w, 2);
  assert.equal(r.lines.length, 2);
  assert.equal(r.truncated, true);
  assert.deepEqual(wrapLines("a\nb", 10, w).lines, ["a", "b"]);
});
