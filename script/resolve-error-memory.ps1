<#
.SYNOPSIS
Marks an error note as resolved with minimal input.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\script\resolve-error-memory.ps1 `
  -NotePath "C:\Users\skyeu\obsidian\TetsuyaSynapse\90-Claude\reflections\build\2026-02-17_x.md" `
  -Resolution "Fixed by updating test setup."

.EXAMPLE
# Resolve the most recently updated unresolved note
powershell -NoProfile -ExecutionPolicy Bypass -File .\script\resolve-error-memory.ps1 `
  -Resolution "fixed"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$NotePath = "",

    [string]$Resolution = "fixed",

    [string]$VaultRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$defaultVaultRoot = "C:\Users\skyeu\obsidian\TetsuyaSynapse\90-Claude"
$repoRoot = Split-Path -Path $PSScriptRoot -Parent

function Get-CandidateRoots {
    param(
        [string]$RequestedRoot,
        [string]$DefaultRoot,
        [string]$LocalRoot
    )

    $roots = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $roots.Add($RequestedRoot.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_ERROR_MEMORY_VAULT)) {
        $roots.Add($env:CODEX_ERROR_MEMORY_VAULT.Trim())
    }

    $roots.Add($DefaultRoot)
    $roots.Add($LocalRoot)

    return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-LatestUnresolvedNote {
    param([string[]]$Roots)

    $candidates = foreach ($root in $Roots) {
        $dir = Join-Path $root "reflections\build"
        if (Test-Path -LiteralPath $dir) {
            Get-ChildItem -LiteralPath $dir -File -Filter *.md -Recurse |
                Where-Object {
                    $_.FullName -notmatch "\\reflections\\build\\auto\\" -and
                    $_.Name -ne "_template.md"
                }
        }
    }

    foreach ($file in ($candidates | Sort-Object LastWriteTime -Descending)) {
        $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ($raw -match "(?m)^resolved:\s*false\s*$") {
            return $file.FullName
        }
    }

    return ""
}

function Add-ResolutionEntry {
    param(
        [string]$Text,
        [string]$EntryLine
    )

    $lineEnding = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        $lines.Add($line)
    }

    $headingIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^## Resolution\s*$") {
            $headingIndex = $i
            break
        }
    }

    if ($headingIndex -ge 0) {
        $insertIndex = $lines.Count
        for ($j = $headingIndex + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match "^##\s+") {
                $insertIndex = $j
                break
            }
        }

        $lines.Insert($insertIndex, $EntryLine)

        if ($insertIndex + 1 -lt $lines.Count -and $lines[$insertIndex + 1] -match "^##\s+") {
            $lines.Insert($insertIndex + 1, "")
        }

        $updated = [string]::Join($lineEnding, $lines)
        if (-not $updated.EndsWith($lineEnding)) {
            $updated += $lineEnding
        }
        return $updated
    }

    $trimmed = $Text.TrimEnd("`r", "`n")
    return $trimmed + $lineEnding + $lineEnding + "## Resolution" + $lineEnding + $EntryLine + $lineEnding
}

$candidateRoots = @(Get-CandidateRoots -RequestedRoot $VaultRoot -DefaultRoot $defaultVaultRoot -LocalRoot $repoRoot)
$existingRoots = @($candidateRoots | Where-Object { Test-Path -LiteralPath $_ })

if ([string]::IsNullOrWhiteSpace($NotePath)) {
    $NotePath = Get-LatestUnresolvedNote -Roots $existingRoots
    if ([string]::IsNullOrWhiteSpace($NotePath)) {
        throw "No unresolved note found in configured roots."
    }
}

if (-not (Test-Path -LiteralPath $NotePath)) {
    throw "Note file not found: $NotePath"
}

$raw = Get-Content -LiteralPath $NotePath -Raw -Encoding UTF8
$resolvedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

if ($raw -match "(?m)^resolved:\s*(true|false)\s*$") {
    $raw = [regex]::Replace($raw, "(?m)^resolved:\s*(true|false)\s*$", "resolved: true", 1)
}
else {
    if ($raw -match "(?m)^type:\s*.+$") {
        $raw = [regex]::Replace($raw, "(?m)^type:\s*.+$", '$0' + [Environment]::NewLine + "resolved: true", 1)
    }
    else {
        $raw = "resolved: true" + [Environment]::NewLine + $raw
    }
}

if ($raw -match "(?m)^resolved_at:\s*.+$") {
    $raw = [regex]::Replace($raw, "(?m)^resolved_at:\s*.+$", "resolved_at: `"$resolvedAt`"", 1)
}
else {
    if ($raw -match "(?m)^resolved:\s*true\s*$") {
        $raw = [regex]::Replace($raw, "(?m)^resolved:\s*true\s*$", 'resolved: true' + [Environment]::NewLine + "resolved_at: `"$resolvedAt`"", 1)
    }
    else {
        $raw = "resolved_at: `"$resolvedAt`"" + [Environment]::NewLine + $raw
    }
}

$line = "- [$resolvedAt] $Resolution"
$raw = Add-ResolutionEntry -Text $raw -EntryLine $line

if ($PSCmdlet.ShouldProcess($NotePath, "Mark error note as resolved")) {
    Set-Content -LiteralPath $NotePath -Value $raw -Encoding UTF8
    Write-Output "Resolved: $NotePath"
}
