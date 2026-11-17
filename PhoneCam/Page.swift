enum Page {
    static let obs = """
    <!doctype html><html><head><meta charset="utf-8"><title>PhoneCam</title>
    <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
    canvas{width:100vw;height:100vh;object-fit:contain;display:block}</style></head>
    <body><canvas id="v"></canvas>
    <script>
    // Reads the MJPEG stream with fetch: no copying of the whole buffer per chunk, JPEG decoded
    // off the main thread (createImageBitmap), only the newest frame drawn. No frame for 2 s → reconnect.
    function play(cv){
      const g=cv.getContext('2d',{alpha:false,desynchronized:true});
      let ctl=null, last=0, pending=null, decoding=false;
      function show(blob){
        if(decoding){ pending=blob; return }       // keep only the newest frame
        decoding=true;
        createImageBitmap(blob).then(bm=>{
          if(cv.width!==bm.width||cv.height!==bm.height){ cv.width=bm.width; cv.height=bm.height }
          g.drawImage(bm,0,0); bm.close();
        }).catch(()=>{}).finally(()=>{
          decoding=false;
          if(pending){ const b=pending; pending=null; show(b) }
        });
      }
      async function run(){
        ctl=new AbortController(); last=performance.now();
        let chunks=[], total=0, need=-1;
        const take=n=>{ // remove n bytes from the front
          const out=new Uint8Array(n); let off=0;
          while(off<n){ const c=chunks[0], k=Math.min(c.length,n-off);
            out.set(k===c.length?c:c.subarray(0,k),off); off+=k;
            if(k===c.length) chunks.shift(); else chunks[0]=c.subarray(k) }
          total-=n; return out };
        const peek=n=>{ const out=new Uint8Array(Math.min(n,total)); let off=0;
          for(const c of chunks){ if(off>=out.length) break; const k=Math.min(c.length,out.length-off); out.set(c.subarray(0,k),off); off+=k }
          return out };
        try{
          const r=await fetch('/video?'+Date.now(),{signal:ctl.signal,cache:'no-store'});
          const rd=r.body.getReader();
          for(;;){
            const {value,done}=await rd.read(); if(done) break;
            chunks.push(value); total+=value.length;
            for(;;){
              if(need<0){ // parse the part header: ...Content-Length: N\r\n\r\n
                const h=peek(512), txt=new TextDecoder().decode(h), e=txt.indexOf('\\r\\n\\r\\n');
                if(e<0){ if(total>512) take(total); break }
                const m=/Content-Length:\\s*(\\d+)/i.exec(txt.slice(0,e));
                take(new TextEncoder().encode(txt.slice(0,e+4)).length);
                if(!m) continue;
                need=+m[1];
              }
              if(total<need) break;
              show(new Blob([take(need)],{type:'image/jpeg'})); need=-1; last=performance.now();
            }
          }
        }catch(e){}
        setTimeout(run,500);
      }
      setInterval(()=>{ if(performance.now()-last>2000 && ctl){ ctl.abort(); ctl=null } },500);
      run();
    }
    play(document.getElementById('v'));
    </script></body></html>
    """

    static let control = """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>PhoneCam</title>
    <style>
    :root{--bg:#111;--panel:#1b1b1b;--fg:#eee;--dim:#888;--acc:#fc0}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--fg);font:14px -apple-system,system-ui,sans-serif;display:flex;gap:16px;padding:16px;min-height:100vh}
    #view{flex:1;min-width:0;position:relative}
    #wrap{position:relative;display:inline-block;max-width:100%}
    #v{max-width:100%;max-height:calc(100vh - 80px);display:block;cursor:crosshair;background:#000;border-radius:6px}
    #mark{position:absolute;width:60px;height:60px;border:2px solid var(--acc);margin:-30px 0 0 -30px;pointer-events:none;opacity:0;transition:opacity .8s}
    #info{color:var(--dim);margin-top:8px}
    #info b{color:var(--fg);font-weight:500}
    aside{width:330px;flex:none;background:var(--panel);border-radius:8px;padding:12px 14px;overflow-y:auto;max-height:calc(100vh - 32px)}
    h3{margin:14px 0 6px;font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);font-weight:600}
    h3:first-child{margin-top:0}
    .seg{display:flex;gap:4px;flex-wrap:wrap}
    .seg button{flex:1;padding:6px 4px;border:0;border-radius:5px;background:#2a2a2a;color:var(--fg);cursor:pointer;font:inherit}
    .seg button.on{background:var(--acc);color:#000;font-weight:600}
    .seg button[hidden]{display:none}
    .row{display:flex;align-items:center;gap:8px;margin-top:6px}
    .row label{width:76px;color:var(--dim);flex:none}
    .row input{flex:1;accent-color:var(--acc)}
    .row output{width:62px;text-align:right;font-variant-numeric:tabular-nums}
    .hint{color:var(--dim);font-size:12px;margin-top:6px;line-height:1.4}
    code{background:#2a2a2a;padding:2px 5px;border-radius:4px;user-select:all}
    @media (max-width:800px){body{flex-direction:column}aside{width:auto;max-height:none}}
    </style></head><body>
    <div id="view">
      <div id="wrap"><canvas id="v"></canvas><div id="mark"></div></div>
      <div id="info">Click the picture to focus and expose there · <b id="fpsOut">–</b> fps · clients <b id="cl">–</b></div>
    </div>
    <aside>
      <h3>Lens</h3>
      <div class="seg" data-k="lens"><button data-v="ultra">0.5×</button><button data-v="wide">1×</button><button data-v="tele">5×</button><button data-v="front">Front</button></div>
      <div class="seg" data-k="frame" style="margin-top:6px"><button data-v="1">Auto-frame</button><button data-v="0">Fixed</button></div>
      <div class="row"><label>Zoom</label><input type="range" id="zoom" step="0.01"><output id="zoomOut"></output></div>

      <div class="hint">Auto-frame keeps you centred by moving a crop of the full picture; Zoom sets how tight. Use 4K for the sharpest crop.</div>

      <h3>Focus</h3>
      <div class="seg" data-k="focus"><button data-v="face">Face</button><button data-v="auto">Auto</button><button data-v="lock">Lock</button></div>
      <div class="row"><label>Distance</label><input type="range" id="lensPos" min="0" max="1" step="0.002"><output id="lensPosOut"></output></div>
      <div class="hint">Face: focus and exposure follow your face <span id="faceOut"></span>. Clicking the picture or moving the slider turns it off. Slider: 0 = near, 1 = infinity.</div>

      <h3>Exposure</h3>
      <div class="seg" data-k="exp"><button data-v="auto">Auto</button><button data-v="lock">Lock</button><button data-v="manual">Manual</button></div>
      <div class="row"><label>EV</label><input type="range" id="ev" step="0.1"><output id="evOut"></output></div>
      <div class="row"><label>ISO</label><input type="range" id="iso" min="0" max="1" step="0.001"><output id="isoOut"></output></div>
      <div class="row"><label>Shutter</label><input type="range" id="shutter" min="0" max="1" step="0.001"><output id="shutterOut"></output></div>
      <div class="hint">EV works in Auto. Moving ISO or shutter switches to Manual.</div>

      <h3>White balance</h3>
      <div class="seg" data-k="wb"><button data-v="skin">Skin</button><button data-v="auto">Auto</button><button data-v="lock">Lock</button></div>
      <div class="hint">Skin: white balance follows your face so the skin tone stays natural, not red or yellow.</div>
      <div class="row"><label>Temp, K</label><input type="range" id="temp" min="2500" max="9000" step="50"><output id="tempOut"></output></div>

      <h3>Color</h3>
      <div class="row"><label>Saturation</label><input type="range" id="sat" min="0" max="2" step="0.01"><output id="satOut"></output></div>
      <div class="row"><label>Contrast</label><input type="range" id="con" min="0.5" max="1.5" step="0.01"><output id="conOut"></output></div>
      <div class="row"><label>Black</label><input type="range" id="black" min="-0.1" max="0.1" step="0.002"><output id="blackOut"></output></div>
      <div class="hint">Black: right = deeper blacks, left = lifted shadows. Double-click a slider to reset it.</div>

      <h3>Background blur</h3>
      <div class="seg" data-k="blur"><button data-v="1">On</button><button data-v="0">Off</button></div>
      <div class="row"><label>Strength</label><input type="range" id="blurAmt" min="0" max="1" step="0.002"><output id="blurAmtOut"></output></div>
      <div class="hint">About 3.5 ms per frame; person detection (Vision, ~23 ms) runs in parallel and does not slow the stream.</div>

      <h3>Video</h3>
      <div class="seg" data-k="res"><button data-v="720">720p</button><button data-v="1080">1080p</button><button data-v="4k">4K</button></div>
      <div class="seg" data-k="fps" style="margin-top:4px"><button data-v="30">30 fps</button><button data-v="60">60 fps</button></div>
      <div class="row"><label>Quality</label><input type="range" id="q" min="0.4" max="0.95" step="0.01"><output id="qOut"></output></div>
      <h3>Rotation</h3>
      <div class="seg" data-k="rot"><button data-v="0">0°</button><button data-v="90">90°</button><button data-v="180">180°</button><button data-v="270">270°</button></div>

      <h3>OBS</h3>
      <div class="hint">Browser Source, 1920×1080, URL:<br><code id="obsUrl"></code></div>
    </aside>
    <script>
    const $=id=>document.getElementById(id);
    let st={}, busy=new Set(), pending=null, timer=null;
    $('obsUrl').textContent=location.origin+'/obs';

    async function send(p){
      try{ st=await (await fetch('/set?'+new URLSearchParams(p))).json(); render(); }catch(e){}
    }
    // Sliders: at most one request per 70 ms, the last value always wins.
    function sendThrottled(p){
      pending=Object.assign(pending||{},p);
      if(timer) return;
      timer=setTimeout(()=>{const x=pending;pending=null;timer=null;send(x)},70);
    }
    async function poll(){ try{ st=await (await fetch('/state')).json(); render(); }catch(e){} }
    setInterval(poll,1000); poll();

    // log scale helpers for ISO and shutter
    const toLog=(v,a,b)=>Math.log(v/a)/Math.log(b/a);
    const fromLog=(t,a,b)=>a*Math.pow(b/a,t);
    const fmtShutter=s=>s>=0.5?s.toFixed(1)+'s':'1/'+Math.round(1/s);

    function setSlider(id,val,text){ if(!busy.has(id)) $(id).value=val; $(id+'Out').textContent=text; }
    function render(){
      if(!st.ok) return;
      document.querySelectorAll('.seg').forEach(seg=>{
        const k=seg.dataset.k;
        seg.querySelectorAll('button').forEach(b=>{
          b.classList.toggle('on',String(st[k])===b.dataset.v);
          if(k==='lens') b.hidden=!(st.lenses||[]).includes(b.dataset.v);
        });
      });
      $('zoom').min=st.zoomMin; $('zoom').max=st.zoomMax;
      setSlider('zoom',st.zoom,st.zoom.toFixed(2)+'×');
      setSlider('lensPos',st.lensPos,st.lensPos.toFixed(3));
      $('lensPos').disabled=!st.focusSupported;
      $('ev').min=Math.max(st.evMin,-4); $('ev').max=Math.min(st.evMax,4);
      setSlider('ev',st.ev,(st.ev>0?'+':'')+st.ev.toFixed(1));
      setSlider('iso',toLog(st.iso,st.isoMin,st.isoMax),Math.round(st.iso));
      setSlider('shutter',toLog(st.shutter,st.shutterMin,st.shutterMax),fmtShutter(st.shutter));
      setSlider('temp',st.temp,Math.round(st.temp));
      setSlider('sat',st.sat,Math.round(st.sat*100)+'%');
      setSlider('con',st.con,Math.round(st.con*100)+'%');
      setSlider('black',st.black,(st.black>0?'+':'')+Math.round(st.black*1000)/10);
      setSlider('blurAmt',toLog(st.blurAmt,0.05,12),st.blurAmt<1?st.blurAmt.toFixed(2):st.blurAmt.toFixed(1));
      setSlider('q',st.q,Math.round(st.q*100)+'%');
      $('faceOut').textContent=st.focus==='face'?(st.faceSeen?'(face found)':'(no face)'):'';
      $('fpsOut').textContent=st.realFps; $('cl').textContent=st.clients;
    }

    document.querySelectorAll('.seg').forEach(seg=>seg.addEventListener('click',e=>{
      const b=e.target.closest('button'); if(!b) return;
      const k=seg.dataset.k, val=b.dataset.v;
      if(k==='focus') send(val==='face'?{face:1}:{face:0,focus:val});
      else send({[k]:val});
    }));

    const sliders={
      zoom:v=>({zoom:v}), lensPos:v=>({lensPos:v}), ev:v=>({ev:v}),
      iso:v=>({iso:fromLog(v,st.isoMin,st.isoMax)}),
      shutter:v=>({shutter:fromLog(v,st.shutterMin,st.shutterMax)}),
      temp:v=>({temp:v}), q:v=>({q:v}),
      blurAmt:v=>({blurAmt:fromLog(v,0.05,12)}),
      sat:v=>({sat:v}), con:v=>({con:v}), black:v=>({black:v}),
    };
    for(const [id,fn] of Object.entries(sliders)){
      const el=$(id);
      el.addEventListener('pointerdown',()=>busy.add(id));
      el.addEventListener('pointerup',()=>setTimeout(()=>busy.delete(id),600));
      el.addEventListener('input',()=>sendThrottled(fn(+el.value)));
      const reset={blurAmt:toLog(3,0.05,12),sat:1.55,con:1,black:0,zoom:1,ev:0}[id];
      if(reset!==undefined) el.addEventListener('dblclick',()=>{el.value=reset;send(fn(reset))});
    }

    const v=$('v'), mark=$('mark');
    play(v);

    // Reads the MJPEG stream with fetch: no copying of the whole buffer per chunk, JPEG decoded
    // off the main thread (createImageBitmap), only the newest frame drawn. No frame for 2 s → reconnect.
    function play(cv){
      const g=cv.getContext('2d',{alpha:false,desynchronized:true});
      let ctl=null, last=0, pending=null, decoding=false;
      function show(blob){
        if(decoding){ pending=blob; return }       // keep only the newest frame
        decoding=true;
        createImageBitmap(blob).then(bm=>{
          if(cv.width!==bm.width||cv.height!==bm.height){ cv.width=bm.width; cv.height=bm.height }
          g.drawImage(bm,0,0); bm.close();
        }).catch(()=>{}).finally(()=>{
          decoding=false;
          if(pending){ const b=pending; pending=null; show(b) }
        });
      }
      async function run(){
        ctl=new AbortController(); last=performance.now();
        let chunks=[], total=0, need=-1;
        const take=n=>{ // remove n bytes from the front
          const out=new Uint8Array(n); let off=0;
          while(off<n){ const c=chunks[0], k=Math.min(c.length,n-off);
            out.set(k===c.length?c:c.subarray(0,k),off); off+=k;
            if(k===c.length) chunks.shift(); else chunks[0]=c.subarray(k) }
          total-=n; return out };
        const peek=n=>{ const out=new Uint8Array(Math.min(n,total)); let off=0;
          for(const c of chunks){ if(off>=out.length) break; const k=Math.min(c.length,out.length-off); out.set(c.subarray(0,k),off); off+=k }
          return out };
        try{
          const r=await fetch('/video?'+Date.now(),{signal:ctl.signal,cache:'no-store'});
          const rd=r.body.getReader();
          for(;;){
            const {value,done}=await rd.read(); if(done) break;
            chunks.push(value); total+=value.length;
            for(;;){
              if(need<0){ // parse the part header: ...Content-Length: N\r\n\r\n
                const h=peek(512), txt=new TextDecoder().decode(h), e=txt.indexOf('\\r\\n\\r\\n');
                if(e<0){ if(total>512) take(total); break }
                const m=/Content-Length:\\s*(\\d+)/i.exec(txt.slice(0,e));
                take(new TextEncoder().encode(txt.slice(0,e+4)).length);
                if(!m) continue;
                need=+m[1];
              }
              if(total<need) break;
              show(new Blob([take(need)],{type:'image/jpeg'})); need=-1; last=performance.now();
            }
          }
        }catch(e){}
        setTimeout(run,500);
      }
      setInterval(()=>{ if(performance.now()-last>2000 && ctl){ ctl.abort(); ctl=null } },500);
      run();
    }
    v.addEventListener('click',e=>{
      const r=v.getBoundingClientRect();
      const u=(e.clientX-r.left)/r.width, w=(e.clientY-r.top)/r.height;
      mark.style.left=(e.clientX-r.left)+'px'; mark.style.top=(e.clientY-r.top)+'px';
      mark.style.transition='none'; mark.style.opacity=1;
      requestAnimationFrame(()=>{mark.style.transition='opacity .8s';mark.style.opacity=0});
      send({tap:u.toFixed(4)+','+w.toFixed(4)});
    });
    </script></body></html>
    """
}
