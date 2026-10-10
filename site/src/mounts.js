// Which previews on a page hold a live render, and which of those move.
//
// A preview mounts its render when it comes within a viewport of the visible
// area, and gives it up (renderer destroyed, DOM freed, timers stopped) once
// it is more than two viewports away; its frame keeps its size, so nothing
// shifts. At most CAP renders are live at once: past that, the farthest go
// first, and among equals the one seen longest ago. Only renders on screen
// move (their clocks tick, and a background animates where the preview asks
// for it); a hidden tab, an open lightbox (for everything behind it), reduced
// motion and the data saver hold them still.
//
// `plan` and `motionFor` are pure, for tests (site/src/mounts.test.mjs);
// `MountManager` feeds them from IntersectionObservers.

export const NEAR = 1;   // viewports: mount within this distance
export const FAR = 2;    // viewports: unmount beyond this
export const CAP = 16;   // live renders at most (on-screen and pinned ones never count against it)

/** Viewports between a box (client top and bottom) and the view [0, vh]: 0 when they overlap. */
export function gap(top, bottom, vh) {
  if (bottom > 0 && top < vh) return 0;
  return (top >= vh ? top - vh : -bottom) / vh;
}

/**
 * Which previews to mount and unmount. `items`: [{ id, d (viewports away; 0
 * on screen, Infinity when not laid out), live, pinned, seen (when last on
 * screen) }]. Returns { mount: [id], unmount: [id] }.
 */
export function plan(items, { near = NEAR, far = FAR, cap = CAP } = {}) {
  const want = items.filter((it) => it.pinned || it.d === 0 || it.d <= (it.live ? far : near));
  want.sort((a, b) => (b.pinned - a.pinned) || (a.d - b.d) || ((b.seen || 0) - (a.seen || 0)));
  const keep = new Set();
  for (const it of want) if (it.pinned || it.d === 0 || keep.size < cap) keep.add(it.id);
  return {
    mount: items.filter((it) => !it.live && keep.has(it.id)).map((it) => it.id),
    unmount: items.filter((it) => it.live && !keep.has(it.id)).map((it) => it.id),
  };
}

/**
 * How a live render moves. `it`: { id, d, animates (its background may move) };
 * `env`: { hidden (the tab), focus (the id that alone moves, for a lightbox),
 * quiet (reduced motion or data saver) }.
 */
export function motionFor(it, { hidden = false, focus = null, quiet = false } = {}) {
  const visible = it.d === 0 && !hidden && (focus == null || focus === it.id);
  return { visible, background: !!it.animates && !quiet, coarse: !!quiet };
}

/** The next few previews after the live ones, in page order, that have no data yet. */
export function prefetchList(items, count = 4) {
  let last = -1;
  items.forEach((it, i) => { if (it.live) last = i; });
  return items.slice(last + 1).filter((it) => !it.loaded).slice(0, count).map((it) => it.id);
}

// MARK: - DOM

const framed = () => { try { return window.self !== window.top; } catch { return true; } };
const idle = (fn) => (typeof requestIdleCallback === "function" ? requestIdleCallback(fn, { timeout: 2000 }) : setTimeout(fn, 200));

/**
 * Feeds `plan` from three IntersectionObservers (on screen, within NEAR,
 * within FAR viewports). A preview is added with
 *   add(el, { mount(), unmount(), setMotion(m), prefetch(), loaded(), animates, pinned })
 * and its `mount`/`unmount` are called as it comes near and goes away.
 */
export class MountManager {
  constructor({ cap = CAP, eager = false } = {}) {
    this.cap = cap;
    this.eager = eager || typeof IntersectionObserver !== "function";
    this.items = [];        // page order
    this.byEl = new Map();
    this.focusId = null;
    this.next = 1;
    this.queued = false;
    const mq = typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : null;
    const conn = typeof navigator !== "undefined" ? navigator.connection : null;
    this.saveData = () => !!(conn && conn.saveData);
    this.quiet = () => !!((mq && mq.matches) || this.saveData());
    if (mq && mq.addEventListener) mq.addEventListener("change", () => this.moveAll());
    if (conn && conn.addEventListener) conn.addEventListener("change", () => this.moveAll());
    if (typeof document !== "undefined") document.addEventListener("visibilitychange", () => this.moveAll());
    if (this.eager) return;
    const watch = (key, margin) => new IntersectionObserver((entries) => {
      for (const e of entries) {
        const it = this.byEl.get(e.target);
        if (!it) continue;
        it[key] = e.isIntersecting;
        if (key === "vis" && e.isIntersecting) it.seen = performance.now();
      }
      this.schedule();
    // In a frame the implicit root ignores rootMargin; the document as root keeps it.
    }, { rootMargin: margin, ...(framed() ? { root: document } : {}) });
    this.ios = [watch("vis", "0px"), watch("near", `${NEAR * 100}% 0px`), watch("far", `${FAR * 100}% 0px`)];
  }

  add(el, h) {
    const it = { id: this.next++, el, h, live: false, vis: false, near: false, far: false, seen: 0, pinned: !!h.pinned, animates: !!h.animates };
    this.items.push(it);
    this.byEl.set(el, it);
    if (this.eager) { this.mountItem(it); return it; }
    for (const io of this.ios) io.observe(el);
    if (it.pinned) this.mountItem(it);
    return it;
  }

  remove(it) {
    if (!it || !this.byEl.has(it.el)) return;
    if (this.ios) for (const io of this.ios) io.unobserve(it.el);
    this.byEl.delete(it.el);
    this.items.splice(this.items.indexOf(it), 1);
    if (this.focusId === it.id) this.focus(null);
  }

  /** Only `it` moves (a lightbox over the page), or everything again with null. */
  focus(it) {
    this.focusId = it ? it.id : null;
    this.moveAll();
  }

  schedule() {
    if (this.queued) return;
    this.queued = true;
    Promise.resolve().then(() => { this.queued = false; this.flush(); });
  }

  distance(it) {
    if (this.eager) return 0;
    if (it.vis) return 0;
    if (!it.far) return Infinity;
    const r = it.el.getBoundingClientRect();
    if (!r.width && !r.height) return Infinity;
    // Off screen by the observer's word: never 0 here; near by its word: at most NEAR
    // (its root and innerHeight can differ by a toolbar on a phone).
    const d = Math.max(1e-3, gap(r.top, r.bottom, innerHeight || 1));
    return it.near ? Math.min(d, NEAR) : d;
  }

  flush() {
    for (const it of this.items) it.d = this.distance(it);
    const { mount, unmount } = plan(this.items, { cap: this.cap });
    const byId = new Map(this.items.map((it) => [it.id, it]));
    for (const id of unmount) this.unmountItem(byId.get(id));
    for (const id of mount) this.mountItem(byId.get(id));
    this.moveAll();
    this.prefetch();
  }

  mountItem(it) {
    if (it.live) return;
    it.live = true;
    if (it.d == null) it.d = this.distance(it);
    try { it.h.mount(this.motion(it)); } catch (err) { console.error("vestal site:", err); }
  }

  unmountItem(it) {
    if (!it.live) return;
    it.live = false;
    it.h.unmount();
  }

  motion(it) {
    return motionFor(it, { hidden: typeof document !== "undefined" && document.hidden, focus: this.focusId, quiet: this.quiet() });
  }

  moveAll() {
    for (const it of this.items) if (it.live && it.h.setMotion) it.h.setMotion(this.motion(it));
  }

  prefetch() {
    if (this.eager || this.prefetching || this.saveData()) return;
    const list = this.items.filter((it) => !it.pinned).map((it) => ({ id: it.id, live: it.live, loaded: !it.h.loaded || it.h.loaded() }));
    const ids = prefetchList(list);
    if (!ids.length) return;
    this.prefetching = true;
    idle(() => {
      this.prefetching = false;
      for (const it of this.items) if (ids.includes(it.id) && it.h.prefetch) it.h.prefetch();
    });
  }

  /** What the page holds now (for checks): live renders and how many move. */
  stats() {
    return { previews: this.items.length, live: this.items.filter((it) => it.live).length, moving: this.items.filter((it) => it.live && this.motion(it).visible).length };
  }
}
