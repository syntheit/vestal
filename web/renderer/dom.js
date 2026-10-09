// Turns laid-out nodes into DOM: one absolutely positioned element per node
// (frames come from layout.js), kept between updates and reconciled by node id
// so a patch touches only what changed.

import { padding, childrenOf } from "./layout.js";
import { DRAWERS } from "./draw.js";
import { fontShorthand } from "./text.js";
import { glyphFor } from "./icons.js";
import { buildFlip, flipSet, changedTiles } from "./clock.js";

const px = (n) => `${Math.round(n * 1000) / 1000}px`;
const SKIP = new Set(["children", "center"]);
const CONTAINERS = new Set(["stack", "grid"]);

function signature(node, frame) {
  return JSON.stringify(node, (k, v) => (SKIP.has(k) ? undefined : v)) + `|${frame.w}|${frame.h}`;
}

/** The element for `node` inside its parent element, created or updated in place. */
export function syncNode(node, rctx, el) {
  const frame = rctx.frames.get(node);
  const type = rctx.layout.isKnown(node) ? node.type : "text";
  if (!el || el.__type !== type) {
    el = document.createElement("div");
    el.className = "vr-n";
    el.__type = type;
  }
  const { pal } = rctx;
  el.dataset.id = node.id;
  el.dataset.type = node.type;
  let css = `left:${px(frame.x)};top:${px(frame.y)};width:${px(frame.w)};height:${px(frame.h)};`;
  if (node.background) css += `background:${pal.css(node.background)};`;
  if (node.radius) css += `border-radius:${px(node.radius)};`;
  if (node.border && node.border.width > 0) css += `box-shadow:inset 0 0 0 ${px(node.border.width)} ${pal.css(node.border.color)};`;
  if (node.opacity != null && node.opacity < 1) css += `opacity:${Math.max(0, node.opacity)};`;
  if (node.clip) css += "overflow:hidden;";
  el.style.cssText = css;
  if (node.action) { el.dataset.invoke = node.id; el.classList.add("vr-action"); }
  else { delete el.dataset.invoke; el.classList.remove("vr-action"); }

  const kids = childrenOf(node);
  if (!CONTAINERS.has(node.type) || kids.length === 0) syncLeaf(node, frame, rctx, el, type);
  else if (el.__leaf) { el.__leaf.remove(); el.__leaf = null; el.__sig = null; }

  // Children, in order, reusing elements by id.
  const old = new Map();
  for (const c of [...el.children]) if (c !== el.__leaf && c.dataset && c.dataset.id) old.set(c.dataset.id, c);
  let anchor = el.__leaf || null;
  const keep = new Set();
  for (const kid of kids) {
    const kidEl = syncNode(kid, rctx, old.get(kid.id));
    keep.add(kidEl);
    const next = anchor ? anchor.nextSibling : el.firstChild;
    if (kidEl !== next) el.insertBefore(kidEl, next);
    anchor = kidEl;
  }
  for (const c of old.values()) if (!keep.has(c)) c.remove();
  return el;
}

function leafBox(el, node, frame) {
  const p = padding(node);
  const box = document.createElement("div");
  box.className = "vr-leaf";
  box.style.cssText = `left:${px(p.l)};top:${px(p.t)};width:${px(Math.max(0, frame.w - p.h))};height:${px(Math.max(0, frame.h - p.v))};`;
  return box;
}

function syncLeaf(node, frame, rctx, el, type) {
  if (type === "spacer") { if (el.__leaf) { el.__leaf.remove(); el.__leaf = null; el.__sig = null; } return; }
  if (type === "flip") return flipLeaf(node, frame, rctx, el);
  const sig = signature(node, frame);
  if (el.__sig === sig) return;
  el.__sig = sig;
  if (el.__leaf) el.__leaf.remove();
  const box = leafBox(el, node, frame);
  const p = padding(node);
  const iw = Math.max(0, frame.w - p.h), ih = Math.max(0, frame.h - p.v);
  if (type === "text") textLeaf(box, rctx.layout.textNode(node), iw, rctx);
  else if (type === "icon") iconLeaf(box, node, rctx);
  else if (type === "image") imageLeaf(box, node, rctx);
  else if (DRAWERS[type]) drawingLeaf(box, node, type, iw, ih, rctx);
  el.insertBefore(box, el.firstChild);
  el.__leaf = box;
}

/**
 * Split-flap tiles. The tile elements stay between updates so a changed
 * character folds over (drawn once per structure: the same number of tiles
 * at the same size); a different shape rebuilds them.
 */
function flipLeaf(node, frame, rctx, el) {
  const shape = JSON.stringify([node.size, node.smallSize, node.color, node.tile, node.tileBottom, [...(node.text || "")].map((c) => (c === ":" || c === " " ? c : "d")), [...(node.small || "")].length, frame.w, frame.h]);
  const chars = (n) => [...(n.text || "")].filter((c) => c !== ":" && c !== " ").concat([...(n.small || "")].filter((c) => c !== ":" && c !== " "));
  const now = chars(node);
  if (el.__flip && el.__flipShape === shape) {
    const old = el.__flip.tiles;
    const animate = node.animate !== false && !rctx.reduced;
    const before = [...old.values()].map((t) => t.value);
    for (const index of changedTiles(before, now)) flipSet(old.get(index), now[index], animate);
    return;
  }
  if (el.__leaf) el.__leaf.remove();
  const box = leafBox(el, node, frame);
  const built = buildFlip(box, node, rctx.drawEnv);
  el.insertBefore(box, el.firstChild);
  el.__leaf = box;
  el.__flip = built;
  el.__flipShape = shape;
  el.__sig = null;
}

function textLeaf(box, node, iw, rctx) {
  const { measurer, theme, pal } = rctx;
  const m = measurer.measureText(node, iw);
  const natural = measurer.measureText(node, null);
  const align = node.textAlign || "start";
  box.style.display = "flex";
  box.style.alignItems = "center";
  box.style.justifyContent = align === "center" ? "center" : align === "end" ? "flex-end" : "flex-start";
  const t = document.createElement("div");
  t.className = "vr-text";
  t.textContent = node.text ?? "";
  let css = `font:${fontShorthand(node, theme)};color:${pal.css(node.color, "text")};line-height:${px(m.lineHeight)};text-align:${align === "start" ? "left" : align === "end" ? "right" : "center"};`;
  if (node.tracking) css += `letter-spacing:${px(node.tracking)};`;
  const oneLine = m.height <= m.lineHeight + 0.01;
  if (oneLine) {
    css += "white-space:pre;max-width:100%;";
    // Cut at the tail only when it really doesn't fit (not on a sub-pixel difference).
    if (natural.width > iw + 0.5) css += "overflow:hidden;text-overflow:ellipsis;";
  } else {
    css += `white-space:pre-wrap;overflow-wrap:anywhere;width:${px(iw + 0.5)};max-width:100%;`;
    if (node.lines != null && natural.width > iw) {
      css += `display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:${Math.max(1, node.lines)};overflow:hidden;`;
    }
  }
  t.style.cssText = css;
  box.appendChild(t);
}

function iconLeaf(box, node, rctx) {
  const { theme, pal } = rctx;
  const weight = node.weight === "fill" ? "fill" : "regular";
  const glyph = node.glyph || glyphFor(node.name, weight);
  if (!glyph) return; // an `sf:` name: nothing, as off macOS
  const fonts = (theme.icons && theme.icons.fonts) || {};
  const family = fonts[weight] || (weight === "fill" ? "Phosphor-Fill" : "Phosphor");
  box.style.display = "flex";
  box.style.alignItems = "center";
  box.style.justifyContent = "center";
  const g = document.createElement("div");
  g.className = "vr-glyph";
  g.textContent = glyph;
  g.style.cssText = `font-family:"${family}";font-size:${px(node.size ?? 13)};color:${pal.css(node.color, "text")};`;
  box.appendChild(g);
}

function imageLeaf(box, node, rctx) {
  const radius = px(node.radius ?? 6);
  const url = rctx.resolveImage ? rctx.resolveImage(node.path) : null;
  if (url) {
    const img = document.createElement("img");
    img.src = url;
    img.alt = node.alt || "";
    img.draggable = false;
    img.style.cssText = `width:100%;height:100%;display:block;object-fit:${node.fit === "contain" ? "contain" : "cover"};border-radius:${radius};`;
    box.appendChild(img);
  } else {
    box.style.background = rctx.pal.css("track");
    box.style.borderRadius = radius;
  }
}

function drawingLeaf(box, node, type, iw, ih, rctx) {
  const markup = DRAWERS[type](node, iw, ih, rctx.drawEnv);
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("width", String(iw));
  svg.setAttribute("height", String(ih));
  svg.setAttribute("viewBox", `0 0 ${iw} ${ih}`);
  svg.style.cssText = "display:block;overflow:visible;";
  svg.innerHTML = markup;
  box.appendChild(svg);
}
