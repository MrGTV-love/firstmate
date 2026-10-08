import cp from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';
import {appendFileSync} from 'node:fs';
const original=cp.spawnSync;
cp.spawnSync=(...args)=>{const start=performance.now();const result=original(...args);appendFileSync(process.env.FM_POLICY_DIAGNOSTIC,JSON.stringify({elapsed_ms:performance.now()-start,status:result.status,signal:result.signal,error:result.error?.code})+'\n');return result;};
syncBuiltinESMExports();
