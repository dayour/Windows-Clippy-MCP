[CmdletBinding()]
param(
    [Alias('cd')]
    [string]$CardDeckPath = (Join-Path $PSScriptRoot 'adaptive-cards\darbit-agent-card-deck.json'),

    [Alias('cdg')]
    [string]$GameOutputPath,

    [string]$OutputRoot = (Join-Path $env:APPDATA 'Windows-Clippy-MCP\darbit-card-deck-game'),

    [ValidateSet('None', 'A', 'B', 'C', 'D')]
    [string]$FailBelowGrade = 'None',

    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
    $root = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
    return $root.ProviderPath
}

function Resolve-RepoPath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $RepoRoot $Path)
}

function Get-RelativeRepoPath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path
    )

    try {
        return [System.IO.Path]::GetRelativePath($RepoRoot, $Path)
    } catch {
        return $Path
    }
}

function Get-JsonPropertyValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$PropertyPath
    )

    $current = $InputObject
    foreach ($segment in $PropertyPath -split '\.') {
        if ($null -eq $current) {
            return $null
        }

        if ($current -is [System.Collections.IDictionary]) {
            $current = $current[$segment]
            continue
        }

        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return $null
        }

        $current = $property.Value
    }

    return $current
}

function Test-DeckCheck {
    param(
        [Parameter(Mandatory)]$Check,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $title = if ($Check.title) { [string]$Check.title } else { [string]$Check.id }
    $result = [ordered]@{
        id = [string]$Check.id
        title = $title
        kind = [string]$Check.kind
        status = 'fail'
        score = 0.0
        evidence = @()
        missing = @()
        errors = @()
    }

    try {
        switch ([string]$Check.kind) {
            'fileExists' {
                $absolutePath = Resolve-RepoPath -RepoRoot $RepoRoot -Path ([string]$Check.path)
                if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
                    $item = Get-Item -LiteralPath $absolutePath
                    $result.status = 'pass'
                    $result.score = 1.0
                    $result.evidence = @("Found file: $(Get-RelativeRepoPath -RepoRoot $RepoRoot -Path $item.FullName)")
                } else {
                    $result.missing = @("Missing file: $($Check.path)")
                }
            }
            'fileContains' {
                $absolutePath = Resolve-RepoPath -RepoRoot $RepoRoot -Path ([string]$Check.path)
                if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
                    $result.missing = @("Missing file: $($Check.path)")
                    break
                }

                $content = Get-Content -LiteralPath $absolutePath -Raw
                $required = @()
                if ($Check.allOf) { $required += @($Check.allOf) }
                if ($Check.contains) { $required += @($Check.contains) }
                $alternatives = @()
                if ($Check.anyOf) { $alternatives += @($Check.anyOf) }

                $missing = @()
                foreach ($needle in $required) {
                    if ($content.Contains([string]$needle)) {
                        $result.evidence += "Matched required text: $needle"
                    } else {
                        $missing += "Missing required text: $needle"
                    }
                }

                $alternativeMatched = $true
                if ($alternatives.Count -gt 0) {
                    $alternativeMatched = $false
                    foreach ($needle in $alternatives) {
                        if ($content.Contains([string]$needle)) {
                            $alternativeMatched = $true
                            $result.evidence += "Matched alternative text: $needle"
                            break
                        }
                    }
                    if (-not $alternativeMatched) {
                        $missing += "Missing one of: $($alternatives -join ', ')"
                    }
                }

                if ($missing.Count -eq 0) {
                    $result.status = 'pass'
                    $result.score = 1.0
                } else {
                    $total = [Math]::Max(1, $required.Count + [Math]::Min(1, $alternatives.Count))
                    $passed = $total - $missing.Count
                    $result.status = if ($passed -gt 0) { 'partial' } else { 'fail' }
                    $result.score = [Math]::Max(0.0, [Math]::Round($passed / $total, 4))
                    $result.missing = $missing
                }
            }
            'jsonRequiredKeys' {
                $absolutePath = Resolve-RepoPath -RepoRoot $RepoRoot -Path ([string]$Check.path)
                if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
                    $result.missing = @("Missing JSON file: $($Check.path)")
                    break
                }

                $json = Get-Content -LiteralPath $absolutePath -Raw | ConvertFrom-Json
                $missing = @()
                foreach ($key in @($Check.requiredKeys)) {
                    if ($null -ne (Get-JsonPropertyValue -InputObject $json -PropertyPath ([string]$key))) {
                        $result.evidence += "Found JSON key: $key"
                    } else {
                        $missing += "Missing JSON key: $key"
                    }
                }

                if ($missing.Count -eq 0) {
                    $result.status = 'pass'
                    $result.score = 1.0
                } else {
                    $total = [Math]::Max(1, @($Check.requiredKeys).Count)
                    $passed = $total - $missing.Count
                    $result.status = if ($passed -gt 0) { 'partial' } else { 'fail' }
                    $result.score = [Math]::Max(0.0, [Math]::Round($passed / $total, 4))
                    $result.missing = $missing
                }
            }
            'jsonArrayMin' {
                $absolutePath = Resolve-RepoPath -RepoRoot $RepoRoot -Path ([string]$Check.path)
                if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
                    $result.missing = @("Missing JSON file: $($Check.path)")
                    break
                }

                $json = Get-Content -LiteralPath $absolutePath -Raw | ConvertFrom-Json
                $value = Get-JsonPropertyValue -InputObject $json -PropertyPath ([string]$Check.propertyPath)
                $count = @($value).Count
                $minimum = [int]$Check.minimum
                if ($count -ge $minimum) {
                    $result.status = 'pass'
                    $result.score = 1.0
                    $result.evidence = @("JSON array '$($Check.propertyPath)' contains $count item(s); minimum is $minimum.")
                } else {
                    $result.missing = @("JSON array '$($Check.propertyPath)' contains $count item(s); minimum is $minimum.")
                }
            }
            default {
                throw "Unsupported deck check kind: $($Check.kind)"
            }
        }
    } catch {
        $result.status = 'error'
        $result.score = 0.0
        $result.errors = @($_.Exception.Message)
    }

    return [pscustomobject]$result
}

function Get-Grade {
    param(
        [Parameter(Mandatory)]$GradeScale,
        [Parameter(Mandatory)][double]$Percent
    )

    foreach ($entry in @($GradeScale | Sort-Object -Property minimumPercent -Descending)) {
        if ($Percent -ge [double]$entry.minimumPercent) {
            return [string]$entry.grade
        }
    }

    return 'F'
}

function New-CdgMarkdown {
    param(
        [Parameter(Mandatory)]$Game
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Darbit Card Deck Game Review")
    $lines.Add("")
    $lines.Add(("- **Deck:** {0}" -f $Game.deck.name))
    $lines.Add(("- **Run ID:** {0}" -f $Game.run.id))
    $lines.Add(("- **Started:** {0}" -f $Game.run.startedAt))
    $lines.Add(("- **Grade:** {0} ({1}%)" -f $Game.review.grade, $Game.review.percent))
    $lines.Add(("- **XP:** {0}/{1}" -f $Game.review.earnedXp, $Game.review.totalXp))
    $lines.Add(("- **Status:** {0}" -f $Game.review.status))
    $lines.Add("")
    $lines.Add("## Review")
    $lines.Add("")
    foreach ($note in @($Game.review.notes)) {
        $lines.Add(("- {0}" -f $note))
    }
    $lines.Add("")
    $lines.Add("## Quest grades")
    $lines.Add("")
    $lines.Add("| Level | Quest | Badge | Status | Score | XP | Review |")
    $lines.Add("|---:|---|---|---|---:|---:|---|")
    foreach ($card in @($Game.cards)) {
        $summary = $card.reviewSummary -replace '\|', '/'
        $lines.Add(("| {0} | {1} | {2} | {3} | {4}% | {5}/{6} | {7} |" -f $card.level, $card.quest, $card.badge, $card.status, $card.percent, $card.earnedXp, $card.xp, $summary))
    }
    $lines.Add("")
    $lines.Add("## Failed or partial checks")
    $lines.Add("")
    $hasFindings = $false
    foreach ($card in @($Game.cards)) {
        $findings = @($card.checks | Where-Object { $_.status -ne 'pass' })
        if ($findings.Count -eq 0) {
            continue
        }

        $hasFindings = $true
        $lines.Add(("### Level {0}: {1}" -f $card.level, $card.quest))
        $lines.Add("")
        foreach ($finding in $findings) {
            $lines.Add(("- **{0}** [{1}]" -f $finding.title, $finding.status))
            foreach ($missing in @($finding.missing)) {
                $lines.Add(("  - {0}" -f $missing))
            }
            foreach ($error in @($finding.errors)) {
                $lines.Add(("  - Error: {0}" -f $error))
            }
        }
        $lines.Add("")
    }

    if (-not $hasFindings) {
        $lines.Add("No failed or partial checks. The game is complete.")
        $lines.Add("")
    }

    $lines.Add("## Output artifacts")
    $lines.Add("")
    $lines.Add(('- CD JSON: `{0}`' -f $Game.outputs.cardDeckJson))
    $lines.Add(('- CDG JSON: `{0}`' -f $Game.outputs.gameJson))
    $lines.Add(('- CDG Markdown: `{0}`' -f $Game.outputs.gameMarkdown))
    $lines.Add("")

    return ($lines -join "`n")
}

$repoRoot = Resolve-RepoRoot
$resolvedDeckPath = Resolve-RepoPath -RepoRoot $repoRoot -Path $CardDeckPath
if (-not (Test-Path -LiteralPath $resolvedDeckPath -PathType Leaf)) {
    throw "Card deck not found: $resolvedDeckPath"
}

$deck = Get-Content -LiteralPath $resolvedDeckPath -Raw | ConvertFrom-Json
if ([string]$deck.artifactType -ne 'darbit-agent-card-deck') {
    throw "Unsupported card deck artifactType '$($deck.artifactType)'. Expected 'darbit-agent-card-deck'."
}

if (-not $deck.cards -or @($deck.cards).Count -eq 0) {
    throw "Card deck has no cards: $resolvedDeckPath"
}

$outputDirectory = if ($GameOutputPath) {
    $parent = Split-Path -Parent $GameOutputPath
    if ([string]::IsNullOrWhiteSpace($parent)) { $OutputRoot } else { $parent }
} else {
    $OutputRoot
}

if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$runId = 'darbit-cdg-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
$gameJsonPath = if ($GameOutputPath) { $GameOutputPath } else { Join-Path $outputDirectory "$runId.cdg.json" }
$gameMarkdownPath = if ($GameOutputPath) {
    $jsonSuffix = '.json'
    if ($gameJsonPath.EndsWith($jsonSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $gameJsonPath.Substring(0, $gameJsonPath.Length - $jsonSuffix.Length) + '.md'
    } else {
        "$gameJsonPath.md"
    }
} else {
    Join-Path $outputDirectory "$runId.cdg.md"
}
$cardDeckJsonPath = Join-Path $outputDirectory "$runId.cd.json"
$startedAt = (Get-Date).ToString('o')

$cardResults = @()
foreach ($card in @($deck.cards | Sort-Object -Property level)) {
    $checkResults = @()
    foreach ($check in @($card.checks)) {
        $checkResults += Test-DeckCheck -Check $check -RepoRoot $repoRoot
    }

    $checkCount = [Math]::Max(1, $checkResults.Count)
    $score = ($checkResults | Measure-Object -Property score -Sum).Sum / $checkCount
    $percent = [Math]::Round($score * 100, 2)
    $earnedXp = [int][Math]::Floor([int]$card.xp * $score)
    $status = if ($checkResults.Count -eq @($checkResults | Where-Object { $_.status -eq 'pass' }).Count) {
        'pass'
    } elseif (@($checkResults | Where-Object { $_.status -in @('partial', 'pass') }).Count -gt 0) {
        'partial'
    } else {
        'fail'
    }
    $failedCount = @($checkResults | Where-Object { $_.status -ne 'pass' }).Count
    $reviewSummary = if ($failedCount -eq 0) {
        'Exit gate passed.'
    } else {
        "$failedCount check(s) need implementation or evidence."
    }

    $cardResults += [pscustomobject][ordered]@{
        id = [string]$card.id
        level = [int]$card.level
        quest = [string]$card.quest
        badge = [string]$card.badge
        objective = [string]$card.objective
        status = $status
        percent = $percent
        xp = [int]$card.xp
        earnedXp = $earnedXp
        reviewSummary = $reviewSummary
        checks = $checkResults
    }
}

$totalXp = ($deck.cards | Measure-Object -Property xp -Sum).Sum
$earnedXp = ($cardResults | Measure-Object -Property earnedXp -Sum).Sum
$overallPercent = if ($totalXp -gt 0) { [Math]::Round(($earnedXp / $totalXp) * 100, 2) } else { 0.0 }
$grade = Get-Grade -GradeScale $deck.gradeScale -Percent $overallPercent
$passCount = @($cardResults | Where-Object { $_.status -eq 'pass' }).Count
$partialCount = @($cardResults | Where-Object { $_.status -eq 'partial' }).Count
$failCount = @($cardResults | Where-Object { $_.status -eq 'fail' }).Count
$reviewStatus = if ($failCount -eq 0 -and $partialCount -eq 0) { 'complete' } elseif ($passCount -gt 0) { 'review-required' } else { 'blocked' }
$reviewNotes = @(
    "Reviewed $($cardResults.Count) card(s) from the CD.",
    "Passed: $passCount. Partial: $partialCount. Failed: $failCount.",
    "Grade is calculated from earned XP and check evidence, not manual assertion."
)
if ($reviewStatus -ne 'complete') {
    $reviewNotes += 'CDG is generated and graded, but the game is not fully complete until failed and partial checks pass.'
} else {
    $reviewNotes += 'All exit gates passed. The CDG is complete.'
}

$deckSnapshot = [ordered]@{
    schemaVersion = [string]$deck.schemaVersion
    artifactType = [string]$deck.artifactType
    shortName = [string]$deck.shortName
    name = [string]$deck.name
    sourcePath = $resolvedDeckPath
    capturedAt = $startedAt
    cards = $deck.cards
}
$deckSnapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $cardDeckJsonPath -Encoding UTF8

$game = [pscustomobject][ordered]@{
    schemaVersion = '1.0.0'
    artifactType = 'darbit-card-deck-game'
    shortName = 'cdg'
    run = [ordered]@{
        id = $runId
        startedAt = $startedAt
        completedAt = (Get-Date).ToString('o')
        repoRoot = $repoRoot
    }
    deck = [ordered]@{
        name = [string]$deck.name
        shortName = [string]$deck.shortName
        sourcePath = $resolvedDeckPath
        cardDeckJson = $cardDeckJsonPath
    }
    review = [ordered]@{
        status = $reviewStatus
        grade = $grade
        percent = $overallPercent
        totalXp = [int]$totalXp
        earnedXp = [int]$earnedXp
        passCount = $passCount
        partialCount = $partialCount
        failCount = $failCount
        notes = $reviewNotes
    }
    cards = $cardResults
    outputs = [ordered]@{
        cardDeckJson = $cardDeckJsonPath
        gameJson = $gameJsonPath
        gameMarkdown = $gameMarkdownPath
    }
}

$game | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $gameJsonPath -Encoding UTF8
New-CdgMarkdown -Game $game | Set-Content -LiteralPath $gameMarkdownPath -Encoding UTF8

Write-Host "Darbit CDG reviewed and graded." -ForegroundColor Cyan
Write-Host "Grade: $grade ($overallPercent%)"
Write-Host "XP: $earnedXp / $totalXp"
Write-Host "Status: $reviewStatus"
Write-Host "CD: $cardDeckJsonPath"
Write-Host "CDG: $gameJsonPath"
Write-Host "Review: $gameMarkdownPath"

if ($OpenReport) {
    Invoke-Item -LiteralPath $gameMarkdownPath
}

if ($FailBelowGrade -ne 'None') {
    $minimumPercentByGrade = @{
        A = 90.0
        B = 80.0
        C = 70.0
        D = 60.0
    }
    if ($overallPercent -lt [double]$minimumPercentByGrade[$FailBelowGrade]) {
        exit 2
    }
}
