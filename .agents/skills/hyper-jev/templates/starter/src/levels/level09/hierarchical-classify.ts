/**
 * Level 9, option B: hierarchical classification.
 * One Choice per expanded node, beam search over the returned probabilities.
 * Request count depends on depth and beam width.
 */
import { jev } from "../../core/client.ts";
import { choice, score } from "../../core/helpers.ts";
import type { ChoiceAnswer } from "../../core/types.ts";

export interface TaxonomyNode {
  name: string;
  description: string;
  children?: TaxonomyNode[];
}

export interface HierarchicalResult {
  path: string[];
  confidence: number;
}

/**
 * B: hierarchical classification. At each level, one Choice over the children;
 * code beam-searches the returned probabilities down the tree, retaining
 * completed leaves alongside new candidates.
 */
export interface BeamStep {
  depth: number;
  at: string[];           // the path being expanded
  options: string[];      // the child categories offered
  choice: string;         // the selected child
  probabilities: Record<string, number>;
}

export async function hierarchicalClassify(
  document: string,
  taxonomy: TaxonomyNode,
  beamWidth = 2,
  onStep?: (step: BeamStep) => void
): Promise<HierarchicalResult[]> {
  const results: HierarchicalResult[] = [];
  let frontier: { node: TaxonomyNode; path: string[]; score: number }[] = [
    { node: taxonomy, path: [taxonomy.name], score: 1 },
  ];
  while (frontier.some((f) => f.node.children && f.node.children.length > 0)) {
    const expandable = frontier.filter((f) => f.node.children && f.node.children.length > 0);
    // Completed candidates compete with new children instead of disappearing.
    const next = frontier.filter((f) => !f.node.children?.length);
    for (const entry of expandable) {
      const children = entry.node.children!;
      const criteria = Object.fromEntries(children.map((c) => [c.name, c.description]));
      const { answers } = await jev.systemOne(
        { document, path_so_far: entry.path.join(" > ") },
        {
          classify: choice(
            `Given the path so far \`path_so_far\`, which child category does \`document\` belong to?`,
            criteria
          ),
        }
      );
      const a = answers.classify as ChoiceAnswer;
      onStep?.({
        depth: entry.path.length,
        at: entry.path,
        options: children.map((c) => c.name),
        choice: a.choice,
        probabilities: a.probabilities,
      });
      for (const child of children) {
        const p = a.probabilities[child.name] ?? 0;
        next.push({ node: child, path: [...entry.path, child.name], score: entry.score * p });
      }
    }
    next.sort((x, y) => y.score - x.score);
    frontier = next.slice(0, beamWidth);
    // Terminal nodes survive into the final ranking; expandable ones continue.
    if (frontier.length === 0) break;
  }
  for (const f of frontier) {
    results.push({ path: f.path, confidence: Math.round(f.score * 1000) / 1000 });
  }
  return results.sort((a, b) => b.confidence - a.confidence);
}
