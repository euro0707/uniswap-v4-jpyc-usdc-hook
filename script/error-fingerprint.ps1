<#
.SYNOPSIS
Builds a lightweight error fingerprint from free text.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\script\error-fingerprint.ps1 `
  -Text "npm ERR! 404 Not Found" -Output json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Text,

    [ValidateSet("text", "json", "object")]
    [string]$Output = "text",

    [int]$MaxTokens = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$normalized = ($Text -replace "`r?`n", " ").ToLowerInvariant()

$tools = @(
    "npm", "pnpm", "yarn", "bun", "node", "python", "pip", "pytest",
    "forge", "anvil", "cast", "solc", "slither",
    "gemini", "codex", "claude", "git", "cargo"
)

$coreRules = @(
    @{ Tag = "not_found"; Pattern = "(not found|404|status[=: ]+4\\d\\d)" },
    @{ Tag = "permission_denied"; Pattern = "(permission denied|forbidden|unauthorized|401|403)" },
    @{ Tag = "module_not_found"; Pattern = "(module not found|cannot find module|no module named)" },
    @{ Tag = "rate_limited"; Pattern = "(429|rate limit|resource[_ ]exhausted|too many requests)" },
    @{ Tag = "timeout"; Pattern = "(timeout|timed out|deadline exceeded)" },
    @{ Tag = "invalid_request"; Pattern = "(400|bad request|invalid argument|invalid field)" },
    @{ Tag = "connection_failed"; Pattern = "(connection refused|econnrefused|network error|dns)" },
    @{ Tag = "revert_or_panic"; Pattern = "(revert|panic|assertion|traceback|stack trace)" }
)

$tokens = New-Object System.Collections.Generic.List[string]

foreach ($tool in $tools) {
    if ($normalized -match "(^|[^a-z0-9])$tool([^a-z0-9]|$)") {
        $tokens.Add("tool:$tool")
    }
}

$httpMatches = [regex]::Matches($normalized, "(^|[^0-9])(4[0-9]{2}|5[0-9]{2})([^0-9]|$)")
foreach ($m in $httpMatches) {
    if ($m.Groups.Count -ge 3) {
        $code = $m.Groups[2].Value
        if (-not [string]::IsNullOrWhiteSpace($code)) {
            $tokens.Add("http:$code")
        }
    }
}

foreach ($rule in $coreRules) {
    if ($normalized -match $rule.Pattern) {
        $tokens.Add("core:$($rule.Tag)")
    }
}

$uniqueTokens = @($tokens | Select-Object -Unique | Select-Object -First $MaxTokens)
$fingerprint = $uniqueTokens -join "|"

$queryTerms = New-Object System.Collections.Generic.List[string]
foreach ($token in $uniqueTokens) {
    $queryTerms.Add($token)
    if ($token.Contains(":")) {
        $queryTerms.Add($token.Split(":", 2)[1])
    }
}

$query = (@($queryTerms | Select-Object -Unique | Select-Object -First $MaxTokens) -join " ").Trim()

$result = [PSCustomObject]@{
    fingerprint = $fingerprint
    tokens      = $uniqueTokens
    query       = $query
}

switch ($Output) {
    "object" { $result; break }
    "json"   { $result | ConvertTo-Json -Compress; break }
    default {
        Write-Output "fingerprint=$($result.fingerprint)"
        Write-Output "query=$($result.query)"
    }
}

