'use strict';
const {chromium}=require('playwright'),path=require('path'),assert=require('assert/strict'),M=require('../desktop/app/model');
(async()=>{
 const launch={headless:true};if(process.env.CHROME_PATH)launch.executablePath=process.env.CHROME_PATH;
 const browser=await chromium.launch(launch);try{const page=await browser.newPage({viewport:{width:1200,height:900}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(initial=>{let state=initial,listeners={};window.littlepets={on:(e,fn)=>{(listeners[e]??=[]).push(fn)},command:async(cmd,arg={})=>{if(cmd==='get')return structuredClone(state);if(cmd==='updateStatus')return {status:'自动更新尚未连接发布服务',feedURL:''};if(cmd==='design'){state.pets[arg.id].design=structuredClone(arg.design);for(let f of listeners.state||[])f(structuredClone(state));return {ok:true,message:'已保存'}}if(cmd==='music'){window.musicRequested=true;return {ok:true}}return {ok:true}}};window.testState=()=>state},M.freshState());
 await page.goto('file://'+path.resolve(__dirname,'../desktop/app/index.html'));await page.locator('#portrait').waitFor();await page.click('[data-tab=creator]');await page.selectOption('#designshape','droplet');await page.selectOption('#designears','leaf');await page.fill('#designPersona','喜欢一起读书');await page.click('#saveDesign');
 let saved=await page.evaluate(()=>testState().pets[0].design);assert.equal(saved.shape,'droplet');assert.equal(saved.ears,'leaf');assert.equal(saved.persona,'喜欢一起读书');
 await page.locator('.petCard').nth(1).click();await page.waitForFunction(()=>document.querySelector('#portrait').dataset.petId==='1');await page.waitForFunction(()=>document.querySelector('#designshape').value==='bean');await page.selectOption('#designshape','orb');await page.click('#saveDesign');assert.equal(await page.evaluate(()=>testState().pets[1].design.shape),'orb');assert.equal(await page.evaluate(()=>testState().pets[0].design.shape),'droplet');
 await page.click('[data-tab=activity]');await page.click('#linkMusic');assert.equal(await page.evaluate(()=>musicRequested),true);assert.deepEqual(errors,[]);
 await page.click('[data-tab=creator]');if(process.argv[2])await page.screenshot({path:process.argv[2]});console.log('PASS: real Chromium UI selects/edits/saves two independent characters, switches tabs, and requests original music with no JavaScript errors');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
