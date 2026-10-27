@echo off
chcp 65001 >nul
title 絮语中继
cd /d "%~dp0"
if not exist node_modules (
  echo 第一次运行，正在安装依赖...
  call npm install --omit=dev
)
node src\server.js
pause
