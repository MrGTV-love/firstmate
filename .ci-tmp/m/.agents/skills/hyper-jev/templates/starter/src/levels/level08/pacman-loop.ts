/**
 * Level 8, option A: the Pac-Man loop.
 * One tile, one request: direction, strategy, danger, trapped. Code moves the character, eats the pellets, and steps the ghost. Jev only ever decides.
 */
import { jev } from "../../core/client.ts";
import { choice, noul, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, NoulAnswer, ScoreAnswer } from "../../core/types.ts";

export interface PacState {
  position: { x: number; y: number };
  pellets_nearby: number;
  ghost_nearby: string | null;
  ghost_pos?: { x: number; y: number };
  power_pellet_active: boolean;
  walls: string[];
}

export interface PacDecision {
  direction: "up" | "down" | "left" | "right";
  strategy: "collect" | "hunt" | "flee";
  danger: number;
  trapped: boolean;
}

/** A: the Pac-Man loop. Every tile, one request, code moves the character. */
export async function pacmanStep(state: PacState): Promise<PacDecision> {
  const { answers } = await jev.systemOne(state as unknown as Record<string, unknown>, {
    direction: choice("Given the state, which direction should Pac-Man move?", {
      up: "Move up; pellet or power pellet above, no wall",
      down: "Move down; pellet or power pellet below, no wall",
      left: "Move left; pellet or power pellet to the left, no wall",
      right: "Move right; pellet or power pellet to the right, no wall",
    }),
    strategy: choice("What should Pac-Man prioritize right now?", {
      collect: "No ghost threat; gather pellets efficiently",
      hunt: "Power pellet active; chase the ghost",
      flee: "A ghost is nearby and no power pellet is active; run away from the ghost",
    }),
    danger: score("How dangerous is the current situation?", [
      "No ghost threat; open space",
      "Ghost in the area but escape routes exist",
      "Ghost closing in and few or no escape routes",
    ]),
    trapped: noul("Is Pac-Man boxed in with no safe move?"),
  });
  return {
    direction: (answers.direction as ChoiceAnswer).choice as PacDecision["direction"],
    strategy: (answers.strategy as ChoiceAnswer).choice as PacDecision["strategy"],
    danger: (answers.danger as ScoreAnswer).score,
    trapped: (answers.trapped as NoulAnswer).noul > 0.5,
  };
}

export const PAC_GRID = { w: 12, h: 8 };

export const PAC_WALLS = new Set(["3,2", "3,3", "8,4", "8,5", "5,6"]);

export const PAC_POWER = { x: 1, y: 6 };

export const PAC_PELLETS = [
  { x: 2, y: 1 }, { x: 6, y: 2 }, { x: 9, y: 1 }, { x: 10, y: 5 }, { x: 4, y: 6 }, { x: 7, y: 7 },
];

export interface PacTick {
  tick: number;
  state: PacState;      // state at decision time (pre-move)
  decision: PacDecision;
  pac: { x: number; y: number };   // post-move position
  ghost: { x: number; y: number }; // post-move position
  pellets: number;
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

const DIRS: Record<string, [number, number]> = { up: [0, -1], down: [0, 1], left: [-1, 0], right: [1, 0] };

function wallsAt(x: number, y: number): string[] {
  return Object.entries(DIRS)
    .filter(([, [dx, dy]]) => {
      const nx = x + dx, ny = y + dy;
      return nx < 0 || ny < 0 || nx >= PAC_GRID.w || ny >= PAC_GRID.h || PAC_WALLS.has(`${nx},${ny}`);
    })
    .map(([dir]) => dir);
}

/** A: the Pac-Man loop as a real loop. Each tick is one Jev call; code moves the pieces. */
export async function pacmanLoop(
  ticks = 8,
  onTick?: (t: PacTick) => void,
  initial: Partial<{ position: { x: number; y: number }; ghost: { x: number; y: number } }> = {}
): Promise<PacTick[]> {
  let pac = initial.position ?? { x: 1, y: 1 };
  let ghost = initial.ghost ?? { x: 10, y: 6 };
  let pellets = PAC_PELLETS.map((p) => ({ ...p }));
  let powerUntil = -1;
  const out: PacTick[] = [];

  for (let tick = 0; tick < ticks; tick++) {
    const near = pellets.filter((p) => Math.abs(p.x - pac.x) + Math.abs(p.y - pac.y) <= 3).length;
    const ghostDist = Math.abs(ghost.x - pac.x) + Math.abs(ghost.y - pac.y);
    const state: PacState = {
      position: { ...pac },
      pellets_nearby: near,
      ghost_nearby: ghostDist <= 3 ? "blinky" : null,
      ghost_pos: { ...ghost },
      power_pellet_active: tick < powerUntil,
      walls: wallsAt(pac.x, pac.y),
    };
    const decision = await pacmanStep(state);

    // act in code: move per the decision, respecting walls
    const [dx, dy] = DIRS[decision.direction] ?? [0, 0];
    if (!state.walls.includes(decision.direction)) {
      pac = { x: clamp(pac.x + dx, 0, PAC_GRID.w - 1), y: clamp(pac.y + dy, 0, PAC_GRID.h - 1) };
    }
    // eat in code
    pellets = pellets.filter((p) => !(p.x === pac.x && p.y === pac.y));
    if (pac.x === PAC_POWER.x && pac.y === PAC_POWER.y) powerUntil = tick + 3;
    // the ghost hunts in code — one greedy step toward Pac-Man
    ghost = {
      x: clamp(ghost.x + Math.sign(pac.x - ghost.x), 0, PAC_GRID.w - 1),
      y: clamp(ghost.y + Math.sign(pac.y - ghost.y), 0, PAC_GRID.h - 1),
    };

    const t: PacTick = { tick, state, decision, pac: { ...pac }, ghost, pellets: pellets.length };
    out.push(t);
    onTick?.(t);
  }
  return out;
}
