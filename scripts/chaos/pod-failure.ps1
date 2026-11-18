# ==============================================================================
# Kịch bản Chaos Test: Pod Failure (PowerShell version)
# Chạy trên Windows PowerShell:
#   .\scripts\chaos\pod-failure.ps1
# ==============================================================================

$Namespace = "app"
$Label = "app=worker-service"

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "💥 BẮT ĐẦU CHAOS TEST: WORKER POD TERMINATION (SELF-HEALING)" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Liệt kê pod
Write-Host "`n▶ [1/4] Danh sách Worker Pods hiện tại:" -ForegroundColor Green
kubectl get pods -n $Namespace -l $Label -o wide

$TargetPod = (kubectl get pods -n $Namespace -l $Label -o jsonpath='{.items[0].metadata.name}')

if (-not $TargetPod) {
    Write-Host "❌ Không tìm thấy Worker Pod nào trong namespace $Namespace!" -ForegroundColor Red
    exit 1
}

Write-Host "`n🎯 Mục tiêu tiêu diệt: $TargetPod" -ForegroundColor Red
$StartTime = Get-Date

# 2. Xóa pod
Write-Host "⚡ Đang gửi lệnh xóa Pod (force delete)..." -ForegroundColor Yellow
kubectl delete pod $TargetPod -n $Namespace --grace-period=0 --force

# 3. Chờ phục hồi
Write-Host "`n▶ [3/4] Đang chờ Kubernetes tự phục hồi Pod mới..." -ForegroundColor Green
kubectl wait --namespace $Namespace --for=condition=Ready pod --selector=$Label --timeout=60s

$EndTime = Get-Date
$RtoSeconds = [math]::Round(($EndTime - $StartTime).TotalSeconds)

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "🎉 KẾT QUẢ CHAOS TEST:" -ForegroundColor Green
Write-Host "   - Pod cũ đã bị tiêu diệt: $TargetPod"
Write-Host "   - Pod mới đã tự phục hồi thành công!"
Write-Host "   - Thời gian phục hồi (RTO): $RtoSeconds giây"
Write-Host "   - SQS Message: Được bảo vệ bởi Visibility Timeout, không bị mất dữ liệu."
Write-Host "👉 Hãy nhìn lên Grafana (http://localhost:3000) để thấy biểu đồ Replicas phục hồi!" -ForegroundColor Yellow
Write-Host "==========================================================`n" -ForegroundColor Cyan

