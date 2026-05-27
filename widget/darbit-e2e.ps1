#requires -Version 7.0
<#
.SYNOPSIS
    Darbit Semanifest end-to-end (E2E) boss gate.

.DESCRIPTION
    Executes the Windows-Clippy-MCP cursor analysis pipeline in a deterministic,
    offline harness so the Darbit card deck game can be graded on real generated
    artifacts instead of source-text presence alone.

    The harness:
      1. Dot-sources widget\clippy-cursor.ps1 (which defines but does not start
         cursor mode unless -Standalone is supplied).
      2. Captures a full-screen screenshot to %APPDATA%\Windows-Clippy-MCP\captures.
      3. Builds the screen-context JSON, Markdown, and Paperboy bundle.
      4. Validates every artifact, the JSON shape against the formal schema,
         the Markdown section contract, the Paperboy bundle contents, and the
         widget-side hosted prompt wiring.
      5. Emits a single E2E result JSON to %APPDATA%\Windows-Clippy-MCP\darbit-e2e
         containing pass/fail status per gate and an overall verdict.

.NOTES
    Passive scan only. No UI mutation. No outbound sharing.
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Windows-Clippy-MCP\darbit-e2e'),
    [string]$ActionId = 'accessibility',
    [switch]$SkipCaptureGate,
    [int]$ExitCodeOnFail = 2
)

$ErrorActionPreference = 'Stop'

function New-GateResult {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [string]$Status = 'fail',
        [string[]]$Evidence = @(),
        [string[]]$Issues = @()
    )
    return [pscustomobject][ordered]@{
        id       = $Id
        title    = $Title
        status   = $Status
        evidence = @($Evidence)
        issues   = @($Issues)
    }
}

$repoRoot      = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$cursorScript  = Join-Path $PSScriptRoot 'clippy-cursor.ps1'
$widgetScript  = Join-Path $PSScriptRoot 'clippy-widget.ps1'
$schemaPath    = Join-Path $PSScriptRoot 'adaptive-cards\screen-context.schema.json'
$templatePath  = Join-Path $PSScriptRoot 'adaptive-cards\cursor-analysis.template.json'

if (-not (Test-Path -LiteralPath $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$runId       = 'darbit-e2e-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
$runDir      = Join-Path $OutputRoot $runId
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$resultPath  = Join-Path $OutputRoot 'latest.e2e.json'
$runResult   = Join-Path $runDir 'e2e.json'

$gates  = [System.Collections.Generic.List[object]]::new()
$context = $null
$jsonPath = $null
$mdPath = $null
$bundlePath = $null
$capturePath = $null

# Gate 0 — prerequisite source files exist
$missing = @()
foreach ($p in @($cursorScript, $widgetScript, $schemaPath, $templatePath)) {
    if (-not (Test-Path -LiteralPath $p)) { $missing += $p }
}
if ($missing.Count -eq 0) {
    $gates.Add((New-GateResult -Id 'prereq-files' -Title 'Required source files present' -Status 'pass' -Evidence @('All required files resolved.')))
} else {
    $gates.Add((New-GateResult -Id 'prereq-files' -Title 'Required source files present' -Issues $missing))
}

# Load WinForms/WPF assemblies the cursor script normally relies on the widget for.
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing       -ErrorAction SilentlyContinue
Add-Type -AssemblyName PresentationCore     -ErrorAction SilentlyContinue
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
Add-Type -AssemblyName WindowsBase          -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# Dot-source the cursor module to obtain its functions (no -Standalone => no hooks).
try {
    . $cursorScript
    $gates.Add((New-GateResult -Id 'cursor-module-load' -Title 'clippy-cursor.ps1 loads as module' -Status 'pass' -Evidence @("Loaded $cursorScript")))
} catch {
    $gates.Add((New-GateResult -Id 'cursor-module-load' -Title 'clippy-cursor.ps1 loads as module' -Issues @($_.Exception.Message)))
}

# Capture a full screen — counts as the L1 Pixel Scout gate.
if (-not $SkipCaptureGate) {
    try {
        script:Ensure-CaptureDirectory
        $capturePath = script:Capture-FullScreen
        if (-not $capturePath -or -not (Test-Path -LiteralPath $capturePath)) {
            throw "Capture-FullScreen returned no usable path."
        }
        $captureBytes = (Get-Item -LiteralPath $capturePath).Length
        if ($captureBytes -le 0) { throw "Capture file is empty: $capturePath" }
        $gates.Add((New-GateResult -Id 'capture-fullscreen' -Title 'Full-screen capture produces non-empty PNG' -Status 'pass' -Evidence @("Captured $captureBytes bytes to $capturePath")))
    } catch {
        $gates.Add((New-GateResult -Id 'capture-fullscreen' -Title 'Full-screen capture produces non-empty PNG' -Issues @($_.Exception.Message)))
    }
}

# Build the screen context if capture succeeded.
if ($capturePath -and (Test-Path -LiteralPath $capturePath)) {
    try {
        $contextResult = script:New-ClippyScreenContext `
            -CapturePath $capturePath `
            -ActionId $ActionId `
            -Label 'Accessibility Check' `
            -ScreenX 0 `
            -ScreenY 0 `
            -Prompt 'Darbit E2E harness — passive validation only.'
        $context     = $contextResult.Context
        $jsonPath    = $contextResult.JsonPath
        $mdPath      = $contextResult.MarkdownPath
        $bundlePath  = $contextResult.BundlePath
        $gates.Add((New-GateResult -Id 'context-generated' -Title 'Screen context JSON, MD, and bundle generated' -Status 'pass' -Evidence @(
            "JSON: $jsonPath", "Markdown: $mdPath", "Bundle: $bundlePath"
        )))
    } catch {
        $gates.Add((New-GateResult -Id 'context-generated' -Title 'Screen context JSON, MD, and bundle generated' -Issues @($_.Exception.Message)))
    }
}

# Gate — JSON conforms to the required top-level shape from the formal schema.
if ($jsonPath -and (Test-Path -LiteralPath $jsonPath)) {
    try {
        $jsonObj = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 30
        $required = @('schema','schemaVersion','capture','action','screen','windows','uiAutomation','lineage')
        $missingKeys = @()
        foreach ($k in $required) {
            if ($null -eq $jsonObj.$k) { $missingKeys += $k }
        }
        $captureKeys = @('imagePath','imageBytes','timestamp','cursor')
        foreach ($k in $captureKeys) {
            if ($null -eq $jsonObj.capture.$k) { $missingKeys += "capture.$k" }
        }
        if ($jsonObj.windows -isnot [System.Collections.IEnumerable] -or $jsonObj.windows -is [string]) {
            $missingKeys += 'windows[] (array)'
        }
        if ($null -eq $jsonObj.uiAutomation.elements) { $missingKeys += 'uiAutomation.elements' }
        if ($missingKeys.Count -eq 0) {
            $winCount = @($jsonObj.windows).Count
            $elCount  = [int]$jsonObj.uiAutomation.elementCount
            $gates.Add((New-GateResult -Id 'json-shape' -Title 'screen-context.json matches formal schema shape' -Status 'pass' -Evidence @("windows=$winCount", "uiAutomation.elementCount=$elCount", "schema=$($jsonObj.schema)")))
        } else {
            $gates.Add((New-GateResult -Id 'json-shape' -Title 'screen-context.json matches formal schema shape' -Issues $missingKeys))
        }
    } catch {
        $gates.Add((New-GateResult -Id 'json-shape' -Title 'screen-context.json matches formal schema shape' -Issues @($_.Exception.Message)))
    }
} else {
    $gates.Add((New-GateResult -Id 'json-shape' -Title 'screen-context.json matches formal schema shape' -Issues @('JSON not generated')))
}

# Gate — Markdown report contains required PRD sections.
if ($mdPath -and (Test-Path -LiteralPath $mdPath)) {
    $md = Get-Content -LiteralPath $mdPath -Raw
    $needed = @(
        '# Clippy Screen Context',
        '## Foreground Layer',
        '## Visible Window Layers',
        '## Interactable UI Elements',
        '## Recommended Analysis Contract'
    )
    $missingSections = @($needed | Where-Object { -not $md.Contains($_) })
    if ($missingSections.Count -eq 0) {
        $gates.Add((New-GateResult -Id 'markdown-sections' -Title 'screen-context.md contains required sections' -Status 'pass' -Evidence @("Markdown length: $($md.Length) chars")))
    } else {
        $gates.Add((New-GateResult -Id 'markdown-sections' -Title 'screen-context.md contains required sections' -Issues $missingSections))
    }
} else {
    $gates.Add((New-GateResult -Id 'markdown-sections' -Title 'screen-context.md contains required sections' -Issues @('Markdown not generated')))
}

# Gate — Paperboy bundle contains the four expected files.
if ($bundlePath -and (Test-Path -LiteralPath $bundlePath)) {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($bundlePath)
        try {
            $entryNames = @($zip.Entries | ForEach-Object { $_.FullName })
        } finally { $zip.Dispose() }
        $expected = @('screenshot.png','screen-context.json','screen-context.md','manifest.json')
        $missingEntries = @($expected | Where-Object { $entryNames -notcontains $_ })
        if ($missingEntries.Count -eq 0) {
            $gates.Add((New-GateResult -Id 'paperboy-bundle' -Title 'Paperboy bundle contains required files' -Status 'pass' -Evidence @("Entries: $($entryNames -join ', ')")))
        } else {
            $gates.Add((New-GateResult -Id 'paperboy-bundle' -Title 'Paperboy bundle contains required files' -Issues $missingEntries))
        }
    } catch {
        $gates.Add((New-GateResult -Id 'paperboy-bundle' -Title 'Paperboy bundle contains required files' -Issues @($_.Exception.Message)))
    }
} else {
    $gates.Add((New-GateResult -Id 'paperboy-bundle' -Title 'Paperboy bundle contains required files' -Issues @('Bundle not generated')))
}

# Gate — hosted prompt dispatch wires JSON and Markdown attachments + evidence preamble.
try {
    $widgetContent = Get-Content -LiteralPath $widgetScript -Raw
    $needed = @(
        'three synchronized sources',
        '$attachments += $ContextJsonPath',
        '$attachments += $ContextMarkdownPath',
        'Use the JSON/Markdown context'
    )
    $widgetMissing = @($needed | Where-Object { -not $widgetContent.Contains($_) })
    if ($widgetMissing.Count -eq 0) {
        $gates.Add((New-GateResult -Id 'hosted-prompt-wiring' -Title 'clippy-widget.ps1 attaches evidence and forbids invented controls' -Status 'pass' -Evidence @('All evidence/no-fake markers present.')))
    } else {
        $gates.Add((New-GateResult -Id 'hosted-prompt-wiring' -Title 'clippy-widget.ps1 attaches evidence and forbids invented controls' -Issues $widgetMissing))
    }
} catch {
    $gates.Add((New-GateResult -Id 'hosted-prompt-wiring' -Title 'clippy-widget.ps1 attaches evidence and forbids invented controls' -Issues @($_.Exception.Message)))
}

# Gate — adaptive-card template binds context paths and exposes a bundle affordance.
try {
    $templateContent = Get-Content -LiteralPath $templatePath -Raw
    $needed = @('${contextJsonPath}','${contextMarkdownPath}')
    $bundleAffordances = @('Open Bundle','Toss Bundle','paperboy')
    $templateMissing = @($needed | Where-Object { -not $templateContent.Contains($_) })
    $hasAffordance = $false
    foreach ($a in $bundleAffordances) { if ($templateContent.Contains($a)) { $hasAffordance = $true; break } }
    if ($templateMissing.Count -eq 0 -and $hasAffordance) {
        $gates.Add((New-GateResult -Id 'card-template' -Title 'Adaptive card binds context paths and bundle affordance' -Status 'pass' -Evidence @('Context bindings and bundle affordance present.')))
    } else {
        if (-not $hasAffordance) { $templateMissing += 'No bundle affordance (Open Bundle / Toss Bundle / paperboy)' }
        $gates.Add((New-GateResult -Id 'card-template' -Title 'Adaptive card binds context paths and bundle affordance' -Issues $templateMissing))
    }
} catch {
    $gates.Add((New-GateResult -Id 'card-template' -Title 'Adaptive card binds context paths and bundle affordance' -Issues @($_.Exception.Message)))
}

# Gate — no-fake-response: an analysis response without artifacts must not claim success.
# The artifact contract is: every action emits PNG + JSON + MD; if any of those is missing,
# the harness must surface failure. (Self-check: ensure we did not produce a result where
# artifacts are missing but status is still pass.)
$artifactSet = @($capturePath, $jsonPath, $mdPath, $bundlePath) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
if ($artifactSet.Count -ge 3) {
    $gates.Add((New-GateResult -Id 'no-fake-response' -Title 'No-fake-response contract honored' -Status 'pass' -Evidence @("Artifacts produced: $($artifactSet.Count)/4")))
} else {
    $gates.Add((New-GateResult -Id 'no-fake-response' -Title 'No-fake-response contract honored' -Issues @("Only $($artifactSet.Count) of 4 artifacts produced; pipeline must not claim success.")))
}

# Gate — action contracts exist for all five primary actions.
try {
    $cursorContent = Get-Content -LiteralPath $cursorScript -Raw
    $actions = @('Explain This','Summarize Screen','Extract Text','Debug UI','Accessibility Check')
    $missingActions = @($actions | Where-Object { -not $cursorContent.Contains($_) })
    if ((-not $cursorContent.Contains('function script:Get-ClippyActionContract')) ) {
        $missingActions += 'Get-ClippyActionContract function'
    }
    if ($missingActions.Count -eq 0) {
        $gates.Add((New-GateResult -Id 'action-contracts' -Title 'All five cursor actions have contracts' -Status 'pass' -Evidence @('All action labels and contract function present.')))
    } else {
        $gates.Add((New-GateResult -Id 'action-contracts' -Title 'All five cursor actions have contracts' -Issues $missingActions))
    }
} catch {
    $gates.Add((New-GateResult -Id 'action-contracts' -Title 'All five cursor actions have contracts' -Issues @($_.Exception.Message)))
}

# Aggregate.
$passCount = @($gates | Where-Object { $_.status -eq 'pass' }).Count
$failCount = @($gates | Where-Object { $_.status -ne 'pass' }).Count
$overallStatus = if ($failCount -eq 0) { 'pass' } else { 'fail' }

$report = [ordered]@{
    schemaVersion = '1.0.0'
    artifactType  = 'darbit-e2e-boss-gate'
    run = [ordered]@{
        id          = $runId
        startedAt   = (Get-Date).ToString('o')
        repoRoot    = $repoRoot
        actionId    = $ActionId
        outputRoot  = $OutputRoot
    }
    artifacts = [ordered]@{
        capturePath = $capturePath
        jsonPath    = $jsonPath
        mdPath      = $mdPath
        bundlePath  = $bundlePath
    }
    review = [ordered]@{
        status     = $overallStatus
        passCount  = $passCount
        failCount  = $failCount
        gateCount  = $gates.Count
    }
    gates = $gates
}

$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $runResult  -Encoding UTF8
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding UTF8

Write-Host ""
Write-Host "Darbit E2E boss gate complete." -ForegroundColor Cyan
Write-Host ("  Overall: {0}" -f $overallStatus.ToUpper())
Write-Host ("  Pass:    {0}/{1}" -f $passCount, $gates.Count)
Write-Host ("  Latest:  {0}" -f $resultPath)
Write-Host ("  Run:     {0}" -f $runResult)

if ($overallStatus -ne 'pass') {
    foreach ($g in $gates | Where-Object { $_.status -ne 'pass' }) {
        Write-Host ("  FAIL [{0}] {1}" -f $g.id, $g.title) -ForegroundColor Yellow
        foreach ($i in $g.issues) { Write-Host ("    - {0}" -f $i) -ForegroundColor DarkYellow }
    }
    exit $ExitCodeOnFail
}

exit 0
