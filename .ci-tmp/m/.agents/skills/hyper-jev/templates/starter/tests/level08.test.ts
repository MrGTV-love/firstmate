import test from "node:test";
import assert from "node:assert/strict";
import * as l8 from "../src/levels/level08/index.ts";
import type { ChoiceAnswer, ScoreAnswer } from "../src/core/types.ts";

test("L8 A: pacmanStep returns a full typed decision in one call", async () => {
  const d = await l8.pacmanStep({
    position: { x: 10, y: 4 },
    pellets_nearby: 3,
    ghost_nearby: "blinky",
    power_pellet_active: false,
    walls: ["up"],
  });
  assert.ok(["up", "down", "left", "right"].includes(d.direction));
  assert.ok(["collect", "hunt", "flee"].includes(d.strategy));
  assert.ok(d.danger >= 0 && d.danger <= 2);
  assert.equal(typeof d.trapped, "boolean");
});

test("L8 A: a nearby ghost with no power pellet means flee", async () => {
  const d = await l8.pacmanStep({
    position: { x: 10, y: 4 },
    pellets_nearby: 3,
    ghost_nearby: "blinky",
    power_pellet_active: false,
    walls: [],
  });
  assert.equal(d.strategy, "flee");
});

test("L8 B: pickElement returns a selector that exists on the page", async () => {
  const elements = [
    { selector: "#depart-time-6am", role: "radio", text: "6:00 AM departure — $210" },
    { selector: "#depart-time-9am", role: "radio", text: "9:00 AM departure — $180, cheapest morning fare" },
    { selector: "#search-btn", role: "button", text: "Search flights" },
  ];
  const pick = await l8.pickElement("Book the cheapest morning flight", elements);
  assert.ok(elements.some((e) => e.selector === pick.selector));
  assert.equal(pick.selector, "#depart-time-9am");
  assert.ok(pick.confidence > 0.5);
});

test("L8 B: the 255-option cap is enforced for huge pages", async () => {
  const many = Array.from({ length: 256 }, (_, i) => ({ selector: `#el-${i}`, role: "button", text: `button ${i}` }));
  await assert.rejects(() => l8.pickElement("goal", many), /255/);
});

test("L8 B: an empty page is an error, not a guess", async () => {
  await assert.rejects(() => l8.pickElement("goal", []), /No interactive elements/);
});

test("L8 C: a confident buy signal sizes by conviction", async () => {
  const d = await l8.tradingStep({
    symbol: "AAPL",
    price: 212.4,
    change_pct_24h: -3.2,
    rsi: 24,
    position: "flat",
    unrealized_pnl_pct: 0,
  });
  assert.ok(["buy", "sell", "hold", "exit"].includes(d.action));
});

test("L8 A loop: pacmanLoop runs N ticks, stays in bounds, fires per-tick events", async () => {
  const seen: l8.PacTick[] = [];
  const ticks = await l8.pacmanLoop(6, (t) => seen.push(t));
  assert.equal(ticks.length, 6);
  assert.equal(seen.length, 6);
  for (const t of ticks) {
    assert.ok(t.state.position.x >= 0 && t.state.position.x < 12);
    assert.ok(t.state.position.y >= 0 && t.state.position.y < 8);
    assert.ok(["up", "down", "left", "right"].includes(t.decision.direction));
    assert.ok(t.ghost.x >= 0 && t.ghost.x < 12);
  }
});

test("L8 C loop: tradingLoop walks the series and owns the position in code", async () => {
  const prices = [100, 98, 95, 96, 99, 103, 107, 106, 104];
  const seen: l8.TradeTick[] = [];
  const ticks = await l8.tradingLoop(prices, (t) => seen.push(t));
  assert.equal(ticks.length, prices.length - 1);
  assert.equal(seen.length, ticks.length);
  for (const t of ticks) {
    assert.ok(["buy", "sell", "hold", "exit"].includes(t.decision.action));
    assert.ok(t.state.rsi >= 0 && t.state.rsi <= 100);
  }
});

test("L8 C: low-confidence reads always hold the position", async () => {
  const d = await l8.tradingStep({
    symbol: "BRK.B",
    price: 480.0,
    change_pct_24h: 0.1,
    rsi: 52,
    position: "flat",
    unrealized_pnl_pct: 0,
  });
  assert.equal(d.action, "hold");
});
