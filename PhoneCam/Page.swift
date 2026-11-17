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
    :root{
      --bg:#1e1e1e;--card:#2a2a2a;--line:#363636;--track:#1f1f1f;--knob:#4a4a4a;
      --fg:#f2f2f2;--dim:#9a9a9a;--faint:#7c7c7c;--acc:#0a84ff;--acc-ink:#ffffff;--live:#ff453a;--ok:#30d158;
    }
    *{box-sizing:border-box}
    html,body{height:100%}
    body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;-webkit-font-smoothing:antialiased;
      display:grid;grid-template-columns:1fr 340px;grid-template-rows:auto 1fr;gap:14px;padding:14px}
    header{grid-column:1/-1;display:flex;align-items:center;gap:10px}
    .brand{font-weight:600;font-size:16px;display:flex;align-items:center;gap:8px;margin-right:auto}
    .brand i{width:10px;height:10px;border-radius:50%;background:var(--acc)}
    .chip{display:flex;align-items:center;gap:6px;padding:5px 11px;border-radius:99px;background:var(--card);border:1px solid var(--line);color:var(--dim);font-size:13px}
    .chip b{color:var(--fg);font-weight:600;font-variant-numeric:tabular-nums}
    .chip.live i{width:7px;height:7px;border-radius:50%;background:var(--live)}
    #view{min-width:0;display:flex;flex-direction:column;gap:10px}
    #wrap{position:relative;align-self:flex-start;max-width:100%;border-radius:14px;overflow:hidden;background:#000;border:1px solid var(--line)}
    #v{display:block;max-width:100%;max-height:calc(100vh - 120px);cursor:crosshair}
    #wrap::before,#wrap::after{content:"";position:absolute;inset:14px;pointer-events:none;
      background:linear-gradient(#fff,#fff) left top/18px 2px,linear-gradient(#fff,#fff) left top/2px 18px,
                 linear-gradient(#fff,#fff) right top/18px 2px,linear-gradient(#fff,#fff) right top/2px 18px;
      background-repeat:no-repeat;opacity:.35}
    #wrap::after{transform:scaleY(-1)}
    #mark{position:absolute;width:64px;height:64px;margin:-32px 0 0 -32px;pointer-events:none;opacity:0;transition:opacity .8s;
      border:1.5px solid var(--acc);border-radius:6px;box-shadow:0 0 0 1px #0006}
    #info{color:var(--faint);font-size:13px}
    aside{display:flex;flex-direction:column;gap:10px;overflow-y:auto;max-height:calc(100vh - 70px);padding-right:2px;scrollbar-width:thin;scrollbar-color:var(--knob) transparent}
    .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px}
    h3{margin:0 0 10px;font-size:15px;font-weight:600;color:var(--fg);display:flex;align-items:center;gap:8px}
    h3 span{margin-left:auto;font-size:13px;font-weight:400;color:var(--faint)}
    .seg{display:flex;gap:2px;padding:3px;border-radius:9px;background:var(--track)}
    .seg+.seg,.seg+.row,.row+.seg{margin-top:8px}
    .seg button{flex:1;padding:6px 4px;border:0;border-radius:7px;background:transparent;color:var(--dim);cursor:pointer;font:inherit;font-size:13px}
    .seg button:hover{color:var(--fg)}
    .seg button.on{background:var(--acc);color:var(--acc-ink);font-weight:600}
    .seg button[hidden]{display:none}
    .row{display:grid;grid-template-columns:82px 1fr 56px;align-items:center;gap:10px;margin-top:8px}
    .row label{color:var(--dim)}
    .row output{justify-self:end;color:var(--fg);font-variant-numeric:tabular-nums}
    input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:18px;margin:0;background:transparent;cursor:pointer}
    input[type=range]::-webkit-slider-runnable-track{height:4px;border-radius:2px;background:var(--knob)}
    input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:16px;height:16px;margin-top:-6px;border-radius:50%;background:#fff;border:0;box-shadow:0 0 0 1px #0003,0 1px 2px #0006}
    input[type=range]::-moz-range-track{height:4px;border-radius:2px;background:var(--knob)}
    input[type=range]::-moz-range-thumb{width:16px;height:16px;border-radius:50%;background:#fff;border:0}
    input[type=range]:disabled{opacity:.35;cursor:default}
    .hint{color:var(--faint);font-size:12.5px;margin-top:10px;line-height:1.45}
    code{display:block;margin-top:6px;padding:7px 9px;border-radius:7px;background:var(--track);color:var(--fg);font:inherit;font-size:13px;user-select:all;word-break:break-all}
    @media (max-width:860px){body{grid-template-columns:1fr}aside{max-height:none}}
    </style></head><body>
    <header>
      <div class="brand"><i></i>PhoneCam</div>
      <div class="chip live"><i></i>Live</div>
      <div class="chip"><b id="fpsOut">–</b>fps</div>
      <div class="chip"><b id="cl">–</b>viewers</div>
    </header>
    <div id="view">
      <div id="wrap"><canvas id="v"></canvas><div id="mark"></div></div>
      <div id="info">Click the picture to focus and expose at that point · double-click a slider to reset it</div>
    </div>
    <aside>
      <section class="card">
        <h3>Lens</h3>
        <div class="seg" data-k="lens"><button data-v="ultra">0.5×</button><button data-v="wide">1×</button><button data-v="tele">5×</button><button data-v="front">Front</button></div>
        <div class="seg" data-k="frame"><button data-v="1">Auto-frame</button><button data-v="0">Fixed</button></div>
        <div class="row"><label>Zoom</label><input type="range" id="zoom" step="0.01"><output id="zoomOut"></output></div>
        <div class="hint">Auto-frame keeps you centred by moving a crop of the full picture; Zoom sets how tight.</div>
      </section>

      <section class="card">
        <h3>Focus <span id="faceOut"></span></h3>
        <div class="seg" data-k="focus"><button data-v="face">Face</button><button data-v="auto">Auto</button><button data-v="lock">Lock</button></div>
        <div class="row"><label>Distance</label><input type="range" id="lensPos" min="0" max="1" step="0.002"><output id="lensPosOut"></output></div>
        <div class="hint">Face follows you. Clicking the picture or the slider switches it off. 0 = near, 1 = infinity.</div>
      </section>

      <section class="card">
        <h3>Exposure</h3>
        <div class="seg" data-k="exp"><button data-v="auto">Auto</button><button data-v="lock">Lock</button><button data-v="manual">Manual</button></div>
        <div class="row"><label>EV</label><input type="range" id="ev" step="0.1"><output id="evOut"></output></div>
        <div class="row"><label>ISO</label><input type="range" id="iso" min="0" max="1" step="0.001"><output id="isoOut"></output></div>
        <div class="row"><label>Shutter</label><input type="range" id="shutter" min="0" max="1" step="0.001"><output id="shutterOut"></output></div>
        <div class="hint">EV works in Auto. ISO or shutter switches to Manual.</div>
      </section>

      <section class="card">
        <h3>White balance</h3>
        <div class="seg" data-k="wb"><button data-v="skin">Skin</button><button data-v="auto">Auto</button><button data-v="lock">Lock</button></div>
        <div class="row"><label>Temp, K</label><input type="range" id="temp" min="2500" max="9000" step="50"><output id="tempOut"></output></div>
        <div class="hint">Skin keeps the face a natural tone under colored light.</div>
      </section>

      <section class="card">
        <h3>Color</h3>
        <div class="row"><label>Saturation</label><input type="range" id="sat" min="0" max="2" step="0.01"><output id="satOut"></output></div>
        <div class="row"><label>Contrast</label><input type="range" id="con" min="0.5" max="1.5" step="0.01"><output id="conOut"></output></div>
        <div class="row"><label>Black</label><input type="range" id="black" min="-0.1" max="0.1" step="0.002"><output id="blackOut"></output></div>
      </section>

      <section class="card">
        <h3>Background blur <span>~3.5 ms</span></h3>
        <div class="seg" data-k="blur"><button data-v="1">On</button><button data-v="0">Off</button></div>
        <div class="row"><label>Strength</label><input type="range" id="blurAmt" min="0" max="1" step="0.002"><output id="blurAmtOut"></output></div>
        <div class="hint">Person detection runs in parallel and does not slow the stream.</div>
      </section>

      <section class="card">
        <h3>Video</h3>
        <div class="seg" data-k="res"><button data-v="720">720p</button><button data-v="1080">1080p</button><button data-v="4k">4K</button></div>
        <div class="seg" data-k="fps"><button data-v="30">30 fps</button><button data-v="60">60 fps</button></div>
        <div class="seg" data-k="rot"><button data-v="0">0°</button><button data-v="90">90°</button><button data-v="180">180°</button><button data-v="270">270°</button></div>
        <div class="row"><label>Quality</label><input type="range" id="q" min="0.4" max="0.95" step="0.01"><output id="qOut"></output></div>
      </section>

      <section class="card">
        <h3>OBS</h3>
        <div class="hint" style="margin-top:0">Browser Source, 1920×1080:</div>
        <code id="obsUrl"></code>
      </section>
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
      $('faceOut').textContent=st.focus==='face'?(st.faceSeen?'● face found':'no face'):'';
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
