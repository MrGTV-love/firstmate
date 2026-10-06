#!/usr/bin/env node
const {spawn}=require('node:child_process');
const args=process.argv.slice(2).map(arg=>arg==='https://api.typesafe.ai/v1/systemone'?process.env.JEV_FAULT_URL:arg);
if(!args.includes(process.env.JEV_FAULT_URL))process.exit(126);
const child=spawn('/usr/bin/curl',args,{stdio:[0,1,2,3]});child.on('error',()=>process.exit(127));child.on('close',code=>process.exit(code??1));
