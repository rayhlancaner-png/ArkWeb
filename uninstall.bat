@echo off
rem Takes ArkWeb out of both games again; a DLL of another mod it had set aside goes back (tools\install.ps1).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1" -Uninstall %*
