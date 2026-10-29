#!/bin/bash
# Builds "Actions Runner Monitor.app" (universal: Apple silicon + Intel) into ./build.
#   ./build.sh            build only
#   ./build.sh --install  also copy it to ~/Applications and (re)start it
#   ./build.sh --zip      also package build/ActionsRunnerMonitor.zip for a release
set -euo pipefail
cd "$(dirname "$0")"

NAME="Actions Runner Monitor"
EXECUTABLE="ActionsRunnerMonitor"
APP="build/$NAME.app"
LABEL="$(plutil -extract CFBundleIdentifier raw Info.plist)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" build/obj
cp Info.plist "$APP/Contents/Info.plist"

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library \
    -target "$arch-apple-macos14" \
    Sources/*.swift \
    -o "build/obj/$EXECUTABLE-$arch"
done
lipo -create build/obj/$EXECUTABLE-* -output "$APP/Contents/MacOS/$EXECUTABLE"

# Ad-hoc signature: enough for launchd and for running a locally built copy.
codesign --force --sign - "$APP"
echo "Built $APP"

case "${1:-}" in
--zip)
  rm -f build/ActionsRunnerMonitor.zip
  ditto -c -k --keepParent "$APP" build/ActionsRunnerMonitor.zip
  echo "Packaged build/ActionsRunnerMonitor.zip"
  ;;
--install)
  INSTALLED="$HOME/Applications/$NAME.app"
  AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

  # launchd would restart the old copy while it's being replaced, so stop the
  # agent first; plain instances just get quit.
  [[ -f "$AGENT" ]] && launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  for _ in {1..20}; do pgrep -x "$EXECUTABLE" >/dev/null || break; sleep 0.25; done

  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALLED"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to $INSTALLED"

  if [[ -f "$AGENT" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    echo "Restarted the launchd agent"
    exit 0
  fi
  # LaunchServices can lag behind the old instance's exit, so retry.
  for _ in {1..5}; do
    open "$INSTALLED" 2>/dev/null && { echo "Launched"; exit 0; }
    sleep 1
  done
  echo "Couldn't launch it; open $INSTALLED by hand." >&2
  exit 1
  ;;
esac
