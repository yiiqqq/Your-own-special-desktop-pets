'use strict';
const assert=require('assert/strict'),fs=require('fs'),os=require('os'),path=require('path');
const D=require('../desktop/app/design-model'),M=require('../desktop/app/model'),IO=require('../desktop/app/design-io');
const png='data:image/png;base64,'+fs.readFileSync(path.join(__dirname,'../desktop/app/assets/tray.png')).toString('base64');
let p=M.freshState().pets[0];p.nickname='我画的小水滴';p.design={...D.fresh(),shape:'droplet',ears:'leaf',eyes:'spark',persona:'爱画画',images:{neutral:png,side:png}};p.chats=[{role:'user',content:'private-chat-do-not-export'}];
let packed=D.pack(p),text=JSON.stringify(packed);assert.ok(!text.includes('private-chat'));assert.equal(D.unpack(packed).design.shape,'droplet');assert.equal(D.png(png),true);
assert.equal(D.png('data:image/svg+xml;base64,PHN2Zz4='),false);assert.equal(D.png('data:image/png;base64,aGVsbG8='),false);
assert.equal(D.png('file:///etc/passwd'),false);assert.equal(D.normalize({color:'url(file://x)',shape:'script',images:{neutral:'https://tracker/face.png'}}).color,D.fresh().color);
assert.throws(()=>D.unpack({format:'wrong',version:1}));assert.throws(()=>D.unpack({...packed,version:999}));
const restored=M.normalize({pets:[p]});assert.equal(restored.pets[0].design.images.neutral,png);assert.equal(restored.pets[0].design.persona,'爱画画');assert.match(M.personality(restored.pets[0]),/爱画画/);
let dir=fs.mkdtempSync(path.join(os.tmpdir(),'little-companions-design-'));let file=path.join(dir,'character.json'),dest=path.join(dir,'export.json');fs.writeFileSync(file,text);
let dialog={showOpenDialog:async()=>({canceled:false,filePaths:[file]}),showSaveDialog:async()=>({canceled:false,filePath:dest})};
(async()=>{let q=M.freshState().pets[3];await IO.command('importCharacter',{},q,null,dialog,{});assert.equal(q.nickname,p.nickname);assert.equal(q.design.images.neutral,png);q.chats=[{role:'user',content:'secret-chat'}];await IO.command('exportCharacter',{},q,null,dialog,{});assert.ok(!fs.readFileSync(dest,'utf8').includes('secret-chat'));await IO.command('design',{design:{...q.design,color:'#b4d3f1'}},q,null,dialog,{});assert.equal(q.design.color,'#b4d3f1');fs.writeFileSync(file,'{"format":"wrong"}');await assert.rejects(IO.command('importCharacter',{},q,null,dialog,{}));
if(process.argv[2]){fs.mkdirSync(process.argv[2],{recursive:true});fs.writeFileSync(path.join(process.argv[2],'character-js.json'),text)}
fs.rmSync(dir,{recursive:true});console.log('PASS: editor validation, saved-state reload, actual JSON file import/export, persona, and private-data-free export');})().catch(e=>{console.error(e);process.exitCode=1});
