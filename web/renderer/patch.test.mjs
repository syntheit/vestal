import test from "node:test";
import assert from "node:assert/strict";
import { applyPatch, findNode } from "./patch.js";

const snapshot = () => ({
  type: "snapshot", seq: 1, view: "main",
  root: { id: "main", type: "stack", children: [
    { id: "main/a", type: "text", text: "one" },
    { id: "main/b", type: "stack", children: [{ id: "main/b/0", type: "text", text: "deep" }] },
    { id: "main/r", type: "ring", center: { id: "main/r/c", type: "text", text: "50%" } },
  ] },
  popup: null, theme: { colors: {} }, views: [{ name: "main" }], diagnostics: [],
});

test("replace swaps a subtree by id, at any depth and in a ring's center", () => {
  const s = snapshot();
  const r = applyPatch(s, { base: 1, seq: 2, ops: [
    { op: "replace", id: "main/b/0", node: { id: "main/b/0", type: "text", text: "changed" } },
    { op: "replace", id: "main/r/c", node: { id: "main/r/c", type: "text", text: "75%" } },
    { op: "replace", id: "main/a", node: { id: "main/a", type: "text", text: "two" } },
  ] });
  assert.equal(r.ok, true);
  assert.equal(s.seq, 2);
  assert.equal(s.root.children[1].children[0].text, "changed");
  assert.equal(s.root.children[2].center.text, "75%");
  assert.equal(s.root.children[0].text, "two");
  assert.ok(r.changed.has("root"));
});

test("a base that is not the last seq asks for a resync and changes nothing", () => {
  const s = snapshot();
  const r = applyPatch(s, { base: 5, seq: 6, ops: [{ op: "popup", popup: { id: "popup", width: 10, node: { id: "popup", type: "text" } } }] });
  assert.equal(r.ok, false);
  assert.equal(s.seq, 1);
  assert.equal(s.popup, null);
});

test("an unknown id asks for a resync", () => {
  const s = snapshot();
  const r = applyPatch(s, { base: 1, seq: 2, ops: [{ op: "replace", id: "nope", node: { id: "nope", type: "text" } }] });
  assert.equal(r.ok, false);
});

test("root, popup, theme, views and diagnostics ops apply in order", () => {
  const s = snapshot();
  const popup = { id: "popup", width: 520, node: { id: "popup", type: "stack", children: [{ id: "popup/0", type: "text", text: "p" }] } };
  const r = applyPatch(s, { base: 1, seq: 2, ops: [
    { op: "popup", popup },
    { op: "replace", id: "popup/0", node: { id: "popup/0", type: "text", text: "q" } },
    { op: "theme", theme: { colors: { text: "#000000ff" } } },
    { op: "views", views: [{ name: "x" }] },
    { op: "diagnostics", diagnostics: [{ id: "a" }] },
    { op: "root", node: { id: "focus", type: "stack", children: [] }, view: "focus" },
    { op: "future-op", whatever: 1 },
  ] });
  assert.equal(r.ok, true);
  assert.equal(s.popup.node.children[0].text, "q");
  assert.equal(s.theme.colors.text, "#000000ff");
  assert.equal(s.views[0].name, "x");
  assert.equal(s.diagnostics.length, 1);
  assert.equal(s.root.id, "focus");
  assert.equal(s.view, "focus");
  assert.ok(r.changed.has("view") && r.changed.has("popup") && r.changed.has("theme"));
});

test("replacing the popup's own root keeps its width", () => {
  const s = snapshot();
  s.popup = { id: "popup", width: 300, node: { id: "popup", type: "text", text: "a" } };
  applyPatch(s, { base: 1, seq: 2, ops: [{ op: "replace", id: "popup", node: { id: "popup", type: "text", text: "b" } }] });
  assert.equal(s.popup.width, 300);
  assert.equal(s.popup.node.text, "b");
});

test("findNode returns parent and slot", () => {
  const s = snapshot();
  const hit = findNode(s.root, "main/b/0");
  assert.equal(hit.parent.id, "main/b");
  assert.equal(hit.slot, "children");
  assert.equal(findNode(s.root, "main/r/c").slot, "center");
  assert.equal(findNode(s.root, "x"), null);
});
