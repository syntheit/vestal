// Pages: which view a step leads to, what a change of view looks like, and the
// swipe state machine. A port of VestalCore/Render/Pages.swift, so the web UI
// pages the way the native ones do. Pure: no DOM.

export const SLIDE_MS = 250;
export const FADE_MS = 180;

/** The page `step` away from the current one (a view name), or null at an end without `wrap` / when not a page. */
export function neighbor(pages, step) {
  if (!pages || pages.index == null || !pages.items || pages.items.length < 2) return null;
  const n = pages.items.length;
  const target = pages.index + step;
  if (target >= 0 && target < n) return pages.items[target].name;
  if (!pages.wrap) return null;
  return pages.items[((target % n) + n) % n].name;
}

/** What a UI draws for a change of view: "slide", "fade" or "none". */
export function transitionKind(transition, direction, reduceMotion) {
  switch (transition) {
    case "none": return "none";
    case "fade": return "fade";
    default: return reduceMotion || !direction ? "fade" : "slide";
  }
}

export const showsDots = (pages) => !!pages && pages.indicator !== "none" && (pages.indicator || "dots") === "dots" && (pages.items || []).length > 1;

/**
 * A two-finger or pointer horizontal swipe. Feed it finger movement and the
 * phase; it answers { type: "passThrough" | "drag" | "commit" | "cancel", ... }.
 * Deltas are finger movement: positive moves the page right, revealing the
 * previous one. `time` is in seconds.
 */
export class PageSwipe {
  static dominance = 1.5;
  static lockDistance = 6;
  static maxOffsetFraction = 0.2;
  static commitFraction = 0.12;
  static flickVelocity = 500;
  static flickDistance = 24;

  constructor({ width, canGoPrevious, canGoNext }) {
    this.width = width;
    this.canGoPrevious = canGoPrevious;
    this.canGoNext = canGoNext;
    this.lock = "finished";
    this.x = 0; this.y = 0;
    this.samples = [];
  }

  get isDragging() { return this.lock === "horizontal"; }

  /** The page offset for `total` finger travel (resistance, stiffer where there is no page). */
  offset(total) {
    const limit = this.width * PageSwipe.maxOffsetFraction;
    const available = total < 0 ? this.canGoNext : this.canGoPrevious;
    const reach = limit * (available ? 1 : 0.35);
    return (total < 0 ? -1 : 1) * reach * Math.tanh(Math.abs(total) / Math.max(this.width * 0.45, 1));
  }

  handle(dx, dy, phase, time) {
    switch (phase) {
      case "began":
        this.lock = "undecided"; this.x = 0; this.y = 0; this.samples = [];
        return this.move(dx, dy, time);
      case "changed":
        return this.lock === "finished" ? { type: "passThrough" } : this.move(dx, dy, time);
      case "cancelled": {
        const was = this.lock;
        this.lock = "finished";
        return was === "horizontal" ? { type: "cancel" } : { type: "passThrough" };
      }
      default: { // ended
        const r = this.release();
        this.lock = "finished";
        return r;
      }
    }
  }

  move(dx, dy, time) {
    this.x += dx; this.y += dy;
    if (this.lock === "undecided") {
      if (Math.abs(this.x) + Math.abs(this.y) < PageSwipe.lockDistance) return { type: "passThrough" };
      this.lock = Math.abs(this.x) > PageSwipe.dominance * Math.abs(this.y) ? "horizontal" : "vertical";
      if (this.lock !== "horizontal") return { type: "passThrough" };
      this.samples = [{ time, x: this.x }];
      return { type: "drag", offset: this.offset(this.x) };
    }
    if (this.lock === "horizontal") {
      this.samples.push({ time, x: this.x });
      if (this.samples.length > 8) this.samples.shift();
      return { type: "drag", offset: this.offset(this.x) };
    }
    return { type: "passThrough" };
  }

  release() {
    if (this.lock !== "horizontal") return { type: "passThrough" };
    const direction = this.x < 0 ? 1 : -1;
    const available = direction > 0 ? this.canGoNext : this.canGoPrevious;
    if (!available) return { type: "cancel" };
    if (Math.abs(this.x) > this.width * PageSwipe.commitFraction) return { type: "commit", direction };
    const last = this.samples[this.samples.length - 1];
    const first = last && this.samples.find((s) => last.time - s.time <= 0.1);
    if (last && first && last.time > first.time) {
      const velocity = (last.x - first.x) / (last.time - first.time);
      if (Math.abs(this.x) >= PageSwipe.flickDistance && Math.abs(velocity) > PageSwipe.flickVelocity
        && (velocity < 0) === (direction > 0)) return { type: "commit", direction };
    }
    return { type: "cancel" };
  }
}

/** Motion of the outgoing / incoming layer at progress p (0...1), as { x, opacity }. */
export function layerMotion(kind, role, direction, width, p, startOffset = 0) {
  if (kind === "slide") {
    return role === "outgoing"
      ? { x: startOffset * (1 - p) - direction * width * p, opacity: 1 }
      : { x: direction * width * (1 - p), opacity: 1 };
  }
  return { x: 0, opacity: role === "outgoing" ? 1 - p : p };
}

/** Key names the web UI maps to the key grammar; null for bare modifiers. */
export function keyName(e) {
  const named = {
    Escape: "escape", Tab: "tab", Enter: "enter", " ": "space", ArrowLeft: "left", ArrowRight: "right",
    ArrowDown: "down", ArrowUp: "up", Home: "home", End: "end", PageUp: "pageup", PageDown: "pagedown",
    Backspace: "backspace", Delete: "delete",
  };
  let key = named[e.key];
  let shift = e.shiftKey;
  if (!key) {
    if (/^F\d{1,2}$/.test(e.key)) key = e.key.toLowerCase();
    else if ([...String(e.key)].length === 1) {
      key = e.key;
      if (/\p{L}/u.test(key)) key = key.toLowerCase(); else shift = false;
    } else return null;
  }
  const parts = [];
  if (e.metaKey) parts.push("cmd");
  if (e.ctrlKey) parts.push("ctrl");
  if (e.altKey) parts.push("alt");
  if (shift) parts.push("shift");
  parts.push(key);
  return parts.join("+");
}
