@echo off
setlocal
title Windows Clippy Widget
start "" powershell.exe -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0clippy-widget.ps1" %*
