import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const app = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const css = readFileSync(new URL("../src/attack.css", import.meta.url), "utf8");

test("replay visualization exposes capture, store, and re-inject stages", () => {
  assert.match(app, /replay-stage-progress/);
  assert.match(app, />CAPTURE</);
  assert.match(app, />STORE</);
  assert.match(app, />RE-INJECT</);
});

test("replay stages use synchronized sequential animations", () => {
  assert.match(css, /--replay-cycle:\s*5\.8s/);
  assert.match(css, /replay-stage-capture/);
  assert.match(css, /replay-stage-store/);
  assert.match(css, /replay-stage-reinject/);
});

test("replay storage reserves a packet bay above its text", () => {
  assert.match(css, /\.replay-storage\s*\{[^}]*width:\s*340px/s);
  assert.match(css, /\.replay-storage\s*\{[^}]*padding:\s*54px/s);
});
