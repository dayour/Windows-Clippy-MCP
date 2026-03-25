
@echo off
echo Starting Windows Clippy MCP Service and widget...
cd /d "%~dp0.."
node "%~dp0service-runner.js"
