#!/usr/bin/env node
const {spawn}=require('node:child_process');
const original=process.argv.slice(2),url=process.env.JEV_FAULT_URL;
if(original[0]!=='-q'||!/^http:\/\/127\.0\.0\.1:\d+\/synthetic$/.test(url||''))process.exit(126);
const args=original.map(arg=>arg==='https://api.typesafe.ai/v1/systemone'?url:arg);
if(!args.includes(url))process.exit(126);
// Synthetic fault key remains on inherited stdin, never read or recorded.
const child=spawn('/usr/bin/curl',args,{stdio:[0,1,2]});child.on('error',()=>process.exit(127));child.on('close',code=>process.exit(code??1));
