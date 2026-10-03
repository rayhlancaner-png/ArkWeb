@echo off
rem Installs ArkWeb into both games, found through Steam (tools\install.ps1). uninstall.bat takes it out again.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1" %*
