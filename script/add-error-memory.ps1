<#
.SYNOPSIS
Creates a new error note in Obsidian based on the existing reflection template.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\script\add-error-memory.ps1 `
  -Title "forge test revert: Price deviation too high" `
  -ErrorMessage "PriceDeviationTooHigh()" `
  -Cause "stale observation window" `
  -Fix "refresh observations before swap" `
  -Learning "run a pre-swap observation update in tests"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [string]$ErrorMessage,

    [Parameter(Mandatory = $true)]
    [string]$Cause,

    [Parameter(Mandatory = $true)]
    [string]$Fix,

    [Parameter(Mandatory = $true)]
    [string]$Learning,

    [string]$Fingerprint = "",

    [string]$Framework = "-",

    [string]$Similar = "",

    [bool]$Resolved = $false,

    [string]$VaultRoot = "C:\Users\skyeu\obsidian\TetsuyaSynapse\90-Claude"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-Slug {
    param([string]$Value)
    $slug = $Value.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    $slug = $slug.Trim("-")
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return "error-note"
    }
    return $slug
}

function ConvertTo-BulletLines {
    param([string]$Text)
    $lines = $Text -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not $lines) {
        return "- "
    }
    return ($lines | ForEach-Object { "- $($_.Trim())" }) -join [Environment]::NewLine
}

function Escape-YamlDoubleQuoted {
    param([string]$Text)
    if ($null -eq $Text) {
        return ""
    }

    $escaped = $Text -replace "\\", "\\\\"
    $escaped = $escaped -replace '"', '\"'
    $escaped = $escaped -replace "(`r`n|`n|`r)", " "
    return $escaped
}

if (-not (Test-Path -LiteralPath $VaultRoot)) {
    throw "Vault path not found: $VaultRoot"
}

$targetDir = Join-Path $VaultRoot "reflections\build"
if (-not (Test-Path -LiteralPath $targetDir)) {
    throw "Target directory not found: $targetDir"
}

$today = Get-Date -Format "yyyy-MM-dd"
$slug = ConvertTo-Slug -Value $Title
$fileName = "$today" + "_" + "$slug.md"
$targetPath = Join-Path $targetDir $fileName

if (Test-Path -LiteralPath $targetPath) {
    $targetPath = Join-Path $targetDir ("{0}_{1}_{2}.md" -f $today, $slug, (Get-Date -Format "HHmmss"))
}

$similarText = if ([string]::IsNullOrWhiteSpace($Similar)) { "[[]]" } else { "[[$Similar]]" }
$resolvedText = if ($Resolved) { "true" } else { "false" }
$fingerprintText = if ([string]::IsNullOrWhiteSpace($Fingerprint)) { "(pending)" } else { $Fingerprint }

$content = @"
---
date: $today
domain: build
type: error
resolved: $resolvedText
fingerprint: "$(Escape-YamlDoubleQuoted -Text $fingerprintText)"
tags: [reflexion, build, error-log]
---

# $Title

## Error
~~~text
$ErrorMessage
~~~

## Cause
$(ConvertTo-BulletLines -Text $Cause)

## Fix
$(ConvertTo-BulletLines -Text $Fix)

## Learning
$(ConvertTo-BulletLines -Text $Learning)

## Fingerprint
- $fingerprintText

## Links
- Framework: $Framework
- Similar: $similarText
"@

if ($PSCmdlet.ShouldProcess($targetPath, "Create error note")) {
    Set-Content -LiteralPath $targetPath -Value $content -Encoding UTF8
    Write-Output "Created: $targetPath"
}
