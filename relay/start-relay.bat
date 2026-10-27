@echo off
chcp 65001 >nul
title Xuyu Relay
cd /d "%~dp0"
rem Node.js may not be on PATH yet right after installing it
where node >nul 2>nul || set "PATH=%ProgramFiles%\nodejs;%APPDATA%\npm;%PATH%"
if not exist node_modules (
  echo Installing dependencies...
  call npm install --omit=dev
)
node src\server.js
pause
