#!/usr/bin/env bash
set -eu
. ./tests/lib.sh
D="$PWD/.live-validation/policy-debug"
mkdir -p "$D/primary/data/vendor/jev-belay" "$D/lane" "$D/shims"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$D/primary" > "$D/lane/.fm-secondmate-parent"
printf 'TYPESAFE_API_KEY=diagnostic-fixture-key\n' > "$D/primary/.env"
cat > "$D/primary/data/vendor/jev-belay/belay.mjs" <<'JS'
for(let n=0;n<2;n++) { try { await (await fetch('https://api.typesafe.ai/v1/systemone',{method:'POST',body:JSON.stringify({state:{task:'ordinary'}})})).json(); } catch(e) { console.error('FETCH',n,e.name,e.message);process.exit(0); } }
JS
cat > "$D/transport.mjs" <<'JS'
import {appendFileSync} from 'node:fs';
globalThis.fetch=async()=>{appendFileSync(process.env.FM_DEBUG_REQUESTS,'transport\n');return {json:async()=>({allowed:true})};};
JS
for command in dirname git jq grep tr mktemp rm cat; do
 real=$(command -v "$command")
 printf '#!/bin/bash\nprintf "%%s %%s\\n" "$SECONDS" "%s" >> "$FM_DEBUG_COMMANDS"\nexec "%s" "$@"\n' "$command" "$real" > "$D/shims/$command"
 chmod +x "$D/shims/$command"
done
blob=$(git hash-object "$D/primary/data/vendor/jev-belay/belay.mjs")
: > "$D/requests"; : > "$D/commands"; : > "$D/diagnostic"
printf payload | env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE FM_HOME="$D/lane" FM_CONFIG_OVERRIDE='' FM_JEV_BELAY_BLOB="$blob" FM_DEBUG_REQUESTS="$D/requests" FM_DEBUG_COMMANDS="$D/commands" FM_POLICY_DIAGNOSTIC="$D/diagnostic" NODE_OPTIONS="--import=$D/transport.mjs --import=$PWD/.live-validation/policy-diagnostic.mjs" PATH="$D/shims:$PATH" "$PWD/bin/fm-jev-belay-hook.sh"
printf 'Per-request policy child observations:\n';cat "$D/diagnostic"
printf 'Completed transport receipts:\n';cat "$D/requests"
