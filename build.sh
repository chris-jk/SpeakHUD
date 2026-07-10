#!/bin/bash
# Build SpeakHUD.app from source, sign it, and install it.
#  - Installs the .app to /Applications (falls back to ~/Applications).
#  - Also refreshes ~/.claude/bin/speak-hud, the binary the Claude Code Stop hook runs.
# Stock-macOS tools only: swiftc, codesign, sips, iconutil.
set -euo pipefail
cd "$(dirname "$0")"

APPNAME="SpeakHUD"
BUNDLEID="com.chris.speakhud"
EXEC="speak-hud"
STAGE="$(mktemp -d)/$APPNAME.app"

echo "== Compiling =="
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
swiftc -O "$EXEC.swift" -o "$STAGE/Contents/MacOS/$EXEC"
echo "  $(file -b "$STAGE/Contents/MacOS/$EXEC")"

echo "== Icon =="
if [ ! -f AppIcon.icns ]; then
  echo "  AppIcon.icns missing; regenerating from make-icon.swift"
  swiftc -O make-icon.swift -o /tmp/spkhud-make-icon
  /tmp/spkhud-make-icon /tmp/spkhud-icon.png
  ISET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ISET"
  for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" /tmp/spkhud-icon.png --out "$ISET/icon_${name}.png" >/dev/null
  done
  iconutil -c icns "$ISET" -o AppIcon.icns
fi
cp AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp hook/read-summary.py "$STAGE/Contents/Resources/read-summary.py"   # for the in-app Claude Code setup

echo "== Info.plist =="
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APPNAME</string>
  <key>CFBundleDisplayName</key><string>Speak HUD</string>
  <key>CFBundleIdentifier</key><string>$BUNDLEID</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

echo "== Code signing =="
# Prefer a stable signing identity. macOS keys the Accessibility (TCC) grant to the
# code signature, and an ad-hoc signature gets a fresh hash on every build — which
# would silently revoke "read my highlighted text" each time this script runs.
# Override with SPEAKHUD_SIGN_ID=<hash|name>, e.g. a self-signed cert.
SIGN_ID="${SPEAKHUD_SIGN_ID:-}"
SIGN_NAME=""
if [ -z "$SIGN_ID" ]; then
  LINE=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" || true)
  if [ -n "$LINE" ]; then
    SIGN_ID=$(awk '{print $2}' <<<"$LINE")
    SIGN_NAME=$(sed -E 's/.*"(.*)".*/\1/' <<<"$LINE")
  fi
fi
if [ -n "$SIGN_ID" ]; then
  codesign --force --options runtime --sign "$SIGN_ID" "$STAGE"
  echo "  signed as ${SIGN_NAME:-$SIGN_ID}"
else
  codesign --force --sign - "$STAGE"
  echo "  ad-hoc signed (no Developer ID Application identity found)"
  echo "  NOTE: macOS will drop SpeakHUD's Accessibility grant on every rebuild."
fi
codesign --verify "$STAGE" && echo "  signature valid"

echo "== Install .app =="
DEST="/Applications/$APPNAME.app"
if [ ! -w /Applications ]; then mkdir -p "$HOME/Applications"; DEST="$HOME/Applications/$APPNAME.app"; fi
rm -rf "$DEST"; cp -R "$STAGE" "$DEST"
# Refresh the icon cache so Finder shows the new icon immediately.
touch "$DEST"
echo "  installed -> $DEST"

echo "== Refresh Claude Code hook =="
if [ -d "$HOME/.claude/bin" ]; then
  cp "$STAGE/Contents/MacOS/$EXEC" "$HOME/.claude/bin/$EXEC"
  echo "  refreshed -> ~/.claude/bin/$EXEC"
fi
# The script is what decides to queue rather than kill; a stale copy silently
# keeps the old "last turn wins" behaviour.
if [ -f "$HOME/.claude/read-summary.py" ]; then
  cp hook/read-summary.py "$HOME/.claude/read-summary.py"
  echo "  refreshed -> ~/.claude/read-summary.py"
fi

echo "== Install global-hotkey agent (LaunchAgent) =="
AGENT_LABEL="com.chris.speakhud.agent"
PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<APLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST/Contents/MacOS/$EXEC</string>
    <string>--agent</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/speakhud-agent.log</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/speakhud-agent.log</string>
</dict>
</plist>
APLIST
UID_NUM=$(id -u)
launchctl bootout "gui/$UID_NUM/$AGENT_LABEL" 2>/dev/null || true
# bootout is asynchronous. Bootstrapping while the old job is still tearing down
# fails with "Operation already in progress" and silently leaves nothing loaded.
for _ in $(seq 25); do
  launchctl print "gui/$UID_NUM/$AGENT_LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
if ! launchctl bootstrap "gui/$UID_NUM" "$PLIST"; then
  echo "  ERROR: could not load the agent; the hotkey and speech queue won't work" >&2
  exit 1
fi
launchctl enable "gui/$UID_NUM/$AGENT_LABEL" 2>/dev/null || true
launchctl kickstart "gui/$UID_NUM/$AGENT_LABEL" >/dev/null 2>&1 || true
echo "  agent loaded; global hotkey reads ~/.config/speakhud/config.json (default ctrl+opt+s)"
echo "  change it with:  $DEST/Contents/MacOS/$EXEC --set-hotkey \"ctrl+opt+r\""

echo "Done."
