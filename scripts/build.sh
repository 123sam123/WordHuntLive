#!/bin/bash
# Generates the Xcode project, builds a Release app, and optionally launches it.
# Usage: scripts/build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

# Regenerate the Xcode project from project.yml when xcodegen is installed; otherwise use
# the committed WordHuntLive.xcodeproj as-is.
XCODEGEN=$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)
if [ -x "$XCODEGEN" ]; then
  "$XCODEGEN" generate --quiet
elif [ ! -d WordHuntLive.xcodeproj ]; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

# Sign with an Apple Development identity when available so the Screen Recording
# grant survives rebuilds; otherwise fall back to ad-hoc signing.
SIGN_ARGS=()
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
  TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)
  if [ -n "$TEAM" ]; then
    SIGN_ARGS=(CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$TEAM" -allowProvisioningUpdates)
  fi
fi
if [ ${#SIGN_ARGS[@]} -eq 0 ]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual)
fi

xcodebuild -project WordHuntLive.xcodeproj -scheme WordHuntLive -configuration Release \
  -derivedDataPath build -destination 'platform=macOS' "${SIGN_ARGS[@]}" build \
  | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" || true

APP=build/Build/Products/Release/WordHuntLive.app
[ -d "$APP" ] || { echo "build failed" >&2; exit 1; }
echo "Built $APP"

# Install to /Applications so it shows up in Spotlight, Launchpad and the Dock.
if [ "${1:-}" = "--run" ] || [ "${1:-}" = "--install" ]; then
  pkill -x WordHuntLive 2>/dev/null || true
  rm -rf "/Applications/WordHuntLive.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/WordHuntLive.app"
fi
if [ "${1:-}" = "--run" ]; then
  open "/Applications/WordHuntLive.app"
fi
