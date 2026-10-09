// Applying render-model patches (docs/reference/render-model.md "Patches").
// Pure: operates on plain JSON, no DOM.

/** Finds the first node with `id` under `node`; returns { node, parent, index, slot } or null. */
export function findNode(node, id, parent = null, index = -1, slot = null) {
  if (!node) return null;
  if (node.id === id) return { node, parent, index, slot };
  if (Array.isArray(node.children)) {
    for (let i = 0; i < node.children.length; i++) {
      const hit = findNode(node.children[i], id, node, i, "children");
      if (hit) return hit;
    }
  }
  if (node.center) {
    const hit = findNode(node.center, id, node, -1, "center");
    if (hit) return hit;
  }
  return null;
}

/** Replaces the subtree `id` in the snapshot (root first, then the popup); false when absent. */
function replaceNode(snapshot, id, node) {
  const roots = [["root", snapshot.root], ["popup", snapshot.popup && snapshot.popup.node]];
  for (const [which, tree] of roots) {
    const hit = findNode(tree, id);
    if (!hit) continue;
    if (!hit.parent) {
      if (which === "root") snapshot.root = node;
      else snapshot.popup = { ...snapshot.popup, node };
    } else if (hit.slot === "center") hit.parent.center = node;
    else hit.parent.children[hit.index] = node;
    return true;
  }
  return false;
}

/**
 * Applies `patch` to `snapshot` in place. Returns { ok: true, changed } or
 * { ok: false, reason } when the caller should ask for a fresh snapshot
 * (a `base` that is not the last `seq` applied, or an unknown node id).
 * `changed` names what moved: "root", "popup", "theme", "views", "diagnostics",
 * "view" (the view name changed).
 */
export function applyPatch(snapshot, patch) {
  if (patch.base !== snapshot.seq) return { ok: false, reason: "base" };
  const changed = new Set();
  for (const op of patch.ops || []) {
    switch (op.op) {
      case "replace":
        if (!replaceNode(snapshot, op.id, op.node)) return { ok: false, reason: `unknown id ${op.id}` };
        changed.add(snapshot.popup && findNode(snapshot.popup.node, op.node.id) ? "popup" : "root");
        break;
      case "root":
        snapshot.root = op.node;
        if (op.view !== undefined && op.view !== snapshot.view) { snapshot.view = op.view; changed.add("view"); }
        changed.add("root");
        break;
      case "popup": snapshot.popup = op.popup; changed.add("popup"); break;
      case "theme": snapshot.theme = op.theme; changed.add("theme"); break;
      case "views": snapshot.views = op.views; changed.add("views"); break;
      case "diagnostics": snapshot.diagnostics = op.diagnostics; changed.add("diagnostics"); break;
      default: break; // clients ignore ops they don't know
    }
  }
  snapshot.seq = patch.seq;
  return { ok: true, changed };
}
