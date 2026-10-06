import fs from 'node:fs';
import path from 'node:path';
import {spawn,execFileSync} from 'node:child_process';
const root=process.cwd(), lab=path.join(root,'jev-main013-0ykxus2e');
const evidence='/Users/charlesabrooker/.no-mistakes/evidence/01M49B0KN51DPCGNZVG2F29T2D';
let credential='', assignment='';
const env={...process.env,PATH:path.join(lab,'realbin')+':'+process.env.PATH,JEV_LAB_REQUESTS:path.join(lab,'real-requests.jsonl'),TEAMCLAUDE_DISABLE_AUTOUPDATE:'1'};
const runs=[];
async function run(host,mode){
 const args=host==='claude'?[path.join(lab,'native-claude.mjs'),root,lab,evidence,mode]:[path.join(lab,'native-omp.mjs'),path.join(lab,'native-omp-omp'),path.join(lab,'generated/omp/effective-state/main013-native-omp.omp-ext.ts'),root,path.join(evidence,'main013-omp'),mode];
 const start=Date.now(); const child=spawn('node',args,{cwd:root,env,stdio:['ignore','pipe','pipe']});
 let stdout='',stderr='';child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);
 const code=await new Promise(r=>{child.on('close',r);child.on('error',()=>r(127));});
 if(stdout.includes(credential)||stderr.includes(credential))throw Error('Credential-output privacy violation');
 const receipt={host,mode,code,elapsed_ms:Date.now()-start,stdout,stderr};runs.push(receipt);
 fs.writeFileSync(path.join(evidence,`main013-${host}-${mode}-driver.json`),JSON.stringify(receipt,null,2)+'\n',{mode:0o600});
 console.log(JSON.stringify({host,mode,code,elapsed_ms:receipt.elapsed_ms,stdout,stderr}));
}
try{
 // Captured extraction returns ONLY the explicitly authorized assignment; no source/eval, dotenv dump, tracing or key-bearing argv.
 assignment=execFileSync('/usr/bin/grep',['-m','1','-E','^(export[[:space:]]+)?TYPESAFE_API_KEY=', '/Users/charlesabrooker/firstmate/.env'],{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim();
 credential=assignment.slice(assignment.indexOf('=')+1).trim();
 if((credential.startsWith('"')&&credential.endsWith('"'))||(credential.startsWith("'")&&credential.endsWith("'")))credential=credential.slice(1,-1);
 if(!credential||/[\r\n]/.test(credential))throw Error('Authorized assignment missing or unsupported');
 assignment='';env.TYPESAFE_API_KEY=credential;delete env.TYPESAFE_API_KEY_PRIVATE;
 // Only omp shadow remains; control runs without a Jev credential and Claude evidence is retained.
 await run('omp','shadow');
 fs.writeFileSync(path.join(evidence,'main013-scoped-acquisition-final.json'),JSON.stringify({scope:'Third scoped acquisition resumes only omp shadow after documented XDG state/cache isolation. Earlier scopes and all failed native starts retained separately. Each captured extraction returns only the authorized assignment, inherited by native children, never written or printed. No repeated provider requests.',runs:runs.map(({host,mode,code,elapsed_ms})=>({host,mode,code,elapsed_ms})),credential_cleanup:'finally removes scoped environment value and references'},null,2)+'\n',{mode:0o600});
}catch{
 fs.writeFileSync(path.join(evidence,'main013-scoped-acquisition-omp-failure.json'),JSON.stringify({error:'Scoped credential acquisition or native execution failed; no credential disclosed',completed:runs.map(({host,mode,code,elapsed_ms})=>({host,mode,code,elapsed_ms}))},null,2)+'\n',{mode:0o600});process.exitCode=2;
}finally{
 delete env.TYPESAFE_API_KEY;delete env.TYPESAFE_API_KEY_PRIVATE;delete process.env.TYPESAFE_API_KEY;delete process.env.TYPESAFE_API_KEY_PRIVATE;assignment='';credential='';
}
