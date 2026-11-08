// Macflix native audio bridge: forwards accepted E-AC-3 appends unchanged to the native decoder.
(() => {
  if (location.hostname !== 'netflix.com' && !location.hostname.endsWith('.netflix.com')) return;
  if (window.__netflixDevNativeAudioStatus) return;
  const status = window.__netflixDevNativeAudioStatus = {state:'idle', active:false, audible:false, reason:'waiting', queueBytes:0, servedSegments:0, nativeSeekable:[], loaded:[], timeline:{}};
  const handler = window.webkit?.messageHandlers?.nativeAudio;
  const sbProto = window.SourceBuffer?.prototype, mediaProto = window.HTMLMediaElement?.prototype;
  const mute = mediaProto && Object.getOwnPropertyDescriptor(mediaProto, 'muted');
  if (!handler || !sbProto || !mute?.get || !mute?.set) { status.reason='unavailable'; return; }
  const records = new WeakMap(), sources = new Map();
  const MAX_APPEND=8*1024*1024, MAX_PENDING=16*1024*1024;
  const MAX_PREWARM_PLAYING_MS=30000;
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
  function topLevelBoxes(bytes) {
    const boxes=[];let offset=0;
    while(offset+8<=bytes.length){
      const size32=((bytes[offset]<<24)|(bytes[offset+1]<<16)|(bytes[offset+2]<<8)|bytes[offset+3])>>>0;
      const type=String.fromCharCode(bytes[offset+4],bytes[offset+5],bytes[offset+6],bytes[offset+7]);
      let size=size32,header=8;
      if(size32===1){
        if(offset+16>bytes.length)return null;
        const high=((bytes[offset+8]<<24)|(bytes[offset+9]<<16)|(bytes[offset+10]<<8)|bytes[offset+11])>>>0;
        const low=((bytes[offset+12]<<24)|(bytes[offset+13]<<16)|(bytes[offset+14]<<8)|bytes[offset+15])>>>0;
        size=high*4294967296+low;header=16;
      }
      if(size32===0||!Number.isSafeInteger(size)||size<header||size>bytes.length-offset)return null;
      boxes.push({type,start:offset});offset+=size;
    }
    return offset===bytes.length?boxes:null;
  }
  function resetReplay(record) { record.replayInit=null;record.replayFragments=[];record.replayBytes=0;record.replaySegments=0; }
  function rememberReplay(record,bytes) {
    const boxes=topLevelBoxes(bytes);
    if(!boxes){record.replayFragments=[];record.replayBytes=record.replayInit?.length||0;record.replaySegments=0;return;}
    const firstMoof=boxes.find(box=>box.type==='moof'),hasInit=boxes.some(box=>box.type==='ftyp')&&boxes.some(box=>box.type==='moov');
    if(hasInit){
      const initEnd=firstMoof?.start??bytes.length;resetReplay(record);
      record.replayInit=bytes.slice(0,initEnd);record.replayBytes=record.replayInit.length;
    }
    if(firstMoof){
      const fragmentBoxes=boxes.filter(box=>box.start>=firstMoof.start),moofs=fragmentBoxes.filter(box=>box.type==='moof').length,mdats=fragmentBoxes.filter(box=>box.type==='mdat').length;
      if(!moofs||mdats<moofs){record.replayFragments=[];record.replayBytes=record.replayInit?.length||0;record.replaySegments=0;return;}
      const data=bytes.slice(firstMoof.start);record.replayFragments.push({data,count:moofs});record.replayBytes+=data.length;record.replaySegments+=moofs;
      while(record.replayFragments.length>3||record.replayBytes>MAX_PENDING){
        const old=record.replayFragments.shift();record.replayBytes-=old.data.length;record.replaySegments-=old.count;
      }
    } else if(!hasInit){record.replayFragments=[];record.replayBytes=record.replayInit?.length||0;record.replaySegments=0;}
  }
  function encode(bytes) { let text='';for(let i=0;i<bytes.length;i+=8192)text+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(text); }
  function restore(stream) {
    if((stream?.owned||stream?.priming) && stream.media) {stream.owned=false;stream.priming=false;mute.set.call(stream.media,stream.userMuted);}
    status.active=false;status.audible=false;
  }
  function stop(stream,reason='stopped') {
    if(!stream || stream.failed)return;
    stream.failed=true;stream.stopReason=reason;
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
    const ranges=value=>Array.isArray(value)?value.slice(0,32).flatMap(range=>Array.isArray(range)&&range.length>=2&&range.slice(0,2).every(n=>Number.isFinite(n)&&n>=0&&n<=1000000)?[[range[0],range[1]]]:[]):[];
    status.servedSegments=Number.isSafeInteger(value.servedSegments)&&value.servedSegments>=0&&value.servedSegments<=100000?value.servedSegments:0;
    status.nativeSeekable=ranges(value.nativeSeekable);status.loaded=ranges(value.loaded);
    const timeline={};
    for(const key of ['itemTime','webTime','anchorSeconds','targetItemTime','firstSegmentStart','firstSegmentEnd','lastSegmentEnd'])
      if(Number.isFinite(value[key])&&Math.abs(value[key])<=1000000)timeline[key]=value[key];
    for(const key of ['targetSeekable','targetLoaded','clearJOCSignaled'])if(typeof value[key]==='boolean')timeline[key]=value[key];
    if(['preparing','ready','failed'].includes(value.itemStatus))timeline.itemStatus=value.itemStatus;
    if(['paused','waiting','playing'].includes(value.timeControlStatus))timeline.timeControlStatus=value.timeControlStatus;
    for(const key of ['sourceBufferTimestampOffset','firstSourceTimestampOffset'])
      if(Number.isFinite(status.timeline?.[key])&&Math.abs(status.timeline[key])<=1000000)timeline[key]=status.timeline[key];
    if(Number.isSafeInteger(status.timeline?.timestampOffsetChanges)&&status.timeline.timestampOffsetChanges>=0&&status.timeline.timestampOffsetChanges<=100000)
      timeline.timestampOffsetChanges=status.timeline.timestampOffsetChanges;
    status.timeline=timeline;
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
    let replay=null;
    if(current?.record===record) {
      if(!current.failed)return current;
      if(current.stopReason!=='timeout'||record.retryUsed||!record.replayInit||record.replaySegments<3)return current;
      record.retryUsed=true;current=null;
      replay=[record.replayInit,...record.replayFragments.map(item=>item.data)];
    } else stop(current,'track-change');
    const stream=current={record,id:sessionID(),failed:false,owned:false,media:null,userMuted:false,last:null,lastReply:Date.now(),syncing:false};
    status.state='collecting';status.reason='starting';status.active=false;status.audible=false;
    send(stream,{action:'begin'}).catch(()=>{});
    if(replay)for(const bytes of replay)send(stream,{action:'append',data:encode(bytes)}).catch(()=>{});
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
      // Warm the native decoder silently while WebKit continues to provide the audible track.
      if(!stream.owned&&!stream.priming&&normal&&!media.paused&&(stream.last?.segments||0)>=3){
        stream.priming=true;stream.prewarmElapsed=0;stream.prewarmLastTick=Date.now();
      }
      if(stream.priming){
        const now=Date.now();
        if(stream.prewarmLastTick&&normal&&!media.paused)stream.prewarmElapsed+=(now-stream.prewarmLastTick);
        stream.prewarmLastTick=now;
        if(stream.prewarmElapsed>=MAX_PREWARM_PLAYING_MS){stop(stream,'preparing-timeout');return;}
      }
      const value=await send(stream,clock(stream,stream.owned&&normal));
      if(!value||stream!==current||stream.failed)return;
      const ready=normal&&value.state==='ready'&&!value.seeking&&Math.abs(value.driftSeconds)<0.15;
      if(!ready) {
        if(stream.owned){await send(stream,clock(stream,false));restore(stream);}
        return;
      }
      if(!stream.owned&&!media.paused&&!media.ended){
        if(media.seeking||media.playbackRate!==1||!Number.isFinite(value.nativeTime)||Math.abs(value.nativeTime-media.currentTime)>=0.15)return;
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
      record.retryUsed=false;resetReplay(record);
    }
    record.seen=true;
    const stream=start(record);
    if(stream.failed)return;
    if(bytes.byteLength>MAX_APPEND || pending+bytes.byteLength>MAX_PENDING){stop(stream,'queue-limit');return;}
    rememberReplay(record,bytes);
    const copy=new Uint8Array(bytes);pending+=copy.length;status.queueBytes=pending;
    // Encoding is deferred, after the caller's unchanged appendBuffer has returned.
    const task=chain.then(()=>{
      if(stream!==current||stream.failed)return null;
      return rawSend({action:'append',session:stream.id,data:encode(copy)}).then(value=>{
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
    proto.addSourceBuffer=function(type){const buffer=Reflect.apply(add,this,arguments);records.set(buffer,{source:this,eligible:eligible(type),seen:false,retryUsed:false,replayInit:null,replayFragments:[],replayBytes:0,replaySegments:0,firstTimestampOffset:null,lastTimestampOffset:null,timestampOffsetChanges:0});return buffer;};
  }
  const append=sbProto.appendBuffer;
  sbProto.appendBuffer=function(input){
    const record=records.get(this);
    try{
      if(record?.eligible&&Number.isFinite(this.timestampOffset)&&Math.abs(this.timestampOffset)<=1000000){
        const value=this.timestampOffset;
        if(record.firstTimestampOffset===null)record.firstTimestampOffset=value;
        if(record.lastTimestampOffset!==null&&record.lastTimestampOffset!==value)record.timestampOffsetChanges++;
        record.lastTimestampOffset=value;
        status.timeline.sourceBufferTimestampOffset=value;
        status.timeline.firstSourceTimestampOffset=record.firstTimestampOffset;
        status.timeline.timestampOffsetChanges=record.timestampOffsetChanges;
      }
    }catch(_){}
    const result=Reflect.apply(append,this,arguments);
    try{if(record?.eligible)capture(record,input);}catch(error){if(current)fail(current,error);}
    return result;
  };
  if(sbProto.changeType){const change=sbProto.changeType;sbProto.changeType=function(type){
    const result=Reflect.apply(change,this,arguments);const record=records.get(this);
    if(record){if(current?.record===record){stop(current,'track-change');current=null;}record.eligible=eligible(type);record.seen=false;record.retryUsed=false;resetReplay(record);}
    return result;
  };}
  Object.defineProperty(mediaProto,'muted',{...mute,
    get(){return current?.media===this&&(current.owned||current.priming)?current.userMuted:mute.get.call(this);},
    set(value){
      const stream=current;
      if(stream?.media===this&&!stream.failed){stream.userMuted=!!value;mute.set.call(this,stream.owned?true:value);sync(stream);}
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
