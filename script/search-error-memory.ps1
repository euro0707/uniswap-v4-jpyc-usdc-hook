<#
.SYNOPSIS
Searches error notes in the Obsidian knowledge base before coding.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\script\search-error-memory.ps1 -Query "forge test revert"
#>

[CmdletBinding()]
param(
    [string]$Query = "",

    [string]$Fingerprint = "",

    [string]$VaultRoot = "C:\Users\skyeu\obsidian\TetsuyaSynapse\90-Claude",

    [string[]]$Targets = @(
        "reflections\build",
        "learnings"
    ),

    [int]$MaxResults = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $VaultRoot)) {
    throw "Vault path not found: $VaultRoot"
}

$files = foreach ($target in $Targets) {
    $targetPath = Join-Path $VaultRoot $target
    if (Test-Path -LiteralPath $targetPath) {
        Get-ChildItem -LiteralPath $targetPath -File -Recurse -Filter *.md -ErrorAction SilentlyContinue
    }
}

if (-not $files) {
    throw "No markdown files found under targets: $($Targets -join ', ')"
}

function Get-SearchTerms {
    param(
        [string]$RawQuery,
        [string]$RawFingerprint
    )

    $terms = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($RawQuery)) {
        $queryTokens = $RawQuery -split '[,\s]+' | Where-Object { $_.Trim().Length -ge 2 }
        foreach ($t in $queryTokens) {
            $terms.Add($t.Trim())
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($RawFingerprint)) {
        $fpTokens = $RawFingerprint -split '[|,\s]+' | Where-Object { $_.Trim().Length -ge 2 }
        foreach ($t in $fpTokens) {
            $clean = $t.Trim()
            $terms.Add($clean)
            if ($clean.Contains(":")) {
                $value = $clean.Split(":", 2)[1]
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $terms.Add($value)
                }
            }
        }
    }

    $unique = $terms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    return @($unique)
}

$searchTerms = @(Get-SearchTerms -RawQuery $Query -RawFingerprint $Fingerprint)
if (-not $searchTerms -or $searchTerms.Count -eq 0) {
    throw "Provide -Query or -Fingerprint."
}

$matches = $files | Select-String -Pattern $searchTerms -SimpleMatch -CaseSensitive:$false

if (-not $matches) {
    Write-Output "No matches found."
    exit 0
}

$matches |
    Select-Object -First $MaxResults |
    ForEach-Object {
        $lineText = $_.Line.Trim()
        if ($lineText.Length -gt 140) {
            $lineText = $lineText.Substring(0, 137) + "..."
        }
        [PSCustomObject]@{
            File = $_.Path
            Line = $_.LineNumber
            Match = $_.Pattern
            Text = $lineText
        }
    } |
    Format-Table -AutoSize -Wrap
