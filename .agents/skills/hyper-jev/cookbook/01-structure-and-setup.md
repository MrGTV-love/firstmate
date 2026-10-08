# Structure and setup

## Install the local skill

Copy the entire `hyper-jev` directory to `.claude/skills/hyper-jev/` in the destination repository. Keep its cookbook and templates together. It does not depend on the original repository or a global skill installation.

Invoke `/hyper-jev <request prompt>`. Restart the agent session if its skill list was loaded before installation.

## Concrete codebase

The starter mirrors the source repository's Jev code without its presentation or agent-launcher files:

```text
jev-service/
  package.json                 Node 24, ESM, offline tests and example commands
  tsconfig.json                strict TypeScript, .ts imports, no build required
  .env.example                 credential names only, never real keys
  src/
    core/
      client.ts                provider selection, HTTP, retries, raw bodies, metadata
      types.ts                 wire types, input validation, limits
      helpers.ts               noul(), choice(), score()
      mock.ts                  deterministic offline contract stand-in
    decisions/
      support-routing.ts       input validation, question, policy, complete result
    levels/
      level01/ ... level10/    three examples per pattern, index.ts exports
    usage-ledger.ts            reported, estimated, unknown, mock, and failed counts
    example.ts                 one decision with safe metadata-only output
  tests/
    core.test.ts               question builders and contract checks
    client.test.ts             HTTP stubs, credentials, retries, raw bodies, costs
    support-routing.test.ts    application-policy boundaries
    level01.test.ts ...        examples tested against the deterministic mock
```

Copy the whole core directory, including any sibling helpers, rather than only `client.ts`.

## Start from a clean directory

Set `SKILL_DIR` to the absolute path of this installed skill. Choose a destination that does not exist so nothing is overwritten.

```sh
SKILL_DIR="/absolute/path/to/repo/.claude/skills/hyper-jev"
DEST="./jev-service"
test ! -e "$DEST" && cp -R "$SKILL_DIR/templates/starter" "$DEST" && (
  cd "$DEST" && npm test && npm run demo
)
```

Node 24 executes TypeScript directly. No install is needed for runtime checks. For static checking, install the starter's development dependencies, then run `npm run typecheck`.

## Configure a live service

Inject credentials through your secret manager:

| Configuration | Default selection |
| --- | --- |
| `TYPESAFE_API_KEY` present | Direct TypeSafe |
| Only `OPENROUTER_API_KEY` present | OpenRouter decisions endpoint |
| Neither present | Startup error outside offline test isolation |
| `JEV_BACKEND=mock` | Explicit offline simulation |
| `JEV_BACKEND=typesafe` or `openrouter` | Force that backend and require its key |

Both live endpoints run Jev. OpenRouter is selected because its key is available, not as an automatic response to a TypeSafe error. Leave `JEV_BACKEND` unset for automatic key precedence.

Load configuration before `new JevClient()`. With an already provisioned local `.env`, Node can load it explicitly:

```sh
node --env-file=.env src/example.ts
```

The template never loads secrets merely because a file is present. Shell-injected credentials work with `npm start`. Do not put keys in frontend environment variables or commit `.env`.

## Integrate into an existing backend

Keep the host application's conventions. Put the core under its server integration directory, instantiate a client at startup, and inject it into the new decision service. Copy only the desired use-case modules. Keep imports server-only.

The examples' shared `jev` export constructs its client lazily on first use. Set configuration before that access. Constructing a client at startup is clearer for production because missing-key errors occur before serving requests.

Use [support-routing.ts](../templates/starter/src/decisions/support-routing.ts) as the service shape: validated input in, `{ decision, result }` out, with transport errors propagated to an explicit application fallback. Do not copy the lab server as a production API.
