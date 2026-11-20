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
    [hidden]{display:none!important}
    body{margin:0 auto;max-width:1400px;padding:14px 16px 28px;background:var(--bg);color:var(--fg);
      font:14px/1.45 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;-webkit-font-smoothing:antialiased}
    /* top line: what the camera is doing on the left, the page's own buttons on the right */
    header{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:12px}
    .brand{font-weight:600;font-size:16px;display:flex;align-items:center;gap:8px;margin-right:6px}
    .brand i{width:10px;height:10px;border-radius:50%;background:var(--acc)}
    .chip{display:flex;align-items:center;gap:6px;padding:5px 11px;border-radius:99px;background:var(--card);border:1px solid var(--line);color:var(--dim);font-size:13px;white-space:nowrap}
    .chip b{color:var(--fg);font-weight:600;font-variant-numeric:tabular-nums}
    .chip.live i{width:7px;height:7px;border-radius:50%;background:var(--live)}
    .chip.warn{color:#ff9f0a;border-color:#ff9f0a55}
    button.chip{cursor:pointer;font:inherit;font-size:13px}
    button.chip:hover{color:var(--fg)}
    button.chip.on{background:var(--acc);border-color:var(--acc);color:var(--acc-ink)}
    .grow{flex:1}
    #link{color:var(--fg)} #link.warn{color:var(--dim);border-color:var(--line)}
    /* presets: one line under the header */
    #bar{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin-bottom:14px;padding:9px 12px}
    #bar>b{font-size:13px;font-weight:600}
    .presets{display:flex;flex-wrap:wrap;gap:6px;flex:1;min-width:120px}
    .presets .p{display:flex;border-radius:99px;background:var(--track);border:1px solid var(--line);overflow:hidden}
    .presets button{border:0;background:transparent;color:var(--fg);font:inherit;font-size:13px;padding:5px 4px 5px 11px;cursor:pointer}
    .presets button.x{color:var(--faint);padding:5px 9px 5px 5px}
    .presets button:hover{color:var(--acc)}
    .presets .none{color:var(--faint);font-size:13px}
    .presets .p.on{background:var(--acc);border-color:var(--acc)} .presets .p.on button{color:var(--acc-ink);font-weight:600}
    h3 label.mini input{display:none}
    .prow{display:flex;gap:6px;width:250px;max-width:100%}
    .prow input{flex:1;min-width:0;padding:6px 9px;border-radius:8px;border:1px solid var(--line);background:var(--track);color:var(--fg);font:inherit;font-size:13px}
    .prow button{padding:6px 12px;border-radius:8px;border:0;background:var(--acc);color:var(--acc-ink);font:inherit;font-size:13px;cursor:pointer}
    /* the picture (only with the preview on) and the settings */
    body.pv main{display:grid;grid-template-columns:minmax(0,1fr) 400px;gap:16px;align-items:start}
    #view{display:none;min-width:0;flex-direction:column;gap:10px;position:sticky;top:14px}
    body.pv #view{display:flex}
    #wrap{position:relative;align-self:flex-start;max-width:100%;border-radius:14px;overflow:hidden;background:#000;border:1px solid var(--line)}
    #v{display:block;max-width:100%;max-height:calc(100vh - 190px);cursor:crosshair}
    #wrap::before,#wrap::after{content:"";position:absolute;inset:14px;pointer-events:none;
      background:linear-gradient(#fff,#fff) left top/18px 2px,linear-gradient(#fff,#fff) left top/2px 18px,
                 linear-gradient(#fff,#fff) right top/18px 2px,linear-gradient(#fff,#fff) right top/2px 18px;
      background-repeat:no-repeat;opacity:.35}
    #wrap::after{transform:scaleY(-1)}
    #mark{position:absolute;width:64px;height:64px;margin:-32px 0 0 -32px;pointer-events:none;opacity:0;transition:opacity .8s;
      border:1.5px solid var(--acc);border-radius:6px;box-shadow:0 0 0 1px #0006}
    #info{color:var(--faint);font-size:13px}
    #zebra{position:absolute;inset:0;width:100%;height:100%;pointer-events:none}
    #hist{width:min(100%,960px);height:56px;border-radius:10px;background:var(--card);border:1px solid var(--line)}
    /* settings: the groups side by side; one at a time, under tabs, when there is no room for that */
    #groups{display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:16px;align-items:start}
    .group{display:flex;flex-direction:column;gap:10px;min-width:0}
    .group>h2{margin:0 2px 0;font-size:12px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--faint)}
    #tabs{display:none;gap:2px;padding:3px;border-radius:10px;background:var(--card);border:1px solid var(--line);margin-bottom:10px}
    #tabs button{flex:1;padding:7px 4px;border:0;border-radius:7px;background:transparent;color:var(--dim);cursor:pointer;font:inherit;font-size:13px}
    #tabs button:hover{color:var(--fg)}
    #tabs button.on{background:var(--knob);color:var(--fg);font-weight:600}
    body.tabs #tabs{display:flex}
    body.tabs #groups{grid-template-columns:minmax(0,1fr)}
    body.tabs .group{display:none} body.tabs .group.on{display:flex}
    body.tabs .group>h2{display:none}
    .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px}
    h3{margin:0 0 10px;font-size:15px;font-weight:600;color:var(--fg);display:flex;align-items:center;gap:8px;min-height:22px}
    h3 .meta{margin-left:auto;font-size:12.5px;font-weight:400;color:var(--faint);text-align:right}
    h3 .mini{padding:2px 10px;border-radius:99px;border:1px solid var(--line);background:var(--track);color:var(--dim);font:inherit;font-size:12px;font-weight:400;cursor:pointer}
    h3 .q{width:22px;height:22px;padding:0;border-radius:50%;border:1px solid var(--line);background:var(--track);color:var(--dim);font:inherit;font-size:12px;font-weight:600;cursor:pointer}
    h3 .mini:hover,h3 .q:hover{color:var(--fg)}
    .card.help h3 .q{background:var(--knob);color:var(--fg)}
    .seg{display:flex;gap:2px;padding:3px;border-radius:9px;background:var(--track)}
    .seg+.seg,.seg+.row,.row+.seg,.block+.seg{margin-top:8px}
    .seg button{flex:1;padding:6px 4px;border:0;border-radius:7px;background:transparent;color:var(--dim);cursor:pointer;font:inherit;font-size:13px}
    .seg button:hover{color:var(--fg)}
    .seg button.on{background:var(--acc);color:var(--acc-ink);font-weight:600}
    .row{display:grid;grid-template-columns:86px 1fr 52px;align-items:center;gap:10px;margin-top:8px}
    .row label{color:var(--dim)}
    .row output{justify-self:end;color:var(--fg);font-variant-numeric:tabular-nums;white-space:nowrap}
    input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:18px;margin:0;background:transparent;cursor:pointer}
    input[type=range]::-webkit-slider-runnable-track{height:4px;border-radius:2px;background:var(--knob)}
    input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:16px;height:16px;margin-top:-6px;border-radius:50%;background:#fff;border:0;box-shadow:0 0 0 1px #0003,0 1px 2px #0006}
    input[type=range]::-moz-range-track{height:4px;border-radius:2px;background:var(--knob)}
    input[type=range]::-moz-range-thumb{width:16px;height:16px;border-radius:50%;background:#fff;border:0}
    input[type=range]:disabled{opacity:.35;cursor:default}
    .hslhead{display:flex;align-items:center;gap:10px;margin-top:12px}
    .hslhead span{width:86px;color:var(--fg);font-size:13px}
    .bands{display:flex;gap:7px;flex-wrap:wrap}
    .bands button{position:relative;width:20px;height:20px;border-radius:50%;border:0;padding:0;cursor:pointer;box-shadow:0 0 0 1px #0004 inset}
    .bands button.on{box-shadow:0 0 0 2px var(--card),0 0 0 4px var(--fg)}
    .bands button.mod::after{content:'';position:absolute;left:50%;bottom:-7px;width:4px;height:4px;margin-left:-2px;border-radius:50%;background:var(--fg)}
    /* what a setting is doing right now: always shown. The explanations: behind the card's "?" */
    .now{color:var(--dim);font-size:12.5px;margin-top:10px;line-height:1.45} .now:empty{display:none}
    .hint{display:none;color:var(--faint);font-size:12.5px;margin-top:10px;line-height:1.45}
    .card.help .hint,.hint.show{display:block}
    code{display:block;margin-top:8px;padding:7px 9px;border-radius:7px;background:var(--track);color:var(--fg);font:inherit;font-size:13px;user-select:all;word-break:break-all}
    footer{margin-top:16px;color:var(--faint);font-size:12.5px}
    @media (max-width:900px){body.pv main{grid-template-columns:minmax(0,1fr)} #view{position:static}}
    </style></head><body>
    <header>
      <div class="brand"><i></i>PhoneCam</div>
      <div class="chip" id="link" title="How the Mac reaches the iPhone">–</div>
      <div class="chip live" title="Frames per second the iPhone camera delivers"><i></i><b id="fpsOut">–</b>fps</div>
      <div class="chip" title="Bitrate of the stream to the Mac camera"><b id="mbOut">–</b>Mbit/s</div>
      <div class="chip" title="Connections reading the picture"><b id="cl">–</b>viewers</div>
      <div class="chip warn" id="sleep" title="No app uses the camera: the iPhone camera sleeps and wakes in about a second when it is used" hidden>Camera asleep</div>
      <div class="chip warn" id="intr" title="iOS stopped the iPhone camera; it starts again by itself when the reason is gone" hidden></div>
      <div class="chip warn" id="heat" title="iPhone temperature (iOS thermal state)" hidden></div>
      <div class="chip warn" id="dark" title="Dark room at 60 fps: 30 fps lets the shutter stay open twice as long, with less noise. Back to 60 fps when it is brighter." hidden>Low light: 30 fps</div>
      <span class="grow"></span>
      <button class="chip" id="zeb" title="Stripes over blown-out highlights in the preview" hidden>Zebra</button>
      <button class="chip" id="prev" title="Video preview on this page, with click-to-focus (the PhoneCam camera works in your apps either way)">Preview off</button>
      <button class="chip" id="reset" title="Return every setting to the PhoneCam defaults">Reset all</button>
    </header>
    <section class="card" id="bar" title="A preset keeps the look and framing: lens, zoom, exposure, white balance and colour (not capture size or frame rate)">
      <b>Presets</b>
      <div class="presets" id="presets"></div>
      <div class="prow"><input id="pname" maxlength="24" placeholder="Name, e.g. Evening"><button id="psave">Save</button></div>
    </section>
    <main>
    <div id="view">
      <div id="wrap"><canvas id="v"></canvas><canvas id="zebra" hidden></canvas><div id="mark"></div></div>
      <canvas id="hist" width="640" height="112" title="Brightness histogram of the preview: shadows left, highlights right (red: clipped)" hidden></canvas>
      <div id="info">Preview <b id="pvOut">–</b> fps · click the picture to focus and expose at that point</div>
    </div>
    <div id="side">
      <div id="tabs"><button data-g="gCamera">Camera</button><button data-g="gLight">Light</button><button data-g="gColour">Colour</button><button data-g="gLegacy">Legacy</button></div>
      <div id="groups">
      <div class="group" id="gCamera">
        <h2>Camera</h2>
        <section class="card">
          <h3>Lens and framing <span class="meta" id="tiltOut"></span><button class="q" title="What these do">?</button></h3>
          <div class="seg" data-k="lens"><button data-v="ultra">0.5×</button><button data-v="wide">1×</button><button data-v="tele">5×</button><button data-v="front">Front</button></div>
          <div class="row"><label>Zoom</label><input type="range" id="zoom" step="0.01"><output id="zoomOut"></output></div>
          <div class="seg" data-k="frame"><button data-v="1">Auto-frame</button><button data-v="0">Fixed</button></div>
          <div class="seg" data-k="level"><button data-v="1">Level horizon</button><button data-v="0">Off</button></div>
          <div class="hint">Auto-frame keeps you centred by moving a crop of the full picture; Zoom sets how tight. Level horizon straightens the picture when the phone is tilted.</div>
        </section>
        <section class="card">
          <h3>Focus <span class="meta" id="faceOut"></span><button class="q" title="What these do">?</button></h3>
          <div class="seg" data-k="focus"><button data-v="face">Face</button><button data-v="auto">Auto</button><button data-v="lock">Lock</button></div>
          <div class="row"><label>Distance</label><input type="range" id="lensPos" min="0" max="1" step="0.002"><output id="lensPosOut"></output></div>
          <div class="hint">Face follows you. Clicking the picture or moving the slider switches it off. 0 = near, 1 = infinity.</div>
        </section>
        <section class="card">
          <h3>Video <span class="meta" id="logOut"></span><button class="q" title="What these do">?</button></h3>
          <div class="seg" data-k="cap"><button data-v="4k">4K capture</button><button data-v="1080">1080p capture</button></div>
          <div class="seg" data-k="fps"><button data-v="30">30 fps</button><button data-v="60">60 fps</button></div>
          <div class="row"><label>Quality</label><input type="range" id="q" min="0.4" max="0.95" step="0.01"><output id="qOut"></output></div>
          <div class="row"><label>Rotation</label><div class="seg" data-k="rot" style="grid-column:2/4"><button data-v="auto">Auto</button><button data-v="0">0°</button><button data-v="90">90°</button><button data-v="180">180°</button><button data-v="270">270°</button></div></div>
          <div class="hint">Apple Log: the iPhone records with almost none of its own processing (no HDR, no lifted shadows, little sharpening) and PhoneCam turns that into a normal picture without adding a look. Cameras without Apple Log give the iPhone's usual picture.</div>
          <div class="hint">4K: sharpest when auto-frame or zoom crop the picture. 1080p: about a quarter of the pixels, so the iPhone runs cooler and uses less battery; crops look a little softer.</div>
        </section>
        <section class="card">
          <h3>OBS</h3>
          <div class="hint show" style="margin-top:0">Add a Video Capture Device and pick the <b>PhoneCam</b> camera. Without the Mac app, use a Browser Source (1920×1080) with:</div>
          <code id="obsUrl"></code>
        </section>
      </div>

      <div class="group" id="gLight">
        <h2>Light</h2>
        <section class="card">
          <h3>Exposure <span class="meta"></span><button class="q" title="What these do">?</button></h3>
          <div class="seg" data-k="exp"><button data-v="auto">Auto</button><button data-v="lock">Lock</button><button data-v="manual">Manual</button></div>
          <div class="row"><label>EV</label><input type="range" id="ev" step="0.1"><output id="evOut"></output></div>
          <div class="row"><label>ISO</label><input type="range" id="iso" min="0" max="1" step="0.001"><output id="isoOut"></output></div>
          <div class="row"><label>Shutter</label><input type="range" id="shutter" min="0" max="1" step="0.001"><output id="shutterOut"></output></div>
          <div class="seg" data-k="mains" title="Lamps flicker with the mains power; Lock and Manual keep the shutter in step with it so the picture shows no bands"><button data-v="auto" id="mainsAuto">Lights auto</button><button data-v="50">50 Hz</button><button data-v="60">60 Hz</button></div>
          <div class="hint">EV works in Auto. ISO or shutter switches to Manual. Lock and Manual pick shutter speeds that don't show lamp flicker (50 Hz or 60 Hz power).</div>
        </section>
        <section class="card">
          <h3>White balance <span class="meta" id="skinInfo"></span><button class="q" title="What these do">?</button></h3>
          <div class="seg" data-k="wb"><button data-v="skin">Skin</button><button data-v="auto">Auto</button><button data-v="lock">Lock</button></div>
          <div class="row"><label>Temp, K</label><input type="range" id="temp" min="2500" max="9000" step="50"><output id="tempOut"></output></div>
          <div class="row"><label>Skin hue</label><input type="range" id="skinWarm" min="-1" max="1" step="0.01"><output id="skinWarmOut"></output></div>
          <div class="hint">Skin: auto white balance for the scene, plus the hue of skin tones only is turned toward natural skin. Skin hue: left = pinker, right = more golden.</div>
        </section>
        <section class="card">
          <h3>Auto operator <span class="meta"></span><button class="q" title="What these do">?</button></h3>
          <div class="seg" data-k="steady" title="Exposure and white balance stay put while the light is the same, so moving a hand or leaning in doesn't make the picture breathe; they adjust again when the light really changes"><button data-v="1">Steady auto</button><button data-v="0">Off</button></div>
          <div class="seg" data-k="faceExp" title="The picture's brightness follows your face, slowly, so a window behind you or a lamp switched on does not leave it dark or burnt (Apple Log only)"><button data-v="1">Face exposure</button><button data-v="0">Off</button></div>
          <div class="seg" data-k="tone" title="Gentle contrast for a flat picture, brighter mid-tones in a dark room; decided slowly from the last half minute"><button data-v="1">Auto tone</button><button data-v="0">Off</button></div>
          <div class="seg" data-k="points" title="Part of Auto tone, for the Apple Log picture: the darkest thing in the picture is brought toward black and the brightest toward white, softly. Off: the tones stay as developed"><button data-v="1">Black / white points</button><button data-v="0">Off</button></div>
          <div class="seg" data-k="light" title="A little light on your face and a soft darkening toward the corners, following you"><button data-v="1">Face light</button><button data-v="0">Off</button></div>
          <div class="row"><label>Face light</label><input type="range" id="lightAmt" min="0" max="1" step="0.01"><output id="lightAmtOut"></output></div>
          <div class="now" id="opInfo"></div>
          <div class="hint">Face exposure: the brightness of the picture follows your face, slowly (within −1…+0.8 stops). Steady auto: exposure and white balance stay put while the light is the same, and adjust when it really changes. Auto tone: gentle contrast for a flat picture, brighter mid-tones in a dark room. Black / white points (with Auto tone on, Apple Log only): haze from a window or a lifted exposure goes, the darkest thing in the picture moves toward black and the brightest toward white, softly; Off leaves the tones as developed. Face light: a little light on your face and a soft darkening toward the corners.</div>
        </section>
      </div>

      <div class="group" id="gColour">
        <h2>Colour</h2>
        <section class="card">
          <h3>Developing <span class="meta"></span><label class="mini" title="Add a 3D LUT (.cube) made for Apple Log footage: Apple Log in, Rec.709 out">Add .cube<input type="file" id="lutFile" accept=".cube" hidden></label><button class="q" title="What these do">?</button></h3>
          <div class="presets" id="luts"></div>
          <div class="now" id="lutMsg"></div>
          <div class="hint">How the Apple Log frames become a picture. Built-in: PhoneCam's own developing, neutral. Your LUT: a .cube made for Apple Log footage (Apple Log in, Rec.709 out), such as Apple's own or a camera-profile LUT; it replaces the built-in developing. A LUT made for normal video will look far too hard here. The settings below and Face exposure work with both.</div>
        </section>
        <section class="card">
          <h3>Balance and tone <span class="meta"></span><button class="mini" id="colorReset" title="These sliders back to the defaults">Reset</button><button class="q" title="What these do">?</button></h3>
          <div class="row" style="margin-top:0"><label>Warmth</label><input type="range" id="warm" min="-1" max="1" step="0.01"><output id="warmOut"></output></div>
          <div class="row"><label>Tint</label><input type="range" id="tint" min="-1" max="1" step="0.01"><output id="tintOut"></output></div>
          <div class="row"><label>Saturation</label><input type="range" id="sat" min="0" max="2" step="0.01"><output id="satOut"></output></div>
          <div class="row" title="Weak colours get richer; colours that are already full hardly change"><label>Vibrance</label><input type="range" id="vib" min="0" max="1" step="0.01"><output id="vibOut"></output></div>
          <div class="row"><label>Contrast</label><input type="range" id="con" min="0.5" max="1.5" step="0.01"><output id="conOut"></output></div>
          <div class="row"><label>Black</label><input type="range" id="black" min="-0.1" max="0.2" step="0.002"><output id="blackOut"></output></div>
          <div class="hint">Vibrance: weak colours get richer, full ones hardly change (Saturation moves everything alike, skin too). Warmth: bluer ↔ more amber. Tint: greener ↔ more magenta. Black: right makes shadows deeper (up to 51 of 255, enough to take the haze of a window behind you off), left lifts them.</div>
        </section>
        <section class="card">
          <h3>HSL <span class="meta"></span><button class="mini" id="hslReset" title="Manual HSL back to no change">Reset</button><button class="q" title="What these do">?</button></h3>
          <div class="seg" data-k="accents" title="Set each colour yourself, or let PhoneCam do it from the scene"><button data-v="0">Manual</button><button data-v="1">Auto</button><button data-v="2" title="You stand out: richer, cleaner clothes colours, a tan, a calmer room">Auto 2</button></div>
          <div class="block" id="hslManual">
            <div class="hslhead"><span id="hslName">Red</span><div class="bands" id="bands"></div></div>
            <div class="row"><label>Hue</label><input type="range" id="hslH" min="-1" max="1" step="0.01"><output id="hslHOut"></output></div>
            <div class="row"><label>Saturation</label><input type="range" id="hslS" min="-1" max="1" step="0.01"><output id="hslSOut"></output></div>
            <div class="row"><label>Luminance</label><input type="range" id="hslL" min="-1" max="1" step="0.01"><output id="hslLOut"></output></div>
            <div class="hint">Hue, saturation and luminance of one colour at a time (pick it in the circles); a dot marks colours you changed. Skin is mostly orange.</div>
          </div>
          <div class="block" id="hslAuto" hidden>
            <div class="row"><label>Strength</label><input type="range" id="accentAmt" min="0" max="1" step="0.01"><output id="accentAmtOut"></output></div>
            <div class="now" id="accentInfo"></div>
            <div class="hint" id="hintAuto1">Small colourful things behind you (a lamp, a light strip, a poster) get a little richer, big loud surfaces a little calmer, skin never changes. Decided slowly from the last half minute, so the picture doesn't jump. Your manual HSL comes back when you switch to manual.</div>
            <div class="hint" id="hintAuto2" hidden>You stand out from the room: your clothes' colours get richer and are turned toward clean, pleasant hues; skin gets a warm tan, neither red nor green; one small colourful thing behind you, if there is one, gets richer; big coloured surfaces get calmer. Decided slowly from the last half minute.</div>
          </div>
        </section>
        <section class="card">
          <h3>Retouch <span class="meta"></span><button class="q" title="What these do">?</button></h3>
          <div class="row" style="margin-top:0"><label>Teeth</label><input type="range" id="teeth" min="0" max="1" step="0.01"><output id="teethOut"></output></div>
          <div class="hint">Whiter teeth when your mouth is open (finds the mouth with face landmarks; 0 is off).</div>
        </section>
      </div>

      <div class="group" id="gLegacy">
        <h2>Legacy</h2>
        <section class="card">
          <h3>Picture mode <span class="meta"></span><button class="q" title="What these do">?</button></h3>
          <div class="seg" data-k="proc"><button data-v="log">Apple Log</button><button data-v="hdr">iPhone HDR</button></div>
          <div class="hint">Apple Log (the normal mode): the iPhone records with almost none of its own processing and PhoneCam develops the picture. iPhone HDR: the picture as it was before, made by the iPhone itself with video HDR (even light, lifted shadows); Face exposure does not apply to it. Switching restarts the camera for a second.</div>
        </section>
      </div>
      </div>
    </div>
    </main>
    <footer>Double-click a slider to put it back to its default · <span id="vwOut"></span></footer>
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
    // Link type comes from the Mac app (it knows whether the phone is on the cable or direct Wi‑Fi).
    async function pollLink(){
      try{
        const l=await (await fetch('/link')).json();
        const name={usb:'USB cable',wifi:'Direct Wi‑Fi',none:'iPhone not found'}[l.link]||l.link;
        $('link').textContent=name+(l.camera&&l.camera!=='–'?' · '+l.camera:'');
        $('link').classList.toggle('warn',l.link!=='usb');
      }catch(e){ $('link').textContent='–' }
    }
    setInterval(pollLink,2000); pollLink();
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
      const sgn=x=>(x>0?'+':'')+Math.round(x*100);
      setSlider('skinWarm',st.skinWarm,sgn(st.skinWarm));
      setSlider('warm',st.warm,sgn(st.warm)); setSlider('tint',st.tint,sgn(st.tint));
      $('skinInfo').textContent=st.wb==='skin'?('face '+st.faceHue+'°, shift '+(st.skinShift>0?'+':'')+st.skinShift+'°'):'';
      renderHSL();
      setSlider('lightAmt',st.lightAmt,Math.round(st.lightAmt*100)+'%');
      $('lightAmt').disabled=st.light!=='1';
      { const parts=[];
        if(st.steady==='1') parts.push((st.steadyExp?'exposure held':'exposure adjusting')+', '+(st.steadyWB?'white balance held':'white balance adjusting'));
        if(st.faceExp==='1'&&st.logOn&&Math.abs(st.faceStops)>=0.1) parts.push('face exposure '+(st.faceStops>0?'+':'')+st.faceStops+' stops');
        if(st.tone==='1'&&st.toneNow){ const [c,m,bk,wh]=st.toneNow, t=[];
          if(st.points==='1'&&st.logOn){ if(bk>=0.01) t.push('black point '+Math.round(bk*255)); if(wh>=0.01) t.push('white point '+Math.round((1-wh)*255)) }
          if(Math.abs(c)>=0.01) t.push('contrast +'+Math.round(c*100)); if(Math.abs(m)>=0.01) t.push('mid-tones '+(m>=0?'+':'')+Math.round(m*100));
          parts.push('tone: '+(t.length?t.join(', '):'fine as it is')) }
        $('opInfo').textContent=parts.length?'Now: '+parts.join(' · '):''; }
      setSlider('accentAmt',st.accentAmt,Math.round(st.accentAmt*100)+'%');
      $('hslManual').hidden=st.accents!=='0'; $('hslAuto').hidden=st.accents==='0';
      $('hintAuto1').hidden=st.accents!=='1'; $('hintAuto2').hidden=st.accents!=='2';
      { const hue=st.accentHue||[], a=(st.accentSat||[]).map((v,i)=>[HSLN[i],v,hue[i]||0]).filter(x=>Math.abs(x[1])>=0.02||Math.abs(x[2])>=0.02);
        const part=([n,v,h])=>n+' saturation '+(v>0?'+':'')+Math.round(v*100)+(Math.abs(h)>=0.02?', hue '+(h>0?'+':'')+Math.round(h*30)+'°':'');
        $('accentInfo').textContent=(a.length?'Now: '+a.map(part).join('; '):'Now: nothing to change (watching the scene)')+(st.accents==='2'?' · skin: tan':''); }
      setSlider('teeth',st.teeth,st.teeth>0.01?Math.round(st.teeth*100)+'%'+(st.mouthOpen?'':' –'):'Off');
      setSlider('vib',st.vib,Math.round(st.vib*100)+'%');
      setSlider('con',st.con,Math.round(st.con*100)+'%');
      setSlider('black',st.black,(st.black>0?'+':'')+Math.round(st.black*1000)/10);
      setSlider('q',st.q,Math.round(st.q*100)+'%');
      $('tiltOut').textContent='tilt '+st.tilt+'°, rotation '+st.rotNow+'°';
      $('faceOut').textContent=st.focus==='face'?(st.faceSeen?'face found':'no face'):'';
      $('logOut').textContent=st.logOn?'Apple Log':'iPhone picture';
      $('sleep').hidden=!st.asleep;
      const intr=$('intr'); intr.hidden=!st.interrupted; intr.textContent='Camera stopped: '+(st.interrupted||'');
      const heat=$('heat'); heat.hidden=!st.thermal||st.thermal==='ok';
      heat.textContent=st.heatLimited?'iPhone hot: 1080p 30 fps until it cools':({warm:'iPhone warm',hot:'iPhone hot',critical:'iPhone overheating'}[st.thermal]||'');
      heat.hidden=heat.hidden&&!st.heatLimited;
      $('dark').hidden=!st.darkLimited;
      $('mainsAuto').textContent='Lights auto ('+st.mainsHz+' Hz)';
      renderPresets(st.presets||[]);
      renderLUTs();
      $('fpsOut').textContent=st.realFps; $('cl').textContent=st.clients; $('mbOut').textContent=st.mbps; $('vwOut').textContent=st.viewers;
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
      sat:v=>({sat:v}), vib:v=>({vib:v}), hslH:v=>hslSet(0,v), hslS:v=>hslSet(1,v), hslL:v=>hslSet(2,v), accentAmt:v=>({accentAmt:v}), teeth:v=>({teeth:v}), lightAmt:v=>({lightAmt:v}), skinWarm:v=>({skinWarm:v}), warm:v=>({warm:v}), tint:v=>({tint:v}), con:v=>({con:v}), black:v=>({black:v}),
    };
    const defaults={teeth:0,vib:0.35,accentAmt:0.6,lightAmt:0.5,hslH:0,hslS:0,hslL:0,skinWarm:0,warm:0,tint:0,sat:1,con:1,black:0,zoom:1.15,ev:0};
    for(const [id,fn] of Object.entries(sliders)){
      const el=$(id);
      el.addEventListener('pointerdown',()=>busy.add(id));
      el.addEventListener('pointerup',()=>setTimeout(()=>busy.delete(id),600));
      el.addEventListener('input',()=>sendThrottled(fn(+el.value)));
      const reset=defaults[id];
      if(reset!==undefined) el.addEventListener('dblclick',()=>{el.value=reset;send(fn(reset))});
    }

    const v=$('v'), mark=$('mark');
    $('colorReset').onclick=()=>send({warm:0,tint:0,sat:1,vib:0.35,con:1,black:0});
    $('hslReset').onclick=()=>send({hsl:''});
    // HSL: eight colours, one edited at a time. The whole set goes to the phone as one "hsl" value.
    const HSLN=['Red','Orange','Yellow','Green','Aqua','Blue','Purple','Magenta'];
    const HSLC=['#e5484d','#f76b15','#ffc53d','#46a758','#12a594','#3e63dd','#8e4ec6','#d6409f'];
    let hslBand=0; try{ hslBand=Math.min(7,Math.max(0,+localStorage.getItem('hslBand')||0)) }catch(e){}
    function hslParse(s){
      const a=[...Array(8)].map(()=>[0,0,0]);
      (s||'').split(';').forEach((g,i)=>{ const v=g.split(',').map(Number); if(i<8&&v.length===3) a[i]=v.map(x=>isFinite(x)?x:0) });
      return a;
    }
    const hslString=a=>a.map(v=>v.map(x=>Math.round(x*100)/100).join(',')).join(';');
    function hslSet(k,v){ const a=hslParse(st.hsl); a[hslBand][k]=v; st.hsl=hslString(a); return {hsl:st.hsl} }
    const bands=$('bands');
    HSLN.forEach((n,i)=>{
      const b=document.createElement('button'); b.style.background=HSLC[i]; b.title=n;
      b.onclick=()=>{ hslBand=i; try{localStorage.setItem('hslBand',i)}catch(e){}; renderHSL() };
      bands.append(b);
    });
    function renderHSL(){
      const a=hslParse(st.hsl), v=a[hslBand], sgn=x=>(x>0?'+':'')+Math.round(x*100);
      $('hslName').textContent=HSLN[hslBand];
      [...bands.children].forEach((b,i)=>{ b.classList.toggle('on',i===hslBand); b.classList.toggle('mod',a[i].some(x=>Math.abs(x)>0.005)) });
      setSlider('hslH',v[0],sgn(v[0])); setSlider('hslS',v[1],sgn(v[1])); setSlider('hslL',v[2],sgn(v[2]));
    }
    // Developing: built-in, then your LUTs (with ×), rebuilt only when the list or the choice changes.
    let lutKey='';
    function renderLUTs(){
      const key=JSON.stringify([st.luts,st.lut]); if(key===lutKey) return; lutKey=key;
      const box=$('luts'); box.textContent='';
      const add=(name,label,mine)=>{
        const w=document.createElement('span'); w.className='p'+((st.lut||'')===name?' on':'');
        const b=document.createElement('button'); b.textContent=label; b.onclick=()=>send({lut:name});
        if(!mine) b.style.paddingRight='11px';
        w.append(b);
        if(mine){
          const x=document.createElement('button'); x.className='x'; x.textContent='×'; x.title='Delete '+name;
          x.onclick=()=>{ if(confirm('Delete LUT '+name+'?')) send({lutDelete:name}) };
          w.append(x);
        }
        box.append(w);
      };
      add('','Built-in',false);
      for(const n of st.luts||[]) add(n,n,true);
    }
    $('lutFile').onchange=async e=>{
      const f=e.target.files[0]; e.target.value=''; if(!f) return;
      const msg=$('lutMsg');
      msg.textContent='Loading '+f.name+'…';
      try{
        const r=await fetch('/lut?name='+encodeURIComponent(f.name),{method:'POST',body:f});
        msg.textContent=r.ok?f.name+' added.':await r.text();
        if(r.ok){ poll(); setTimeout(()=>msg.textContent='',4000) }
      }catch(err){ msg.textContent='Upload failed: '+err }
    };
    // Presets: buttons rebuilt only when the list changes.
    let presetList='';
    function renderPresets(list){
      const key=JSON.stringify(list); if(key===presetList) return; presetList=key;
      const box=$('presets'); box.textContent='';
      if(!list.length){ const e=document.createElement('span'); e.className='none'; e.textContent='None yet: set the picture up, name it, Save'; box.append(e); return }
      for(const n of list){
        const w=document.createElement('span'); w.className='p';
        const b=document.createElement('button'); b.textContent=n; b.title='Load '+n; b.onclick=()=>send({presetLoad:n});
        const x=document.createElement('button'); x.className='x'; x.textContent='×'; x.title='Delete '+n;
        x.onclick=()=>{ if(confirm('Delete preset '+n+'?')) send({presetDelete:n}) };
        w.append(b,x); box.append(w);
      }
    }
    const savePreset=()=>{ const n=$('pname').value.trim(); if(!n) return; send({presetSave:n}); $('pname').value='' };
    $('psave').onclick=savePreset;
    $('pname').addEventListener('keydown',e=>{ if(e.key==='Enter') savePreset() });

    // Histogram and zebra, computed here from the preview frames (the iPhone does no extra work).
    let zebraOn=false;
    try{ zebraOn=localStorage.getItem('zebra')==='1' }catch(e){}
    const AW=320, AH=180;
    const work=Object.assign(document.createElement('canvas'),{width:AW,height:AH}).getContext('2d',{willReadFrequently:true});
    const zc=$('zebra'); zc.width=AW; zc.height=AH;
    const zg=zc.getContext('2d'), hg=$('hist').getContext('2d');
    let lastAnalysis=0, phase=0;
    function analyse(bm){
      const now=performance.now(); if(now-lastAnalysis<125) return; lastAnalysis=now;
      work.drawImage(bm,0,0,AW,AH);
      const px=work.getImageData(0,0,AW,AH).data;
      const bins=new Uint32Array(64); let clipped=0;
      const z=zebraOn?zg.createImageData(AW,AH):null; phase=(phase+1)%8;
      for(let i=0,p=0;i<px.length;i+=4,p++){
        const y=0.2126*px[i]+0.7152*px[i+1]+0.0722*px[i+2];
        bins[Math.min(63,y>>2)]++;
        if(y>=245){ clipped++;
          if(z){ const x=p%AW, yy=(p/AW)|0; const on=((x+yy+phase)&7)<4;
            z.data[i]=on?0:255; z.data[i+1]=on?0:255; z.data[i+2]=on?0:255; z.data[i+3]=170 } }
      }
      if(z) zg.putImageData(z,0,0);
      // Histogram: square-root height so small peaks stay visible.
      const W=hg.canvas.width, H=hg.canvas.height, css=getComputedStyle(document.documentElement);
      hg.clearRect(0,0,W,H);
      const max=Math.max(...bins), bw=W/64;
      for(let b=0;b<64;b++){
        const h=Math.sqrt(bins[b]/max)*(H-8);
        hg.fillStyle=b===63&&clipped/(AW*AH)>0.01?css.getPropertyValue('--live'):css.getPropertyValue('--dim');
        hg.fillRect(b*bw+1,H-4-h,bw-2,h);
      }
    }
    window.onPreviewFrame=analyse;

    $('reset').onclick=()=>{ if(confirm('Reset all settings to the defaults?')) send({reset:1}) };

    // "?" on a card shows its explanations (remembered per card).
    let helpOn={}; try{ helpOn=JSON.parse(localStorage.getItem('help')||'{}') }catch(e){}
    document.querySelectorAll('.card .q').forEach(b=>{
      const card=b.closest('.card'), name=card.querySelector('h3').firstChild.textContent.trim();
      card.classList.toggle('help',!!helpOn[name]);
      b.onclick=()=>{ helpOn[name]=card.classList.toggle('help'); try{ localStorage.setItem('help',JSON.stringify(helpOn)) }catch(e){} };
    });

    // Preview is off by default: apps use the PhoneCam camera, the page only needs the settings.
    let previewOn=false;
    try{ previewOn=localStorage.getItem('preview')==='1' }catch(e){}
    const prev=$('prev');
    prev.classList.toggle('on',previewOn);
    prev.textContent=previewOn?'Preview on':'Preview off';
    prev.onclick=()=>{ try{ localStorage.setItem('preview',previewOn?'0':'1') }catch(e){} location.reload() };
    if(previewOn){
      v.dataset.preview='1'; play(v);
      $('hist').hidden=false;
      const zb=$('zeb'); zb.hidden=false; zb.classList.toggle('on',zebraOn); zc.hidden=!zebraOn;
      zb.onclick=()=>{ zebraOn=!zebraOn; try{ localStorage.setItem('zebra',zebraOn?'1':'0') }catch(e){}
        zb.classList.toggle('on',zebraOn); zc.hidden=!zebraOn; zg.clearRect(0,0,AW,AH) };
    }
    document.body.classList.toggle('pv',previewOn);
    // Groups: side by side when the page has the room, else one at a time under tabs.
    let group='gCamera'; try{ group=localStorage.getItem('group')||group }catch(e){}
    if(!$(group)) group='gCamera';
    function showGroup(){
      document.querySelectorAll('.group').forEach(g=>g.classList.toggle('on',g.id===group));
      document.querySelectorAll('#tabs button').forEach(b=>b.classList.toggle('on',b.dataset.g===group));
    }
    $('tabs').onclick=e=>{ const b=e.target.closest('button'); if(!b) return; group=b.dataset.g; try{ localStorage.setItem('group',group) }catch(e){} showGroup() };
    const layout=()=>document.body.classList.toggle('tabs',previewOn||window.innerWidth<1000);
    addEventListener('resize',layout); layout(); showGroup();

    // Reads the MJPEG stream with fetch: no copying of the whole buffer per chunk, JPEG decoded
    // off the main thread (createImageBitmap), only the newest frame drawn. No frame for 2 s → reconnect.
    function play(cv){
      const g=cv.getContext('2d',{alpha:false,desynchronized:true});
      let ctl=null, last=0, pending=null, decoding=false, shown=0;
      setInterval(()=>{ const o=document.getElementById('pvOut'); if(o) o.textContent=shown; shown=0 },1000);
      function show(blob){
        if(decoding){ pending=blob; return }       // keep only the newest frame
        decoding=true;
        createImageBitmap(blob).then(bm=>{
          if(cv.width!==bm.width||cv.height!==bm.height){ cv.width=bm.width; cv.height=bm.height }
          g.drawImage(bm,0,0); if(window.onPreviewFrame) window.onPreviewFrame(bm); bm.close(); shown++;
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
          const r=await fetch('/video?'+(cv.dataset.preview?'preview=1&':'')+'t='+Date.now(),{signal:ctl.signal,cache:'no-store'});
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
