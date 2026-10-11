// Small TrueType glyf subsetter for the website. No external packages.
// Only tables needed to draw codepoint-addressed outlines are retained.

function need(ok, message) { if (!ok) throw new Error(`font subset: ${message}`); }
const u16 = (b, p) => b.readUInt16BE(p);
const i16 = (b, p) => b.readInt16BE(p);
const u32 = (b, p) => b.readUInt32BE(p);
const pad4 = (n) => (n + 3) & ~3;

export function parseFont(bytes) {
  const b = Buffer.from(bytes);
  need(b.length >= 12 && u32(b, 0) === 0x00010000, "expected a TrueType glyf font");
  const tables = new Map();
  const count = u16(b, 4);
  need(12 + 16 * count <= b.length, "truncated table directory");
  for (let i = 0; i < count; i++) {
    const p = 12 + i * 16, tag = b.toString("ascii", p, p + 4);
    const offset = u32(b, p + 8), length = u32(b, p + 12);
    need(offset + length <= b.length && !tables.has(tag), `bad ${tag} table`);
    tables.set(tag, b.subarray(offset, offset + length));
  }
  for (const tag of ["cmap", "glyf", "loca", "head", "hhea", "hmtx", "maxp"]) need(tables.has(tag), `missing ${tag}`);
  const countGlyphs = u16(tables.get("maxp"), 4);
  const locFormat = i16(tables.get("head"), 50);
  need(locFormat === 0 || locFormat === 1, "unsupported loca format");
  const loca = tables.get("loca"), glyf = tables.get("glyf"), stride = locFormat ? 4 : 2;
  need(loca.length >= (countGlyphs + 1) * stride, "short loca");
  const offset = (id) => (locFormat ? u32(loca, id * 4) : u16(loca, id * 2) * 2);
  const glyph = (id) => {
    need(id >= 0 && id < countGlyphs, `invalid glyph ${id}`);
    const start = offset(id), end = offset(id + 1);
    need(start <= end && end <= glyf.length, `invalid glyph offset ${id}`);
    return glyf.subarray(start, end);
  };
  const metricCount = u16(tables.get("hhea"), 34), hmtx = tables.get("hmtx");
  need(metricCount > 0 && metricCount <= countGlyphs && hmtx.length >= 4 * metricCount + 2 * (countGlyphs - metricCount), "short hmtx");
  const metric = (id) => ({
    advance: u16(hmtx, Math.min(id, metricCount - 1) * 4),
    lsb: i16(hmtx, id < metricCount ? id * 4 + 2 : metricCount * 4 + (id - metricCount) * 2),
  });
  const cmap = tables.get("cmap"), maps = [];
  need(cmap.length >= 4 + u16(cmap, 2) * 8, "short cmap");
  for (let i = 0; i < u16(cmap, 2); i++) {
    const off = u32(cmap, 4 + i * 8 + 4);
    need(off + 2 <= cmap.length, "bad cmap offset");
    const format = u16(cmap, off);
    if (format === 4) {
      const length = u16(cmap, off + 2), segs = u16(cmap, off + 6) / 2;
      need(off + length <= cmap.length && segs > 0, "bad format 4 cmap");
      maps.push((cp) => {
        if (cp > 0xffff) return 0;
        const end = off + 14, start = end + 2 * segs + 2, delta = start + 2 * segs, range = delta + 2 * segs;
        for (let s = 0; s < segs; s++) {
          if (cp > u16(cmap, end + 2 * s)) continue;
          if (cp < u16(cmap, start + 2 * s)) return 0;
          const ro = u16(cmap, range + 2 * s);
          if (!ro) return (cp + i16(cmap, delta + 2 * s)) & 0xffff;
          const p = range + 2 * s + ro + 2 * (cp - u16(cmap, start + 2 * s));
          need(p + 2 <= off + length, "bad format 4 glyph offset");
          const id = u16(cmap, p);
          return id ? (id + i16(cmap, delta + 2 * s)) & 0xffff : 0;
        }
        return 0;
      });
    } else if (format === 12) {
      const length = u32(cmap, off + 4), groups = u32(cmap, off + 12);
      need(off + length <= cmap.length && length >= 16 + 12 * groups, "bad format 12 cmap");
      maps.unshift((cp) => {
        let lo = 0, hi = groups;
        while (lo < hi) {
          const mid = (lo + hi) >>> 1, p = off + 16 + mid * 12;
          if (cp < u32(cmap, p)) hi = mid;
          else if (cp > u32(cmap, p + 4)) lo = mid + 1;
          else return u32(cmap, p + 8) + cp - u32(cmap, p);
        }
        return 0;
      });
    }
  }
  need(maps.length > 0, "no supported cmap");
  const lookup = (cp) => { for (const map of maps) { const id = map(cp); if (id) return id; } return 0; };
  return { bytes: b, tables, countGlyphs, locFormat, glyph, metric, lookup };
}

function components(glyph) {
  if (glyph.length < 10 || i16(glyph, 0) >= 0) return [];
  const found = [];
  let p = 10, flags;
  do {
    need(p + 4 <= glyph.length, "short composite glyph");
    flags = u16(glyph, p);
    found.push({ offset: p + 2, id: u16(glyph, p + 2) });
    p += 4 + (flags & 1 ? 4 : 2) + (flags & 8 ? 2 : flags & 64 ? 4 : flags & 128 ? 8 : 0);
  } while (flags & 32);
  need(p <= glyph.length, "short composite glyph");
  return found;
}

function makeCmap(entries) {
  const bmp = entries.filter(([cp]) => cp < 0xffff);
  const n = bmp.length + 1, power = 2 ** Math.floor(Math.log2(n));
  const f4 = Buffer.alloc(16 + n * 8);
  f4.writeUInt16BE(4, 0); f4.writeUInt16BE(f4.length, 2);
  f4.writeUInt16BE(n * 2, 6); f4.writeUInt16BE(power * 2, 8);
  f4.writeUInt16BE(Math.log2(power), 10); f4.writeUInt16BE(n * 2 - power * 2, 12);
  for (let i = 0; i < n; i++) {
    const [cp, id] = i < bmp.length ? bmp[i] : [0xffff, 0];
    f4.writeUInt16BE(cp, 14 + 2 * i);
    f4.writeUInt16BE(cp, 16 + 2 * n + 2 * i);
    f4.writeUInt16BE((id - cp) & 0xffff, 16 + 4 * n + 2 * i);
  }
  const wide = entries.some(([cp]) => cp > 0xffff);
  const records = wide ? 4 : 2;
  const f12 = wide ? Buffer.alloc(16 + 12 * entries.length) : null;
  if (f12) {
    f12.writeUInt16BE(12, 0); f12.writeUInt32BE(f12.length, 4); f12.writeUInt32BE(entries.length, 12);
    entries.forEach(([cp, id], i) => {
      f12.writeUInt32BE(cp, 16 + 12 * i);
      f12.writeUInt32BE(cp, 20 + 12 * i);
      f12.writeUInt32BE(id, 24 + 12 * i);
    });
  }
  const out = Buffer.alloc(4 + 8 * records + f4.length + (f12?.length || 0));
  out.writeUInt16BE(records, 2);
  const rec = [[0, 3, f4], [3, 1, f4], ...(wide ? [[0, 4, f12], [3, 10, f12]] : [])];
  let pos = 4 + records * 8;
  rec.forEach(([platform, encoding, table], i) => {
    const p = 4 + i * 8;
    out.writeUInt16BE(platform, p); out.writeUInt16BE(encoding, p + 2);
    out.writeUInt32BE(table === f4 ? 4 + records * 8 : 4 + records * 8 + f4.length, p + 4);
  });
  f4.copy(out, pos); pos += f4.length;
  if (f12) f12.copy(out, pos);
  return out;
}

function checksum(b) {
  let sum = 0;
  for (let p = 0; p < pad4(b.length); p += 4) {
    let word = 0;
    for (let i = 0; i < 4; i++) word = ((word << 8) | (b[p + i] || 0)) >>> 0;
    sum = (sum + word) >>> 0;
  }
  return sum;
}

export function subsetFont(bytes, codepoints) {
  const original = parseFont(bytes), oldIds = new Set([0]), requested = [...new Set(codepoints)].sort((a, b) => a - b);
  for (const cp of requested) {
    need(Number.isInteger(cp) && cp >= 0 && cp <= 0x10ffff, `invalid codepoint ${cp}`);
    const id = original.lookup(cp);
    need(id > 0 && id < original.countGlyphs, `missing U+${cp.toString(16).toUpperCase()}`);
    oldIds.add(id);
  }
  const pending = [...oldIds];
  for (let i = 0; i < pending.length; i++) {
    for (const { id } of components(original.glyph(pending[i]))) {
      need(id < original.countGlyphs, `invalid component ${id}`);
      if (!oldIds.has(id)) { oldIds.add(id); pending.push(id); }
    }
  }
  const order = [0, ...[...oldIds].filter((id) => id !== 0).sort((a, b) => a - b)];
  const renumber = new Map(order.map((id, i) => [id, i]));
  const chunks = [], offsets = [0];
  for (const id of order) {
    const data = Buffer.from(original.glyph(id));
    for (const part of components(data)) data.writeUInt16BE(renumber.get(part.id), part.offset);
    chunks.push(data);
    const align = original.locFormat ? 4 : 2;
    const padding = (align - data.length % align) % align;
    if (padding) chunks.push(Buffer.alloc(padding));
    offsets.push(offsets.at(-1) + data.length + padding);
  }
  const loca = Buffer.alloc(offsets.length * (original.locFormat ? 4 : 2));
  offsets.forEach((off, i) => original.locFormat ? loca.writeUInt32BE(off, i * 4) : loca.writeUInt16BE(off / 2, i * 2));
  const hmtx = Buffer.alloc(order.length * 4);
  order.forEach((id, i) => { const m = original.metric(id); hmtx.writeUInt16BE(m.advance, i * 4); hmtx.writeInt16BE(m.lsb, i * 4 + 2); });
  const head = Buffer.from(original.tables.get("head")); head.writeUInt32BE(0, 8);
  const hhea = Buffer.from(original.tables.get("hhea")); hhea.writeUInt16BE(order.length, 34);
  const maxp = Buffer.from(original.tables.get("maxp")); maxp.writeUInt16BE(order.length, 4);
  const post = Buffer.alloc(32); post.writeUInt32BE(0x00030000, 0);
  if (original.tables.has("post")) original.tables.get("post").copy(post, 4, 4, Math.min(32, original.tables.get("post").length));
  const tables = new Map([["cmap", makeCmap(requested.map((cp) => [cp, renumber.get(original.lookup(cp))]))], ["glyf", Buffer.concat(chunks)], ["loca", loca], ["head", head], ["hhea", hhea], ["hmtx", hmtx], ["maxp", maxp], ["post", post]]);
  for (const tag of ["OS/2", "name", "gasp"]) if (original.tables.has(tag)) tables.set(tag, original.tables.get(tag));
  const sorted = [...tables].sort(([a], [b]) => a.localeCompare(b));
  const num = sorted.length, power = 2 ** Math.floor(Math.log2(num));
  const size = 12 + num * 16 + sorted.reduce((n, [, data]) => n + pad4(data.length), 0);
  const out = Buffer.alloc(size);
  out.writeUInt32BE(0x00010000, 0); out.writeUInt16BE(num, 4);
  out.writeUInt16BE(power * 16, 6); out.writeUInt16BE(Math.log2(power), 8); out.writeUInt16BE((num - power) * 16, 10);
  let pos = 12 + num * 16, headOffset;
  sorted.forEach(([tag, data], i) => {
    const p = 12 + i * 16;
    out.write(tag, p, 4, "ascii"); out.writeUInt32BE(checksum(data), p + 4);
    out.writeUInt32BE(pos, p + 8); out.writeUInt32BE(data.length, p + 12);
    data.copy(out, pos); if (tag === "head") headOffset = pos;
    pos += pad4(data.length);
  });
  out.writeUInt32BE((0xb1b0afba - checksum(out)) >>> 0, headOffset + 8);
  verifySubset(original, out, requested);
  return out;
}

export function verifySubset(originalBytes, subsetBytes, codepoints) {
  const original = originalBytes?.glyph ? originalBytes : parseFont(originalBytes);
  const subset = parseFont(subsetBytes);
  need(checksum(subset.bytes) === 0xb1b0afba, "whole-font checksum mismatch");
  const checked = new Set();
  const compare = (oldId, newId) => {
    if (checked.has(`${oldId}/${newId}`)) return;
    checked.add(`${oldId}/${newId}`);
    const oldGlyph = original.glyph(oldId), newGlyph = subset.glyph(newId);
    // Component indices change when composites are renumbered; compare their
    // outlines after replacing those indices with the original glyph ids.
    const restored = Buffer.from(newGlyph);
    const oldParts = components(oldGlyph), newParts = components(restored);
    need(oldParts.length === newParts.length, `composite structure differs for glyph ${oldId}`);
    for (let i = 0; i < newParts.length; i++) {
      need(oldParts[i].offset === newParts[i].offset, `composite structure differs for glyph ${oldId}`);
      restored.writeUInt16BE(oldParts[i].id, newParts[i].offset);
      compare(oldParts[i].id, newParts[i].id);
    }
    need(oldGlyph.equals(restored), `outline differs for glyph ${oldId}`);
    need(original.metric(oldId).advance === subset.metric(newId).advance, `advance differs for glyph ${oldId}`);
  };
  for (const cp of codepoints) {
    const oldId = original.lookup(cp), newId = subset.lookup(cp);
    need(oldId > 0 && newId > 0, `U+${cp.toString(16)} missing after subset`);
    compare(oldId, newId);
  }
}
