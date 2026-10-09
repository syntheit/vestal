import test from "node:test";
import assert from "node:assert/strict";
import {
  analogTime, handAngles, analogGeometry, analogTicks, polar, flipLayout, colonSquares, changedTiles, ringGeometry, analogSVG,
} from "./clock.js";
import { makePalette } from "./color.js";

const close = (a, b, eps = 1e-9) => assert.ok(Math.abs(a - b) < eps, `${a} != ${b}`);
const NOW = new Date("2026-09-27T17:03:22Z");

test("hand angles move continuously", () => {
  const a = handAngles({ hour: 10, minute: 10, second: 30 }, "sweep");
  close(a.second, 180);
  close(a.minute, (10 + 0.5) * 6);
  close(a.hour, (10 + 10 / 60 + 30 / 3600) * 30);
  close(handAngles({ hour: 15, minute: 0, second: 0 }, "none").hour, 90);
  close(handAngles({ hour: 1, minute: 2, second: 3.75 }, "step").second, 18);
  close(handAngles({ hour: 1, minute: 2, second: 3.75 }, "sweep").second, 22.5);
});

test("time in a zone", () => {
  const tokyo = analogTime(NOW, "Asia/Tokyo");
  assert.equal(tokyo.hour, 2);
  assert.equal(tokyo.minute, 3);
  assert.equal(tokyo.day, 28);
  assert.equal(analogTime(NOW, "UTC").hour, 17);
});

test("polar is clockwise from twelve", () => {
  const [x, y] = polar(100, 100, 50, 90);
  close(x, 150);
  close(y, 100);
});

test("geometry matches the native renderers", () => {
  const q = analogGeometry(236, "none", "none", false, false);
  assert.deepEqual(q.hour, { length: 58, tail: 0, width: 5 });
  assert.equal(q.second, null);
  const g = analogGeometry(260, "minutes", "sweep", true, false);
  assert.equal(analogTicks(g).length, 60);
  assert.equal(analogTicks(g).filter((t) => t.major).length, 12);
  assert.equal(g.window.x, 188);
  assert.equal(g.tickOuter, 123);
  close(analogGeometry(130, "minutes", "sweep", false, false).minute.length, 51);
});

test("flip layout of a time with seconds", () => {
  const l = flipLayout("10:42", "07", 90, 40);
  assert.equal(l.tileCount, 6);
  assert.equal(l.height, 114);
  assert.equal(l.width, 4 * 80 + 21 + 4 * 6 + 14 + 2 * 36 + 3);
  const tiles = l.items.filter((i) => i.kind === "tile");
  assert.equal(tiles[2].x, 80 + 6 + 80 + 6 + 21 + 6);
  assert.equal(tiles[4].y, 114 - 52);
  assert.deepEqual(colonSquares(114, 1), { y: [19, 50], side: 9 });
});

test("only changed tiles fold", () => {
  assert.deepEqual(changedTiles(["1", "7", "0", "3"], ["1", "7", "0", "4"]), [3]);
  assert.deepEqual(changedTiles(["1", "7"], ["1", "7"]), []);
  assert.deepEqual(changedTiles([], ["1"]), []);
  assert.deepEqual(changedTiles(["1"], ["1", "2"]), []);
});

test("ring geometry", () => {
  const plain = ringGeometry(64, { thickness: 6 });
  assert.equal(plain.radius, 29);
  close(plain.start, Math.PI / 2 + (2 * Math.PI - (270 * Math.PI) / 180) / 2);
  const full = ringGeometry(272, { sweep: 360, thickness: 5, ticks: 24 });
  close(full.start, -Math.PI / 2);
  assert.equal(full.radius, 121);
  close(full.angle(0.25), 0);
  assert.ok(full.isMajor(6) && !full.isMajor(5));
});

test("analog markup carries the hands and the fixed time", () => {
  const env = { pal: makePalette({}), theme: {}, now: NOW, timeZone: "UTC" };
  const svg = analogSVG({ size: 260, ticks: "minutes", seconds: "sweep", dateWindow: true }, 260, 260, env);
  assert.match(svg, /data-hand="h"/);
  assert.match(svg, /data-hand="s"/);
  assert.match(svg, /data-mode="sweep"/);
  assert.match(svg, />27</);
  assert.equal((svg.match(/<line /g) || []).length, 60 + 3);
});
