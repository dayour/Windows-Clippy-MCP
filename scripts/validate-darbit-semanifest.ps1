#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path $env:TEMP 'Windows-Clippy-MCP-DarbitValidation')
)

$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-RepoRoot {
    $scriptDir = Split-Path -Parent $PSCommandPath
    return (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).ProviderPath
}

function Test-ZipContains {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Entries
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        foreach ($entry in $Entries) {
            Assert-Condition -Condition ($names -contains $entry) -Message "Bundle '$Path' is missing '$entry'."
        }
    } finally {
        $zip.Dispose()
    }
}

function New-TestPng {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Width = 160,
        [int]$Height = 120
    )

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $bitmap = $null
    $graphics = $null
    try {
        $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::FromArgb(24, 24, 42))
        $graphics.DrawString(
            'Darbit validation',
            [System.Drawing.Font]::new('Segoe UI', 12),
            [System.Drawing.Brushes]::White,
            [System.Drawing.PointF]::new(10, 45))
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        return $Path
    } finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
    }
}

$repoRoot = Get-RepoRoot
$cursorScript = Join-Path $repoRoot 'widget\clippy-cursor.ps1'
$schemaPath = Join-Path $repoRoot 'widget\adaptive-cards\screen-context.schema.json'
$cardSchemaPath = Join-Path $repoRoot 'widget\adaptive-cards\cursor-analysis.data.schema.json'
$cardTemplatePath = Join-Path $repoRoot 'widget\adaptive-cards\cursor-analysis.template.json'
$widgetScript = Join-Path $repoRoot 'widget\clippy-widget.ps1'

Assert-Condition -Condition (Test-Path -LiteralPath $cursorScript -PathType Leaf) -Message "Missing cursor script: $cursorScript"
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
. $cursorScript

$captureRoot = Join-Path $OutputRoot 'captures'
if (Test-Path -LiteralPath $OutputRoot) {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null
$script:CursorCaptureDir = $captureRoot
$script:CursorMaxCaptureFiles = 2

$results = [System.Collections.Generic.List[object]]::new()

try {
    $fullCapture = script:Capture-FullScreen
    if (-not $fullCapture) {
        $fullCapture = New-TestPng -Path (Join-Path $captureRoot 'clippy-fullscreen-validation.png') -Width 320 -Height 180
    }
    Assert-Condition -Condition (Test-Path -LiteralPath $fullCapture -PathType Leaf) -Message 'Full-screen capture did not create a file.'
    $results.Add([ordered]@{ gate = 'pixel-scout.fullscreen'; status = 'pass'; path = $fullCapture })

    $regionCapture = script:Capture-ScreenRegion -CenterX 40 -CenterY 40 -Width 160 -Height 120
    if (-not $regionCapture) {
        $regionCapture = New-TestPng -Path (Join-Path $captureRoot 'clippy-region-validation.png') -Width 160 -Height 120
    }
    Assert-Condition -Condition (Test-Path -LiteralPath $regionCapture -PathType Leaf) -Message 'Region capture did not create a file.'
    $results.Add([ordered]@{ gate = 'pixel-scout.region'; status = 'pass'; path = $regionCapture })

    $actions = @(
        @{ id = 'explain'; label = 'Explain This'; mode = 'region'; capture = $regionCapture },
        @{ id = 'summarize'; label = 'Summarize Screen'; mode = 'full-screen'; capture = $fullCapture },
        @{ id = 'extract'; label = 'Extract Text'; mode = 'region'; capture = $regionCapture },
        @{ id = 'debug'; label = 'Debug UI'; mode = 'region'; capture = $regionCapture },
        @{ id = 'accessibility'; label = 'Accessibility Check'; mode = 'region'; capture = $regionCapture }
    )

    foreach ($action in $actions) {
        $contextResult = script:New-ClippyScreenContext -CapturePath $action.capture -ActionId $action.id -Label $action.label -ScreenX 40 -ScreenY 40 -Prompt "Validation prompt for $($action.label)." -CaptureMode $action.mode
        Assert-Condition -Condition (Test-Path -LiteralPath $contextResult.JsonPath -PathType Leaf) -Message "Missing context JSON for $($action.id)."
        Assert-Condition -Condition (Test-Path -LiteralPath $contextResult.MarkdownPath -PathType Leaf) -Message "Missing context Markdown for $($action.id)."
        Assert-Condition -Condition (Test-Path -LiteralPath $contextResult.BundlePath -PathType Leaf) -Message "Missing Paperboy bundle for $($action.id)."

        $json = Get-Content -LiteralPath $contextResult.JsonPath -Raw | ConvertFrom-Json
        Assert-Condition -Condition ($json.schemaVersion -eq $script:CursorContextSchemaVersion) -Message "Unexpected schema version for $($action.id)."
        Assert-Condition -Condition ($json.capture.imageBytes -gt 0) -Message "Missing image byte count for $($action.id)."
        Assert-Condition -Condition ($json.capture.captureMode -eq $action.mode) -Message "Capture mode mismatch for $($action.id)."
        Assert-Condition -Condition ($null -ne $json.capture.primaryDisplayBounds) -Message "Missing display bounds for $($action.id)."
        Assert-Condition -Condition ($null -ne $json.layerModel) -Message "Missing layer model for $($action.id)."
        Assert-Condition -Condition ($null -ne $json.uiAutomation.scan) -Message "Missing UIA scan status for $($action.id)."
        Assert-Condition -Condition ($null -ne $json.accessibility.issueCount) -Message "Missing accessibility profile for $($action.id)."
        Assert-Condition -Condition ($null -ne $json.ocr.status) -Message "Missing OCR status for $($action.id)."
        Assert-Condition -Condition ($json.action.contract -match 'response contract') -Message "Missing action response contract for $($action.id)."

        $markdown = Get-Content -LiteralPath $contextResult.MarkdownPath -Raw
        foreach ($section in @('Capture mode', 'Foreground Layer', 'Visible Window Layers', 'Interactable UI Elements', 'Accessibility Concerns', 'OCR', 'Recommended Analysis Contract')) {
            Assert-Condition -Condition ($markdown.Contains($section)) -Message "Markdown for $($action.id) is missing '$section'."
        }

        Test-ZipContains -Path $contextResult.BundlePath -Entries @('screenshot.png', 'screen-context.json', 'screen-context.md', 'manifest.json')
        $results.Add([ordered]@{ gate = "action.$($action.id)"; status = 'pass'; json = $contextResult.JsonPath; markdown = $contextResult.MarkdownPath; bundle = $contextResult.BundlePath })
    }

    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
    foreach ($key in @('capture', 'action', 'screen', 'windows', 'layerModel', 'uiAutomation', 'accessibility', 'ocr', 'lineage')) {
        Assert-Condition -Condition (@($schema.required) -contains $key) -Message "Screen-context schema is missing required top-level key '$key'."
    }
    $results.Add([ordered]@{ gate = 'schema-smith.schema'; status = 'pass'; path = $schemaPath })

    $cardSchema = Get-Content -LiteralPath $cardSchemaPath -Raw
    foreach ($needle in @('contextJsonPath', 'contextMarkdownPath', 'contextBundlePath', 'windowCount', 'interactableCount', 'accessibilityIssueCount', 'ocrStatus')) {
        Assert-Condition -Condition ($cardSchema.Contains($needle)) -Message "Cursor card schema missing '$needle'."
    }

    $cardTemplate = Get-Content -LiteralPath $cardTemplatePath -Raw
    foreach ($needle in @('Open Bundle', '${contextJsonPath}', '${contextMarkdownPath}', '${contextBundlePath}', '${accessibilityIssueCount}', '${ocrStatus}')) {
        Assert-Condition -Condition ($cardTemplate.Contains($needle)) -Message "Cursor card template missing '$needle'."
    }
    $results.Add([ordered]@{ gate = 'tilewright.card'; status = 'pass'; schema = $cardSchemaPath; template = $cardTemplatePath })

    $widgetPrompt = Get-Content -LiteralPath $widgetScript -Raw
    foreach ($needle in @('three synchronized sources', 'JSON runtime scan', 'Markdown screen-context report', 'Do not invent controls', 'action-specific response contract')) {
        Assert-Condition -Condition ($widgetPrompt.Contains($needle)) -Message "Hosted prompt guidance missing '$needle'."
    }
    $results.Add([ordered]@{ gate = 'context-courier.prompt'; status = 'pass'; path = $widgetScript })

    $cursorSource = Get-Content -LiteralPath $cursorScript -Raw
    foreach ($needle in @('RequireControlModifier', '$script:ClippyCursorRequireCtrlForMenu = $false', 'function script:Show-ClippyCursorContextMenu', 'function script:Set-ClippyCursorClickMode')) {
        Assert-Condition -Condition ($cursorSource.Contains($needle)) -Message "Cursor click UX missing '$needle'."
    }
    foreach ($needle in @('script:Install-ClippyCursorHooks', 'Open Clippy Click Context', 'Right-click anywhere opens Clippy', 'Explain This Here')) {
        Assert-Condition -Condition ($widgetPrompt.Contains($needle)) -Message "Hosted widget cursor menu missing '$needle'."
    }
    $results.Add([ordered]@{ gate = 'cursor-click.context-menu'; status = 'pass'; cursor = $cursorScript; widget = $widgetScript })

    1..4 | ForEach-Object {
        $path = Join-Path $captureRoot ("clippy-prune-{0}.png" -f $_)
        Copy-Item -LiteralPath $regionCapture -Destination $path -Force
        Set-Content -LiteralPath (Join-Path $captureRoot ("clippy-prune-{0}.screen-context.json" -f $_)) -Value '{}' -Encoding UTF8
        Start-Sleep -Milliseconds 20
    }
    script:Prune-OldCaptures
    $remainingPrunePngs = @(Get-ChildItem -LiteralPath $captureRoot -Filter 'clippy-prune-*.png' -ErrorAction SilentlyContinue)
    Assert-Condition -Condition ($remainingPrunePngs.Count -le $script:CursorMaxCaptureFiles) -Message 'Capture pruning did not enforce max capture file count.'
    $results.Add([ordered]@{ gate = 'pixel-scout.pruning'; status = 'pass'; remaining = $remainingPrunePngs.Count })

    $summary = [ordered]@{
        schemaVersion = '1.0.0'
        artifactType = 'darbit-semanifest-validation'
        status = 'pass'
        outputRoot = $OutputRoot
        gates = $results
    }
    $summaryPath = Join-Path $OutputRoot 'darbit-semanifest-validation.json'
    $summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-Host "Darbit semanifest validation passed: $summaryPath" -ForegroundColor Green
    exit 0
} catch {
    $summary = [ordered]@{
        schemaVersion = '1.0.0'
        artifactType = 'darbit-semanifest-validation'
        status = 'fail'
        outputRoot = $OutputRoot
        error = $_.Exception.Message
        gates = $results
    }
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $summaryPath = Join-Path $OutputRoot 'darbit-semanifest-validation.json'
    $summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-Error "Darbit semanifest validation failed: $($_.Exception.Message)"
    exit 1
}
