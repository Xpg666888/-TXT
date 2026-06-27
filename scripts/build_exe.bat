@echo off
setlocal

set "ROOT_DIR=%~dp0.."
set "PYTHON_EXE=%ROOT_DIR%\runtime\python.exe"
set "ALT_PYTHON_EXE=D:\python310\python.exe"

if exist "%PYTHON_EXE%" goto use_primary
if exist "%ALT_PYTHON_EXE%" goto use_alt
goto use_system

:use_primary
echo [INFO] Use embedded python: %PYTHON_EXE%
goto build

:use_alt
set "PYTHON_EXE=%ALT_PYTHON_EXE%"
echo [INFO] Use alternate python: %PYTHON_EXE%
goto build

:use_system
set "PYTHON_EXE=python"
echo [INFO] Embedded python not found, use system python from PATH

:build
cd /d "%ROOT_DIR%"
set "ICON_ARG="
if exist "%ROOT_DIR%\resources\app.ico" set "ICON_ARG=--icon resources\app.ico"
if not "%ICON_ARG%"=="" (
  echo [INFO] Use app icon: resources\app.ico
) else (
  echo [WARN] Icon not found, put icon at resources\app.ico
)

echo [STEP] Install dependencies...
"%PYTHON_EXE%" -m pip install -r requirements.txt
if errorlevel 1 goto failed

echo [STEP] Build EXE with PyInstaller...
"%PYTHON_EXE%" -m PyInstaller ^
  --noconfirm ^
  --clean ^
  --windowed ^
  %ICON_ARG% ^
  --name ForeverSubtitleFactory ^
  --add-data "resources;resources" ^
  --add-data "models;models" ^
  --hidden-import qfluentwidgets ^
  --hidden-import faster_whisper ^
  --hidden-import ctranslate2 ^
  --hidden-import onnxruntime ^
  --hidden-import av ^
  --collect-all faster_whisper ^
  --collect-all ctranslate2 ^
  --collect-all onnxruntime ^
  --collect-all tokenizers ^
  --collect-all av ^
  asr_gui.py
if errorlevel 1 goto failed

echo.
echo [DONE] Build output: %ROOT_DIR%\dist\ForeverSubtitleFactory
goto end

:failed
echo.
echo [ERROR] Build failed.
exit /b 1

:end
endlocal
