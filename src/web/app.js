const $ = id => document.getElementById(id);
let rate=0, raw=[], processed=[], paused=false, lastSeq=null, lastArrival=0, lastStats=null;
let selectedChannel=0, frameCount=0, clipCount=0;
async function request(url, body) {
  const response=await fetch(url, body===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const value=await response.json(); if(!response.ok) throw Error(value.error||response.statusText); return value;
}
function action(fn){return async()=>{try{$('message').textContent='';await fn();}catch(e){$('message').textContent=e.message;}};}
async function ports(){const list=await request('/api/ports');const old=$('port').value;$('port').replaceChildren();for(const p of list){const o=new Option(`${p.device} · ${p.description}`,p.device);$('port').add(o);}if(list.some(p=>p.device===old))$('port').value=old;if(!list.length)$('port').add(new Option('未发现串口',''));}
$('refresh').onclick=action(ports);
$('connect').onclick=action(async()=>{await request('/api/connect',{port:$('port').value,baud:Number($('baud').value)});clear();});
$('disconnect').onclick=action(()=>request('/api/disconnect',{}));
$('apply').onclick=action(async()=>{await request('/api/filters',{highpass:Number($('hp').value),lowpass:Number($('lp').value),notch:Number($('notch').value)});$('filterstate').textContent='滤波设置已提交';});
function clear(){raw=[];processed=[];lastSeq=null;frameCount=0;clipCount=0;$('export').disabled=true;}
$('clear').onclick=clear;
$('pause').onclick=()=>{paused=!paused;$('pause').textContent=paused?'继续显示':'暂停显示';$('pause').setAttribute('aria-pressed',String(paused));};
$('channel').onchange=()=>{selectedChannel=Number($('channel').value);clear();};
const stream=new EventSource('/events');
stream.onerror=()=>{$('status').textContent='网页与接收服务连接中断';$('dot').className='';};
stream.onmessage=event=>{
  const e=JSON.parse(event.data);
  if(e.type==='recognition'){$('sound').textContent=e.name||e.label||'等待识别';return;}
  if(e.type==='board_error'){$('boarderror').textContent=e.message;return;}
  if(e.type==='status'){$('status').textContent=e.message;$('dot').className=e.connected?'active':'';return;}
  lastArrival=performance.now();
  const labels=e.channels===1?['所选单路（板端配置）']:['前方 CH0','左方 CH1','右方 CH2','后方 CH3'];
  if($('channel').options.length!==e.channels||$('channel').options[0].text!==labels[0]){$('channel').replaceChildren(...labels.slice(0,e.channels).map((s,i)=>new Option(s,i)));selectedChannel=0;clear();}
  if(paused)return;
  if(rate!==e.rate||e.reset||(lastSeq!==null&&e.seq!==((lastSeq+1)>>>0))){raw=[];processed=[];}
  rate=e.rate;lastSeq=e.seq;const ch=Math.min(selectedChannel,e.channels-1);
  raw.push(...e.raw[ch]);processed.push(...e.filtered[ch]);const max=Math.ceil(rate*2);if(raw.length>max){raw.splice(0,raw.length-max);processed.splice(0,processed.length-max);}
  frameCount+=e.raw[ch].length;clipCount+=e.clipped[ch];lastStats=e;
  $('rate').textContent=`${rate.toFixed(3)} Hz`;$('rms').textContent=e.rms[ch].toFixed(6);$('dbfs').textContent=`${e.dbfs[ch].toFixed(1)} dBFS`;
  $('mode').textContent=e.buffered?'两秒采集 / 分块传输':'FIX2 连续音频流';$('errors').textContent=`${e.missing} / ${e.crc_errors}`;
  $('rawlabel').textContent=e.board_filtered?'板端已抗混叠低通 / 降采样':'接收的 PCM';$('empty').hidden=true;$('export').disabled=false;
  const [hp,lp,notch]=e.filters;$('filterstate').textContent=`高通 ${hp} Hz · 低通 ${lp} Hz${notch?` · ${notch} Hz 抑制`:''}`;
  $('detail').textContent=`帧 ${e.seq} · ${e.channels} 路 · 累计削顶 ${clipCount} 点${e.gap?' · 采集边界/丢包处已重置滤波':''}`;
};
function plot(canvas, data, color, extent){
  const rect=canvas.getBoundingClientRect(), dpr=devicePixelRatio||1;
  const width=Math.round(rect.width*dpr),height=Math.round(rect.height*dpr);if(canvas.width!==width||canvas.height!==height){canvas.width=width;canvas.height=height;}
  const c=canvas.getContext('2d');c.setTransform(dpr,0,0,dpr,0,0);const w=rect.width,h=rect.height,L=62,R=15,T=15,B=27,pw=w-L-R,ph=h-T-B;
  c.clearRect(0,0,w,h);c.font='11px Consolas, monospace';c.lineWidth=1;
  for(let i=0;i<=4;i++){const y=T+i*ph/4;c.strokeStyle=i===2?'#bdcdd1':'#edf1f3';c.beginPath();c.moveTo(L,y);c.lineTo(w-R,y);c.stroke();c.fillStyle='#718087';c.textAlign='right';c.fillText(((1-i/2)*extent).toFixed(extent<.01?4:3),L-8,y+4);}
  const seconds=Number($('window').value);for(let i=0;i<=4;i++){const x=L+i*pw/4;c.strokeStyle='#edf1f3';c.beginPath();c.moveTo(x,T);c.lineTo(x,h-B);c.stroke();c.fillStyle='#718087';c.textAlign='center';c.fillText(`${Math.round((i/4-1)*seconds*1000)} ms`,x,h-8);}
  if(!rate||!data.length)return;const n=Math.max(2,Math.round(seconds*rate)),start=data.length-n;
  c.save();c.beginPath();c.rect(L,T,pw,ph);c.clip();c.strokeStyle=color;c.lineWidth=1.2;c.beginPath();
  // Min/max per screen column preserves short transients when zoomed out.
  for(let px=0;px<Math.ceil(pw);px++){let lo=Infinity,hi=-Infinity;const a=Math.max(0,start+Math.floor(px*n/pw)),b=Math.min(data.length,start+Math.max(Math.floor((px+1)*n/pw),Math.floor(px*n/pw)+1));for(let j=a;j<b;j++){lo=Math.min(lo,data[j]);hi=Math.max(hi,data[j]);}if(lo!==Infinity){const x=L+px;c.moveTo(x,T+ph/2-hi/extent*ph/2);c.lineTo(x,T+ph/2-lo/extent*ph/2+.7);}}
  c.stroke();c.restore();
}
let lastPaint=0;
function render(now){if(now-lastPaint>40){let extent=Number($('scale').value);if(!extent){let peak=.0001;const n=Math.ceil((rate||1)*Number($('window').value));for(const a of [raw,processed])for(let i=Math.max(0,a.length-n);i<a.length;i++)peak=Math.max(peak,Math.abs(a[i]));extent=peak*1.15;}plot($('raw'),raw,'#3775c1',extent);plot($('processed'),processed,'#087f80',extent);if(lastArrival&&now-lastArrival>2500&&!paused)$('mode').textContent='等待下一采集块';lastPaint=now;}requestAnimationFrame(render);}
requestAnimationFrame(render);
$('export').onclick=()=>{
  if(!raw.length)return;
  const n=Math.min(raw.length,Math.round(rate*Number($('window').value))),start=raw.length-n;
  const b=new ArrayBuffer(44+n*4),v=new DataView(b);
  const text=(p,s)=>{for(let i=0;i<s.length;i++)v.setUint8(p+i,s.charCodeAt(i));};
  text(0,'RIFF');v.setUint32(4,36+n*4,true);text(8,'WAVE');text(12,'fmt ');
  v.setUint32(16,16,true);v.setUint16(20,1,true);v.setUint16(22,2,true);
  const wavRate=Math.round(rate);v.setUint32(24,wavRate,true);v.setUint32(28,wavRate*4,true);
  v.setUint16(32,4,true);v.setUint16(34,16,true);text(36,'data');v.setUint32(40,n*4,true);
  for(let i=0;i<n;i++){
    v.setInt16(44+i*4,Math.round(Math.max(-1,Math.min(.999969,raw[start+i]))*32768),true);
    v.setInt16(46+i*4,Math.round(Math.max(-1,Math.min(.999969,processed[start+i]))*32768),true);
  }
  const url=URL.createObjectURL(new Blob([b],{type:'audio/wav'})),a=document.createElement('a');
  a.href=url;a.download=`wave_compare_${Date.now()}.wav`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  $('message').textContent='已导出当前窗口：左声道接收波形，右声道滤波波形；采样率按 WAV 整数格式取整。';
};
action(ports)();
