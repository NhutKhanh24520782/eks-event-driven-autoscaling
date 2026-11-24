<#
.SYNOPSIS
    Reproducible k6 Load Test Runner for Windows PowerShell.
.DESCRIPTION
    Executes bounded, repeatable load profiles against the API service and saves
    CSV metrics directly into the designated docs/evidence/<run-id>/ folder.
.EXAMPLE
    .\run-k6.ps1 -Profile baseline
    .\run-k6.ps1 -Profile load -PeakVUs 10 -ApiUrl "http://k8s-alb-endpoint.amazonaws.com"
    .\run-k6.ps1 -Profile spike -SpikeVUs 25 -ApiUrl "http://localhost:3000"
#>

[CmdletBinding()]
param(
    [ValidateSet('smoke', 'baseline', 'load', 'spike', 'stress', 'soak')]
    [string]$Profile = 'baseline',

    [string]$ApiUrl = ($env:API_URL -as [string]),

    [string]$RunId = '',

    [int]$BaselineVUs = 1,
    [int]$PeakVUs = 10,
    [int]$SpikeVUs = 20,
    [int]$ProcessTimeMs = 1000,
    [string]$BaselineDuration = '30s',
    [string]$RampUpDuration = '60s',
    [string]$HoldDuration = '120s',
    [string]$RampDownDuration = '30s',
    [string]$SoakDuration = '3m',
    [double]$RequestPauseSeconds = 1.0,
    [double]$FailureRate = 0.0
)

$ErrorActionPreference = 'Stop'

if (-not $ApiUrl) {
    $ApiUrl = 'http://localhost:3000'
}
$ApiUrl = $ApiUrl.TrimEnd('/')

if (-not $RunId) {
    $utcTimestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $RunId = "$Profile-$utcTimestamp"
}

$evidenceDir = Join-Path "docs" "evidence" | Join-Path -ChildPath $RunId
if (-not (Test-Path $evidenceDir)) {
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
}

$csvPath = Join-Path $evidenceDir "k6.csv"
$scriptPath = Join-Path "scripts" "load-test" | Join-Path -ChildPath "k6-workload.js"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  REPRODUCIBLE K6 WORKLOAD RUNNER" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Run ID:           $RunId"
Write-Host "  Profile:          $Profile"
Write-Host "  Target API URL:   $ApiUrl"
Write-Host "  Process Time:     ${ProcessTimeMs}ms"
Write-Host "  Output Directory: $evidenceDir"
Write-Host "  Output CSV:       $csvPath"
Write-Host "==========================================================" -ForegroundColor Cyan

# Check if k6 is installed
$k6Cmd = Get-Command "k6" -ErrorAction SilentlyContinue
if (-not $k6Cmd) {
    Write-Warning "k6 command was not found in PATH."
    Write-Host "Install k6 via winget (`winget install k6 --source winget`) or choco (`choco install k6`)." -ForegroundColor Yellow
    Write-Host "`nTo execute manually once installed:"
    Write-Host "k6 run -e API_URL=$ApiUrl -e RUN_ID=$RunId -e K6_PROFILE=$Profile --out csv=$csvPath $scriptPath" -ForegroundColor Green
    exit 1
}

$k6Env = @(
    "-e", "API_URL=$ApiUrl",
    "-e", "RUN_ID=$RunId",
    "-e", "K6_PROFILE=$Profile",
    "-e", "PROCESS_TIME_MS=$ProcessTimeMs",
    "-e", "BASELINE_VUS=$BaselineVUs",
    "-e", "PEAK_VUS=$PeakVUs",
    "-e", "SPIKE_VUS=$SpikeVUs",
    "-e", "BASELINE_DURATION=$BaselineDuration",
    "-e", "RAMP_UP_DURATION=$RampUpDuration",
    "-e", "HOLD_DURATION=$HoldDuration",
    "-e", "RAMP_DOWN_DURATION=$RampDownDuration",
    "-e", "SOAK_DURATION=$SoakDuration",
    "-e", "REQUEST_PAUSE_SECONDS=$RequestPauseSeconds",
    "-e", "FAILURE_RATE=$FailureRate"
)

Write-Host "Starting k6 workload..." -ForegroundColor Green
$startTime = Get-Date

& k6 run @k6Env --out "csv=$csvPath" "$scriptPath"
$exitCode = $LASTEXITCODE

$duration = (Get-Date) - $startTime
Write-Host "`n==========================================================" -ForegroundColor Cyan
if ($exitCode -eq 0) {
    Write-Host "✅ K6 run completed successfully in $($duration.TotalSeconds.ToString('F1')) seconds!" -ForegroundColor Green
    Write-Host "   Metrics exported to: $csvPath"
} else {
    Write-Host "⚠️ K6 run finished with exit code $exitCode" -ForegroundColor Red
}
Write-Host "==========================================================" -ForegroundColor Cyan

exit $exitCode
