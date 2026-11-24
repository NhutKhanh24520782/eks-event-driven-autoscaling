<#
.SYNOPSIS
    Automated Experiment Runner for Controlled Load Tests & Latency Evidence Collection.
#>
[CmdletBinding()]
param(
    [ValidateSet('baseline', 'load')]
    [string]$Profile = 'baseline',

    [string]$RunId = '',
    [string]$ApiUrl = 'http://k8s-app-apiingre-d63a472806-1783453292.ap-southeast-1.elb.amazonaws.com',
    [string]$QueueUrl = 'https://sqs.ap-southeast-1.amazonaws.com/867703356304/jobs-queue',
    [int]$CollectionDuration = 0
)

$ErrorActionPreference = 'Stop'

if (-not $RunId) {
    $utcTimestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $RunId = "$Profile-$utcTimestamp"
}

if ($CollectionDuration -eq 0) {
    if ($Profile -eq 'baseline') {
        $CollectionDuration = 80 # ~1.3 minutes (60s baseline workload + 20s buffer)
    } else {
        $CollectionDuration = 660 # 4-minute workload plus queue drain, KEDA cooldown, and buffer
    }
}

$evidenceDir = Join-Path "docs" "evidence" | Join-Path -ChildPath $RunId

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  STARTING EXPERIMENT: $Profile ($RunId)" -ForegroundColor Yellow
Write-Host "  Target API: $ApiUrl"
Write-Host "  Collection Duration: ${CollectionDuration}s"
Write-Host "  Evidence Dir: $evidenceDir"
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Start Collector in background job
Write-Host "Starting metrics collector in background..." -ForegroundColor Green
$collectorJob = Start-Job -ScriptBlock {
    param($runId, $qUrl, $duration, $repoRoot)
    Set-Location $repoRoot
    powershell -ExecutionPolicy Bypass -File .\scripts\metrics\collect-control-loop-latency.ps1 -RunId $runId -QueueUrl $qUrl -CollectionDurationSeconds $duration
} -ArgumentList $RunId, $QueueUrl, $CollectionDuration, (Get-Location).Path

# Wait 6 seconds for collector initialization
Start-Sleep -Seconds 6

# 2. Run k6 Workload
Write-Host "Starting k6 workload for profile: $Profile..." -ForegroundColor Green
if ($Profile -eq 'baseline') {
    powershell -ExecutionPolicy Bypass -File .\scripts\load-test\run-k6.ps1 `
        -Profile baseline `
        -RunId $RunId `
        -ApiUrl $ApiUrl `
        -BaselineVUs 1 `
        -BaselineDuration "60s" `
        -ProcessTimeMs 1000 `
        -RequestPauseSeconds 1.2
} elseif ($Profile -eq 'load') {
    powershell -ExecutionPolicy Bypass -File .\scripts\load-test\run-k6.ps1 `
        -Profile load `
        -RunId $RunId `
        -ApiUrl $ApiUrl `
        -PeakVUs 10 `
        -BaselineDuration "30s" `
        -RampUpDuration "60s" `
        -HoldDuration "120s" `
        -RampDownDuration "30s" `
        -ProcessTimeMs 1000 `
        -RequestPauseSeconds 1
}

Write-Host "k6 workload finished. Waiting for collector to complete monitoring cycle (${CollectionDuration}s)..." -ForegroundColor Yellow
$collectorOutput = Receive-Job -Job $collectorJob -Wait
$collectorOutput | Out-Host
Remove-Job $collectorJob -Force -ErrorAction SilentlyContinue

# 3. Analyze Latencies & Generate Visual Evidence
Write-Host "Running latency analysis and chart generation..." -ForegroundColor Green
python .\scripts\metrics\analyze-control-loop-latency.py $evidenceDir

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "✅ Experiment $Profile completed successfully!" -ForegroundColor Green
Write-Host "   Evidence saved in: $evidenceDir"
Write-Host "==========================================================" -ForegroundColor Cyan
