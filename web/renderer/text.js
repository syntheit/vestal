// Fonts and text measurement. The layout asks for sizes; the DOM draws the
// same strings with the same font shorthand, so the two agree.

export const SANS = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Geist", system-ui, sans-serif';
export const MONO = 'ui-monospace, "SF Mono", "Geist Mono", SFMono-Regular, Menlo, monospace';
export const ROUNDED = 'ui-rounded, "SF Pro Rounded", -apple-system, BlinkMacSystemFont, "SF Pro Text", "Geist", system-ui, sans-serif';

const quote = (f) => (/[\s,"]/.test(f) ? `"${f.replace(/"/g, "")}"` : f);

/** The CSS family list of a font role; `theme.fonts` (a family or null) goes first. */
export function fontFamily(role, theme) {
  const custom = theme && theme.fonts && theme.fonts[role === "mono" || role === "rounded" ? role : "sans"];
  const base = role === "mono" ? MONO : role === "rounded" ? ROUNDED : SANS;
  return custom ? `${quote(custom)}, ${base}` : base;
}

/** Weights are 100...900 in hundreds; other numbers round to the nearest hundred. */
export function cssWeight(weight) {
  return Math.floor((Math.min(900, Math.max(100, weight ?? 400)) + 50) / 100) * 100;
}

/** `weight size px family` for a text node. */
export function fontShorthand(node, theme) {
  return `${cssWeight(node.weight)} ${node.size ?? 13}px ${fontFamily(node.font || "sans", theme)}`;
}

/**
 * Greedy word wrap. `width(s)` measures a string; returns the lines (at most
 * `maxLines` when given, the last one cut with an ellipsis when text remains).
 * A word wider than `maxWidth` breaks between characters.
 */
export function wrapLines(text, maxWidth, width, maxLines = null) {
  const out = [];
  let truncated = false;
  for (const para of String(text).split("\n")) {
    if (maxWidth == null) { out.push(para); continue; }
    const words = para.split(/(?<= )/); // keep the trailing space with its word
    let line = "";
    for (const word of words) {
      if (line === "") line = word;
      else if (width((line + word).trimEnd()) <= maxWidth) line += word;
      else { out.push(line.trimEnd()); line = word; }
      // Break a single word that is still too wide between characters.
      while (width(line.trimEnd()) > maxWidth && [...line].length > 1) {
        const chars = [...line];
        let k = chars.length - 1;
        while (k > 1 && width(chars.slice(0, k).join("")) > maxWidth) k--;
        out.push(chars.slice(0, k).join(""));
        line = chars.slice(k).join("");
      }
    }
    out.push(line.trimEnd());
  }
  if (maxLines != null && out.length > maxLines) { out.length = maxLines; truncated = true; }
  return { lines: out, truncated };
}

/**
 * A measurer for the layout, over a canvas 2D context (anything with `font`
 * and `measureText`). `theme` supplies the font families.
 */
export function createMeasurer(ctx, theme) {
  const cache = new Map();
  const metricsCache = new Map();

  function metrics(font, size) {
    let m = metricsCache.get(font);
    if (!m) {
      ctx.font = font;
      const t = ctx.measureText("Hxgy");
      const asc = t.fontBoundingBoxAscent ?? size * 0.95;
      const desc = t.fontBoundingBoxDescent ?? size * 0.25;
      m = { asc, lh: asc + desc };
      metricsCache.set(font, m);
    }
    return m;
  }

  function widthOf(font, text, tracking) {
    const key = `${font}\u0000${tracking}\u0000${text}`;
    let w = cache.get(key);
    if (w === undefined) {
      ctx.font = font;
      w = ctx.measureText(text).width + tracking * [...text].length;
      cache.set(key, w);
    }
    return w;
  }

  /** Raw string width in a node's font (used by the timeline labels). */
  function stringWidth(node, text) {
    return widthOf(fontShorthand(node, theme), text, node.tracking || 0);
  }

  function measureText(node, maxWidth) {
    const size = node.size ?? 13;
    const font = fontShorthand(node, theme);
    const tracking = node.tracking || 0;
    const m = metrics(font, size);
    const w = (s) => widthOf(font, s, tracking);
    const text = node.text ?? "";
    const lines = node.lines != null ? Math.max(1, node.lines) : null;
    if (maxWidth == null) {
      const parts = String(text).split("\n");
      return { width: Math.max(...parts.map(w)), height: m.lh * parts.length, baseline: m.asc, lineHeight: m.lh };
    }
    const wrapped = wrapLines(text, maxWidth, w, lines);
    const widest = Math.max(...wrapped.lines.map(w));
    return { width: Math.min(widest, maxWidth), height: m.lh * wrapped.lines.length, baseline: m.asc, lineHeight: m.lh };
  }

  return { measureText, stringWidth, metrics: (node) => metrics(fontShorthand(node, theme), node.size ?? 13) };
}
