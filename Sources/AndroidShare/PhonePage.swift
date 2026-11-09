import Foundation

/// The web app served to the phone. Plain HTML/JS so it works in any Android browser
/// (Chrome, Mi Browser, Huawei Browser, vivo/OPPO browsers…) with nothing installed.
enum PhonePage {
    static let manifest = #"""
    {
      "id": "/",
      "name": "Android Share",
      "short_name": "Android Share",
      "description": "Send photos and files between your phone and Mac over Wi-Fi.",
      "start_url": "/",
      "scope": "/",
      "display": "standalone",
      "orientation": "portrait",
      "background_color": "#0b0c0f",
      "theme_color": "#0b0c0f",
      "icons": [
        {"src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any"},
        {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"}
      ],
      "share_target": {
        "action": "/share-target",
        "method": "POST",
        "enctype": "multipart/form-data",
        "params": {"files": [{"name": "files", "accept": ["*/*"]}]}
      }
    }
    """#

    /// Only active when the page is a secure context (see notes on the Mac). Lets the installed
    /// app appear in Android's Share menu: shared files are handed to the page, which uploads them.
    static let serviceWorker = #"""
    let shared = [];
    self.addEventListener('install', () => self.skipWaiting());
    self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
    self.addEventListener('fetch', e => {
      const url = new URL(e.request.url);
      if (e.request.method === 'POST' && url.pathname === '/share-target') {
        e.respondWith((async () => {
          const data = await e.request.formData();
          shared = data.getAll('files');
          return Response.redirect('/?shared=1', 303);
        })());
      }
    });
    self.addEventListener('message', e => {
      if (e.data === 'get-shared') {
        e.source.postMessage({type: 'shared', files: shared});
        shared = [];
      }
    });
    """#

    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="color-scheme" content="light dark">
    <meta name="theme-color" content="#f4f5f7" media="(prefers-color-scheme: light)">
    <meta name="theme-color" content="#0b0c0f" media="(prefers-color-scheme: dark)">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="application-name" content="Android Share">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="icon" href="/icon-192.png">
    <link rel="apple-touch-icon" href="/icon-192.png">
    <title>Android Share</title>
    <style>
    :root{
      --bg:#f4f5f7;--card:#fff;--raised:#f0f1f4;--text:#101114;--sub:#6b7079;--faint:#9aa0a9;
      --line:#e7e8ec;--accent:#2563eb;--accent-2:#1d4ed8;--accent-soft:rgba(37,99,235,.10);
      --ok:#15803d;--ok-soft:rgba(21,128,61,.12);--err:#dc2626;--err-soft:rgba(220,38,38,.10);
      --shadow:0 1px 2px rgba(16,17,20,.05),0 4px 16px rgba(16,17,20,.05);
    }
    @media (prefers-color-scheme:dark){:root{
      --bg:#0b0c0f;--card:#16181d;--raised:#1e2128;--text:#f2f3f5;--sub:#9ca1ab;--faint:#6c717b;
      --line:#24272e;--accent:#3b82f6;--accent-2:#60a5fa;--accent-soft:rgba(59,130,246,.16);
      --ok:#22c55e;--ok-soft:rgba(34,197,94,.14);--err:#f87171;--err-soft:rgba(248,113,113,.14);
      --shadow:none;
    }}
    *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
    html{background:var(--bg)}
    body{margin:0 auto;max-width:560px;min-height:100vh;color:var(--text);background:var(--bg);
      font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans","PingFang SC","Microsoft YaHei",sans-serif;
      padding:max(env(safe-area-inset-top),12px) 16px calc(env(safe-area-inset-bottom) + 32px)}
    button{font:inherit;color:inherit;border:0;background:none;cursor:pointer;padding:0}
    svg{display:block;flex:none}
    [hidden]{display:none!important}

    /* Header */
    .top{display:flex;align-items:center;gap:12px;padding:8px 2px 18px}
    .top img{width:42px;height:42px;border-radius:11px;flex:none;box-shadow:var(--shadow)}
    .top .who{min-width:0;flex:1}
    .top h1{margin:0;font-size:18px;font-weight:650;letter-spacing:-.01em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .pill{display:inline-flex;align-items:center;gap:6px;font-size:12.5px;font-weight:500;color:var(--sub);margin-top:1px}
    .pill i{width:7px;height:7px;border-radius:50%;background:var(--faint)}
    .pill.on i{background:var(--ok);box-shadow:0 0 0 3px var(--ok-soft)}
    .pill.off{color:var(--err)} .pill.off i{background:var(--err)}

    /* Cards */
    .card{background:var(--card);border-radius:20px;box-shadow:var(--shadow);margin-bottom:14px;overflow:hidden}
    .hero{padding:22px 18px 18px;background:
      radial-gradient(120% 90% at 100% 0%,var(--accent-soft),transparent 60%),var(--card)}
    .hero h2{margin:0 0 4px;font-size:22px;font-weight:700;letter-spacing:-.02em}
    .hero p{margin:0 0 18px;color:var(--sub);font-size:14px}
    .actions{display:grid;grid-template-columns:1fr 1fr;gap:10px}
    .btn{display:flex;align-items:center;justify-content:center;gap:8px;height:52px;border-radius:14px;font-weight:600;font-size:15px;transition:transform .12s,opacity .12s}
    .btn:active{transform:scale(.97)}
    .btn.primary{background:var(--accent);color:#fff}
    .btn.secondary{background:var(--raised);color:var(--text)}

    .sec-head{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:16px 18px 10px}
    .sec-head h3{margin:0;font-size:15px;font-weight:650}
    .sec-head .meta{color:var(--sub);font-size:13px;margin-top:1px}
    .link{color:var(--accent);font-weight:600;font-size:14px;padding:6px 2px}
    .overall{height:4px;margin:0 18px 6px;border-radius:2px;background:var(--raised);overflow:hidden}
    .overall b{display:block;height:100%;width:0;background:var(--accent);border-radius:2px;transition:width .25s}

    /* Sending list */
    .item{display:flex;align-items:center;gap:12px;padding:10px 18px}
    .item+.item{border-top:1px solid var(--line)}
    .thumb{width:52px;height:52px;border-radius:12px;background:var(--raised);flex:none;overflow:hidden;position:relative;display:flex;align-items:center;justify-content:center}
    .thumb img,.thumb video{width:100%;height:100%;object-fit:cover;display:block}
    .ext{font-size:10.5px;font-weight:700;letter-spacing:.03em;color:var(--sub);text-transform:uppercase;max-width:46px;overflow:hidden;text-overflow:ellipsis}
    .thumb .play{position:absolute;inset:auto auto 4px 4px;width:18px;height:18px;border-radius:50%;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center}
    .info{flex:1;min-width:0}
    .name{font-size:14.5px;font-weight:550;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .sub{font-size:12.5px;color:var(--sub);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .bar{height:4px;border-radius:2px;background:var(--raised);margin-top:7px;overflow:hidden}
    .bar b{display:block;height:100%;width:0;background:var(--accent);border-radius:2px;transition:width .2s}
    .state{width:30px;height:30px;border-radius:50%;flex:none;display:flex;align-items:center;justify-content:center}
    .item.done .state{background:var(--ok-soft);color:var(--ok)}
    .item.fail .state{background:var(--err-soft);color:var(--err)}
    .item.done .bar,.item.fail .bar{display:none}
    .item.done .sub{color:var(--ok)} .item.fail .sub{color:var(--err)}
    .spin{width:18px;height:18px;border-radius:50%;border:2.5px solid var(--raised);border-top-color:var(--accent);animation:spin .8s linear infinite}
    @keyframes spin{to{transform:rotate(360deg)}}

    /* From Mac grid */
    .grid{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;padding:0 12px 14px}
    .tile{position:relative;border-radius:14px;background:var(--raised);overflow:hidden;text-decoration:none;color:inherit;display:block}
    .tile .pic{aspect-ratio:1;display:flex;align-items:center;justify-content:center;background:var(--raised)}
    .tile .pic img{width:100%;height:100%;object-fit:cover}
    .tile .pic .ext{font-size:15px;max-width:80%}
    .tile .cap{padding:8px 10px 10px;background:var(--card);border:1px solid var(--raised);border-top:0;border-radius:0 0 14px 14px}
    .tile .name{font-size:13px}
    .tile .sub{font-size:12px;margin-top:0}
    .tile .dl{position:absolute;top:8px;right:8px;width:32px;height:32px;border-radius:50%;background:rgba(0,0,0,.55);color:#fff;display:flex;align-items:center;justify-content:center;backdrop-filter:blur(6px)}
    .empty{display:flex;flex-direction:column;align-items:center;text-align:center;gap:8px;padding:8px 24px 24px;color:var(--sub);font-size:13.5px}
    .empty .ic{width:44px;height:44px;border-radius:12px;background:var(--raised);display:flex;align-items:center;justify-content:center;color:var(--faint)}

    /* Install card */
    .install{display:flex;gap:12px;align-items:flex-start;padding:16px 16px 16px 18px}
    .install .ic{width:38px;height:38px;border-radius:10px;background:var(--accent-soft);color:var(--accent);display:flex;align-items:center;justify-content:center;flex:none}
    .install h4{margin:0 0 2px;font-size:14.5px;font-weight:650}
    .install p{margin:0;color:var(--sub);font-size:13px}
    .install .go{margin-top:10px;height:36px;padding:0 14px;border-radius:10px;background:var(--accent);color:#fff;font-weight:600;font-size:13.5px}
    .x{margin-left:auto;color:var(--faint);padding:4px}

    /* Banner, toast, unpaired */
    .tip{padding:12px 14px;margin:-2px 0 14px;border-radius:14px;background:rgba(234,179,8,.13);color:var(--text);font-size:13.5px;line-height:1.45}
    .tip b{font-weight:650}
    .banner{display:flex;gap:10px;align-items:center;padding:12px 14px;margin-bottom:14px;border-radius:14px;background:var(--err-soft);color:var(--err);font-size:13.5px;font-weight:500}
    .toast{position:fixed;left:50%;bottom:calc(env(safe-area-inset-bottom) + 20px);transform:translate(-50%,20px);opacity:0;
      background:#111317;color:#fff;padding:11px 16px;border-radius:14px;font-size:14px;font-weight:500;display:flex;gap:8px;align-items:center;
      box-shadow:0 8px 30px rgba(0,0,0,.25);transition:all .25s;pointer-events:none;max-width:calc(100% - 32px)}
    .toast.show{opacity:1;transform:translate(-50%,0)}
    .center{padding:36px 24px 32px;text-align:center}
    .center .ic{width:56px;height:56px;margin:0 auto 14px;border-radius:16px;background:var(--accent-soft);color:var(--accent);display:flex;align-items:center;justify-content:center}
    .center h2{margin:0 0 6px;font-size:19px;font-weight:700}
    .center p{margin:0;color:var(--sub);font-size:14px}
    </style>
    </head>
    <body>

    <svg width="0" height="0" style="position:absolute">
      <symbol id="i-photo" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="9" cy="9" r="2"/><path d="m21 15-4.5-4.5L6 21"/></symbol>
      <symbol id="i-file" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/></symbol>
      <symbol id="i-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5 10 17 19 7"/></symbol>
      <symbol id="i-retry" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/></symbol>
      <symbol id="i-down" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v12M6 11l6 6 6-6M5 20h14"/></symbol>
      <symbol id="i-laptop" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="11" rx="2"/><path d="M2 19h20"/></symbol>
      <symbol id="i-home" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2" width="12" height="20" rx="3"/><path d="M11 18h2"/></symbol>
      <symbol id="i-x" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></symbol>
      <symbol id="i-qr" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3M21 14v.01M14 21h7v-4"/></symbol>
      <symbol id="i-wifi" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 2l20 20M8.5 16.5a5 5 0 0 1 7 0M5 13a10 10 0 0 1 5.2-2.8M19 13a10 10 0 0 0-2.3-1.7M2 8.8a15 15 0 0 1 4.2-2.7M22 8.8A15 15 0 0 0 10.7 5M12 20h.01"/></symbol>
      <symbol id="i-play" viewBox="0 0 24 24" fill="#fff"><path d="M8 5v14l11-7z"/></symbol>
    </svg>

    <header class="top">
      <img src="/icon-192.png" alt="">
      <div class="who">
        <h1 id="mac">Android Share</h1>
        <div class="pill" id="pill"><i></i><span id="pillText">Connecting…</span></div>
      </div>
    </header>

    <div class="banner" id="offline" hidden><svg width="18" height="18"><use href="#i-wifi"/></svg><span>Can't reach your Mac. Make sure Android Share is open and you're on the same Wi-Fi.</span></div>

    <main id="app" hidden>
      <section class="card hero">
        <h2>Send to Mac</h2>
        <p id="dest">Files are saved on your Mac.</p>
        <div class="actions">
          <button class="btn primary" id="pickPhotos"><svg width="20" height="20"><use href="#i-photo"/></svg>Photos</button>
          <button class="btn secondary" id="pickFiles"><svg width="20" height="20"><use href="#i-file"/></svg>Files</button>
        </div>
        <input type="file" id="photos" accept="image/*,video/*" multiple hidden>
        <input type="file" id="files" multiple hidden>
      </section>

      <div class="tip" id="bigTip" hidden>
        <b>Big files?</b> Wi-Fi works, but for long videos and anything over about 1 GB a <b>USB cable</b> is usually 3–10× faster. Keep this page open and the screen on until it's done.
      </div>

      <section class="card" id="sendCard" hidden>
        <div class="sec-head">
          <div><h3>Sending</h3><div class="meta" id="summary"></div></div>
          <button class="link" id="clearSent">Clear</button>
        </div>
        <div class="overall"><b id="overallBar"></b></div>
        <div id="sendList"></div>
      </section>

      <section class="card">
        <div class="sec-head"><div><h3>From Mac</h3><div class="meta" id="inboxMeta">Files your Mac shares with you</div></div></div>
        <div id="inbox"></div>
      </section>

      <section class="card install" id="installCard" hidden>
        <div class="ic"><svg width="20" height="20"><use href="#i-home"/></svg></div>
        <div>
          <h4>Add to Home screen</h4>
          <p id="installText">Open the browser menu <b>⋮</b> and tap <b>Add to Home screen</b>. Next time, just tap the icon.</p>
          <button class="go" id="installBtn" hidden>Install app</button>
        </div>
        <button class="x" id="installX" aria-label="Dismiss"><svg width="16" height="16"><use href="#i-x"/></svg></button>
      </section>
    </main>

    <section class="card center" id="unpaired" hidden>
      <div class="ic"><svg width="26" height="26"><use href="#i-qr"/></svg></div>
      <h2>Pair this phone</h2>
      <p>On your Mac, open <b>Android Share → Quick Share &amp; Wi-Fi</b> and scan the QR code with this phone's camera.</p>
    </section>

    <div class="toast" id="toast"><svg width="18" height="18" style="color:#4ade80"><use href="#i-check"/></svg><span id="toastText"></span></div>

    <script>
    (function(){
      var $ = function(id){ return document.getElementById(id); };
      function el(tag, cls, text){ var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
      function icon(id, size){ var s = document.createElementNS('http://www.w3.org/2000/svg','svg'); s.setAttribute('width', size); s.setAttribute('height', size);
        var u = document.createElementNS('http://www.w3.org/2000/svg','use'); u.setAttribute('href', '#' + id); s.appendChild(u); return s; }
      function fmt(b){ if (b < 1024) return b + ' B'; var u = ['KB','MB','GB','TB'], i = -1; do { b /= 1024; i++; } while (b >= 1024 && i < 3);
        return (b >= 100 ? b.toFixed(0) : b.toFixed(1)) + ' ' + u[i]; }
      function ext(name){ var m = /\.([a-z0-9]{1,5})$/i.exec(name || ''); return m ? m[1] : 'file'; }
      function store(k, v){ try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } }

      // ---- Pairing key: arrives once in the QR link (#k=…), then lives in this browser ----
      var key = null, m = location.hash.match(/k=([A-Za-z0-9]+)/);
      if (m) store('androidshare-key', m[1]);
      key = store('androidshare-key') || store('droidbridge-key') || (m && m[1]);   // old name kept so paired phones stay paired
      if (location.hash || location.search) history.replaceState(null, '', '/' + (location.search.indexOf('shared=1') >= 0 ? '?shared=1' : ''));

      var toastTimer;
      function toast(msg){ $('toastText').textContent = msg; $('toast').classList.add('show');
        clearTimeout(toastTimer); toastTimer = setTimeout(function(){ $('toast').classList.remove('show'); }, 2600); }

      // ---- Connection state ----
      var paired = false, failures = 0, macName = 'your Mac';
      function setPill(state, text){ $('pill').className = 'pill ' + state; $('pillText').textContent = text; }
      function showUnpaired(){ paired = false; $('app').hidden = true; $('unpaired').hidden = false; $('offline').hidden = true; setPill('off', 'Not paired'); }

      var outboxSig = '';
      function renderInbox(list){
        var sig = JSON.stringify(list); if (sig === outboxSig) return; outboxSig = sig;
        var box = $('inbox'); box.innerHTML = '';
        $('inboxMeta').textContent = list.length ? list.length + (list.length === 1 ? ' file ready' : ' files ready') : 'Files your Mac shares with you';
        if (!list.length){
          var e = el('div', 'empty'); var ic = el('div', 'ic'); ic.appendChild(icon('i-laptop', 22)); e.appendChild(ic);
          e.appendChild(el('div', null, 'Drag files onto the Wi-Fi page in Android Share on your Mac and they appear here.'));
          box.appendChild(e); return;
        }
        var grid = el('div', 'grid');
        list.forEach(function(f){
          var a = el('a', 'tile');
          a.href = '/api/file/' + encodeURIComponent(f.id) + '?k=' + encodeURIComponent(key);
          a.setAttribute('download', f.name);
          var pic = el('div', 'pic');
          if (f.thumb){ var img = el('img'); img.loading = 'lazy'; img.alt = '';
            img.src = '/api/thumb/' + encodeURIComponent(f.id) + '?k=' + encodeURIComponent(key); pic.appendChild(img); }
          else pic.appendChild(el('span', 'ext', ext(f.name)));
          var dl = el('span', 'dl'); dl.appendChild(icon('i-down', 16));
          var cap = el('div', 'cap'); cap.appendChild(el('div', 'name', f.name)); cap.appendChild(el('div', 'sub', fmt(f.size)));
          a.appendChild(pic); a.appendChild(dl); a.appendChild(cap);
          a.addEventListener('click', function(){ toast('Downloading ' + f.name); });
          grid.appendChild(a);
        });
        box.appendChild(grid);
      }

      function poll(){
        if (!key) { showUnpaired(); return; }
        var x = new XMLHttpRequest();
        x.open('GET', '/api/info'); x.setRequestHeader('X-AndroidShare-Key', key); x.timeout = 5000;
        x.onload = function(){
          if (x.status === 401) { showUnpaired(); return; }
          if (x.status !== 200) return;
          var info = JSON.parse(x.responseText);
          paired = true; failures = 0; macName = info.name;
          $('unpaired').hidden = true; $('app').hidden = false; $('offline').hidden = true;
          $('mac').textContent = info.name; document.title = 'Android Share · ' + info.name;
          $('dest').textContent = 'Saved to ' + (info.folder || 'Downloads') + ' on ' + info.name + '.';
          setPill('on', 'Connected');
          renderInbox(info.outbox || []);
        };
        x.onerror = x.ontimeout = function(){
          failures++;
          if (failures >= 2) { $('offline').hidden = false; setPill('off', 'Offline'); }
          if (!paired && key) $('app').hidden = false;
        };
        x.send();
      }

      // ---- Sending ----
      var items = [], queue = [], busy = false;
      function thumbFor(f){
        var t = el('div', 'thumb'), type = f.type || '';
        if (type.indexOf('image/') === 0) {
          var img = el('img'); img.alt = ''; img.src = URL.createObjectURL(f); t.appendChild(img);
        } else if (type.indexOf('video/') === 0) {
          var v = el('video'); v.muted = true; v.preload = 'metadata'; v.playsInline = true; v.src = URL.createObjectURL(f) + '#t=0.1'; t.appendChild(v);
          var p = el('span', 'play'); p.appendChild(icon('i-play', 10)); t.appendChild(p);
        } else t.appendChild(el('span', 'ext', ext(f.name)));
        return t;
      }
      function setState(it, s, text){
        it.status = s; it.row.className = 'item ' + (s === 'done' ? 'done' : s === 'fail' ? 'fail' : '');
        it.sub.textContent = text; it.state.innerHTML = '';
        if (s === 'done') it.state.appendChild(icon('i-check', 16));
        else if (s === 'fail') { var b = el('button'); b.setAttribute('aria-label', 'Retry'); b.appendChild(icon('i-retry', 16));
          b.onclick = function(){ setState(it, 'wait', 'Waiting · ' + fmt(it.file.size)); it.fill.style.width = '0'; queue.push(it); next(); };
          it.state.appendChild(b); }
        else if (s === 'send') it.state.appendChild(el('div', 'spin'));
        summary();
      }
      function summary(){
        var total = items.length, done = 0, failed = 0, bytes = 0, sent = 0;
        items.forEach(function(it){ bytes += it.file.size; sent += it.status === 'done' ? it.file.size : (it.loaded || 0);
          if (it.status === 'done') done++; if (it.status === 'fail') failed++; });
        var s = done + ' of ' + total + ' sent';
        if (failed) s += ' · ' + failed + ' failed';
        if (busy) s += ' · keep this page open';
        $('summary').textContent = s;
        $('overallBar').style.width = (bytes ? Math.round(sent / bytes * 100) : 0) + '%';
        $('sendCard').hidden = total === 0;
      }
      function addFiles(list){
        var files = Array.prototype.slice.call(list || []); if (!files.length) return;
        var picked = files.reduce(function(s, f){ return s + f.size; }, 0);
        if (picked >= 1e9 || files.some(function(f){ return f.size >= 5e8; })) $('bigTip').hidden = false;
        files.forEach(function(f){
          var row = el('div', 'item'), info = el('div', 'info'), bar = el('div', 'bar'), fill = el('b'), state = el('div', 'state');
          var sub = el('div', 'sub');
          bar.appendChild(fill); info.appendChild(el('div', 'name', f.name)); info.appendChild(sub); info.appendChild(bar);
          row.appendChild(thumbFor(f)); row.appendChild(info); row.appendChild(state);
          $('sendList').insertBefore(row, $('sendList').firstChild);
          var it = {file: f, row: row, fill: fill, sub: sub, state: state, loaded: 0};
          items.push(it); queue.push(it);
          setState(it, 'wait', 'Waiting · ' + fmt(f.size));
        });
        next();
      }
      function next(){
        if (busy) return;
        var it = queue.shift();
        if (!it) { summary(); return; }
        busy = true;
        var f = it.file, started = Date.now();
        setState(it, 'send', 'Starting…');
        var x = new XMLHttpRequest();
        x.open('POST', '/api/upload?name=' + encodeURIComponent(f.name) + '&size=' + f.size + '&mtime=' + (f.lastModified || 0));
        x.setRequestHeader('X-AndroidShare-Key', key);
        x.setRequestHeader('Content-Type', 'application/octet-stream');
        x.upload.onprogress = function(e){
          var t = e.lengthComputable ? e.total : f.size; it.loaded = e.loaded;
          it.fill.style.width = (t ? Math.round(e.loaded / t * 100) : 0) + '%';
          var secs = (Date.now() - started) / 1000;
          it.sub.textContent = fmt(e.loaded) + ' of ' + fmt(t) + (secs > .5 ? ' · ' + fmt(e.loaded / secs) + '/s' : '');
          summary();
        };
        function end(ok, msg){
          busy = false; setState(it, ok ? 'done' : 'fail', msg);
          if (!queue.length) {
            var done = items.filter(function(i){ return i.status === 'done'; }).length;
            if (ok) toast(done === 1 ? 'Sent to ' + macName : done + ' files sent to ' + macName);
          }
          next();
        }
        x.onload = function(){
          if (x.status === 200) {
            var r = {}; try { r = JSON.parse(x.responseText); } catch (e) {}
            end(true, r.name && r.name !== f.name ? 'Saved as ' + r.name : 'Saved on Mac · ' + fmt(f.size));
          } else if (x.status === 401) { end(false, 'Not paired. Scan the QR code again'); showUnpaired(); }
          else { var err = ''; try { err = JSON.parse(x.responseText).error; } catch (e) {} end(false, err || 'Failed. Tap to retry'); }
        };
        x.onerror = function(){ end(false, 'Connection lost. Tap to retry'); };
        x.send(f);
      }

      $('pickPhotos').onclick = function(){ $('photos').click(); };
      $('pickFiles').onclick = function(){ $('files').click(); };
      $('photos').onchange = $('files').onchange = function(){ addFiles(this.files); this.value = ''; };
      $('clearSent').onclick = function(){
        items = items.filter(function(it){ if (it.status === 'done' || it.status === 'fail') { it.row.remove(); return false; } return true; });
        summary();
      };
      window.addEventListener('beforeunload', function(e){ if (busy) { e.preventDefault(); e.returnValue = ''; } });

      // ---- Install as an app ----
      var standalone = window.matchMedia && window.matchMedia('(display-mode: standalone)').matches;
      var deferred = null;
      if (!standalone && store('androidshare-install-dismissed') !== '1') $('installCard').hidden = false;
      window.addEventListener('beforeinstallprompt', function(e){
        e.preventDefault(); deferred = e;
        $('installBtn').hidden = false;
        $('installText').textContent = 'Get Android Share as an app on your Home screen. It also shows up in the Share menu.';
        $('installCard').hidden = false;
      });
      $('installBtn').onclick = function(){ if (deferred) { deferred.prompt(); deferred = null; } };
      $('installX').onclick = function(){ $('installCard').hidden = true; store('androidshare-install-dismissed', '1'); };
      window.addEventListener('appinstalled', function(){ $('installCard').hidden = true; toast('Android Share installed'); });

      if (window.isSecureContext && 'serviceWorker' in navigator) {
        navigator.serviceWorker.register('/sw.js').catch(function(){});
        navigator.serviceWorker.addEventListener('message', function(e){
          if (e.data && e.data.type === 'shared' && e.data.files && e.data.files.length) addFiles(e.data.files);
        });
        if (location.search.indexOf('shared=1') >= 0) navigator.serviceWorker.ready.then(function(r){
          (navigator.serviceWorker.controller || r.active).postMessage('get-shared'); history.replaceState(null, '', '/');
        });
      }

      summary();
      poll();
      setInterval(poll, 3000);
      document.addEventListener('visibilitychange', function(){ if (!document.hidden) poll(); });
    })();
    </script>
    </body>
    </html>
    """#
}
