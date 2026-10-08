# Production checks

## Deploy the integration, not the lab

Run the Jev client inside an authenticated backend or worker. There is no model server to provision in this starter. Node 24 supplies native fetch, abort signals, TypeScript execution, and the test runner.

Construct the client after secrets/configuration load and before accepting work. Report the selected provider name at startup. Rotate credentials by constructing a new instance or restarting the process. Pin a provider-supported model ID when reproducibility requires it.

The repository previously exercised OpenRouter live. Direct TypeSafe is supplied as a transport path, not a newly verified deployment. Offline tests in this bundle simulate both providers. Validate endpoint, account access, limits, and model availability with an authorized smoke test.

## Release checklist

| Check | Required evidence |
| --- | --- |
| Credentials | No key in browser bundles, logs, source, or raw audit headers |
| Provider selection | Both keys, one key, no keys, explicit override, post-construction changes |
| Contract | Invalid requests rejected, malformed responses fail, unknown labels never dispatch |
| Input policy | Data minimization, size limits, access controls, approved provider data handling |
| Time and load | Caller cancellation, total deadline, bounded concurrency and volume |
| Accounting | Reported/estimated costs separated, unknown not counted as zero, failures tracked |
| Audit | Complete wire data only in an approved restricted store, with a retention/deletion policy |
| Model quality | Labeled validation, per-route errors, calibrated thresholds, model/rubric version |
| Side effects | Deterministic permissions and business validation, review, idempotent execution |
| Failures | Auth/config fails visibly, outages use safe application fallback, no provider switching |

## Failure policy belongs to the use case

A router can send uncertain requests to a human queue. A tool-risk gate should pause execution if its classifier is unavailable. An advisory tone signal can be omitted temporarily. Make these choices explicit rather than treating missing answers as positive results.

Confidence does not grant permission. A highly confident answer cannot authorize a transfer, execute a shell command, approve deployment, or bypass required human confirmation. Jev evaluates supplied evidence and can be wrong.

Retries can incur charges and the final response cannot reveal every failed attempt's usage. Do not automatically retry a whole business operation after a decision triggered side effects. Keep classification separate from idempotent execution.

## Raw payloads and privacy

Keep exact request/response bodies when the domain requires reproducibility. They can contain customer text, identifiers, sensitive rubrics, and provider metadata. Returning them does not authorize public logging.

Store raw bodies in a restricted encrypted audit store if required. Routine telemetry gets provider, requested/resolved model, latency, attempts, usage, cost source, policy version, and a correlation ID. A redacted operational log is a separate artifact, not a replacement presented as the original payload.

The starter retains payloads in memory and returns them. It does not choose a database or implement durable retention for your organization.

## Operating checks

- Monitor latency/failures by provider/model, review rate by use case, and reported versus estimated spend.
- Bound loops by ticks/depth, deadline, and budget. Recheck state before delayed actions.
- For interactive requests, debounce, abort superseded work, and ignore stale responses. A fast model does not remove race conditions.
- Detect distribution shifts with labeled review samples. Do not promote an alias update just because its JSON contract passes.

See [client operations](04-client-operations.md) for exact retry/cost behavior and the [use-case catalog](use-cases/README.md) for sample limitations.
