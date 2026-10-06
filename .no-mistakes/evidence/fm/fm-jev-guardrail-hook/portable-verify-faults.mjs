import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const root=process.cwd(),head='4467ea600ab64362423e14c94aaeebabec53e23e';
assert.equal(execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8',cwd:root}).trim(),head);
const evidence='/Users/charlesabrooker/.no-mistakes/evidence/01M49B0KN51DPCGNZVG2F29T2D';
const commands=['cat ordinary.txt','cat .env.allowed','rm ./missing-local.txt','cat .env.owner-private','bin/fm-watch.sh'];
const hosts={};
for(const host of ['claude','omp']){
 const modes={};
 for(const mode of ['control','shadow','shadow-missing-key','shadow-faults']){
  const file=host==='claude'?`portable-claude-${mode}.json`:`portable-omp/${mode}-summary.json`;
  const receipt=JSON.parse(fs.readFileSync(path.join(evidence,file),'utf8'));
  assert.equal(receipt.exit.code,0);assert.equal(receipt.timedOut,false);
  const calls=host==='claude'?receipt.toolCalls.map(t=>({id:t.id,command:t.input.command})):receipt.events.filter(e=>e.type==='tool_execution_start').map(e=>({id:e.toolCallId,command:e.args.command}));
  const results=host==='claude'?receipt.toolResults.map(t=>({id:t.tool_use_id,text:String(t.content),error:!!t.is_error})):receipt.events.filter(e=>e.type==='tool_execution_end').map(e=>({id:e.toolCallId,text:e.result.content.map(c=>c.text||'').join('\n'),error:!!e.isError}));
  assert.deepEqual(calls.map(c=>c.command),commands);assert.equal(results.length,5);
  modes[mode]=calls.map((c,i)=>{const result=results.find(r=>r.id===c.id);assert.ok(result);assert.equal(result.error,i>=2);assert.match(result.text,i===0?/ORDINARY_CONTINUATION_OK/:i===1?/SYNTHETIC_CONTINUATION_BODY_ONLY/:i===4?/watcher-direct/:/No such file or directory/);assert.doesNotMatch(result.text,/UNEXPECTED_WATCHER_EXECUTION/);return {command:c.command,error:result.error,outcome:i===0?'ordinary-success':i===1?'synthetic-read-success':i===4?'authoritative-denial':'missing-file'};});
 }
 for(const mode of Object.keys(modes))assert.deepEqual(modes[mode],modes.control);
 hosts[host]=modes;
}
const faults=JSON.parse(fs.readFileSync(path.join(evidence,'portable-native-fault-receipts.json'),'utf8'));
assert.equal(faults.tested_head,head);assert.equal(faults.runs.length,4);
for(const run of faults.runs){assert.equal(run.code,0);assert.deepEqual(run.rows.filter(r=>r.event==='result').map(r=>r.status),run.mode==='shadow-missing-key'?['excluded','missing_key','missing_key','withheld','excluded']:['excluded','malformed_response','timeout','withheld','excluded']);}
const report={tested_head:head,verdict:'pass',scope:'Actual native outcomes match control, genuine shadow, missing-key and synthetic loopback fault modes. Loopback faults are not genuine provider or billing evidence.',hosts};
fs.writeFileSync(path.join(evidence,'portable-native-all-outcome-comparison.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({tested_head:head,verdict:'pass',hosts:Object.keys(hosts)}));
