@echo off
setlocal

set "ROOT_DIR=%~dp0.."
set "DIST_DIR=%ROOT_DIR%\dist\ForeverSubtitleFactory"
set "RELEASE_DIR=%ROOT_DIR%\release"
set "ZIP_FILE=%RELEASE_DIR%\ForeverSubtitleFactory-win64.zip"

if not exist "%DIST_DIR%\ForeverSubtitleFactory.exe" (
  echo [ERROR] EXE not found. Build first: scripts\build_exe.bat
  exit /b 1
)

if not exist "%RELEASE_DIR%" mkdir "%RELEASE_DIR%"
if exist "%ZIP_FILE%" del /f /q "%ZIP_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Compress-Archive -Path '%DIST_DIR%\*' -DestinationPath '%ZIP_FILE%' -Force"

if errorlevel 1 (
  echo [ERROR] Release zip failed.
  exit /b 1
)

echo [DONE] Release zip created: %ZIP_FILE%
endlocal
