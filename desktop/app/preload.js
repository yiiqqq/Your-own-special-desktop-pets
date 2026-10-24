'use strict';
const {contextBridge,ipcRenderer}=require('electron');
const channels=new Set(['state','pet','scene','select','music','ball','update']);
contextBridge.exposeInMainWorld('littlepets',Object.freeze({command:(cmd,args)=>ipcRenderer.invoke('command',cmd,args),on:(event,callback)=>{if(!channels.has(event)||typeof callback!=='function')return ()=>{};const listener=(_e,value)=>callback(value);ipcRenderer.on(event,listener);return ()=>ipcRenderer.removeListener(event,listener)}}));
