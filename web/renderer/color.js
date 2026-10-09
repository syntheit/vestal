// Palette names and `#rrggbbaa` colors, resolved as the native renderers do:
// a name is looked up in `theme.colors` (a value may name another), `@alpha`
// multiplies the alpha, an unknown name draws as `text`.

const TOKYO_NIGHT = {
  text: "#ffffffff", subtle: "#ffffff80", dim: "#ffffff4d", accent: "#7aa1f7ff", bg: "#1a1c26ff",
  track: "#ffffff0f", scrim: "#000000a6", good: "#73cf8fff", warn: "#e3c975ff", bad: "#f06b6bff",
};

/** `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa` to {r,g,b,a} (0...255, alpha 0...1), or null. */
export function parseHex(hex) {
  if (typeof hex !== "string" || hex[0] !== "#") return null;
  let d = hex.slice(1);
  if (d.length === 3 || d.length === 4) d = [...d].map((c) => c + c).join("");
  if ((d.length !== 6 && d.length !== 8) || /[^0-9a-fA-F]/.test(d)) return null;
  const n = (i) => parseInt(d.slice(i, i + 2), 16);
  return { r: n(0), g: n(2), b: n(4), a: d.length === 8 ? n(6) / 255 : 1 };
}

export function cssColor(c) {
  const a = Math.round(c.a * 1000) / 1000;
  return `rgba(${c.r},${c.g},${c.b},${a})`;
}

export function withAlpha(c, factor) {
  return { ...c, a: c.a * factor };
}

/** A resolver for one theme: `(spec, fallback = "text") -> {r,g,b,a}`. */
export function makePalette(theme) {
  const colors = (theme && theme.colors) || {};
  const WHITE = { r: 255, g: 255, b: 255, a: 1 };

  function resolve(spec, depth) {
    if (depth > 8 || typeof spec !== "string") return null;
    const at = spec.lastIndexOf("@");
    if (at > 0) {
      const factor = Number(spec.slice(at + 1));
      if (spec.slice(at + 1) !== "" && Number.isFinite(factor)) {
        const base = resolve(spec.slice(0, at), depth + 1);
        return base && withAlpha(base, factor);
      }
    }
    if (spec[0] === "#") return parseHex(spec);
    if (colors[spec] !== undefined) return resolve(colors[spec], depth + 1);
    if (TOKYO_NIGHT[spec] !== undefined) return parseHex(TOKYO_NIGHT[spec]);
    return null;
  }

  const rgba = (spec, fallback = "text") =>
    resolve(spec == null ? fallback : spec, 0) || resolve("text", 0) || WHITE;
  const css = (spec, fallback = "text") => cssColor(rgba(spec, fallback));
  return { rgba, css };
}
