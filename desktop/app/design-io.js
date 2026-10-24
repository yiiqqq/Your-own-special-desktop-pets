'use strict';
const fs=require('fs'),D=require('./design-model');
const MAX=10*1024*1024;
async function command(cmd,arg,p,window,dialog,nativeImage){
 if(cmd==='design'){if(!p)return {ok:false};p.design=D.normalize(arg.design,p.id);return {ok:true,message:'角色已保存，桌面和小房间会同步变化'}}
 if(cmd==='designImage'){
  const r=await dialog.showOpenDialog(window,{title:'选择自己的透明 PNG（最大 1 MB / 2048 像素）',filters:[{name:'PNG',extensions:['png']}],properties:['openFile']});if(r.canceled)return {ok:false};const file=r.filePaths[0];if(fs.statSync(file).size>1048576)return {ok:false,message:'图片超过 1 MB，请先缩小'};
  const data='data:image/png;base64,'+fs.readFileSync(file).toString('base64');if(!D.png(data))return {ok:false,message:'需要不超过 2048 × 2048 的有效 PNG'};let im=nativeImage.createFromDataURL(data);if(im.isEmpty())return {ok:false,message:'图片损坏，无法读取'};let size=im.getSize(),ratio=Math.min(1,512/Math.max(size.width,size.height));im=im.resize({width:Math.max(1,Math.round(size.width*ratio)),height:Math.max(1,Math.round(size.height*ratio))});return {ok:true,data:'data:image/png;base64,'+im.toPNG().toString('base64')};
 }
 if(!p)return {ok:false};
 if(cmd==='exportCharacter'){const r=await dialog.showSaveDialog(window,{title:'导出角色（不含聊天和密钥）',defaultPath:'my-character.littlepet.json',filters:[{name:'角色 JSON',extensions:['json']}]});if(r.canceled)return {ok:false};fs.writeFileSync(r.filePath,JSON.stringify(D.pack(p),null,2));return {ok:true,message:'角色已导出'}}
 if(cmd==='importCharacter'){const r=await dialog.showOpenDialog(window,{title:'导入角色 JSON',filters:[{name:'角色 JSON',extensions:['json']}],properties:['openFile']});if(r.canceled)return {ok:false};if(fs.statSync(r.filePaths[0]).size>MAX)return {ok:false,message:'角色文件超过 10 MB'};let v=D.unpack(JSON.parse(fs.readFileSync(r.filePaths[0],'utf8')));p.design=v.design;p.nickname=v.name;return {ok:true,message:'角色已导入'}}
 throw Error('不支持的角色操作');
}
module.exports={command};
