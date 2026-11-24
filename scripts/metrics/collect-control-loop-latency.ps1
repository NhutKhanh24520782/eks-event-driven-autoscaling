<#
.SYNOPSIS
    Collect Control Loop Latency (T0–T6) — Windows PowerShell Collector.
.DESCRIPTION
    Collects timestamped application/KEDA logs, replica counts, SQS attributes, and
    Kubernetes state snapshots for one controlled experiment.
    Does not generate load or modify cluster resources.
.EXAMPLE
    $env:KUBE_CONTEXT = (kubectl config current-context)
    $env:QUEUE_URL = "https://sqs.ap-southeast-1.amazonaws.com/123456789012/jobs-queue"
    $env:AWS_REGION = "ap-southeast-1"
    .\scripts\metrics\collect-control-loop-latency.ps1 -CollectionDurationSeconds 180
#>

[CmdletBinding()]
param(
    [string]$KubeContext = ($env:KUBE_CONTEXT -as [string]),
    [string]$QueueUrl = ($env:QUEUE_URL -as [string]),
    [string]$AwsRegion = ($env:AWS_REGION -as [string]),
    [string]$Namespace = 'app',
    [string]$RunId = '',
    [int]$SampleIntervalSeconds = 1,
    [int]$CollectionDurationSeconds = 0,
    [string]$EvidenceDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not $KubeContext) {
    $KubeContext = (kubectl config current-context).Trim()
}
if (-not $KubeContext) {
    Write-Error "KUBE_CONTEXT is not set and could not be determined from kubectl."
}

if (-not $QueueUrl) {
    Write-Error "QUEUE_URL is required. Set `$env:QUEUE_URL or pass -QueueUrl."
}

if (-not $AwsRegion) {
    $AwsRegion = if ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { 'ap-southeast-1' }
}

if (-not $RunId) {
    $utcTimestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $RunId = "run-$utcTimestamp"
}

if (-not $EvidenceDir) {
    $EvidenceDir = Join-Path "docs" "evidence" | Join-Path -ChildPath $RunId
}

if (-not (Test-Path $EvidenceDir)) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
}

$queueName = $QueueUrl.Split('/')[-1]
$startedAt = (Get-Date).ToUniversalTime().ToString("o")

# Initialize run metadata
@"
run_id=$RunId
started_at=$startedAt
context=$KubeContext
namespace=$Namespace
region=$AwsRegion
queue_name=$queueName
sample_interval_seconds=$SampleIntervalSeconds
collection_duration_seconds=$CollectionDurationSeconds
"@ | Set-Content -Path (Join-Path $EvidenceDir "run.txt") -Encoding utf8

"mark,timestamp,source,uncertainty_ms" | Set-Content -Path (Join-Path $EvidenceDir "run-events.csv") -Encoding utf8
"observed_at_utc`tdesired_replicas`tready_replicas`tavailable_replicas" | Set-Content -Path (Join-Path $EvidenceDir "replicas.tsv") -Encoding utf8
"observed_at_utc`tpod_name`tcreation_timestamp`tready_status`tready_transition_time`tnode_name" | Set-Content -Path (Join-Path $EvidenceDir "worker-pod-observations.tsv") -Encoding utf8
"observed_at_utc`tvisible_messages`tin_flight_messages`tdelayed_messages" | Set-Content -Path (Join-Path $EvidenceDir "sqs-attributes.tsv") -Encoding utf8
New-Item -ItemType File -Path (Join-Path $EvidenceDir "kubernetes-events.jsonl") -Force | Out-Null

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  CONTROL LOOP LATENCY COLLECTOR (T0–T6)" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Run ID:           $RunId"
Write-Host "  Kube Context:     $KubeContext"
Write-Host "  Namespace:        $Namespace"
Write-Host "  Queue URL:        $QueueUrl"
Write-Host "  Region:           $AwsRegion"
Write-Host "  Sampling Rate:    Every ${SampleIntervalSeconds}s"
Write-Host "  Evidence Folder:  $EvidenceDir"
Write-Host "==========================================================" -ForegroundColor Cyan

# Pre-experiment Snapshots
Write-Host "Taking pre-experiment snapshots..." -ForegroundColor Green
kubectl --context $KubeContext -n $Namespace get pods -o wide | Out-File (Join-Path $EvidenceDir "pods-before.txt") -Encoding utf8
kubectl --context $KubeContext -n $Namespace get pods -l app=worker-service -o json | Out-File (Join-Path $EvidenceDir "worker-pods-before.json") -Encoding utf8
kubectl --context $KubeContext -n $Namespace get hpa,scaledobject -o yaml | Out-File (Join-Path $EvidenceDir "autoscaler-before.yaml") -Encoding utf8
kubectl --context $KubeContext get nodes -L topology.kubernetes.io/zone | Out-File (Join-Path $EvidenceDir "nodes-before.txt") -Encoding utf8

# Background Log Streaming Jobs
Write-Host "Starting background log streaming..." -ForegroundColor Green
$logJobs = @()
$observedEventVersions = @{}
$kubernetesEventsPath = Join-Path $EvidenceDir "kubernetes-events.jsonl"
$kubernetesEventsErrorsPath = Join-Path $EvidenceDir "kubernetes-events-errors.log"

$logJobs += Start-Job -ScriptBlock {
    param($ctx, $ns, $out)
    kubectl --context $ctx -n $ns logs -l app=api-service --max-log-requests=20 --all-containers=true --prefix --timestamps --since=2m -f > $out 2>&1
} -ArgumentList $KubeContext, $Namespace, (Join-Path $EvidenceDir "api.log")

$logJobs += Start-Job -ScriptBlock {
    param($ctx, $ns, $out)
    kubectl --context $ctx -n $ns logs -l app=worker-service --max-log-requests=20 --all-containers=true --prefix --timestamps --since=2m -f > $out 2>&1
} -ArgumentList $KubeContext, $Namespace, (Join-Path $EvidenceDir "worker.log")

$logJobs += Start-Job -ScriptBlock {
    param($ctx, $out)
    kubectl --context $ctx -n keda logs deployment/keda-operator --all-containers=true --prefix --timestamps --since=2m -f > $out 2>&1
} -ArgumentList $KubeContext, (Join-Path $EvidenceDir "keda-operator.log")

# Background SQS Attributes Sampler Job
$logJobs += Start-Job -ScriptBlock {
    param($qUrl, $reg, $outTsv, $errLog)
    while ($true) {
        $now = (Get-Date).ToUniversalTime().ToString("o")
        try {
            $attrs = aws sqs get-queue-attributes --queue-url $qUrl --region $reg `
                --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed `
                --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible,ApproximateNumberOfMessagesDelayed]' `
                --output text 2>> $errLog
            if ($attrs) {
                "$now`t$attrs" | Out-File -FilePath $outTsv -Append -Encoding utf8
            }
        } catch {
            "$_" | Out-File -FilePath $errLog -Append -Encoding utf8
        }
        Start-Sleep -Seconds 2
    }
} -ArgumentList $QueueUrl, $AwsRegion, (Join-Path $EvidenceDir "sqs-attributes.tsv"), (Join-Path $EvidenceDir "aws-errors.log")

function Cleanup-And-Exit {
    Write-Host "`nStopping background collectors and saving final snapshots..." -ForegroundColor Yellow
    foreach ($j in $logJobs) {
        Stop-Job $j -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $j -ErrorAction SilentlyContinue | Out-Null
    }

    Write-Host "Fetching final complete container logs..." -ForegroundColor Green
    kubectl --context $KubeContext -n $Namespace logs -l app=api-service --all-containers=true --prefix=true --timestamps=true --tail=3000 | Out-File (Join-Path $EvidenceDir "api.log") -Append -Encoding utf8
    kubectl --context $KubeContext -n $Namespace logs -l app=worker-service --all-containers=true --prefix=true --timestamps=true --tail=3000 | Out-File (Join-Path $EvidenceDir "worker.log") -Append -Encoding utf8
    kubectl --context $KubeContext -n keda logs deployment/keda-operator --all-containers=true --prefix=true --timestamps=true --tail=3000 | Out-File (Join-Path $EvidenceDir "keda-operator.log") -Append -Encoding utf8

    kubectl --context $KubeContext -n $Namespace get pods -o wide | Out-File (Join-Path $EvidenceDir "pods-after.txt") -Encoding utf8
    kubectl --context $KubeContext -n $Namespace get hpa,scaledobject -o yaml | Out-File (Join-Path $EvidenceDir "autoscaler-after.yaml") -Encoding utf8
    kubectl --context $KubeContext -n $Namespace get events --sort-by=.metadata.creationTimestamp | Out-File (Join-Path $EvidenceDir "app-events.txt") -Encoding utf8
    kubectl --context $KubeContext -n $Namespace get events -o json | Out-File (Join-Path $EvidenceDir "app-events.json") -Encoding utf8
    kubectl --context $KubeContext -n keda get events -o json | Out-File (Join-Path $EvidenceDir "keda-events.json") -Encoding utf8
    kubectl --context $KubeContext -n $Namespace get pods -l app=worker-service -o json | Out-File (Join-Path $EvidenceDir "worker-pods.json") -Encoding utf8
    
    $finishedAt = (Get-Date).ToUniversalTime().ToString("o")
    "finished_at=$finishedAt" | Out-File -FilePath (Join-Path $EvidenceDir "run.txt") -Append -Encoding utf8

    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "✅ Evidence collection complete!" -ForegroundColor Green
    Write-Host "   Saved in: $EvidenceDir"
    Write-Host "   Analyze via: python scripts/metrics/analyze-control-loop-latency.py $EvidenceDir" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Cyan
}

try {
    Write-Host "`nSampling replicas and pod states. Start workload in another terminal." -ForegroundColor Green
    if ($CollectionDurationSeconds -eq 0) {
        Write-Host "Press Ctrl+C to terminate collection when workload finishes and queue drains.`n" -ForegroundColor Yellow
    } else {
        Write-Host "Collection will automatically stop after ${CollectionDurationSeconds}s.`n" -ForegroundColor Yellow
    }

    $startTime = Get-Date
    while ($true) {
        $now = (Get-Date).ToUniversalTime().ToString("o")
        
        # 1. Sample Worker deployment replicas
        try {
            $depJson = kubectl --context $KubeContext -n $Namespace get deployment worker-service -o json 2>$null
            if ($depJson) {
                $dep = $depJson | ConvertFrom-Json
                $des = if ($dep.spec.replicas) { $dep.spec.replicas } else { 0 }
                $rdy = if ($dep.status.readyReplicas) { $dep.status.readyReplicas } else { 0 }
                $avl = if ($dep.status.availableReplicas) { $dep.status.availableReplicas } else { 0 }
                "$now`t$des`t$rdy`t$avl" | Out-File -FilePath (Join-Path $EvidenceDir "replicas.tsv") -Append -Encoding utf8
            }
        } catch {}

        # 2. Sample Pod states
        try {
            $podsRaw = kubectl --context $KubeContext -n $Namespace get pods -l app=worker-service -o json 2>$null
            if ($podsRaw) {
                $pods = $podsRaw | ConvertFrom-Json
                foreach ($item in $pods.items) {
                    $pName = $item.metadata.name
                    $pCreated = $item.metadata.creationTimestamp
                    $rCond = $item.status.conditions | Where-Object { $_.type -eq 'Ready' }
                    $rStatus = if ($rCond) { $rCond.status } else { 'False' }
                    $rTrans = if ($rCond) { $rCond.lastTransitionTime } else { '' }
                    $pNode = $item.spec.nodeName
                    "$now`t$pName`t$pCreated`t$rStatus`t$rTrans`t$pNode" | Out-File -FilePath (Join-Path $EvidenceDir "worker-pod-observations.tsv") -Append -Encoding utf8
                }
            }
        } catch {}

        # Preserve event changes while the experiment runs; final snapshots alone can miss expired events.
        try {
            foreach ($eventNamespace in @($Namespace, 'keda')) {
                $eventsRaw = kubectl --context $KubeContext -n $eventNamespace get events -o json 2>$null
                if ($eventsRaw) {
                    $eventList = ($eventsRaw | ConvertFrom-Json).items
                    foreach ($event in $eventList) {
                        $eventVersion = "$($event.metadata.uid):$($event.metadata.resourceVersion)"
                        if (-not $observedEventVersions.ContainsKey($eventVersion)) {
                            $observedEventVersions[$eventVersion] = $true
                            $record = [ordered]@{
                                observed_at_utc = $now
                                event = $event
                            }
                            ConvertTo-Json -InputObject $record -Compress -Depth 20 |
                                Add-Content -Path $kubernetesEventsPath -Encoding utf8
                        }
                    }
                }
            }
        } catch {
            "$now`t$_" | Out-File -FilePath $kubernetesEventsErrorsPath -Append -Encoding utf8
        }

        if ($CollectionDurationSeconds -gt 0) {
            $elapsed = (Get-Date) - $startTime
            if ($elapsed.TotalSeconds -ge $CollectionDurationSeconds) {
                break
            }
        }

        Start-Sleep -Seconds $SampleIntervalSeconds
    }
} finally {
    Cleanup-And-Exit
}
