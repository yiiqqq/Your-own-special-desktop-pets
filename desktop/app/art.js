'use strict';
(function(){
const images=new Map();
function loaded(src){if(!images.has(src)){let im=new Image();im.src=src;images.set(src,im);if(images.size>64)images.delete(images.keys().next().value)}return images.get(src)}
function draw(c,p,r={},time=Date.now(),scale=1){const ctx=c.getContext('2d');c.width=144*scale;c.height=132*scale;ctx.scale(scale,scale);ctx.clearRect(0,0,144,132);const d=p.design||DesignModel.fresh(p.id),t=time/1000,a=r.action||'idle',side=['walk','fly','tail'].includes(a),back=r.back===true;let mood=PetModel.moodAt(p,time);if(['hug','eat','wave','cheer','dance','wink'].includes(a))mood='happy';if(['read','sleep'].includes(a))mood='neutral';const pose=back?'back':side?'side':mood;let src=d.images[pose]||(!side&&!back?d.images.neutral:null);ctx.save();ctx.translate(72,80+(a==='jump'?-Math.abs(Math.sin(t*5))*20:Math.sin(t*2)*.6));ctx.scale(1+PetModel.stage(p)*.035,1+PetModel.stage(p)*.035);if(a==='fly')ctx.rotate(-Math.PI/2);if(r.direction<0&&side)ctx.scale(-1,1);
const ink='#52646a';ctx.lineWidth=1.5;ctx.lineCap='round';ctx.lineJoin='round';
function ellipse(x,y,w,h,color=d.color){ctx.fillStyle=color;ctx.strokeStyle=ink;ctx.beginPath();ctx.ellipse(x,y,w,h,0,0,Math.PI*2);ctx.fill();ctx.stroke()}
function path(points,color,stroke=true){ctx.fillStyle=color;ctx.strokeStyle=ink;ctx.beginPath();points(ctx);ctx.fill();if(stroke)ctx.stroke()}
const im=src?loaded(src):null;
if(im?.complete&&im.naturalWidth){let f=Math.min(80/im.naturalWidth,80/im.naturalHeight);ctx.drawImage(im,-im.naturalWidth*f/2,-16-im.naturalHeight*f/2,im.naturalWidth*f,im.naturalHeight*f)}else{
 if(d.tail){ctx.save();ctx.translate(18,15);ctx.rotate(a==='tail'?Math.sin(t*10)*.7:-.3);ellipse(9,0,14,5,d.accent);ctx.restore()}
 for(let sign of [-1,1]){ctx.save();ctx.translate(sign*12,23);ctx.rotate(a==='kick'&&sign===1?-Math.max(0,Math.sin(t*20))*.9:(a==='walk'?Math.sin(t*8+sign)*.3:0));ellipse(0,0,8,5);ctx.restore()}
 for(let sign of [-1,1]){ctx.save();ctx.translate(sign*20,7);let up=['wave','cheer','dance'].includes(a);ctx.rotate(up?sign*(-.95+Math.sin(t*8)*.3):['read','eat','hug','sing'].includes(a)?sign*.8:sign*.2);ellipse(sign*5,0,10,5);ctx.restore()}
 if(d.ears==='round'){ellipse(-15,-28,8,9);ellipse(15,-28,8,9)}
 if(d.ears==='leaf')path(x=>{x.moveTo(0,-29);x.quadraticCurveTo(-16,-51,0,-45);x.quadraticCurveTo(17,-48,0,-29)},d.accent);
 if(d.shape==='droplet')path(x=>{x.moveTo(0,-36);x.bezierCurveTo(30,-7,30,24,0,26);x.bezierCurveTo(-30,24,-30,-7,0,-36)},d.color);
 else ellipse(0,-2,d.shape==='orb'?25:23,d.shape==='orb'?25:30);
 if(p.outfit!=='none'){ctx.fillStyle=({bib:'#e4c4dc',white:'#f8fbfc',picnic:'#8db6d4',pink:'#e7bed4'})[p.outfit]||d.accent;ctx.beginPath();ctx.roundRect(-16,9,32,12,5);ctx.fill();ctx.strokeStyle=ink;ctx.stroke()}
 if(back){ellipse(0,10,4,4,d.accent)}else{
 const eyes=side?[[-12,-9]]:[[-9,-9],[9,-9]];
 for(let [x,y]of eyes){ctx.strokeStyle=ink;if(['happy','angry','sad'].includes(mood)||['sleep','wink'].includes(a)){ctx.beginPath();ctx.moveTo(x-3,y+1);ctx.quadraticCurveTo(x,y+(mood==='sad'?3:-4),x+3,y+1);ctx.stroke()}else{ellipse(x,y,2.7,d.eyes==='spark'?4:3,ink);if(d.eyes==='spark'){ctx.fillStyle='white';ctx.beginPath();ctx.arc(x-.6,y-1,1,0,7);ctx.fill()}}}
 ctx.strokeStyle=ink;ctx.beginPath();ctx.moveTo(-4,1);ctx.quadraticCurveTo(0,mood==='sad'?-3:6,4,1);ctx.stroke();ctx.fillStyle=d.accent;for(let x of [-15,15]){ctx.beginPath();ctx.ellipse(x,-1,4,2,0,0,7);ctx.fill()}
 }
 if(p.accessory!=='none'){ctx.font='17px Emoji, "Segoe UI Emoji", "Apple Color Emoji", sans-serif';ctx.textAlign='center';ctx.fillText(({bow:'🎀',flowers:'🌼',visor:'🧢',bucket:'👒',glasses:'👓'})[p.accessory]||'✨',0,p.accessory==='glasses'?-4:-28)}
}
if(['read','eat','sing'].includes(a)){ctx.font='19px Emoji, "Segoe UI Emoji", "Apple Color Emoji", sans-serif';ctx.textAlign='center';ctx.fillText(a==='read'?'📖':a==='sing'?'🎤':PetModel.FOODS.find(f=>f.id===p.food)?.emoji||'🍎',0,15);ellipse(-9,11,4,3);ellipse(9,11,4,3)}
if(a==='sleep'){ctx.font='12px Emoji, "Segoe UI Emoji", "Apple Color Emoji", sans-serif';ctx.fillStyle=ink;ctx.fillText('z Z',24,-25)}ctx.restore();if(r.emoji){ctx.font='17px Emoji, "Segoe UI Emoji", "Apple Color Emoji", sans-serif';ctx.fillText(r.emoji,110,42+Math.sin(t*3)*2)}
}
window.PetArt={draw};})();
