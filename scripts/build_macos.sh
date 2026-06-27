#!/usr/bin/env bash
set -euo pipefail

# Run on macOS only:
#   chmod +x scripts/build_macos.sh
#   ./scripts/build_macos.sh

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${ROOT_DIR}/.venv-macos"
ICON_PATH="${ROOT_DIR}/resources/app.icns"

echo "[INFO] Root: $ROOT_DIR"
echo "[INFO] Python: $PYTHON_BIN"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "[ERROR] Python not found: $PYTHON_BIN"
  exit 1
fi

"$PYTHON_BIN" -m venv "$VENV_DIR"
source "${VENV_DIR}/bin/activate"

python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python -m pip install pyinstaller

ICON_ARGS=()
if [[ -f "$ICON_PATH" ]]; then
  echo "[INFO] Use icon: $ICON_PATH"
  ICON_ARGS=(--icon "$ICON_PATH")
else
  echo "[WARN] app.icns not found, app will use default icon"
fi

echo "[STEP] Build macOS .app"
python -m PyInstaller \
  --noconfirm \
  --clean \
  --windowed \
  "${ICON_ARGS[@]}" \
  --name ForeverSubtitleFactory \
  --add-data "resources:resources" \
  --add-data "models:models" \
  --hidden-import qfluentwidgets \
  --hidden-import faster_whisper \
  --hidden-import ctranslate2 \
  --hidden-import onnxruntime \
  --hidden-import av \
  --collect-all faster_whisper \
  --collect-all ctranslate2 \
  --collect-all onnxruntime \
  --collect-all tokenizers \
  --collect-all av \
  asr_gui.py

echo "[DONE] Output: ${ROOT_DIR}/dist/ForeverSubtitleFactory.app"
