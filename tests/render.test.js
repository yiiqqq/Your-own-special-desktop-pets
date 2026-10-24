'use strict';
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert/strict'),D=require('../desktop/app/design-model'),M=require('../desktop/app/model');
const C=require('@napi-rs/canvas');if(process.env.EMOJI_FONT)C.GlobalFonts.registerFromPath(process.env.EMOJI_FONT,'Emoji');let ctx={window:{},DesignModel:D,PetModel:M,Image:C.Image,Map,Math,Date};vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../desktop/app/art.js'),'utf8'),ctx);
let canvas=C.createCanvas(144,132),count=0;
for(let shape of D.SHAPES)for(let ears of D.EARS)for(let eyes of D.EYES)for(let xp of [0,300])for(let action of M.ACTIONS)for(let n=0;n<12;n++){
 let p=M.freshState().pets[0];p.design={...D.fresh(),shape,ears,eyes};p.xp=xp;p.outfit='picnic';p.accessory='bow';
 ctx.window.PetArt.draw(canvas,p,{action,direction:n%2?-1:1,back:n===11},1700000000000+n*73);
 let data=canvas.getContext('2d').getImageData(0,0,144,132).data;assert.ok(data.some((v,i)=>i%4===3&&v>100));
 for(let x=0;x<144;x++){assert.equal(data[x*4+3],0,'top clipping');assert.equal(data[((131*144+x)*4)+3],0,'bottom clipping')}
 for(let y=0;y<132;y++){assert.equal(data[(y*144)*4+3],0,'left clipping');assert.equal(data[(y*144+143)*4+3],0,'right clipping')}
 count++;
}
let sheet=C.createCanvas(960,520),c=sheet.getContext('2d');c.fillStyle='#fffaf5';c.fillRect(0,0,960,520);let colors=['#a8cdbb','#c5b8df','#efc393','#a9cede','#dfacc8','#d9d095'];for(let i=0;i<6;i++){let p=M.freshState().pets[0];p.design={...D.fresh(),shape:D.SHAPES[i%3],ears:D.EARS[i%3],eyes:i%2?'spark':'dot',color:colors[i]};p.outfit=i%2?'picnic':'none';p.accessory=i===3?'flowers':'none';ctx.window.PetArt.draw(canvas,p,{action:['wave','jump','read','tail','eat','fly'][i]},1700000000150,3);c.drawImage(canvas,(i%3)*320+45,(i/3|0)*250+10,240,220)}
if(process.argv[2])fs.writeFileSync(process.argv[2],sheet.toBuffer('image/png'));
console.log('PASS: '+count+' actual Canvas frames across every body/head/eye/action variant, max growth and wardrobe, zero clipped edges');
