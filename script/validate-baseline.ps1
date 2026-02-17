param(
    [switch]$UpdateLatest,
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Host "==> $Command $($Arguments -join ' ')" -ForegroundColor Cyan
    & $Command @Arguments
    $exitCode = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "Command failed: $Command $($Arguments -join ' ') (exit: $exitCode)"
    }
    return $exitCode
}

function Get-SrcCheckCounts {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Report
    )

    $srcDetectors = @()
    foreach ($detector in @($Report.results.detectors)) {
        if ($null -eq $detector.elements) {
            continue
        }

        $hasSrcElement = $false
        foreach ($element in @($detector.elements)) {
            $relativePath = $element.source_mapping.filename_relative
            if ($relativePath -and $relativePath -like "src/*") {
                $hasSrcElement = $true
                break
            }
        }

        if ($hasSrcElement) {
            $srcDetectors += $detector
        }
    }

    return @($srcDetectors | Group-Object check | Sort-Object Name)
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
    $foundryBin = Join-Path $env:USERPROFILE ".foundry\bin"
    if ((Test-Path $foundryBin) -and (($env:PATH -split ";") -notcontains $foundryBin)) {
        $env:PATH = "$foundryBin;$($env:PATH)"
    }

    $slitherTmp = "slither-report.tmp.json"
    $slitherIgnoredTmp = "slither-report.show-ignored.tmp.json"
    $slitherLatest = "slither-report.latest.json"

    foreach ($tmpFile in @($slitherTmp, $slitherIgnoredTmp)) {
        if (Test-Path $tmpFile) {
            Remove-Item $tmpFile -Force
        }
    }

    $null = Invoke-External -Command "forge" -Arguments @("test", "--gas-report")
    $null = Invoke-External -Command "forge" -Arguments @("snapshot")
    $null = Invoke-External -Command "forge" -Arguments @("snapshot", "--check", ".gas-snapshot")

    $null = Invoke-External -Command "slither" -Arguments @(".", "--json", $slitherTmp) -AllowedExitCodes @(0, 1, -1, 255)
    $null = Invoke-External -Command "slither" -Arguments @(".", "--show-ignored-findings", "--json", $slitherIgnoredTmp) -AllowedExitCodes @(0, 1, -1, 255)

    if (-not (Test-Path $slitherTmp)) {
        throw "Missing expected report: $slitherTmp"
    }
    if (-not (Test-Path $slitherIgnoredTmp)) {
        throw "Missing expected report: $slitherIgnoredTmp"
    }

    $visibleReport = Get-Content -Raw $slitherTmp | ConvertFrom-Json
    $ignoredReport = Get-Content -Raw $slitherIgnoredTmp | ConvertFrom-Json

    $visibleSrcChecks = Get-SrcCheckCounts -Report $visibleReport
    $ignoredSrcChecks = Get-SrcCheckCounts -Report $ignoredReport

    Write-Host ""
    Write-Host "==> Slither src/ checks (visible)" -ForegroundColor Green
    if ($visibleSrcChecks.Count -eq 0) {
        Write-Host "none"
    } else {
        foreach ($item in $visibleSrcChecks) {
            Write-Host ("{0}`t{1}" -f $item.Name, $item.Count)
        }
    }

    Write-Host ""
    Write-Host "==> Slither src/ checks (show-ignored-findings)" -ForegroundColor Green
    if ($ignoredSrcChecks.Count -eq 0) {
        Write-Host "none"
    } else {
        foreach ($item in $ignoredSrcChecks) {
            Write-Host ("{0}`t{1}" -f $item.Name, $item.Count)
        }
    }

    $latestExists = Test-Path $slitherLatest
    if ($latestExists) {
        $tmpHash = (Get-FileHash -Algorithm SHA256 $slitherTmp).Hash
        $latestHash = (Get-FileHash -Algorithm SHA256 $slitherLatest).Hash

        Write-Host ""
        if ($tmpHash -eq $latestHash) {
            Write-Host "slither-report.tmp.json matches slither-report.latest.json" -ForegroundColor Green
        } else {
            Write-Warning "slither-report.tmp.json differs from slither-report.latest.json"
            if ($UpdateLatest) {
                Copy-Item $slitherTmp $slitherLatest -Force
                Write-Host "Updated $slitherLatest from $slitherTmp" -ForegroundColor Yellow
            } else {
                Write-Host "Re-run with -UpdateLatest to refresh slither-report.latest.json"
            }
        }
    } elseif ($UpdateLatest) {
        Copy-Item $slitherTmp $slitherLatest -Force
        Write-Host "Created $slitherLatest from $slitherTmp" -ForegroundColor Yellow
    } else {
        Write-Warning "$slitherLatest not found"
    }
}
finally {
    if (-not $KeepTemp) {
        foreach ($tmpFile in @("slither-report.tmp.json", "slither-report.show-ignored.tmp.json")) {
            if (Test-Path $tmpFile) {
                Remove-Item $tmpFile -Force
            }
        }
    }
    Pop-Location
}
