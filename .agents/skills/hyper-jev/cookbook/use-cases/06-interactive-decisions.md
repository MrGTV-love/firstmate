# 06. Interactive decisions

[Catalog and runtime setup](README.md). Demonstrations only, not calibrated production policies.

Use compact decisions to suggest an edit, hide a feed item reversibly, or choose the next form controls. The functions classify snapshots; they are not UI controllers. Keep network credentials on the server and let the UI apply only a decision for its current state.

## Three implementations

- **[watchEditorTone](../../templates/starter/src/levels/level06/editor-tone-watch.ts)**: draft -> three Scores for tone, urgency, and AI-like style, plus a specifics Noul -> `{ tone, urgency, readsAsAI, suggest }`. Scores range from 0 to 2. Tone `> 1.2` suggests `soften_tone`; otherwise specifics `< 0.4` suggests `add_specificity`; otherwise `none`. Use for optional feedback, not automatic rewriting or authorship detection.
- **[filterFeed](../../templates/starter/src/levels/level06/feed-filter.ts)**: one post's id/author/text per request -> category Choice + hide Noul -> `{ id, hide, reason }[]`. Hide when category is not `genuine` with confidence `> 0.6`, or hide Noul `> 0.75`. Other categories are `rage_bait`, `promo`, `political_argument`. Results preserve input order. Use for a user-controlled filter with undo, not irreversible moderation.
- **[adaptiveForm / decideForm](../../templates/starter/src/levels/level06/adaptive-form.ts)**: answer text -> intent Choice + readiness Score -> `{ controls, rationale }`. Enterprise gets security questionnaire, pricing tier, company details. Small teams get pricing plus integration checklist when readiness `> 1`, otherwise checklist plus free text. Support and solo/default get free text. Use to suggest navigation through registered controls; it does not validate form fields or gate by confidence.

## Try a latest-result-only adapter

Save as `example.ts` in the starter root. This adapter discards stale results; it does **not** abort a request or debounce typing.

```ts
import { watchEditorTone } from "./src/levels/level06/editor-tone-watch.ts";

let revision = 0;
async function inspectDraft(draft: string) {
  const requestedRevision = ++revision;
  try {
    const signals = await watchEditorTone(draft);
    if (requestedRevision === revision) console.log({ signals });
  } catch {
    if (requestedRevision === revision) console.log({ status: "unavailable" });
  }
}
await Promise.all([
  inspectDraft("Please review the invoice."),
  inspectDraft("Invoice INV-204 is $490 instead of $245. Can we fix it this week?"),
]);
```

```bash
JEV_BACKEND=mock node example.ts
npm test
```

## Boundaries and tests

[Existing tests](../../templates/starter/tests/level06.test.ts) check score ranges, hostile-tone suggestions, genuine/outrage posts, enterprise controls, and the pure support form path. They do **not** test debounce, abort, stale responses, or race conditions.

Source comments mention a 600 ms typing pause, but no timer, event subscription, abort, or latest-state guard is implemented. Production code must debounce, advance a revision on every edit, abort superseded work, and check revision again before rendering. The [core client](../../templates/starter/src/core/client.ts) accepts `systemOne(..., { signal })`: live cancellation covers fetch, retry waits, and response bodies; already-aborted calls reject in both live and mock modes. Mock work is synchronous, so it does not simulate an in-flight network race. These wrappers do not expose the signal. Adapt them to thread cancellation through and retain a latest-state guard even after adding abort. The [client tests](../../templates/starter/tests/client.test.ts) cover transport cancellation, not UI state correctness.

Add tests that resolve two requests in reverse order, reject an obsolete request, unmount a view, return an empty feed, and hit exact threshold values. Verify hidden posts can be restored and form changes do not discard entered data.

## Production policy

`filterFeed` uses unbounded `Promise.all`; limit concurrency, deduplicate stable item IDs, and decide whether one failed request should fail the batch or preserve existing UI state. Cache only against the full input and policy/model version. Show neutral unavailable state on failure. Avoid uploading sensitive drafts without appropriate consent and retention controls. An AI-like style score is not evidence that a person used AI.
