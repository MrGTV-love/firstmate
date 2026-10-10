/**
 * Level 8, option C: trading loop.
 * Buy, hold, sell, or exit per tick. Conviction sizes the position, low confidence holds. RSI and the position live in code, never in the model.
 */
import { jev } from "../../core/client.ts";
import { choice, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, ScoreAnswer } from "../../core/types.ts";

export interface MarketState {
  symbol: string;
  price: number;
  change_pct_24h: number;
  rsi: number;
  position: "long" | "short" | "flat";
  unrealized_pnl_pct: number;
}

export type TradeAction =
  | { action: "buy"; size: "full" | "half" }
  | { action: "sell" }
  | { action: "hold" }
  | { action: "exit"; reason: string };

export interface TradeTick {
  tick: number;
  state: MarketState;
  decision: TradeAction;
}

/** RSI over the available window — deterministic, in code, never in the model. */
function rsi(prices: number[]): number {
  if (prices.length < 2) return 50;
  let gains = 0, losses = 0;
  for (let i = 1; i < prices.length; i++) {
    const d = prices[i] - prices[i - 1];
    if (d > 0) gains += d; else losses -= d;
  }
  if (losses === 0) return gains > 0 ? 100 : 50;
  const rs = gains / losses;
  return Math.round(100 - 100 / (1 + rs));
}

/** C-loop: walk a price series; each tick is one Jev call, code owns the position. */
export async function tradingLoop(
  prices: number[],
  onTick?: (t: TradeTick) => void,
  symbol = "AAPL"
): Promise<TradeTick[]> {
  let position: "long" | "flat" = "flat";
  let entry = 0;
  const out: TradeTick[] = [];
  for (let tick = 1; tick < prices.length; tick++) {
    const window = prices.slice(0, tick + 1);
    const price = prices[tick];
    const state: MarketState = {
      symbol,
      price,
      change_pct_24h: Math.round(((price - prices[tick - 1]) / prices[tick - 1]) * 1000) / 10,
      rsi: rsi(window.slice(-8)),
      position,
      unrealized_pnl_pct: position === "long" ? Math.round(((price - entry) / entry) * 1000) / 10 : 0,
    };
    const decision = await tradingStep(state);
    if (decision.action === "buy" && position === "flat") { position = "long"; entry = price; }
    if ((decision.action === "sell" || decision.action === "exit") && position === "long") position = "flat";
    const t: TradeTick = { tick, state, decision };
    out.push(t);
    onTick?.(t);
  }
  return out;
}

/** C: the live trading agent. One call per tick; code owns position sizing and the exits. */
export async function tradingStep(state: MarketState): Promise<TradeAction> {
  const { answers } = await jev.systemOne(state as unknown as Record<string, unknown>, {
    action: choice("Given the market state and current position, what should the agent do?", {
      buy: "Momentum and oversold signals align; entering is favorable",
      sell: "Momentum has reversed while holding a long position",
      hold: "No signal is strong enough to change the position",
      exit: "Position is losing and the signal says get out",
    }),
    conviction: score("How strong is the signal in the current state?", [
      "Weak, mixed indicators",
      "Clear but not extreme",
      "Multiple indicators aligned, extreme reading",
    ]),
  });
  const a = answers.action as ChoiceAnswer;
  const conviction = (answers.conviction as ScoreAnswer).score;
  if (a.confidence < 0.5) return { action: "hold" };
  if (a.choice === "buy") return { action: "buy", size: conviction > 1.5 ? "full" : "half" };
  if (a.choice === "sell") return { action: "sell" };
  if (a.choice === "exit") return { action: "exit", reason: `conviction ${conviction}` };
  return { action: "hold" };
}
