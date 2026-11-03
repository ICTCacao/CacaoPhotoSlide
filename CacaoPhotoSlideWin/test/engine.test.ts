import test from "node:test";
import assert from "node:assert/strict";
import { SlideTiming, easeInOut, endFadeAlpha, incoming, overlayState, titleState, kenBurnsFor } from "../src/engine.ts";
import { newOverlay, newTitle } from "../src/model.ts";

test("SlideTiming: 個別の長さと切り替えを反映して、開始時刻と全体の長さを出す", () => {
  const t = new SlideTiming(["a", "b", "c"], { dwell: 2, transition: "crossfade", transitionDuration: 1, fit: "fit" },
    { b: { dwell: 4, transition: "push" }, c: { transition: "none" } });
  assert.deepEqual(t.starts, [0, 2, 6]);
  assert.equal(t.total, 8);                 // 2 + 4 + 2 + 最後の切り替え 0（c は none）
  assert.equal(t.index(1.9), 0);
  assert.equal(t.index(2), 1);
  assert.equal(t.index(100), 2);
  assert.deepEqual(t.bounds(), [0, 2, 6, 8]);
});

test("easeInOut と incoming", () => {
  assert.equal(easeInOut(0), 0);
  assert.equal(easeInOut(1), 1);
  assert.equal(incoming("push", 0.25, 100).dx, 75);
});

test("endFadeAlpha", () => {
  assert.equal(endFadeAlpha(0, 3, 0), 0);
  assert.ok(Math.abs(endFadeAlpha(2, 3, 2) - 0.5) < 1e-9);
});

test("overlayState: 範囲外は null、入りは透明から", () => {
  const c = newOverlay("x", 10, 4); c.fadeIn = 1; c.fadeOut = 1; c.transition = "crossfade";
  assert.equal(overlayState(c, 9, "kenBurns", "fit", undefined), null);
  const s = overlayState(c, 10, "kenBurns", "fit", undefined)!;
  assert.equal(s.opacity, 0);
  assert.equal(overlayState(c, 12, "kenBurns", "fit", undefined)!.opacity, 1);
});

test("titleState: タイプライターは reveal が進む", () => {
  const t = newTitle({ effect: "typewriter", start: 0, duration: 0, effectDuration: 2 });
  assert.equal(titleState(t, 0, false)!.reveal, 0);
  assert.equal(titleState(t, 1, false)!.reveal, 0.5);
  assert.equal(titleState(t, 5, false)!.reveal, 1);
});

test("kenBurnsFor: 同じ種は同じ動き", () => {
  assert.deepEqual(kenBurnsFor(42), kenBurnsFor(42));
});
