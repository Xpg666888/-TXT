@echo off
rem kai launcher for Windows - makes kai callable from any directory
setlocal
set "KAI_HOME=%~dp0.."
node "%KAI_HOME%\bin\kai.mjs" %*
