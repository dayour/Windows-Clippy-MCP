@echo off
REM Launch Clippy Cursor Mode (standalone)
REM Replaces the mouse pointer with Clippy and adds Ctrl+Right-Click AI context menu.
REM
REM  Ctrl+Right-Click : Clippy AI context menu
REM  Ctrl+Shift+E     : Explain This
REM  Ctrl+Shift+S     : Summarize Screen
REM  Ctrl+Shift+T     : Extract Text
REM
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0clippy-cursor.ps1" -Standalone
