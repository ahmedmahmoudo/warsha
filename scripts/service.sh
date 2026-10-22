#!/bin/bash
# Runs Warsha as a macOS background service (a launchd agent): it starts when you log in,
# restarts if it crashes, and keeps running with no terminal open.
#
#   npm run service:install   build, then install and start it on http://localhost:5180
#   npm run service:restart   rebuild and restart after pulling or changing code
#   npm run service:stop      stop it and remove the agent
#   npm run service:logs      follow its output
set -euo pipefail

LABEL=com.warsha.app
PORT=5180
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/warsha.log"
DOMAIN="gui/$(id -u)"

stop() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  # Warsha was called Workbench: its agent goes too, so the two never fight over the port.
  launchctl bootout "$DOMAIN/com.workbench.app" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.workbench.app.plist"
}

install() {
  local node
  node="$(command -v node)"
  (cd "$ROOT" && npm run build)
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  # launchd starts with a bare PATH: give it node's folder (nvm) plus the usual places for git and open.
  cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>ProgramArguments</key>
  <array>
    <string>$node</string>
    <string>--import</string>
    <string>tsx</string>
    <string>server/index.ts</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NODE_ENV</key><string>production</string>
    <key>WARSHA_LOCAL</key><string>1</string>
    <key>PORT</key><string>$PORT</string>
    <key>PATH</key><string>$(dirname "$node"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
  stop
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "Warsha is running on http://localhost:$PORT (logs: $LOG)"
}

case "${1:-}" in
  install | restart) install ;;
  stop)
    stop
    rm -f "$PLIST"
    echo "Warsha service stopped and removed"
    ;;
  logs) tail -f "$LOG" ;;
  *)
    echo "usage: $0 install|restart|stop|logs" >&2
    exit 1
    ;;
esac
