#!/usr/bin/env python3
"""
webdesktop.py - a tiny browser-based remote desktop for a macOS CI runner.

Why not Apple's own VNC?
------------------------
macOS refuses to hand a screen framebuffer to Apple Remote Management on a
CI runner. tccd says it outright:

    Platform binary prompting is 'Deny' because: is Platform Binary

ARD's daemons are Apple platform binaries, and platform binaries cannot be
granted Screen Recording through the TCC database - they need a real MDM
enrolment. So the daemon listens on 5900, authenticates, and then serves a
black framebuffer.

What works instead
------------------
/usr/sbin/screencapture CAN capture the display (the runner image already
pre-grants Full Disk Access to /bin/bash), and /usr/bin/osascript already
has Accessibility pre-granted. Both are proven on a live runner: the menu bar
renders at 98.9% non-black and the dock at 57.8%.

So this server does the obvious thing: poll screencapture for frames and turn
HTTP requests into synthetic input events. Input goes through `cliclick` for
the mouse and `osascript`/System Events for the keyboard.

It MUST be started inside the console user's GUI session, e.g.

    launchctl asuser $(stat -f %u /dev/console) sudo -u $(stat -f %Su /dev/console) \
        python3 webdesktop.py
"""

import http.server
import json
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse

PORT = int(os.environ.get("WEB_DESKTOP_PORT", "6080"))
FRAMEDIR = "/tmp/webdesktop"
FRAME = os.path.join(FRAMEDIR, "frame.jpg")
TOKEN = os.environ.get("WEB_DESKTOP_TOKEN") or secrets.token_urlsafe(16)
INTERVAL = float(os.environ.get("WEB_DESKTOP_INTERVAL", "0.2"))
WIDTH, HEIGHT = 1024, 768

os.makedirs(FRAMEDIR, exist_ok=True)


def log(*a):
    print("[webdesktop]", *a, flush=True)


def sh(cmd, timeout=10):
    """Run a command, swallow errors - input injection must never crash us."""
    try:
        subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True,
                       timeout=timeout, check=False)
    except Exception as e:  # noqa: BLE001
        log("cmd failed:", cmd, e)


# --------------------------------------------------------------------------
# capture loop
# --------------------------------------------------------------------------
# Flag sets to try, most-preferred first. Only "-x" has been proven on a live
# runner; the others are progressively plainer fallbacks so a bad flag on some
# future macOS degrades performance instead of killing the feature.
CAPTURE_CMDS = (
    ["/usr/sbin/screencapture", "-x", "-C", "-t", "jpg"],
    ["/usr/sbin/screencapture", "-x", "-t", "jpg"],
    ["/usr/sbin/screencapture", "-x", "-t", "png"],
)


def capture_loop():
    """Keep FRAME updated. Runs forever; the process dies with the job."""
    which = 0
    n = 0
    last_err = ""
    while True:
        ext = "png" if which == 2 else "jpg"
        tmp = os.path.join(FRAMEDIR, f"frame.{ext}")
        cmd = CAPTURE_CMDS[which] + [tmp]
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=20, check=False)
        except Exception as e:  # noqa: BLE001
            last_err = f"{type(e).__name__}: {e}"
            time.sleep(1)
            continue

        if r.returncode == 0 and os.path.exists(tmp) and os.path.getsize(tmp) > 0:
            if which != 0:
                log(f"capture working with cmd[{which}] = {' '.join(cmd)}")
            if which == 2:
                # PNG -> JPEG for a smaller poll response
                try:
                    subprocess.run(
                        ["/usr/bin/sips", "-s", "format", "jpeg", tmp,
                         "--out", FRAME + ".tmp"],
                        capture_output=True, timeout=15, check=False)
                    if os.path.exists(FRAME + ".tmp") and os.path.getsize(FRAME + ".tmp") > 0:
                        os.replace(FRAME + ".tmp", FRAME)
                        n += 1
                except Exception as e:  # noqa: BLE001
                    log("sips failed:", e)
            else:
                os.replace(tmp, FRAME)
                n += 1
            if n == 1:
                log(f"first frame captured ({os.path.getsize(FRAME)} bytes)")
            # No artificial sleep: screencapture's own runtime (~150-250ms) is
            # the natural frame pacing, and sleeping on top of it halved the rate.
            continue

        # failed - remember why, then fall back to a plainer invocation
        last_err = f"rc={r.returncode} err={r.stderr.decode('utf8', 'replace')[:200]}"
        log(f"capture cmd[{which}] failed: {last_err}")
        which = (which + 1) % len(CAPTURE_CMDS)
        time.sleep(0.5)


# --------------------------------------------------------------------------
# input injection
# --------------------------------------------------------------------------
# Maps a browser KeyboardEvent.key -> System Events `key code`.
KEYCODES = {
    "Enter": 36, "Return": 36, "Tab": 48, "Escape": 53, "Backspace": 51,
    "Delete": 117, "ArrowLeft": 123, "ArrowUp": 126, "ArrowRight": 124,
    "ArrowDown": 125, "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121,
    " ": 49, "Space": 49,
}
# Keys that need a modifier held down alongside the code.
MODIFIER_KEYCODES = {
    "ArrowLeft": 1, "ArrowUp": 2, "ArrowRight": 3, "ArrowDown": 4,
    "Home": 6, "End": 7, "PageUp": 5, "PageDown": 8,
}


def click(x, y, button=0, clicks=1):
    # coordinates arrive 0..1 from the browser, scale to the real display
    px = int(x * WIDTH)
    py = int(y * HEIGHT)
    kind = {0: "c", 1: "rc", 2: "tc"}.get(button, "c")
    cmd = f"/opt/homebrew/bin/cliclick {kind}:{px},{py}"
    for _ in range(clicks - 1):
        sh(cmd, timeout=3)
    sh(cmd, timeout=3)


def move(x, y):
    sh(f"/opt/homebrew/bin/cliclick m:{int(x * WIDTH)},{int(y * HEIGHT)}", timeout=3)


def drag(x1, y1, x2, y2):
    a = f"{int(x1 * WIDTH)},{int(y1 * HEIGHT)}"
    b = f"{int(x2 * WIDTH)},{int(y2 * HEIGHT)}"
    sh(f"/opt/homebrew/bin/cliclick dd:{a} m:{b} du:{b}", timeout=8)


def scroll(x, y, dy):
    px, py = int(x * WIDTH), int(y * HEIGHT)
    steps = max(1, min(20, abs(dy)))
    sign = "-" if dy < 0 else ""
    sh(f"/opt/homebrew/bin/cliclick {sign}{steps}:{px},{py}", timeout=5)


def key(k):
    """Send one key press."""
    if k in KEYCODES:
        code = KEYCODES[k]
        if k in MODIFIER_KEYCODES:
            mod = MODIFIER_KEYCODES[k]
            sh(f'osascript -e \'tell application "System Events" to key code {code} using {{{mod}}}\'',
               timeout=5)
        else:
            sh(f'osascript -e \'tell application "System Events" to key code {code}\'', timeout=5)
        return

    # modifier + ordinary key, e.g. Cmd+Shift+A
    combo = None
    if k.startswith("Mod+"):
        combo, k = "command down", k[4:]
    elif k.startswith("Shift+"):
        combo, k = "shift down", k[6:]
    elif k.startswith("Alt+"):
        combo, k = "option down", k[4:]

    esc = k.replace("\\", "\\\\").replace('"', '\\"')
    if combo:
        sh(f'osascript -e \'tell application "System Events" to keystroke "{esc}" using {{{combo}}}\'',
           timeout=5)
    elif len(k) == 1:
        sh(f'osascript -e \'tell application "System Events" to keystroke "{esc}"\'', timeout=5)
    else:
        log("unmapped key:", k)


def handle_input(qs):
    t = qs.get("type", [""])[0]
    f = lambda n, d=0.0: float(qs.get(n, [d])[0])  # noqa: E731
    i = lambda n, d=0: int(qs.get(n, [d])[0])      # noqa: E731

    if t == "move":
        move(f("x"), f("y"))
    elif t == "click":
        click(f("x"), f("y"), i("button", 0), i("clicks", 1))
    elif t == "drag":
        drag(f("x1"), f("y1"), f("x2"), f("y2"))
    elif t == "scroll":
        scroll(f("x"), f("y"), f("dy"))
    elif t == "key":
        key(qs.get("k", [""])[0])
    return {"ok": True}


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
PAGE = """<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>macOS CI Desktop</title>
<style>
  html,body{margin:0;background:#111;color:#eee;font:13px -apple-system,sans-serif;
            height:100%;overflow:hidden}
  #wrap{position:relative;width:100vw;height:100vh;display:flex;
        align-items:center;justify-content:center}
  #screen{image-rendering:pixelated;max-width:100vw;max-height:100vh;cursor:crosshair}
  #bar{position:fixed;top:0;left:0;right:0;background:#000c;padding:5px 10px;
       display:flex;gap:14px;align-items:center;z-index:9}
  .k{padding:2px 7px;border:1px solid #555;border-radius:4px;cursor:pointer;
     background:#222}
  .k:hover{background:#333}
  #fps{margin-left:auto;color:#8f8;font-family:monospace}
</style></head><body>
<div id="bar">
  <span class="k" data-send="key:Escape">Esc</span>
  <span class="k" data-send="key:Tab">Tab</span>
  <span class="k" data-send="key:Enter">Enter</span>
  <span class="k" data-send="key:Backspace">Bksp</span>
  <span class="k" data-send="key:ArrowUp">&#9650;</span>
  <span class="k" data-send="key:ArrowDown">&#9660;</span>
  <span class="k" data-send="key:ArrowLeft">&#9664;</span>
  <span class="k" data-send="key:ArrowRight">&#9654;</span>
  <span class="k" data-send="key:Mod+Tab">Cmd+Tab</span>
  <span id="fps">--</span>
</div>
<div id="wrap"><img id="screen" alt="macOS desktop"></div>
<script>
const T="__TOKEN__", img=document.getElementById('screen');
const send=p=>fetch('/input?'+p,{method:'POST'});
const rect=()=>img.getBoundingClientRect();
const norm=e=>{const r=rect();return{
  x:((e.clientX-r.left)/r.width).toFixed(4), y:((e.clientY-r.top)/r.height).toFixed(4)};};

img.addEventListener('mousedown',e=>{e.preventDefault();const n=norm(e);
  send(`type=click&x=${n.x}&y=${n.y}&button=${e.button}&clicks=${e.detail}`);});
img.addEventListener('mousemove',e=>{const n=norm(e);
  send(`type=move&x=${n.x}&y=${n.y}`);});
img.addEventListener('contextmenu',e=>e.preventDefault());
img.addEventListener('wheel',e=>{e.preventDefault();const n=norm(e);
  send(`type=scroll&x=${n.x}&y=${n.y}&dy=${e.deltaY>0?-3:3}`);},{passive:false});

window.addEventListener('keydown',e=>{
  e.preventDefault();
  let k=e.key;
  if(e.metaKey)k='Mod+'+k; else if(e.shiftKey&&k.length>1)k='Shift+'+k;
  send('type=key&k='+encodeURIComponent(k));
});
document.querySelectorAll('.k').forEach(el=>el.onclick=()=>{
  const v=el.dataset.send; send('type='+v.split(':')[0]+'&k='+v.split(':')[1]);
});

// The token MUST be on the frame request too - without it the server 403s and
// the <img> silently never paints. `_` is only a cache-buster.
let ok=0,bad=0;
function tick(){
  img.src='/frame.jpg?t='+T+'&_='+Date.now();
}
img.onload=()=>{ok++;bad=0;document.getElementById('fps').textContent=ok+' fps';
                setTimeout(tick,30);};
img.onerror=()=>{bad++;document.getElementById('fps').textContent=
                  'ERROR '+(bad===1?'(check token)':'x'+bad);
                setTimeout(tick,500);};
tick();
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # keep the Actions log readable
        pass

    def _authed(self, qs):
        return qs.get("t", [""])[0] == TOKEN

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(u.query)
        if not self._authed(qs):
            self.send_error(403, "bad token")
            return
        if u.path == "/":
            body = PAGE.replace("__TOKEN__", TOKEN).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif u.path == "/frame.jpg":
            try:
                with open(FRAME, "rb") as fh:
                    body = fh.read()
                code = 200
            except OSError:
                body = b""
                code = 503
            self.send_response(code)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif u.path == "/token":
            body = json.dumps({"token": TOKEN}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(u.query)
        if not self._authed(qs):
            self.send_error(403, "bad token")
            return
        try:
            res = handle_input(qs)
        except Exception as e:  # noqa: BLE001
            res = {"ok": False, "error": str(e)}
        body = json.dumps(res).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    log(f"token={TOKEN}")
    log(f"listening on 127.0.0.1:{PORT}")
    threading.Thread(target=capture_loop, daemon=True).start()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
