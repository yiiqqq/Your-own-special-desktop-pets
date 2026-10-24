'use strict';
const assert=require('assert/strict'),crypto=require('crypto'),U=require('../desktop/app/updater');
let {publicKey,privateKey}=crypto.generateKeyPairSync('ed25519'),key=publicKey.export({format:'der',type:'spki'}).subarray(-32).toString('base64');
let artifact={url:'https://example.test/character-update.zip',bytes:1024,sha256:'a'.repeat(64),kind:'resources-app',runtimeMajor:45};
let data={schema:1,version:'0.8.2',notes:'test only',artifacts:{'win32-x64':artifact}};
function sign(d){let payload=Buffer.from(JSON.stringify(d));return JSON.stringify({payload:payload.toString('base64'),signature:crypto.sign(null,payload,privateKey).toString('base64')})}
assert.equal(U.verify(sign(data),key,'win32-x64').version,'0.8.2');assert.equal(U.verify(sign({...data,version:U.VERSION}),key,'win32-x64'),null);let text=JSON.parse(sign(data));text.signature=Buffer.alloc(64).toString('base64');assert.throws(()=>U.verify(JSON.stringify(text),key,'win32-x64'));assert.throws(()=>U.verify(sign({...data,artifacts:{'win32-x64':{...artifact,url:'http://example.test/unsafe.zip'}}}),key,'win32-x64'));assert.throws(()=>U.verify(sign({...data,artifacts:{'win32-x64':{...artifact,runtimeMajor:46}}}),key,'win32-x64'));
console.log('PASS: update signatures, tampering, old version, HTTPS and runtime version rejection');
