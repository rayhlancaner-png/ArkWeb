@echo off
rem Starts an ArkWeb session: whichever game is not running yet, through Steam, then the streamer (tools\play.ps1).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\play.ps1" %*
