#!/usr/bin/env bash
#
# grant_tcc.sh - Pre-approve Apple Screen Sharing's privacy (TCC) privileges.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# Since macOS 12.1, `kickstart` can start Apple's RFB/VNC daemon but it CANNOT
# grant that daemon Screen Recording access. From Apple's own docs
# (support.apple.com/guide/remote-desktop/apd8b1c65bd/mac):
#
#   "In macOS 12.1 or later, Screen Sharing can't be enabled by the kickstart
#    command-line tool. You can use a mobile device management (MDM) solution to
#    enable Remote Management."
#
# So the symptom on a headless CI runner is:
#   * `kickstart` itself prints, on every invocation:
#       "Screen recording might be disabled. Screen Sharing or Remote
#        Management must be enabled from System Settings or via MDM."
#   * port 5900 never binds, or binds and serves a black framebuffer
#
# `tccutil` cannot help either: it can only RESET a grant, never GRANT one.
# There is no command line switch that grants Screen Recording.
#
# The way this is solved in practice (and the way GitHub's own macOS runner
# images do it) is to seed the row directly into TCC.db. The hosted runners ship
# with SIP disabled, so that write is permitted.
#
# Schema note: the `access` table gains NOT NULL columns over time - macOS 26
# added `auth_version`, which silently broke a hand-written column list with
#   Error: stepping, NOT NULL constraint failed: access.auth_version (19)
# So we never hardcode a column list. We clone an existing row of the same
# service and override only the fields we care about; any column we do not
# recognise is copied verbatim. New columns are handled for free.
# ---------------------------------------------------------------------------

set -uo pipefail

readonly SERVICES=(
  "kTCCServiceScreenCapture"   # read the framebuffer  -> fixes the black screen
  "kTCCServiceAccessibility"   # synthesise input events
  "kTCCServiceListenEvent"     # observe input events
  "kTCCServicePostEvent"       # post input events
)
# Every identity that can end up doing the capture / event injection, verified
# against a live macOS 26 runner (see .github/workflows/deskprobe.yml).
# Format: "<client>|<client_type>"  0 = bundle id, 1 = absolute binary path.
readonly CLIENTS=(
  "com.apple.screensharing.agent|0"    # ScreensharingAgent.bundle
  "com.apple.screensharing.daemon|0"   # screensharingd.bundle  <- the real server
  "com.apple.RemoteDesktopAgent|0"     # ARDAgent.app
  "com.apple.AppleVNCServer|0"         # AppleVNCServer.bundle
  "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd|1"
  "/System/Library/CoreServices/RemoteManagement/ScreensharingAgent.bundle/Contents/MacOS/ScreensharingAgent|1"
  "/System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/MacOS/AppleVNCServer|1"
  "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent|1"
  "/System/Library/CoreServices/RemoteManagement/SSMenuAgent.app/Contents/MacOS/SSMenuAgent|1"
)
readonly AUTH_VALUE=2          # 2 = allowed
readonly AUTH_REASON=4         # matches the row GitHub ships
readonly FLAGS=1

# Callers can add their own clients, e.g.
#   EXTRA_CLIENTS="com.realvnc.vncserver|0,/path/to/bin|1" ./grant_tcc.sh
# The platform-binary TCC rule only applies to Apple's own binaries, so a
# third-party server (RealVNC, etc.) IS grantable this way.
ALL_CLIENTS=("${CLIENTS[@]}")
if [[ -n "${EXTRA_CLIENTS:-}" ]]; then
  IFS=',' read -r -a _extra <<< "$EXTRA_CLIENTS"
  for e in "${_extra[@]}"; do
    [[ -n "$e" ]] && ALL_CLIENTS+=("$e")
  done
fi

log()  { printf '  %s\n' "$*"; }
warn() { printf '  !! %s\n' "$*" >&2; }

# The system database plus every user home we can find. ARD captures the
# *console* session's framebuffer, so the grant has to exist in the TCC.db of
# whichever account owns that session - not just the account running this script.
collect_dbs() {
  {
    printf '%s\n' "/Library/Application Support/com.apple.TCC/TCC.db"
    printf '%s\n' "$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    local home
    for home in /Users/*; do
      [[ -d "$home/Library/Application Support/com.apple.TCC" ]] &&
        printf '%s\n' "$home/Library/Application Support/com.apple.TCC/TCC.db"
    done
  } | awk 'NF && !seen[$0]++'
  return 0
}

# expr_for <column> <service> <client> <client_type>
expr_for() {
  case "$1" in
    service)       printf "'%s'" "$2" ;;
    client)        printf "'%s'" "$3" ;;
    client_type)   printf '%s' "$4" ;;
    auth_value)    printf '%s' "$AUTH_VALUE" ;;
    auth_reason)   printf '%s' "$AUTH_REASON" ;;
    flags)         printf '%s' "$FLAGS" ;;
    last_modified) printf "CAST(strftime('%%s','now') AS INTEGER)" ;;
    # csreq is the binary's code-signing requirement. Inheriting the template
    # row's csreq is WRONG - it belongs to a different binary, so TCC rejects
    # the grant at match time and the capture stays black. NULL means "no code
    # requirement", which is what GitHub's own runner image uses.
    csreq)         printf 'NULL' ;;
    *)             printf '"%s"' "$1" ;;   # inherit from the template row
  esac
}

# grant_service <db> <service> <client> <client_type>
grant_service() {
  local db="$1" service="$2" client="$3" ctype="$4"
  local columns select_list col tmpl sql err

  [[ -f "$db" ]] || return 0
  if ! sudo sqlite3 "$db" "SELECT 1 FROM access LIMIT 1;" >/dev/null 2>&1; then
    warn "cannot read access table in $db"
    return 1
  fi

  # Prefer a template row of the same service (most semantically correct),
  # otherwise any row, so unknown columns still inherit sane values.
  tmpl="$(sudo sqlite3 "$db" "SELECT rowid FROM access WHERE service='$service' LIMIT 1;" 2>/dev/null)"
  [[ -z "$tmpl" ]] && tmpl="$(sudo sqlite3 "$db" "SELECT rowid FROM access LIMIT 1;" 2>/dev/null)"

  columns=""; select_list=""
  while IFS= read -r col; do
    [[ -z "$col" ]] && continue
    if [[ -n "$columns" ]]; then columns="$columns,"; select_list="$select_list,"; fi
    columns="$columns\"$col\""
    select_list="$select_list$(expr_for "$col" "$service" "$client" "$ctype")"
  done < <(sudo sqlite3 "$db" "PRAGMA table_info(access);" | cut -d'|' -f2)

  # Deterministic: drop any stale row (including a `denied` one) first, since
  # INSERT OR IGNORE would silently keep a bad grant.
  sudo sqlite3 "$db" "DELETE FROM access WHERE service='$service' AND client='$client';"

  if [[ -n "$tmpl" ]]; then
    sql="INSERT INTO access ($columns) SELECT $select_list FROM access WHERE rowid=$tmpl;"
  else
    sql="INSERT INTO access ($columns) VALUES ($select_list);"
    warn "  (access table empty in $db - no template row to clone)"
  fi

  if err="$(sudo sqlite3 "$db" "$sql" 2>&1)"; then
    log "granted ${service} -> ${client}"
  else
    warn "FAILED ${service} -> ${client}: ${err}"
    return 1
  fi
}

# macOS 15+ can pop a "bypassing the system private window picker" alert that
# steals focus and wrecks headed UI tests. replayd tracks the reminder in this
# plist; a far-future date suppresses it. Best effort - harmless if ignored.
suppress_replayd_reminder() {
  local plist="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
  mkdir -p "$(dirname "$plist")" 2>/dev/null || return 0
  for proc in "/System/Library/CoreServices/RemoteManagement/ARDAgent.app" \
              "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle"; do
    defaults write "$plist" "$proc" -date "3024-01-01 00:00:00 +0000" 2>/dev/null || true
  done
}

# tccd caches the previous (denied) state in memory; force it to re-read.
flush_tcc() {
  sudo killall tccd 2>/dev/null || true
  killall  cfprefsd 2>/dev/null || true
}

echo "==> Pre-approving Screen Sharing privacy permissions (TCC)..."

rc=0
while IFS= read -r db; do
  log "--- $db"
  for service in "${SERVICES[@]}"; do
    for spec in "${ALL_CLIENTS[@]}"; do
      grant_service "$db" "$service" "${spec%%|*}" "${spec##*|}" || rc=1
    done
  done
done < <(collect_dbs)

suppress_replayd_reminder
flush_tcc

# Show the resulting rows so a failed run is obvious in the Actions log.
echo "==> Verifying screen-capture grants:"
while IFS= read -r db; do
  [[ -f "$db" ]] || continue
  sudo sqlite3 "$db" \
    "SELECT '    ' || client || '  type=' || client_type || '  auth=' || auth_value
              || '  csreq=' || CASE WHEN csreq IS NULL THEN 'NULL' ELSE 'SET(BAD)' END
       FROM access
      WHERE service = 'kTCCServiceScreenCapture'
        AND auth_value = 2
      ORDER BY client;" 2>/dev/null || true
done < <(collect_dbs)

if [[ "$rc" -ne 0 ]]; then
  warn "TCC seeding incomplete - see errors above."
  exit 1
fi
log "TCC seeding complete."
