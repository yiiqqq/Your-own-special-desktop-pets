(function(root,factory){if(typeof module==='object')module.exports=factory();else root.DesignModel=factory()})(globalThis,function(){
'use strict';
const SLOTS=['neutral','happy','angry','sad','excited','side','back'];
const SHAPES=['orb','bean','droplet'],EARS=['none','round','leaf'],EYES=['dot','spark'];
function fresh(i=0){return {version:1,shape:'bean',color:'#a8cdbb',accent:'#efd69c',ears:'none',eyes:'dot',tail:true,persona:'温柔好奇，喜欢和伙伴一起探索',images:{}}}
function png(value){
 if(typeof value!=='string'||value.length>1500000||!/^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/.test(value))return false;
 try{let b=typeof Buffer==='function'?Buffer.from(value.split(',')[1],'base64'):Uint8Array.from(atob(value.split(',')[1]),c=>c.charCodeAt(0));
 if(b.length<33||b.length>1048576)return false;
 if([137,80,78,71,13,10,26,10].some((v,i)=>b[i]!==v)||String.fromCharCode(...b.slice(12,16))!=='IHDR')return false;
 let view=new DataView(b.buffer,b.byteOffset,b.byteLength);return view.getUint32(16)>0&&view.getUint32(20)>0&&view.getUint32(16)<=2048&&view.getUint32(20)<=2048;
 }catch{return false}
}
function normalize(v,i=0){let d=fresh(i);if(!v||typeof v!=='object')return d;
 for(let [k,allowed] of [['shape',SHAPES],['ears',EARS],['eyes',EYES]])if(allowed.includes(v[k]))d[k]=v[k];
 for(let k of ['color','accent'])if(typeof v[k]==='string'&&/^#[0-9a-f]{6}$/i.test(v[k]))d[k]=v[k];
 if(typeof v.tail==='boolean')d.tail=v.tail;if(typeof v.persona==='string')d.persona=v.persona.trim().slice(0,200)||d.persona;
 for(let slot of SLOTS)if(png(v.images?.[slot]))d.images[slot]=v.images[slot];return d;
}
function pack(p){return {format:'little-companions-character',version:1,name:p.nickname,design:normalize(p.design,p.id)}}
function unpack(v){if(v?.format!=='little-companions-character'||v.version!==1)throw Error('不是支持的角色文件');return {name:String(v.name||'小伙伴').slice(0,24),design:normalize(v.design)}}
return {SLOTS,SHAPES,EARS,EYES,fresh,normalize,png,pack,unpack};
});
