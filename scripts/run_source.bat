@echo off
setlocal

set "ROOT_DIR=%~dp0.."
set "PYTHON_EXE=%ROOT_DIR%\runtime\python.exe"

if exist "%PYTHON_EXE%" goto use_primary
goto use_system

:use_primary
echo [INFO] Use embedded python: %PYTHON_EXE%
goto run

:use_system
set "PYTHON_EXE=python"
echo [INFO] Embedded python not found, use system python from PATH

:run
cd /d "%ROOT_DIR%"
"%PYTHON_EXE%" -c "import sys; sys.path.insert(0, r'%ROOT_DIR%'); import asr_gui; asr_gui.start()"

endlocal
