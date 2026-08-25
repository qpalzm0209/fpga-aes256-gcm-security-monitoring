import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const css = readFileSync(new URL("../src/attack.css", import.meta.url), "utf8");

test("tamper markers are large enough to explain ciphertext-only mutation at a glance", () => {
  assert.match(css, /\.bit-flip-marker\s*\{[^}]*min-width:\s*148px/s);
  assert.match(css, /\.tag-unchanged-marker\s*\{[^}]*min-width:\s*136px/s);
  assert.match(css, /\.bit-flip-marker b\s*\{[^}]*font:\s*14px/s);
  assert.match(css, /\.bit-flip-marker small\s*\{[^}]*font:\s*9px/s);
  assert.match(css, /\.tag-unchanged-marker\s*\{[^}]*font:\s*12px/s);
});

test("enlarged tamper markers stay outside the traveling packet", () => {
  assert.match(css, /\.bit-flip-marker\s*\{[^}]*left:\s*calc\(9% - 160px\)/s);
  assert.match(css, /\.tag-unchanged-marker\s*\{[^}]*right:\s*calc\(9% - 148px\)/s);
});
