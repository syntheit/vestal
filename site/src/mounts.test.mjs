// node --test site/src/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { gap, plan, motionFor, prefetchList, NEAR, FAR } from "./mounts.js";

const item = (id, d, extra = {}) => ({ id, d, live: false, pinned: false, seen: 0, ...extra });
const sorted = (xs) => [...xs].sort((a, b) => a - b);

test("gap: viewports between a box and the view", () => {
  assert.equal(gap(100, 300, 800), 0);         // inside
  assert.equal(gap(-50, 10, 800), 0);          // overlapping the top
  assert.equal(gap(1600, 1900, 800), 1);       // a viewport below
  assert.equal(gap(-1700, -100, 800), 0.125);  // above, its bottom 100px up
  assert.equal(gap(800, 900, 800), 0);         // touching the bottom edge is outside, at 0 viewports
});

test("plan: mount within NEAR, keep until FAR", () => {
  const items = [item(1, 0), item(2, 0.5), item(3, NEAR + 0.2), item(4, 1.5, { live: true }), item(5, FAR + 0.1, { live: true }), item(6, Infinity, { live: true })];
  const p = plan(items);
  assert.deepEqual(sorted(p.mount), [1, 2]);
  assert.deepEqual(sorted(p.unmount), [5, 6]);
});

test("plan: hysteresis, nothing flips between NEAR and FAR", () => {
  const p = plan([item(1, 1.5), item(2, 1.5, { live: true })]);
  assert.deepEqual(p, { mount: [], unmount: [] });
});

test("plan: the cap evicts the farthest live render", () => {
  const items = [item(1, 0.2, { live: true }), item(2, 0.9, { live: true }), item(3, 1.8, { live: true }), item(4, 0.1)];
  const p = plan(items, { cap: 3 });
  assert.deepEqual(p.mount, [4]);
  assert.deepEqual(p.unmount, [3]);
});

test("plan: among equals the one seen longest ago goes first", () => {
  const items = [item(1, 1.2, { live: true, seen: 100 }), item(2, 1.2, { live: true, seen: 50 }), item(3, 0.5)];
  assert.deepEqual(plan(items, { cap: 2 }).unmount, [2]);
});

test("plan: a candidate farther than every live render is not mounted at the cap", () => {
  const items = [item(1, 0.1, { live: true }), item(2, 0.2, { live: true }), item(3, 0.9)];
  assert.deepEqual(plan(items, { cap: 2 }), { mount: [], unmount: [] });
});

test("plan: on-screen and pinned renders stay past the cap", () => {
  const items = [item(1, 0, { live: true }), item(2, 0, { live: true }), item(3, 0), item(4, Infinity, { pinned: true, live: true }), item(5, 0.3, { live: true })];
  const p = plan(items, { cap: 2 });
  assert.deepEqual(p.mount, [3]);
  assert.deepEqual(p.unmount, [5]);
});

test("plan: a pinned render mounts wherever it is", () => {
  assert.deepEqual(plan([item(1, Infinity, { pinned: true })]).mount, [1]);
});

test("motionFor: only what is on screen moves", () => {
  assert.deepEqual(motionFor({ id: 1, d: 0, animates: true }), { visible: true, background: true, coarse: false });
  assert.equal(motionFor({ id: 1, d: 0.4, animates: true }).visible, false);
  assert.equal(motionFor({ id: 1, d: 0, animates: false }).background, false);
});

test("motionFor: a hidden tab and a lightbox hold the rest still", () => {
  assert.equal(motionFor({ id: 1, d: 0 }, { hidden: true }).visible, false);
  assert.equal(motionFor({ id: 1, d: 0 }, { focus: 2 }).visible, false);
  assert.equal(motionFor({ id: 2, d: 0 }, { focus: 2 }).visible, true);
});

test("motionFor: reduced motion and data saver: still backgrounds, coarse clocks", () => {
  assert.deepEqual(motionFor({ id: 1, d: 0, animates: true }, { quiet: true }), { visible: true, background: false, coarse: true });
});

test("prefetchList: the next previews after the live ones, without data", () => {
  const items = [
    { id: 1, live: true, loaded: true }, { id: 2, live: true, loaded: true },
    { id: 3, live: false, loaded: true }, { id: 4, live: false, loaded: false },
    { id: 5, live: false, loaded: false }, { id: 6, live: false, loaded: false },
  ];
  assert.deepEqual(prefetchList(items, 2), [4, 5]);
  assert.deepEqual(prefetchList(items.map((x) => ({ ...x, live: false }))), [4, 5, 6]);
});
