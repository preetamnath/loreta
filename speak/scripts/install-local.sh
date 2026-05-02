#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/app/LoretaSpeak.xcodeproj"
DERIVED_DATA_PATH="$ROOT_DIR/build/DerivedData"
BUILT_APP="$DERIVED_DATA_PATH/Build/Products/Debug/LoretaSpeak.app"
INSTALLED_APP="/Applications/LoretaSpeak.app"
BUNDLE_ID="com.loreta.speak"
RESET_ACCESSIBILITY=0
OPEN_ACCESSIBILITY_SETTINGS=0
UNSIGNED_FALLBACK=0

usage() {
  cat <<USAGE
Usage: $0 [--unsigned-fallback] [--reset-accessibility] [--open-accessibility-settings]

Builds Loreta Speak for local use, installs it at:
  $INSTALLED_APP

Options:
  --unsigned-fallback           Use an ad-hoc local build when the normal signed
                                project build is unavailable. This resets
                                Accessibility and opens Accessibility settings
                                automatically because macOS may treat the app as
                                a different trusted client.
  --reset-accessibility          Reset macOS Accessibility permission for $BUNDLE_ID before launching.
  --open-accessibility-settings  Open Accessibility settings after launch.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned-fallback)
      UNSIGNED_FALLBACK=1
      RESET_ACCESSIBILITY=1
      OPEN_ACCESSIBILITY_SETTINGS=1
      shift
      ;;
    --reset-accessibility)
      RESET_ACCESSIBILITY=1
      shift
      ;;
    --open-accessibility-settings)
      OPEN_ACCESSIBILITY_SETTINGS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$UNSIGNED_FALLBACK" -eq 1 ]]; then
  echo "Using unsigned fallback build. Accessibility trust will be reset before launch."
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme LoretaSpeak \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
else
  if ! xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme LoretaSpeak \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -allowProvisioningUpdates \
    build; then
    cat >&2 <<'EOF'

Loreta Speak signed local install failed.

Do not silently replace the trusted installed app with an unsigned build.
If you need to proceed anyway, rerun this script with:

  scripts/install-local.sh --unsigned-fallback

That path changes the app's Accessibility trust identity and will require
re-enabling LoretaSpeak in System Settings > Privacy & Security > Accessibility.
EOF
    exit 1
  fi
fi

/usr/bin/ditto "$BUILT_APP" "$INSTALLED_APP"

if [[ "$RESET_ACCESSIBILITY" -eq 1 ]]; then
  tccutil reset Accessibility "$BUNDLE_ID"
fi

open "$INSTALLED_APP"

echo "Installed and launched $INSTALLED_APP"
if [[ "$UNSIGNED_FALLBACK" -eq 1 ]]; then
  echo "Unsigned fallback installed. Re-enable LoretaSpeak in System Settings > Privacy & Security > Accessibility before testing insertion."
fi
if [[ "$RESET_ACCESSIBILITY" -eq 1 ]]; then
  echo "Accessibility was reset. Re-enable LoretaSpeak in System Settings > Privacy & Security > Accessibility."
fi
if [[ "$OPEN_ACCESSIBILITY_SETTINGS" -eq 1 ]]; then
  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
fi
