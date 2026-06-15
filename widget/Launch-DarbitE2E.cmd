@echo off
setlocal
title Darbit E2E Boss Gate
REM Runs the Darbit Semanifest end-to-end harness, which captures a real screen,
REM builds JSON + Markdown + Paperboy bundle, validates every artifact, and writes
REM a verdict to %APPDATA%\Windows-Clippy-MCP\darbit-e2e\latest.e2e.json.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0darbit-e2e.ps1" %*
