# 08. Decision loops

[Catalog and runtime setup](README.md). Demonstrations only, not calibrated production policies.

Use `observe -> ask -> validate -> act in code -> observe again` when decisions depend on changing state. Jev selects a step; code owns state transitions and termination. A valid action name is not proof that the action is legal in the current state.

## Three implementations

- **[pacmanStep / pacmanLoop](../../templates/starter/src/levels/level08/pacman-loop.ts)**: position, nearby pellets/ghost, power state, walls -> direction Choice, strategy Choice, danger Score, trapped Noul -> `PacDecision`. The loop defaults to eight ticks, calls Jev once per tick, enforces player walls/grid bounds, updates pellets/ghost in code, and emits `PacTick` records. `state` is pre-move; `pac` and `ghost` are post-move. Use as a small state-machine pattern, not a complete game engine.
- **[pickElement](../../templates/starter/src/levels/level08/element-picker.ts)**: goal + current element selector/role/text records -> Choice built from array indices -> `{ selector, confidence }`. It rejects zero or more than 255 elements. Use to propose an action target from a fresh snapshot. It does not collect a DOM, click, wait for navigation, or enforce a confidence threshold.
- **[tradingStep / tradingLoop](../../templates/starter/src/levels/level08/trading-loop.ts)**: market snapshot -> buy/sell/hold/exit Choice + conviction Score -> `TradeAction`. Confidence `< 0.5` holds; a buy is full when conviction `> 1.5`, otherwise half. The loop computes RSI and PnL in code, starts flat, walks `prices.length - 1` ticks, and records long/flat transitions. Use only as a simulation of decision/state separation; it does not place orders.

## Try bounded simulations

Save as `example.ts` in the starter root.

```ts
import { pacmanLoop, tradingLoop } from "./src/levels/level08/index.ts";

const ticks = 3;
if (!Number.isInteger(ticks) || ticks < 1 || ticks > 20) throw new Error("Invalid tick budget");
const prices = [100, 98, 95, 99];
if (!prices.every((p) => Number.isFinite(p) && p > 0)) throw new Error("Invalid prices");
console.log({ game: await pacmanLoop(ticks) });
console.log({ marketSimulation: await tradingLoop(prices) });
```

```bash
JEV_BACKEND=mock node example.ts
npm test
```

## Boundaries and tests

[Existing tests](../../templates/starter/tests/level08.test.ts) cover decision shapes, fleeing, element membership, empty/256-element rejection, bounded game positions, callbacks, series length, RSI range, and an uncertain hold. The buy test checks action membership, not actual position sizing.

Add numerical validation in code for finite positive prices, legal initial positions, bounded integer tick counts, and positive denominators. `pacmanLoop` itself does not reject `Infinity`, fractional ticks, or invalid initial positions. Add deadlines, cancellation, no-progress detection, and maximum total requests/cost. Test 1 and 255 candidates, stale snapshots, low confidence, and missing/duplicate selectors.

## Production policy and source limits

- Player walls are enforced, but the ghost moves diagonally without wall/collision rules; `trapped` does not stop the loop. Supply domain invariants and stop conditions outside the model.
- An element Choice has no abstain option. Add a no-action/review path, validate candidate IDs against the exact snapshot, recheck visibility and selector uniqueness before acting, and enforce destination/action permissions. A selector valid when observed may no longer be valid when used.
- Trading `change_pct_24h` is actually the change from the preceding array entry; no timestamps establish a 24-hour interval. The simulation ignores returned full/half size, fees, fills, exposure, and short positions. `exit` flattens the simulated position but does not terminate iteration.
- For any real financial integration, use separate risk limits, authorization, order reconciliation, idempotency, and a kill switch. Confidence and toy backtests do not establish profitability or suitability.
