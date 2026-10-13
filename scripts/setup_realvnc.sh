#!/usr/bin/env bash
#
# setup_realvnc.sh - install and start RealVNC Server headlessly on a macOS runner.
#
# WHY NOT APPLE'S OWN VNC
# -----------------------
# Apple Remote Management's daemons are Apple *platform binaries*. macOS TCC
# refuses screen-capture grants to platform binaries outside a real MDM
# enrolment:
#
#     tccd: Platform binary prompting is 'Deny' because: is Platform Binary
#
# so ARD listens, authenticates, and then serves a black framebuffer.
#
# RealVNC Server is a third-party binary, so that rule does not apply and a
# TCC.db row IS honoured. On macOS its CaptureMethod=0 path uses
# ScreenCaptureKit, so it also gives real frame rates instead of the ~5fps
# ceiling you get from polling `screencapture`.
#
# Config (per RealVNC's own parameter reference):
#   Authentication = VncAuth  <- "the only scheme that allows direct
#                                 connections from non-RealVNC VNC Viewers"
#                                 i.e. TigerVNC / Remmina
#   RfbPort        = pick a port; ARD already owns 5900
#   CaptureMethod  = 0 (ScreenCaptureKit on macOS 13+)
#
# Password must be written in RealVNC's obfuscated format - generated with the
# bundled `vncpasswd -print`, never by hand.

set -uo pipefail

PW="${1:-FarisMac2026}"
PORT="${2:-5901}"
APP="/Applications/VNC Server.app"

log()  { printf '  %s\n' "$*"; }
warn() { printf '  !! %s\n' "$*" >&2; }

echo "==> Installing RealVNC Server..."
[ -d /Library/vnc ] || { brew install --cask vnc-server 2>&1 | tail -3 || warn "brew install failed"; }

# The cask installs into /Library/vnc, NOT /Applications:
#   /Library/vnc/RealVNC Server.app        -> com.realvnc.vncserverui
#   /Library/vnc/RealVNC Server Agent.app  -> com.realvnc.vncagent  <- does the capture
APP="$(find /Library/vnc /Applications -maxdepth 3 -name 'RealVNC Server.app' 2>/dev/null | head -1)"
[ -d "$APP" ] || { warn "no 'RealVNC Server.app' found"; exit 1; }
log "app: $APP"

find_bin() { find /Library/vnc "$APP" -type f -name "$1" -perm -u+x 2>/dev/null | head -1; }
VNCSERVER="$(find_bin vncserver)"
VNCPASSWD="$(find_bin vncpasswd)"
log "vncserver : ${VNCSERVER:-<not found>}"
log "vncpasswd : ${VNCPASSWD:-<not found>}"

echo "==> Granting Screen Recording / Accessibility to RealVNC..."
EXTRA=""
while IFS= read -r app; do
  bid=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)
  [ -n "$bid" ] && { EXTRA="$EXTRA,${bid}|0"; log "bundle: $bid"; }
done < <(find /Library/vnc -maxdepth 1 -name '*.app' 2>/dev/null)
EXTRA="${EXTRA#,}"
while IFS= read -r exe; do EXTRA="$EXTRA,$exe|1"; done \
  < <(find /Library/vnc "$APP" -type f -perm -u+x 2>/dev/null | head -60)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRA_CLIENTS="$EXTRA" "$SCRIPT_DIR/grant_tcc.sh" 2>&1 \
  | grep -iE 'realvnc|FAILED|complete' | tail -8 || warn "TCC grant problem (continuing)"

sudo pkill -f 'vncagent|vncserverui|vncserver' 2>/dev/null || true
sudo killall tccd 2>/dev/null || true
sleep 1

echo "==> Generating obfuscated VNC password..."
OBF=""
if [ -n "$VNCPASSWD" ]; then
  for attempt in "-print" "-print -service" "-service -print" ""; do
    # shellcheck disable=SC2086
    OBF=$(printf '%s' "$PW" | "$VNCPASSWD" $attempt 2>/dev/null | tr -d '\r\n' || true)
    [ -n "$OBF" ] && { log "vncpasswd $attempt -> $OBF"; break; }
  done
fi
if [ -z "$OBF" ]; then
  warn "vncpasswd gave nothing; classic VNC fixed-key obfuscation"
  OBF=$(printf '%s' "$PW" | perl -we '
    BEGIN { @k = unpack "C*", pack "H*", "23826B06354E5807" }
    $_ = <>; chomp; s/^(.{8}).*/$1/; @p = unpack "C*", $_;
    foreach (@k) { printf "%02X", $_ ^ (shift @p || 0) } print "\n";')
  log "fallback -> $OBF"
fi

echo "==> Writing RealVNC config..."
CU=$(stat -f '%Su' /dev/console)
BODY="Authentication=VncAuth
Password=$OBF
RfbPort=$PORT
CaptureMethod=0
AcceptKeyEvents=1
AcceptPointerEvents=1
AlwaysShared=1
NeverShared=0
DisconnectClients=1
IdleTimeout=0
AuthTimeout=0
BlacklistThreshold=0
AllowIpListenRfb=1
localhost=0
Log=*:stderr:30"

for d in "/var/root/.vnc/config.d" "/Users/$CU/.vnc/config.d" "$HOME/.vnc/config.d"; do
  mkdir -p "$d" 2>/dev/null || continue
  if printf '%s\n' "$BODY" > "$d/vncserver" 2>/dev/null; then
    log "wrote $d/vncserver"; chmod 600 "$d/vncserver" 2>/dev/null
  else
    log "could not write $d/vncserver"
  fi
done

echo "==> Starting RealVNC Server..."
for plist in /Library/LaunchDaemons/com.realvnc.vncserver.plist \
             "/Users/$CU/Library/LaunchAgents/com.realvnc.vncserver.plist"; do
  [ -f "$plist" ] && { sudo launchctl unload "$plist" 2>/dev/null || true
                       sudo launchctl load "$plist" 2>/dev/null && log "loaded $plist"; }
done

if [ -n "$VNCSERVER" ]; then
  sudo "$VNCSERVER" -start >/tmp/rv-start.log 2>&1; log "service start rc=$?"
  sleep 5
fi
if ! sudo lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && [ -n "$VNCSERVER" ]; then
  CUID=$(stat -f '%u' /dev/console)
  sudo launchctl asuser "$CUID" sudo -u "$CU" "$VNCSERVER" -start >/tmp/rv-user.log 2>&1
  log "user-mode start rc=$?"; sleep 5
fi

echo "==> Listeners:"; sudo lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E ':59[0-9][0-9]' || warn "no VNC listener"
echo "==> Processes:"; pgrep -fl -i 'vnc' | head -6 || warn "no vnc process"
echo "==> service log:"; tail -15 /tmp/rv-start.log 2>/dev/null || true
echo "==> user log:";     tail -15 /tmp/rv-user.log  2>/dev/null || true

echo "$PORT" > /tmp/realvnc.port
echo "$OBF"  > /tmp/realvnc.obf
echo "$PW"   > /tmp/realvnc.pw
