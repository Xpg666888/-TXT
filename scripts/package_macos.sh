#!/usr/bin/env bash
set -euo pipefail

# Package .app into zip (run after build_macos.sh)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${ROOT_DIR}/dist/ForeverSubtitleFactory.app"
RELEASE_DIR="${ROOT_DIR}/release"
ZIP_PATH="${RELEASE_DIR}/ForeverSubtitleFactory-macos.zip"

if [[ ! -d "$APP_PATH" ]]; then
  echo "[ERROR] App not found: $APP_PATH"
  echo "Run: ./scripts/build_macos.sh"
  exit 1
fi

mkdir -p "$RELEASE_DIR"
rm -f "$ZIP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "[DONE] Release package: $ZIP_PATH"
