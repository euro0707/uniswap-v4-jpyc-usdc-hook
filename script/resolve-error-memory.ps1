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

    [string]$VaultRoot = "C:\Users\skyeu\obsidian\TetsuyaSynapse\90-Claude"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LatestUnresolvedNote {
    param([string]$Root)

    $dir = Join-Path $Root "reflections\build"
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "Build reflections directory not found: $dir"
    }

    $candidates = Get-ChildItem -LiteralPath $dir -File -Filter *.md -Recurse |
        Where-Object {
            $_.FullName -notmatch "\\reflections\\build\\auto\\" -and
            $_.Name -ne "_template.md"
        } |
        Sort-Object LastWriteTime -Descending

    foreach ($file in $candidates) {
        $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ($raw -match "(?m)^resolved:\s*false\s*$") {
            return $file.FullName
        }
    }

    return ""
}

if (-not (Test-Path -LiteralPath $VaultRoot)) {
    throw "Vault path not found: $VaultRoot"
}

if ([string]::IsNullOrWhiteSpace($NotePath)) {
    $NotePath = Get-LatestUnresolvedNote -Root $VaultRoot
    if ([string]::IsNullOrWhiteSpace($NotePath)) {
        throw "No unresolved note found."
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
if ($raw -match "(?m)^## Resolution\s*$") {
    $raw = $raw.TrimEnd() + [Environment]::NewLine + $line + [Environment]::NewLine
}
else {
    $raw = $raw.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + "## Resolution" + [Environment]::NewLine + $line + [Environment]::NewLine
}

if ($PSCmdlet.ShouldProcess($NotePath, "Mark error note as resolved")) {
    Set-Content -LiteralPath $NotePath -Value $raw -Encoding UTF8
    Write-Output "Resolved: $NotePath"
}

