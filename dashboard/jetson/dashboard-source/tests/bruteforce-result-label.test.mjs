import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import * as bruteForceModel from "../src/bruteforce-model.js";

const { searchResultLabel } = bruteForceModel;

test("found marker includes the actual bit width, compute profile, and elapsed time", () => {
  assert.equal(searchResultLabel({ bits: 20, engineId: "cpu-multi", elapsed: 31 }), "20-BIT · CPU / 31s");
  assert.equal(searchResultLabel({ bits: 24, engineId: "cuda-low", elapsed: 1.2 }), "24-BIT · CUDA LOW / 1.2s");
  assert.equal(searchResultLabel({ bits: 26, engineId: "cuda-max", elapsed: 0.54 }), "26-BIT · CUDA MAX / 0.5s");
});

test("comparison graph identifies the y-axis unit as keys", () => {
  const source = readFileSync(new URL("../src/BruteForcePage.jsx", import.meta.url), "utf8");
  assert.match(source, /CUMULATIVE CANDIDATES TESTED \[KEYS\]/);
});

test("prepare status maps only observed backend events to the existing pipeline", () => {
  const progress = bruteForceModel.prepareProgress;
  assert.deepEqual(progress?.("queued", 0), {
    step: 0,
    detail: "Weak-session preparation queued on Jetson",
  });
  assert.deepEqual(progress?.("checking-live-stream", 0), {
    step: 0,
    detail: "Checking the live AES-GCM ciphertext stream",
  });
  assert.deepEqual(progress?.("requesting-session", 0), {
    step: 0,
    detail: "Weak-session request sent · waiting for the TX/RX ACK",
  });
  assert.deepEqual(progress?.("capturing-matching-packet", 4), {
    step: 4,
    detail: "Session ACK verified · capturing a matching authenticated packet",
  });
  assert.deepEqual(progress?.("retrying", 4), {
    step: 4,
    detail: "Session ACK verified · retrying the matching packet capture",
  });
  assert.deepEqual(progress?.("retrying", 0), {
    step: 0,
    detail: "Retrying the same weak-session request ID · waiting for the TX/RX ACK",
  });
  assert.deepEqual(progress?.("ready", 4), {
    step: 4,
    detail: "Session ACK and matching authenticated packet verified",
  });
});
