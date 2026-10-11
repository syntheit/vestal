import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { subsetFont, parseFont, verifySubset } from "../fontsubset.mjs";

for (const file of ["Phosphor.ttf", "Phosphor-Fill.ttf"]) {
  test(`${file} subset round trip`, () => {
    const original = readFileSync(fileURLToPath(new URL(`../../Resources/icons/${file}`, import.meta.url)));
    const source = parseFont(original);
    const points = [0xe000, 0xe002, 0xe004];
    const subset = subsetFont(original, points);
    const parsed = parseFont(subset);
    assert.ok(subset.length < original.length / 4);
    assert.equal(parsed.countGlyphs, 4);
    for (const cp of points) {
      assert.ok(parsed.lookup(cp) > 0);
      assert.deepEqual(parsed.glyph(parsed.lookup(cp)), source.glyph(source.lookup(cp)));
      assert.equal(parsed.metric(parsed.lookup(cp)).advance, source.metric(source.lookup(cp)).advance);
    }
    assert.equal(parsed.lookup(0xe006), 0);
    verifySubset(original, subset, points);
  });
}
