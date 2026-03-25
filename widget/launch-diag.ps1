param([switch]$OpenChat)

$diagPath = Join-Path $env:APPDATA 'Windows-Clippy-MCP\widget-startup-diag.log'
$timestamp = { "[$(Get-Date -Format o)]" }

try {
    & $timestamp.Invoke() + " DIAG: Starting clippy-widget.ps1" | Out-File $diagPath -Force
    & "$PSScriptRoot\clippy-widget.ps1" -OpenChat:$OpenChat 2>&1 *>&1 | ForEach-Object {
        "$_" | Out-File $diagPath -Append
    }
    & $timestamp.Invoke() + " DIAG: Script exited normally" | Out-File $diagPath -Append
} catch {
    & $timestamp.Invoke() + " DIAG: FATAL ERROR: $($_.Exception.Message)" | Out-File $diagPath -Append
    $_.Exception.ToString() | Out-File $diagPath -Append
    $_.ScriptStackTrace | Out-File $diagPath -Append
}
