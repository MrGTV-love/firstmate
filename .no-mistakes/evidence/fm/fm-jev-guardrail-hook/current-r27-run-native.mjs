import fs from 'node:fs';
import path from 'node:path';
import {spawn,execFileSync} from 'node:child_process';
const root=process.cwd(),lab=path.join(root,'jev-current-native-lab');
const evidence='/Users/charlesabrooker/.no-mistakes/evidence/01M49B0KN51DPCGNZVG2F29T2D';
const env={...process.env,PATH:path.join(lab,'realbin')+':'+process.env.PATH,JEV_LAB_REQUESTS:path.join(lab,'real-requests.jsonl'),TEAMCLAUDE_DISABLE_AUTOUPDATE:'1'};
let credential='',assignment='';const runs=[];
async function run(host,mode){
 const args=host==='claude'?[path.join(lab,'native-claude.mjs'),root,lab,evidence,mode]:[path.join(lab,'native-omp.mjs'),path.join(lab,'native-omp-omp'),path.join(lab,'generated/omp/effective-state/current-r27-native-omp.omp-ext.ts'),root,path.join(evidence,'current-r27-omp'),mode];
 const childEnv={...env};if(mode==='control'){delete childEnv.TYPESAFE_API_KEY;delete childEnv.TYPESAFE_API_KEY_PRIVATE;}
 const start=Date.now();const child=spawn('node',args,{cwd:root,env:childEnv,stdio:['ignore','pipe','pipe']});let stdout='',stderr='';child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);
 const code=await new Promise(r=>{child.on('close',r);child.on('error',()=>r(127));});
 delete childEnv.TYPESAFE_API_KEY;delete childEnv.TYPESAFE_API_KEY_PRIVATE;
 if(credential&&(stdout.includes(credential)||stderr.includes(credential)))throw Error('Credential-output privacy violation');
 const receipt={host,mode,code,elapsed_ms:Date.now()-start,stdout,stderr};runs.push(receipt);fs.writeFileSync(path.join(evidence,`current-r27-${host}-${mode}-driver.json`),JSON.stringify(receipt,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(receipt));if(code!==0)throw Error('Native driver failed');
}
try{
 await run('claude','control');await run('omp','control');
 // Authorized extraction is captured in execution memory only; never source/eval/dump the dotenv or put key in argv.
 assignment=execFileSync('/usr/bin/grep',['-m','1','-E','^(export[[:space:]]+)?TYPESAFE_API_KEY=','/Users/charlesabrooker/firstmate/.env'],{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim();
 credential=assignment.slice(assignment.indexOf('=')+1).trim();if((credential.startsWith('"')&&credential.endsWith('"'))||(credential.startsWith("'")&&credential.endsWith("'")))credential=credential.slice(1,-1);
 if(!credential||/[\r\n]/.test(credential))throw Error('Authorized assignment missing or unsupported');assignment='';env.TYPESAFE_API_KEY=credential;delete env.TYPESAFE_API_KEY_PRIVATE;
 await run('claude','shadow');await run('omp','shadow');
}catch{process.exitCode=2;console.log(JSON.stringify({error:'Scoped acquisition or native execution failed; see preserved driver receipts, no credential disclosure'}));}
finally{delete env.TYPESAFE_API_KEY;delete env.TYPESAFE_API_KEY_PRIVATE;delete process.env.TYPESAFE_API_KEY;delete process.env.TYPESAFE_API_KEY_PRIVATE;assignment='';credential='';fs.writeFileSync(path.join(evidence,'current-r27-scoped-acquisition.json'),JSON.stringify({head:'d2e4380c3b80be99babe3d4ec04b32b1c3007340',runs:runs.map(({host,mode,code,elapsed_ms})=>({host,mode,code,elapsed_ms})),credential_route:'Only authorized assignment captured once directly inside execution process; no key file/argv/header capture; native children inherit process environment; references removed in finally',prior_receipts:'All main012/main013 and earlier setup/synthetic/provider receipts retained unchanged'},null,2)+'\n',{mode:0o600});}
