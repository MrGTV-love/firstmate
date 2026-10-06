#!/usr/bin/env node
'use strict';
const {spawn}=require('node:child_process');
const fs=require('node:fs');
const args=process.argv.slice(2);
// Authorization lives on stdin: inherit fd 0 without ever reading it.
if(args[0]!=='-q')process.exit(126);
const index=args.indexOf('--data-binary');
if(index<0||index+1>=args.length||args[index+1].startsWith('@'))process.exit(126);
if(!args.some((arg,i)=>arg==='-H'&&args[i+1]==='@-'))process.exit(126);
let request;try{request=JSON.parse(args[index+1]);}catch{process.exit(126);}
if(JSON.stringify(Object.keys(request).sort())!==JSON.stringify(['model','questions','state']))process.exit(126);
if(request.model!=='jev-1.13.0'||JSON.stringify(Object.keys(request.state).sort())!==JSON.stringify(['operations','syntax_uncertain'])||JSON.stringify(Object.keys(request.questions))!==JSON.stringify(['risk']))process.exit(126);
if(!Array.isArray(request.state.operations)||request.state.operations.some(op=>JSON.stringify(Object.keys(op).sort())!==JSON.stringify(['force','operation','recursive','scope'])))process.exit(126);
fs.appendFileSync(process.env.JEV_LAB_REQUESTS,JSON.stringify({at:Date.now(),transport:'real /usr/bin/curl; -q first; structural --data-binary argv observed only; authorization stdin inherited unread; unmodified argv/stdin; no response injection',request})+'\n',{mode:0o600});
const child=spawn('/usr/bin/curl',args,{stdio:[0,1,2]});
child.on('error',()=>process.exit(127));child.on('close',code=>process.exit(code??1));
