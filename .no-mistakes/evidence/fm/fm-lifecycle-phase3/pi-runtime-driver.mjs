import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,existsSync,rmSync,cpSync} from 'node:fs';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const root=process.cwd(), evidence=process.env.FM_TEST_EVIDENCE;
const work=join(root,'.phase3-live/pi-runtime'); mkdirSync(work,{recursive:true});
const home=mkdtempSync(join(evidence,'pi-lab-'));
assert.equal(spawnSync('bin/fm-lab-home.sh',['create',home],{encoding:'utf8'}).status,0);
const agentDir=join(work,'agent');mkdirSync(agentDir,{recursive:true});
const watcher=join(work,'watch.ts');
writeFileSync(watcher,`export {default} from ${JSON.stringify(join(work,'.pi/extensions/fm-primary-pi-watch.ts'))};\n`);
const duplicate=join(work,'duplicate.ts');writeFileSync(duplicate,`export {default} from ${JSON.stringify(watcher)};\n`);
for(const key of ['FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_HOME','TMUX','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH']) delete process.env[key];
Object.assign(process.env,{FM_HOME:home,PI_CODING_AGENT_DIR:agentDir,FM_PI_SUCCESSOR_GRACE_MS:'1500'});
writeFileSync(join(home,'state/.lock'),`${process.pid}\n`);
const {DefaultResourceLoader,SettingsManager,SessionManager,createAgentSession}=await import(pathToFileURL(join(process.env.FM_PI_PACKAGE_DIR,'dist/index.js')).href);
const loader=new DefaultResourceLoader({cwd:work,agentDir,settingsManager:SettingsManager.inMemory(),additionalExtensionPaths:[watcher,duplicate],noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,noContextFiles:true});
let session;
const logFile=join(home,'state/extensions/pi-primary-watch/lifecycle.log');
const log=()=>existsSync(logFile)?readFileSync(logFile,'utf8'):'';
const watcherPid=()=>{try{return Number(readFileSync(join(home,'state/.watch.lock/pid'),'utf8').trim())}catch{return 0}};
const alive=pid=>{if(!pid)return false;try{process.kill(pid,0);return true}catch{return false}};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function waitFor(fn,label){for(let n=0;n<400;n++){if(fn())return;await sleep(100)}throw new Error(`timeout: ${label}\n${log()}`)}
const observations=[];
try {
 await loader.reload();assert.deepEqual(loader.getExtensions().errors,[]);
 ({session}=await createAgentSession({cwd:work,agentDir,resourceLoader:loader,sessionManager:SessionManager.inMemory(work),settingsManager:SettingsManager.inMemory(),tools:['fm_watch_arm_pi']}));
 await session.bindExtensions({onError:error=>observations.push({extensionError:error})});
 await waitFor(()=>alive(watcherPid()),'real first watcher');await sleep(1500);
 const first=watcherPid();assert.equal(session.getAllTools().filter(t=>t.name==='fm_watch_arm_pi').length,1);
 const arm=await session.getToolDefinition('fm_watch_arm_pi').execute('live-arm',{},undefined,undefined,{});assert.equal(arm.details.ok,true);assert.match(arm.details.message,/unchanged/);
 assert.equal(watcherPid(),first);observations.push({scenario:'duplicate entrypoint and idempotent tool',firstWatcher:first,armResult:arm.details});
 await session.reload();await waitFor(()=>watcherPid()!==first&&alive(watcherPid()),'reload successor');
 await waitFor(()=>!alive(first),'retired first watcher');
 const successor=watcherPid();assert.equal(session.getAllTools().filter(t=>t.name==='fm_watch_arm_pi').length,1);
 observations.push({scenario:'reload successor',retiredWatcher:first,currentWatcher:successor});
 // Real replacement failure: invalidate the outgoing runtime, then make the watched module invalid before resource reload.
 writeFileSync(watcher,'this is deliberately invalid TypeScript !!!\n');
 await session.reload();
 await waitFor(()=>log().includes('event=successor-missing'),'missing-successor diagnostic');
 const expiry=log().split('\n').filter(s=>s.includes('event=bound-expired')&&s.includes('waited-on=session_start'));
 assert.equal(expiry.length,1);assert.match(expiry[0],/waiter=pi-watch-extension.*bound=1500ms.*actual=\d+ms.*outcome=successor-missing/);
 assert.ok(!session.getAllTools().some(t=>t.name==='fm_watch_arm_pi'));
 const owner=readFileSync(join(home,'state/.pi-watch-extension-loaded'),'utf8');
 assert.match(owner,/phase=handoff/);assert.ok(!owner.includes('phase=active'));
 observations.push({scenario:'failed reload refuses false active state',resourceErrors:loader.getExtensions().errors,expiry:expiry[0],owner,tools:session.getAllTools().map(t=>t.name)});
 console.log(JSON.stringify(observations,null,2));
} finally {
 writeFileSync(join(evidence,'pi-live-runtime.json'),JSON.stringify(observations,null,2)+'\n');
 writeFileSync(join(evidence,'pi-live-lifecycle.log'),log());
 if(existsSync(join(home,'state/.watch-extension.log'))) cpSync(join(home,'state/.watch-extension.log'),join(evidence,'pi-live-extension.log'));
 writeFileSync(join(evidence,'pi-live-session-messages.json'),JSON.stringify(session?.state?.messages??[],null,2));
 if(session){await session.extensionRunner?.emit({type:'session_shutdown',reason:'quit'});session.dispose()}
 spawnSync('bin/fm-watch-arm.sh',['--stop'],{env:process.env,encoding:'utf8'});
 rmSync(home,{recursive:true,force:true});
}
process.exit(0);
