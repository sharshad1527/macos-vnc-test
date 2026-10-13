#!/usr/bin/env bash
set -e

VNC_PASSWORD="${1:-FarisMac2026}"
NGROK_TOKEN="${2}"
NGROK_REGION="${3:-in}"

echo "=========================================================="
echo "🍏 Configuring macOS GUI Screen Sharing & VNC Service..."
echo "=========================================================="

# 1. Disable spotlight indexing to conserve VM resources
sudo mdutil -i off -a 2>/dev/null || true

# 2. Prevent virtual display sleep and wake session
echo "==> Disabling display sleep and waking session..."
sudo pmset -a displaysleep 0 sleep 0 disablesleep 1 2>/dev/null || true
defaults -currentHost write com.apple.screensaver idleTime 0 2>/dev/null || true
caffeinate -u -t 21600 &

# 3. Create dedicated desktop account 'vncuser' with home directory & admin rights
echo "==> Configuring desktop user 'vncuser' and 'runner'..."
if ! dscl . -read /Users/vncuser &>/dev/null; then
  sudo dscl . -create /Users/vncuser UserShell /bin/bash 2>/dev/null || true
  sudo dscl . -create /Users/vncuser RealName "VNC User" 2>/dev/null || true
  sudo dscl . -create /Users/vncuser UniqueID 1001 2>/dev/null || true
  sudo dscl . -create /Users/vncuser PrimaryGroupID 80 2>/dev/null || true
  sudo dscl . -create /Users/vncuser NFSHomeDirectory /Users/vncuser 2>/dev/null || true
  sudo dscl . -passwd /Users/vncuser "$VNC_PASSWORD" 2>/dev/null || true
  sudo createhomedir -c -u vncuser 2>/dev/null || true
  sudo dscl . -append /Groups/admin GroupMembership vncuser 2>/dev/null || true
fi
sudo dscl . -passwd /Users/runner "$VNC_PASSWORD" 2>/dev/null || true

# 3b. Make sure the account passwords actually took.
#     `dscl -passwd` fails SILENTLY in some cases (we already saw
#     "passwd: DS error: eDSAuthFailed" for vncuser), and Apple DH auth - which
#     is what the VNC server offers - then rejects us with a bare
#     "Authentication or authorization failure". So verify with -authonly and
#     fall back to sysadminctl, which goes through the proper admin path.
set_account_password() {
  local user="$1" pw="$2"
  sudo dscl . -passwd "/Users/$user" "$pw" >/dev/null 2>&1 || true

  if sudo dscl . -authonly "$user" "$pw" >/dev/null 2>&1; then
    echo "    $user: password verified"
    return 0
  fi

  echo "    $user: dscl passwd did not take, retrying via sysadminctl..." >&2
  sudo sysadminctl -adminUser "$user" -password "$pw" >/dev/null 2>&1 || true
  if sudo dscl . -authonly "$user" "$pw" >/dev/null 2>&1; then
    echo "    $user: password verified via sysadminctl"
    return 0
  fi

  echo "    !! $user: CANNOT AUTHENTICATE - VNC login will fail" >&2
  return 1
}

echo "==> Verifying login credentials..."
set_account_password vncuser "$VNC_PASSWORD" || true
set_account_password runner  "$VNC_PASSWORD" || true

# 4. Pre-approve Screen Sharing's TCC privileges BEFORE starting the agent.
#    `kickstart` cannot do this on macOS 12.1+ (Apple requires System Settings
#    or MDM), and there is no human at the desktop on a CI runner. Without it
#    the RFB daemon starts and authenticates but every framebuffer grab is
#    refused by TCC -> black screen + "Screen recording might be disabled".
echo "==> Granting Screen Recording / Accessibility to Screen Sharing..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR/grant_tcc.sh"
# Non-fatal on purpose: if the grant fails we still want the tunnels to come up
# and the Health Check step to run, so the failure is diagnosable instead of
# just aborting the job with no output.
"$SCRIPT_DIR/grant_tcc.sh" || \
  echo "!! TCC grant failed - VNC will authenticate but show a BLACK SCREEN." >&2

# 4b. Register the RemoteManagement bundles with LaunchServices.
#     tccd logs "Failed to create LSApplicationRecord ... OSStatus error -10811"
#     for ScreensharingAgent.bundle, which means it cannot even resolve the
#     binary's identity to look up a grant. lsregister -f fixes that.
if [ "${LSREGISTER:-0}" = "1" ]; then
  echo "==> Registering RemoteManagement bundles with LaunchServices..."
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  for b in ScreensharingAgent.bundle screensharingd.bundle AppleVNCServer.bundle \
           ARDAgent.app SSMenuAgent.app; do
    if [ -e "/System/Library/CoreServices/RemoteManagement/$b" ]; then
      sudo "$LSREG" -f "/System/Library/CoreServices/RemoteManagement/$b" >/dev/null 2>&1 \
        && echo "    registered $b" \
        || echo "    !! failed to register $b" >&2
    fi
  done
  # Make sure tccd re-reads the now-registered identity.
  sudo killall tccd 2>/dev/null || true
  sleep 1
fi

# 5. Enable Apple Remote Management (Apple Remote Desktop)
#
#    NOTE the flag combination, it is the whole ballgame:
#      -access -on   turns the service ON. Without it ARD prints
#                    "Activated Remote Management." but never actually
#                    listens on 5900.
#      -allusers     is only a *modifier* of -access; on its own it does
#                    nothing (the original script used -allowAccessFor -allUsers
#                    with no -access, which is why 5900 never bound).
#      -privs -all   grants observe+control.
#      -menu         starts the menu-extra agent alongside the daemon.
echo "==> Configuring Apple Remote Management..."
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on -allusers -privs -all \
  -clientopts -setvnclegacy -vnclegacy "${LEGACY_VNC:-yes}" \
  -restart -agent -menu

# 6. Set legacy VNC password hash in system preferences
echo "==> Setting VNC authentication hash..."
echo "$VNC_PASSWORD" | perl -we 'BEGIN { @k = unpack "C*", pack "H*", "1734516E8BA8C5E2"}; $_ = <>; chomp; s/^(.{8}).*/$1/; @p = unpack "C*", $_; foreach (@k) { printf "%02X", $_ ^ (shift @p || 0) }; print "\n"' | sudo tee /Library/Preferences/com.apple.VNCSettings.txt

# 7. Re-assert activation AFTER the legacy-VNC password is written, so the
#    agent comes back up with the grant from step 4 already in place.
echo "==> Restarting ARD service..."
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -restart -agent -menu
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on -allusers -privs -all

# 8. Prove the listener is actually up before we advertise a tunnel URL.
#    ARD binds the framebuffer listener only once the screen-capture grant from
#    step 4 is in place, so give it a moment and poll rather than assume.
echo "==> Waiting for the VNC listener on 5900..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  # NOTE: must be sudo lsof - the socket is owned by launchd/root, and a
  # non-root lsof cannot see it and will falsely report nothing listening.
  if sudo lsof -nP -iTCP:5900 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "✅ macOS Screen Sharing & VNC is listening on port 5900!"
    break
  fi
  [[ "$i" -eq 10 ]] && break
  sleep 3
done
if ! sudo lsof -nP -iTCP:5900 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "❌ Nothing is listening on 5900 - VNC will not connect." >&2
  echo "   If the TCC grant above succeeded, ARD itself is refusing to start the" >&2
  echo "   framebuffer listener. See 'Health Check' for daemons + SIP state." >&2
fi

# 9. Start tunnels
echo ""
echo "=========================================================="
echo "🌐 Starting Remote Tunnels..."
echo "=========================================================="

NGROK_ACTIVE="false"
if [ -n "$NGROK_TOKEN" ]; then
  echo "==> Configuring Ngrok..."
  if ! command -v ngrok &>/dev/null; then
    ARCH=$(uname -m)
    echo "Downloading ngrok for $ARCH..."
    if [ "$ARCH" = "arm64" ]; then
      curl -sSL https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-arm64.zip -o /tmp/ngrok.zip
    else
      curl -sSL https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-amd64.zip -o /tmp/ngrok.zip
    fi
    sudo unzip -q -o /tmp/ngrok.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/ngrok
  fi

  ngrok authtoken "$NGROK_TOKEN"
  ngrok tcp 5900 --region="$NGROK_REGION" --log=stdout > /tmp/ngrok.log 2>&1 &
  sleep 4

  NGROK_URL=$(curl -s http://127.0.0.1:4040/api/tunnels | grep -o '"public_url":"[^"]*' | sed 's/"public_url":"//' | head -n1 || true)
  if [ -n "$NGROK_URL" ]; then
    NGROK_ACTIVE="true"
  fi
fi

# Always launch Pinggy TCP tunnel (tokenless backup)
echo "==> Launching Pinggy TCP tunnel (tokenless backup)..."
ssh -T -p 443 -R0:localhost:5900 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 tcp@a.pinggy.io > /tmp/pinggy.log 2>&1 &

echo "==> Waiting for Pinggy TCP endpoint..."
PINGGY_URL=""
for i in {1..15}; do
  PINGGY_URL=$(grep -o 'tcp://[^ ]*' /tmp/pinggy.log | head -n1 || true)
  if [ -n "$PINGGY_URL" ]; then
    break
  fi
  sleep 1
done

if [ -z "$PINGGY_URL" ]; then
  echo "--- Pinggy debug output ---"
  cat /tmp/pinggy.log 2>/dev/null || true
fi

echo ""
echo "=========================================================="
echo "🎉 MACOS DESKTOP CONNECTION DETAILS"
echo "=========================================================="
echo "👤 Username:   vncuser    (NOT 'runner' - GitHub manages that account's"
echo "                           password and it cannot be set, so login fails)"
echo "🔑 Password:   $VNC_PASSWORD"
echo "🖥️  OS:         $(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null || true)"
echo ""

if [ "$NGROK_ACTIVE" = "true" ]; then
  CLEAN_NGROK=$(echo "$NGROK_URL" | sed 's#tcp://##')
  echo "⚡ NGROK TUNNEL (PRIMARY):"
  echo "   VNC Target: $NGROK_URL"
  echo "   Connect directly to: $CLEAN_NGROK"
  echo ""
fi

if [ -n "$PINGGY_URL" ]; then
  CLEAN_PINGGY=$(echo "$PINGGY_URL" | sed 's#tcp://##')
  echo "⚡ PINGGY TUNNEL (TOKENLESS BACKUP):"
  echo "   VNC Target: $PINGGY_URL"
  echo "   Connect directly to: $CLEAN_PINGGY"
  echo ""
fi

echo "=========================================================="

# Also write to GitHub Actions Step Summary if in CI environment
if [ -n "$GITHUB_STEP_SUMMARY" ]; then
  cat << EOF >> "$GITHUB_STEP_SUMMARY"
## 🍏 macOS Cloud Desktop Ready!

- **Username:** \`vncuser\` *(or \`runner\`)*
- **Password:** \`$VNC_PASSWORD\`
- **Resolution:** Full Native macOS Virtual Display

### ⚡ Connection Endpoints:

EOF

  if [ "$NGROK_ACTIVE" = "true" ]; then
    CLEAN_NGROK=$(echo "$NGROK_URL" | sed 's#tcp://##')
    cat << EOF >> "$GITHUB_STEP_SUMMARY"
#### 🚀 Ngrok (Direct TCP):
- **Server Address:** \`$CLEAN_NGROK\`
- **Remmina Protocol:** \`VNC\`
- **Remmina Color Depth:** \`High color (24 bpp)\` or \`True color (32 bpp)\`
EOF
  fi

  if [ -n "$PINGGY_URL" ]; then
    CLEAN_PINGGY=$(echo "$PINGGY_URL" | sed 's#tcp://##')
    cat << EOF >> "$GITHUB_STEP_SUMMARY"
#### 🌐 Pinggy (No Token Needed):
- **Server Address:** \`$CLEAN_PINGGY\`
- **Remmina Protocol:** \`VNC\`
- **Remmina Color Depth:** \`High color (24 bpp)\` or \`True color (32 bpp)\`
EOF
  fi

  cat << EOF >> "$GITHUB_STEP_SUMMARY"

### 💻 Kali Linux Remmina Setup Guide:
1. Open **Remmina** on Kali.
2. Protocol: select **VNC**.
3. Server: enter the Server Address above (e.g. \`$CLEAN_PINGGY\` without \`tcp://\`).
4. **IMPORTANT (Black Screen Fix):** Click the **Settings/Edit** icon on the connection profile:
   - Tab **Basic** -> **Color depth**: Select **High color (24 bpp)** or **True color (32 bpp)**.
   - Quality: **Good** or **Best**.
5. Username: \`vncuser\`
6. Password: \`$VNC_PASSWORD\`
7. Connect!
EOF
fi
