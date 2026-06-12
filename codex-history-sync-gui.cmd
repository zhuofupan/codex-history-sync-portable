@echo off
setlocal
chcp 65001 >nul
wscript.exe "%~dp0codex-history-sync-gui.vbs" %*
exit /b
