$ErrorActionPreference = 'Continue'
try {
  & 'E:\Windows-Clippy-MCP\widget\clippy-widget.ps1' -OpenChat
  Write-Output 'SCRIPT_COMPLETED'
} catch {
  Write-Output ('CAUGHT=' + $_.Exception.Message)
}
Write-Output ('ERROR_COUNT=' + $error.Count)
if ($error.Count -gt 0) {
  $error | ForEach-Object {
    Write-Output '---ERROR---'
    $_ | Format-List * -Force | Out-String | Write-Output
  }
}
