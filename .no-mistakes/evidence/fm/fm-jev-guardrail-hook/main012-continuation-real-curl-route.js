#!/usr/bin/env node
const {spawn}=require('node:child_process');const args=process.argv.slice(2).map(x=>x==='https://api.typesafe.ai/v1/systemone'?'http://127.0.0.1:52377/v1/systemone':x);const c=spawn('/usr/bin/curl',args,{stdio:[0,1,2,3]});c.on('exit',(code)=>process.exit(code??1));c.on('error',()=>process.exit(1));
