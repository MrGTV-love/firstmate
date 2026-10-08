import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
const root = process.cwd();
const lab = `${root}/.native-stop-lab`;
const state = `${lab}/case/home/state`;
const timeline = [];
const panes = [];
let prior = '';
let blockedSeen = false;
const start = Date.now();
function read(path) { try { return fs.readFileSync(path, 'utf8'); } catch { return ''; } }
while (Date.now() - start < 180000) {
  const busy = read(`${state}/native-stop.busy-state`).trim();
  const turnEnded = fs.existsSync(`${state}/native-stop.turn-ended`);
  const decisions = read(`${lab}/hook-home/.claude/belay/decisions.jsonl`).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  const blocked = decisions.some(d => d.verdict === 'blocked');
  const key = JSON.stringify({busy, turnEnded, decisions: decisions.length, exited: fs.existsSync(`${lab}/native-exit-code`)});
  if (key !== prior) {
    timeline.push({ts: new Date().toISOString(), elapsedMs: Date.now()-start, busy, turnEnded, decisions, exitCode: read(`${lab}/native-exit-code`).trim() || null});
    fs.writeFileSync(`${lab}/timeline.json`, JSON.stringify(timeline, null, 2)+'\n');
    prior = key;
  }
  if ((blocked && !blockedSeen) || fs.existsSync(`${lab}/native-exit-code`)) {
    const capture = spawnSync(`${root}/bin/fm-herdr-lab.sh`, ['run','fm-lab-native-stop-65931','pane','read','w1:p1','--source','visible'], {env:{...process.env,FM_HERDR_LAB_STATE_DIR:`${lab}/helper-state`},encoding:'utf8'});
    panes.push({ts:new Date().toISOString(), reason:blocked && !blockedSeen ? 'first-block' : 'native-exit', code:capture.status, output:capture.stdout, stderr:capture.stderr});
    fs.writeFileSync(`${lab}/pane-captures.json`, JSON.stringify(panes,null,2)+'\n');
    blockedSeen = blocked;
  }
  if (fs.existsSync(`${lab}/native-exit-code`)) break;
  await new Promise(resolve => setTimeout(resolve,100));
}
console.log(JSON.stringify({observationFinished:true, samples:timeline.length, blockedSeen, exited:fs.existsSync(`${lab}/native-exit-code`), elapsedMs:Date.now()-start}));
