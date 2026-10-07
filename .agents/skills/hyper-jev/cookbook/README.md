# Jev cookbook

Start with the decision you need. The reusable structure is transport, typed questions, reviewable policy, and tests.

| Read | Use it for |
| --- | --- |
| [Structure and setup](01-structure-and-setup.md) | Copy the starter or integrate its core into an existing backend |
| [Input and output](02-input-output.md) | Endpoints, state, question types, response shapes, limits |
| [Question design](03-question-design.md) | Rubrics, uncertainty, batching, deterministic policy |
| [Client operations](04-client-operations.md) | One-time provider selection, retries, raw payloads, costs |
| [Production checks](05-production.md) | Deploy safely, calibrate, observe, and test failure behavior |
| [Use cases](use-cases/README.md) | Thirty concrete examples across ten patterns |

## Three layers

1. **Transport:** `src/core/client.ts` sends the decision contract to TypeSafe or OpenRouter. Its sibling types, builders, and mock keep the boundary explicit.
2. **Judgment:** `src/levels/levelNN/<use-case>.ts` defines the state and questions. Rename these folders by domain in an application.
3. **Policy:** derive a route, score, or review decision without losing the original result. [The starter service](../templates/starter/src/decisions/support-routing.ts) shows this shape.

The [starter](../templates/starter/README.md) has no presentation layer and no runtime dependencies beyond Node 24. Its thirty examples are teaching implementations. Their thresholds are not calibrated defaults for your product.
