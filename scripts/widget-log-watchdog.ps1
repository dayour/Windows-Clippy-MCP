<#
.SYNOPSIS
    Clippy Widget Log Watchdog - real-time anomaly detection for widget terminal tabs.
.DESCRIPTION
    Tails the widget debug log and startup diagnostics, detects performance
    anomalies (slow attach, double-attach, unexpected host exits, pump stalls),
    and writes structured alerts to a separate watchdog log.

    Run in the background or attach to a terminal for live output.

    Usage:
        .\widget-log-watchdog.ps1                  # foreground, live console output
        .\widget-log-watchdog.ps1 -Quiet            # suppress console, only write log
        .\widget-log-watchdog.ps1 -AlertThresholdMs 5000  # custom slow-attach threshold
#>

param(
    [switch]$Quiet,
    [int]$AlertThresholdMs = 3000,
    [int]$PollIntervalMs = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ──────────────────────────────────────────────────────────
$WidgetConfigDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Windows-Clippy-MCP'
$DebugLogPath    = Join-Path $WidgetConfigDir 'widget-debug.log'
$DiagLogPath     = Join-Path $WidgetConfigDir 'widget-startup-diag.log'
$WatchdogLogPath = Join-Path $WidgetConfigDir 'widget-watchdog.log'

if (-not (Test-Path $WidgetConfigDir)) {
    New-Item -ItemType Directory -Path $WidgetConfigDir -Force | Out-Null
}

# ── State ──────────────────────────────────────────────────────────
$script:DebugLineIndex     = 0
$script:DiagLineIndex      = 0
$script:SessionAlerts      = 0
$script:TotalAlerts        = 0
$script:TabTimestamps      = @{}     # tabId -> last event timestamp
$script:TabEventLog        = @{}     # tabId -> list of events
$script:TabAttachCount     = @{}     # tabId -> attach call count
$script:ReadyTimestamps    = @{}     # tabId -> ready timestamp
$script:AttachTimestamps   = @{}     # tabId -> first attach timestamp
$script:PumpIntervals      = @{}     # tabId -> pump intervalMs
$script:HostExitMap        = @{}     # tabId -> exit info
$script:InitStartTime      = $null
$script:InitEndTime        = $null

# ── Logging ────────────────────────────────────────────────────────
function Write-WatchdogEntry {
    param(
        [ValidateSet('INFO','WARN','ALERT','PERF','ERROR')]
        [string]$Level,
        [string]$Category,
        [string]$Message,
        [string]$TabId = '',
        [hashtable]$Data = @{}
    )

    $timestamp = [DateTime]::UtcNow.ToString('o')
    $dataJson = if ($Data.Count -gt 0) { ($Data | ConvertTo-Json -Compress -Depth 4) } else { '{}' }
    $entry = "[$timestamp] $Level [$Category] $Message tab=$TabId data=$dataJson"

    Add-Content -Path $WatchdogLogPath -Value $entry -ErrorAction SilentlyContinue
    if (-not $Quiet) {
        $color = switch ($Level) {
            'ALERT' { 'Red' }
            'WARN'  { 'Yellow' }
            'PERF'  { 'Cyan' }
            'ERROR' { 'Magenta' }
            default { 'Gray' }
        }
        Write-Host $entry -ForegroundColor $color
    }

    if ($Level -in @('ALERT','WARN','ERROR')) {
        $script:SessionAlerts++
        $script:TotalAlerts++
    }
}

# ── Parsers ────────────────────────────────────────────────────────
function Parse-DebugTimestamp {
    param([string]$Line)

    if ($Line -match '^\[([^\]]+)\]') {
        try {
            return [DateTimeOffset]::Parse($Matches[1]).UtcDateTime
        } catch {
            return $null
        }
    }
    return $null
}

function Extract-TabId {
    param([string]$Line)

    if ($Line -match '\[([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]') {
        return $Matches[1]
    }
    return $null
}

# ── Detection Rules ────────────────────────────────────────────────

function Detect-SlowAttach {
    param([string]$TabId, [DateTime]$AttachTime)

    if (-not $script:ReadyTimestamps.ContainsKey($TabId)) {
        return
    }

    $readyTime = $script:ReadyTimestamps[$TabId]
    $deltaMs = ($AttachTime - $readyTime).TotalMilliseconds

    if ($deltaMs -gt $AlertThresholdMs) {
        Write-WatchdogEntry -Level 'ALERT' -Category 'SLOW_ATTACH' `
            -Message ("Terminal attach took {0:N0}ms (threshold: {1}ms). Ready at {2}, attached at {3}." -f $deltaMs, $AlertThresholdMs, $readyTime.ToString('HH:mm:ss.fff'), $AttachTime.ToString('HH:mm:ss.fff')) `
            -TabId $TabId `
            -Data @{ deltaMs = [int]$deltaMs; readyAt = $readyTime.ToString('o'); attachedAt = $AttachTime.ToString('o') }
    } else {
        Write-WatchdogEntry -Level 'PERF' -Category 'ATTACH_OK' `
            -Message ("Terminal attached in {0:N0}ms." -f $deltaMs) `
            -TabId $TabId `
            -Data @{ deltaMs = [int]$deltaMs }
    }
}

function Detect-DoubleAttach {
    param([string]$TabId)

    $count = if ($script:TabAttachCount.ContainsKey($TabId)) { $script:TabAttachCount[$TabId] } else { 0 }
    $count++
    $script:TabAttachCount[$TabId] = $count

    if ($count -gt 1) {
        Write-WatchdogEntry -Level 'WARN' -Category 'DOUBLE_ATTACH' `
            -Message ("Terminal attached {0} times for same tab. Redundant SetParent/ShowWindow calls waste Win32 resources." -f $count) `
            -TabId $TabId `
            -Data @{ attachCount = $count }
    }
}

function Detect-UnexpectedExit {
    param([string]$TabId, [DateTime]$ExitTime, [bool]$ClosingRequested)

    if (-not $ClosingRequested) {
        $attachTime = if ($script:AttachTimestamps.ContainsKey($TabId)) { $script:AttachTimestamps[$TabId] } else { $null }
        $aliveMs = if ($attachTime) { ($ExitTime - $attachTime).TotalMilliseconds } else { -1 }

        $severity = if ($aliveMs -ge 0 -and $aliveMs -lt 5000) { 'ALERT' } else { 'WARN' }

        Write-WatchdogEntry -Level $severity -Category 'UNEXPECTED_EXIT' `
            -Message ("Host exited without close request. Alive for {0:N0}ms after attach." -f $aliveMs) `
            -TabId $TabId `
            -Data @{ aliveMs = [int]$aliveMs; closingRequested = $false }
    } else {
        Write-WatchdogEntry -Level 'INFO' -Category 'CLEAN_EXIT' `
            -Message 'Host exited normally (close was requested).' `
            -TabId $TabId
    }
}

function Detect-PumpInterval {
    param([string]$TabId, [int]$IntervalMs)

    $script:PumpIntervals[$TabId] = $IntervalMs

    if ($IntervalMs -lt 50) {
        Write-WatchdogEntry -Level 'WARN' -Category 'PUMP_FAST' `
            -Message ("Host pump interval is {0}ms. Sub-50ms polling burns CPU with diminishing returns on a DispatcherTimer." -f $IntervalMs) `
            -TabId $TabId `
            -Data @{ intervalMs = $IntervalMs }
    } elseif ($IntervalMs -gt 300) {
        Write-WatchdogEntry -Level 'PERF' -Category 'PUMP_SLOW' `
            -Message ("Host pump interval is {0}ms. May cause visible lag in host-exit detection." -f $IntervalMs) `
            -TabId $TabId `
            -Data @{ intervalMs = $IntervalMs }
    }
}

function Detect-SlowInit {
    if ($script:InitStartTime -and $script:InitEndTime) {
        $deltaMs = ($script:InitEndTime - $script:InitStartTime).TotalMilliseconds

        if ($deltaMs -gt 10000) {
            Write-WatchdogEntry -Level 'ALERT' -Category 'SLOW_INIT' `
                -Message ("Initialize-ClippyTabs took {0:N0}ms ({1:N1}s). Target is under 5s." -f $deltaMs, ($deltaMs / 1000)) `
                -Data @{ deltaMs = [int]$deltaMs }
        } elseif ($deltaMs -gt 5000) {
            Write-WatchdogEntry -Level 'WARN' -Category 'SLOW_INIT' `
                -Message ("Initialize-ClippyTabs took {0:N0}ms." -f $deltaMs) `
                -Data @{ deltaMs = [int]$deltaMs }
        } else {
            Write-WatchdogEntry -Level 'PERF' -Category 'INIT_OK' `
                -Message ("Initialize-ClippyTabs completed in {0:N0}ms." -f $deltaMs) `
                -Data @{ deltaMs = [int]$deltaMs }
        }
    }
}

# ── Line Processors ────────────────────────────────────────────────

function Process-DebugLine {
    param([string]$Line)

    $ts = Parse-DebugTimestamp -Line $Line
    $tabId = Extract-TabId -Line $Line

    # Terminal ready
    if ($Line -match 'Started embedded terminal.*session=([0-9a-f-]+)\s+hwnd=') {
        if ($tabId) {
            $script:ReadyTimestamps[$tabId] = $ts
            $script:TabAttachCount[$tabId] = 0
            Write-WatchdogEntry -Level 'INFO' -Category 'TERM_READY' `
                -Message "Embedded terminal started." `
                -TabId $tabId
        }
    }

    # Terminal attached
    if ($Line -match 'Attached embedded terminal') {
        if ($tabId -and $ts) {
            if (-not $script:AttachTimestamps.ContainsKey($tabId)) {
                $script:AttachTimestamps[$tabId] = $ts
            }
            Detect-DoubleAttach -TabId $tabId
            Detect-SlowAttach -TabId $tabId -AttachTime $ts
        }
    }

    # Attach deferred
    if ($Line -match 'Attach deferred') {
        if ($tabId) {
            Write-WatchdogEntry -Level 'PERF' -Category 'ATTACH_DEFERRED' `
                -Message 'Terminal panel handle is zero; attach will retry.' `
                -TabId $tabId
        }
    }

    # Attach timeout
    if ($Line -match 'Embedded terminal attach timed out') {
        if ($tabId) {
            Write-WatchdogEntry -Level 'ALERT' -Category 'ATTACH_TIMEOUT' `
                -Message 'Embedded terminal attach timed out after 30 retry attempts.' `
                -TabId $tabId
        }
    }

    # Host pump started
    if ($Line -match 'Started host pump.*intervalMs=(\d+)') {
        $intervalMs = [int]$Matches[1]
        if ($tabId) {
            Detect-PumpInterval -TabId $tabId -IntervalMs $intervalMs
        }
    }

    # Host exit
    if ($Line -match 'Host exit.*closing=(True|False)') {
        $closing = $Matches[1] -eq 'True'
        if ($tabId -and $ts) {
            Detect-UnexpectedExit -TabId $tabId -ExitTime $ts -ClosingRequested $closing
        }
    }

    # Terminal resize failures
    if ($Line -match 'Terminal resize failed') {
        if ($tabId) {
            Write-WatchdogEntry -Level 'WARN' -Category 'RESIZE_FAIL' `
                -Message 'Terminal resize failed.' `
                -TabId $tabId
        }
    }

    # Host startup failures
    if ($Line -match '(Node bridge|Embedded terminal) launch failed') {
        if ($tabId) {
            Write-WatchdogEntry -Level 'ALERT' -Category 'LAUNCH_FAIL' `
                -Message "Host launch failed: $Line" `
                -TabId $tabId
        }
    }

    # Startup script errors (STDERR lines)
    if ($Line -match 'STDERR \[') {
        if ($tabId) {
            Write-WatchdogEntry -Level 'WARN' -Category 'STDERR' `
                -Message ($Line -replace '^\[[^\]]+\]\s*', '') `
                -TabId $tabId
        }
    }
}

function Process-DiagLine {
    param([string]$Line)

    $ts = Parse-DebugTimestamp -Line $Line

    if ($Line -match 'DIAG: Calling Initialize-ClippyTabs' -and $ts) {
        $script:InitStartTime = $ts
    }

    if ($Line -match 'DIAG: Initialize-ClippyTabs done' -and $ts) {
        $script:InitEndTime = $ts
        Detect-SlowInit
    }

    if ($Line -match 'DIAG: Creating Application' -and $ts -and $script:InitEndTime) {
        $gapMs = ($ts - $script:InitEndTime).TotalMilliseconds
        if ($gapMs -gt 2000) {
            Write-WatchdogEntry -Level 'WARN' -Category 'SLOW_APP_CREATE' `
                -Message ("Application creation took {0:N0}ms after tab init." -f $gapMs) `
                -Data @{ gapMs = [int]$gapMs }
        }
    }
}

# ── Main Loop ──────────────────────────────────────────────────────

function Read-NewLines {
    param(
        [string]$Path,
        [ref]$LineIndex
    )

    if (-not (Test-Path $Path)) {
        return @()
    }

    $allLines = @(Get-Content -Path $Path -ErrorAction SilentlyContinue)
    if ($allLines.Count -le $LineIndex.Value) {
        return @()
    }

    $newLines = $allLines[$LineIndex.Value..($allLines.Count - 1)]
    $LineIndex.Value = $allLines.Count
    return $newLines
}

# ── Entry Point ────────────────────────────────────────────────────

Write-WatchdogEntry -Level 'INFO' -Category 'WATCHDOG' `
    -Message ("Watchdog started. alertThreshold={0}ms poll={1}ms debugLog={2}" -f $AlertThresholdMs, $PollIntervalMs, $DebugLogPath)

# Process any existing log content first
$existingDebugLines = Read-NewLines -Path $DebugLogPath -LineIndex ([ref]$script:DebugLineIndex)
foreach ($line in $existingDebugLines) {
    Process-DebugLine -Line $line
}

$existingDiagLines = Read-NewLines -Path $DiagLogPath -LineIndex ([ref]$script:DiagLineIndex)
foreach ($line in $existingDiagLines) {
    Process-DiagLine -Line $line
}

if ($existingDebugLines.Count -gt 0 -or $existingDiagLines.Count -gt 0) {
    Write-WatchdogEntry -Level 'INFO' -Category 'WATCHDOG' `
        -Message ("Processed {0} existing debug lines and {1} diag lines." -f $existingDebugLines.Count, $existingDiagLines.Count)
}

# Live tail loop
Write-WatchdogEntry -Level 'INFO' -Category 'WATCHDOG' `
    -Message 'Entering live tail mode. Press Ctrl+C to stop.'

try {
    while ($true) {
        $newDebug = Read-NewLines -Path $DebugLogPath -LineIndex ([ref]$script:DebugLineIndex)
        foreach ($line in $newDebug) {
            Process-DebugLine -Line $line
        }

        $newDiag = Read-NewLines -Path $DiagLogPath -LineIndex ([ref]$script:DiagLineIndex)
        foreach ($line in $newDiag) {
            Process-DiagLine -Line $line
        }

        Start-Sleep -Milliseconds $PollIntervalMs
    }
} finally {
    Write-WatchdogEntry -Level 'INFO' -Category 'WATCHDOG' `
        -Message ("Watchdog stopped. Session alerts: {0}, Total alerts: {1}." -f $script:SessionAlerts, $script:TotalAlerts)
}
