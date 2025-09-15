#!/usr/bin/env powershell
# Windows Clippy MCP - Admin PowerShell with Copilot CLI Setup
# This script sets up an admin PowerShell session with Copilot CLI integration

Write-Host ""
Write-Host "📎 Windows Clippy MCP - Admin PowerShell Setup" -ForegroundColor Green
Write-Host "   Your friendly AI assistant for Windows desktop automation" -ForegroundColor Blue
Write-Host "   Logo: assets/WC25.png" -ForegroundColor Cyan
Write-Host ""

# Set location to Windows Clippy MCP directory
Set-Location "G:\Github\DAYOUR\Windows-Clippy-MCP"
Write-Host "✅ Location set to: $(Get-Location)" -ForegroundColor Green

# Check if we're running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Host "✅ Running as Administrator" -ForegroundColor Green
} else {
    Write-Host "⚠️  Not running as Administrator - some operations may be limited" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "🔧 Available Windows Clippy MCP Commands:" -ForegroundColor Yellow
Write-Host "   • uv run python main.py          - Start MCP server"
Write-Host "   • npm run install-service        - Install Windows service (admin required)"
Write-Host "   • npm run uninstall-service      - Remove Windows service"
Write-Host "   • npm run validate               - Validate installation"
Write-Host "   • node scripts/setup.js          - Re-run setup"
Write-Host ""

# Check GitHub CLI and Copilot
Write-Host "🔍 Checking GitHub CLI and Copilot..." -ForegroundColor Yellow
try {
    $ghVersion = gh --version 2>$null
    if ($?) {
        Write-Host "✅ GitHub CLI found: $($ghVersion[0])" -ForegroundColor Green
        
        # Try to check Copilot extension
        try {
            gh copilot --version 2>$null
            if ($?) {
                Write-Host "✅ GitHub Copilot CLI extension is available" -ForegroundColor Green
                Write-Host "   Use: gh copilot suggest '<your question>'" -ForegroundColor Cyan
                Write-Host "   Use: gh copilot explain '<command to explain>'" -ForegroundColor Cyan
            } else {
                Write-Host "⚠️  GitHub Copilot CLI extension not found" -ForegroundColor Yellow
                Write-Host "   Install with: gh extension install github/gh-copilot" -ForegroundColor Cyan
            }
        } catch {
            Write-Host "⚠️  GitHub Copilot CLI extension not available" -ForegroundColor Yellow
            Write-Host "   Update GitHub CLI or install extension manually" -ForegroundColor Cyan
        }
    } else {
        Write-Host "❌ GitHub CLI not found" -ForegroundColor Red
        Write-Host "   Install from: https://cli.github.com/" -ForegroundColor Cyan
    }
} catch {
    Write-Host "❌ GitHub CLI not found or error occurred" -ForegroundColor Red
    Write-Host "   Install from: https://cli.github.com/" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "🎯 Windows Clippy MCP Admin Session Ready!" -ForegroundColor Green
Write-Host "   Type commands or use GitHub Copilot CLI for assistance" -ForegroundColor Blue
Write-Host ""

# Set custom prompt to show this is the Clippy MCP admin session
function prompt {
    Write-Host "📎 " -NoNewline -ForegroundColor Green
    Write-Host "ClippyMCP-Admin" -NoNewline -ForegroundColor Blue  
    Write-Host " $(Split-Path -Leaf (Get-Location))" -NoNewline -ForegroundColor Yellow
    Write-Host " > " -NoNewline -ForegroundColor White
    return " "
}