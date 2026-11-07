// Macflix native audio bridge: forwards accepted E-AC-3 appends unchanged to the native decoder.
(() => {
  if (location.hostname !== 'netflix.com' && !location.hostname.endsWith('.netflix.com')) return;
  if (window.__netflixDevNativeAudioStatus) return;
  const status = window.__netflixDevNativeAudioStatus = {state:'idle', active:false, audible:false, reason:'waiting', queueBytes:0};
  const handler = window.webkit?.messageHandlers?.nativeAudio;
  const sbProto = window.SourceBuffer?.prototype, mediaProto = window.HTMLMediaElement?.prototype;
  const mute = mediaProto && Object.getOwnPropertyDescriptor(mediaProto, 'muted');
  if (!handler || !sbProto || !mute?.get || !mute?.set) { status.reason='unavailable'; return; }
  const records = new WeakMap(), sources = new Map();
  const MAX_APPEND=8*1024*1024, MAX_PENDING=16*1024*1024;
  let current=null, chain=Promise.resolve(), pending=0, lastID=0;
  const eligible = type => typeof type === 'string' && /^audio\/mp4\s*;/i.test(type) && /(?:["'\s=,])ec-3(?:["'\s,]|$)/i.test(type);
  const timed = promise => new Promise((resolve,reject) => {
    const timer=setTimeout(()=>reject(new Error('timeout')),2500);
    Promise.resolve(promise).then(value=>{clearTimeout(timer);resolve(value);},error=>{clearTimeout(timer);reject(error);});
  });
  const rawSend = message => timed(handler.postMessage(message));
  function sessionID() {
    let old=0;try{old=Number(sessionStorage.getItem('netflixNativeBridgeSession'))||0;}catch(_){}
    lastID=Math.max(Date.now()*1000,old+1,lastID+1);
    try{sessionStorage.setItem('netflixNativeBridgeSession',String(lastID));}catch(_){}
    return lastID;
  }
  function restore(stream) {
    if((stream?.owned||stream?.priming) && stream.media) {stream.owned=false;stream.priming=false;mute.set.call(stream.media,stream.userMuted);}
    status.active=false;status.audible=false;
  }
  function stop(stream,reason='stopped') {
    if(!stream || stream.failed)return;
    stream.failed=true;
    // Stop is issued immediately; a blocked append queue must not keep native audio audible.
    const stopped=rawSend({action:'stop',session:stream.id}).catch(()=>{});
    restore(stream);
    status.state='stopped';status.reason=reason;
    return stopped;
  }
  function fail(stream,error) {
    if(stream!==current)return;
    const message=String(error?.message||'');
    const category=message.match(/^MacflixNativeAudio:(protected-audio|unsupported-audio|decode-error|listener-failed|stale-session|invalid-message|parser-error|native-error)$/)?.[1];
    const reason=category|| (message==='timeout'?'timeout':/protected/i.test(message)?'protected-audio':/JOC|codec/i.test(message)?'unsupported-audio':'native-error');
    stop(stream,reason);
  }
  function reply(stream,value) {
    if(!value || !['collecting','preparing','ready','stopped'].includes(value.state))throw new Error('invalid-reply');
    stream.last=value;stream.lastReply=Date.now();
    status.state=value.state;
    for(const key of ['nativeTime','driftSeconds','rate','segments','bytes'])status[key]=Number.isFinite(value[key])?value[key]:0;
    status.seeking=value.seeking===true;status.audible=value.audible===true;
    status.active=stream.owned&&!stream.failed;status.reason=stream.owned?'native':'preparing';
    return value;
  }
  function send(stream,body) {
    const task=chain.then(async()=>{
      if(stream!==current||stream.failed)return null;
      const outgoing=body.action==='sync'?clock(stream,body.audible):body;
      const value=await rawSend({session:stream.id,...outgoing});
      if(stream!==current||stream.failed)return null;
      return reply(stream,value);
    });
    chain=task.catch(error=>fail(stream,error));
    return task;
  }
  function mediaFor(record) {
    const media=Array.from(document.querySelectorAll('video,audio'));
    return media.find(element=>element.srcObject===record.source || sources.get(element.currentSrc||element.src)===record.source) ||
      (media.length===1?media[0]:null);
  }
  function start(record) {
    if(current?.record===record)return current;
    stop(current,'track-change');
    const stream=current={record,id:sessionID(),failed:false,owned:false,media:null,userMuted:false,last:null,lastReply:Date.now(),syncing:false};
    status.state='collecting';status.reason='starting';status.active=false;status.audible=false;
    send(stream,{action:'begin'}).catch(()=>{});
    return stream;
  }
  function clock(stream,audible) {
    const media=stream.media;
    return {action:'sync',time:media.currentTime,paused:media.paused||media.ended||(!stream.priming&&!stream.owned),seeking:media.seeking,
      rate:media.playbackRate,volume:media.volume,muted:stream.userMuted,audible};
  }
  async function sync(stream) {
    if(!stream||stream!==current||stream.failed||stream.syncing)return;
    const media=mediaFor(stream.record);
    if(!media){if(stream.owned)stop(stream,'media-gone');return;}
    if(stream.media && stream.media!==media){stop(stream,'media-change');return;}
    if(!stream.media){stream.media=media;stream.userMuted=mute.get.call(media);}
    if(!Number.isFinite(media.currentTime))return;
    stream.syncing=true;
    try {
      const normal=media.playbackRate===1&&!media.seeking;
      // Muting before native playback prevents macOS from pausing the web video for audio focus.
      if(!stream.owned&&!stream.priming&&normal&&!media.paused&&(stream.last?.segments||0)>=3){
        stream.priming=true;stream.primingAt=Date.now();mute.set.call(media,true);
      }
      if(stream.priming&&Date.now()-stream.primingAt>8000){stop(stream,'timeout');return;}
      const value=await send(stream,clock(stream,stream.owned&&normal));
      if(!value||stream!==current||stream.failed)return;
      const ready=normal&&value.state==='ready'&&!value.seeking&&Math.abs(value.driftSeconds)<0.15;
      if(!ready) {
        if(stream.owned){await send(stream,clock(stream,false));restore(stream);}
        return;
      }
      if(!stream.owned&&!media.paused&&!media.ended){
        mute.set.call(media,true);stream.owned=true;stream.priming=false;
        const enabled=await send(stream,clock(stream,true));
        if(!enabled||enabled.state!=='ready'||enabled.seeking||Math.abs(enabled.driftSeconds)>0.35){
          await send(stream,clock(stream,false));restore(stream);
        }
      }
    } catch(error){fail(stream,error);}
    finally{stream.syncing=false;}
  }
  function capture(record,input) {
    const bytes=ArrayBuffer.isView(input)?new Uint8Array(input.buffer,input.byteOffset,input.byteLength):new Uint8Array(input);
    if(!bytes.byteLength)return;
    // New initialization on a reused SourceBuffer means a different audio track.
    if(record.seen && bytes.length>=8 && String.fromCharCode(...bytes.subarray(4,8))==='ftyp') {
      if(current?.record===record){stop(current,'track-change');current=null;}
    }
    record.seen=true;
    const stream=start(record);
    if(stream.failed)return;
    if(bytes.byteLength>MAX_APPEND || pending+bytes.byteLength>MAX_PENDING){stop(stream,'queue-limit');return;}
    const copy=new Uint8Array(bytes);pending+=copy.length;status.queueBytes=pending;
    // Encoding is deferred, after the caller's unchanged appendBuffer has returned.
    const task=chain.then(()=>{
      if(stream!==current||stream.failed)return null;
      let text='';for(let i=0;i<copy.length;i+=8192)text+=String.fromCharCode(...copy.subarray(i,i+8192));
      return rawSend({action:'append',session:stream.id,data:btoa(text)}).then(value=>{
        if(stream===current&&!stream.failed)return reply(stream,value);
      });
    });
    chain=task.catch(error=>fail(stream,error)).finally(()=>{pending-=copy.length;status.queueBytes=pending;});
    chain.then(()=>sync(stream));
  }
  if(window.URL?.createObjectURL){
    const create=window.URL.createObjectURL;
    window.URL.createObjectURL=function(object){const result=Reflect.apply(create,this,arguments);sources.set(result,object);return result;};
    const revoke=window.URL.revokeObjectURL;
    if(revoke)window.URL.revokeObjectURL=function(url){sources.delete(url);return Reflect.apply(revoke,this,arguments);};
  }
  const patched=new Set();
  for(const Constructor of [window.MediaSource,window.ManagedMediaSource].filter(Boolean)){
    const proto=Constructor.prototype;if(patched.has(proto))continue;patched.add(proto);
    const add=proto.addSourceBuffer;
    proto.addSourceBuffer=function(type){const buffer=Reflect.apply(add,this,arguments);records.set(buffer,{source:this,eligible:eligible(type),seen:false});return buffer;};
  }
  const append=sbProto.appendBuffer;
  sbProto.appendBuffer=function(input){
    const result=Reflect.apply(append,this,arguments);
    try{const record=records.get(this);if(record?.eligible)capture(record,input);}catch(error){if(current)fail(current,error);}
    return result;
  };
  if(sbProto.changeType){const change=sbProto.changeType;sbProto.changeType=function(type){
    const result=Reflect.apply(change,this,arguments);const record=records.get(this);
    if(record){if(current?.record===record){stop(current,'track-change');current=null;}record.eligible=eligible(type);record.seen=false;}
    return result;
  };}
  Object.defineProperty(mediaProto,'muted',{...mute,
    get(){return current?.media===this&&(current.owned||current.priming)?current.userMuted:mute.get.call(this);},
    set(value){
      const stream=current;
      if(stream?.media===this&&!stream.failed){stream.userMuted=!!value;mute.set.call(this,(stream.owned||stream.priming)?true:value);sync(stream);}
      else mute.set.call(this,value);
    }
  });
  for(const event of ['play','pause','seeking','seeked','ratechange','volumechange'])document.addEventListener(event,e=>{
    if(e.target===current?.media)sync(current);
  },true);
  setInterval(()=>{
    const stream=current;if(!stream||stream.failed)return;
    if(stream.owned&&Date.now()-stream.lastReply>2000){stop(stream,'timeout');return;}
    sync(stream);
  },250);
  window.addEventListener('pagehide',()=>stop(current,'navigation'),{once:true});
})();
