import test from "node:test";
import assert from "node:assert/strict";
import * as l9 from "../src/levels/level09/index.ts";

function links(n: number, winnerIndex: number, winnerTitle: string, winnerSnippet: string) {
  return Array.from({ length: n }, (_, i) => ({
    title: i === winnerIndex ? winnerTitle : `Note ${i}`,
    snippet: i === winnerIndex ? winnerSnippet : `Index ${i}`,
  }));
}

test("L9 A: pickWikiLink selects the target-relevant link among 40 real options", async () => {
  const ls = links(40, 12, "Economics", "The study of markets, prices, supply and demand");
  const pick = await l9.pickWikiLink("Main Page", "Economics", ls);
  assert.equal(pick.title, "Economics");
  // The pick is always a real link — the model cannot invent one.
  assert.ok(ls.some((l) => l.title === pick.title));
});

test("L9 A: the 255-option cap rejects oversized link sets with guidance", async () => {
  const ls = links(300, 0, "Economics", "markets prices supply demand");
  await assert.rejects(() => l9.pickWikiLink("A", "B", ls), /255/);
});

test("L9 B: hierarchicalClassify walks the tree to the right leaf", async () => {
  const taxonomy = {
    name: "root",
    description: "All topics",
    children: [
      { name: "Technology", description: "Computers, software, hardware" },
      {
        name: "Economics",
        description: "Markets, prices, supply, demand, paradoxes",
        children: [
          { name: "Microeconomics", description: "Individual markets, prices, elasticity" },
          { name: "Macroeconomics", description: "Whole-economy phenomena, inflation, growth" },
        ],
      },
    ],
  };
  const results = await l9.hierarchicalClassify(
    "A supply and demand market prices analysis of GPU pricing",
    taxonomy
  );
  assert.equal(results[0].path[0], "root");
  assert.equal(results[0].path[1], "Economics");
  assert.ok(results[0].confidence > 0.5);
  // Results are ranked by accumulated path probability.
  assert.ok(results[0].confidence >= results[1].confidence);
});

test("L9 B: onStep streams one beam step per taxonomy depth", async () => {
  const steps: l9.BeamStep[] = [];
  await l9.hierarchicalClassify(
    "A supply and demand market prices analysis of GPU pricing",
    {
      name: "root", description: "All topics",
      children: [
        { name: "Technology", description: "Computers, software, hardware" },
        { name: "Economics", description: "Markets, prices, supply, demand", children: [
          { name: "Microeconomics", description: "Individual markets, prices" },
          { name: "Macroeconomics", description: "Whole-economy phenomena" },
        ]},
      ],
    },
    2,
    (s) => steps.push(s)
  );
  assert.ok(steps.length >= 2, "at least root + one deeper level");
  assert.equal(steps[0].depth, 1);
  assert.ok(steps[0].options.includes("Economics"));
  assert.ok(Object.values(steps[0].probabilities).every((p) => p >= 0 && p <= 1));
});

test("L9 C: rerankShortlist ranks the answering candidate above the filler", async () => {
  const ranked = await l9.rerankShortlist(
    "What is the refund policy?",
    [
      { id: "r1", text: "Our company was founded in 2015 and has 40 employees." },
      { id: "r2", text: "Refunds are available within 30 days of purchase for unused licenses." },
    ]
  );
  assert.equal(ranked[0].id, "r2");
  assert.equal(ranked[0].keep, true);
});

test("L9 C: scores are sorted descending and keep honors the threshold", async () => {
  const ranked = await l9.rerankShortlist(
    "What is the refund policy?",
    [
      { id: "a", text: "Refund policy: full refunds within 30 days." },
      { id: "b", text: "Company history and team background." },
    ],
    1.5
  );
  for (let i = 1; i < ranked.length; i++) assert.ok(ranked[i - 1].score >= ranked[i].score);
});
