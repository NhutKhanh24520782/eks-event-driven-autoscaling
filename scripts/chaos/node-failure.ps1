# ==============================================================================
# Kịch bản Chaos Test 2: Node Failure (PowerShell version)
# Chạy trên Windows PowerShell:
#   .\scripts\chaos\node-failure.ps1
# ==============================================================================

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "💥 BẮT ĐẦU CHAOS TEST: NODE FAILURE / MULTI-AZ RESILIENCY" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Liệt kê nodes
Write-Host "`n▶ [1/4] Danh sách các Nodes hiện tại theo từng Zone:" -ForegroundColor Green
kubectl get nodes -L topology.kubernetes.io/zone

$TargetNode = (kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
$TargetZone = (kubectl get node $TargetNode -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')

Write-Host "`n🎯 Mục tiêu giả lập sự cố: Node $TargetNode (Zone: $TargetZone)" -ForegroundColor Red

# 2. Drain node
Write-Host "`n⚡ [2/4] Thực hiện Cordon & Drain node (giả lập node chết)..." -ForegroundColor Yellow
kubectl drain $TargetNode --ignore-daemonsets --delete-emptydir-data --force

# 3. Kiểm tra pod
Write-Host "`n▶ [3/4] Trạng thái các Pods sau khi node chết (đã dời sang node khác):" -ForegroundColor Green
kubectl get pods -n app -o wide

Write-Host "`n⏳ Giữ trạng thái sự cố trong 20 giây để quan sát Grafana..." -ForegroundColor Yellow
Start-Sleep -Seconds 20

# 4. Uncordon
Write-Host "`n▶ [4/4] Khôi phục lại Node vào cụm (Uncordon)..." -ForegroundColor Green
kubectl uncordon $TargetNode

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "🎉 HOÀN TẤT CHAOS TEST MULTI-AZ:" -ForegroundColor Green
Write-Host "   - Node $TargetNode (Zone $TargetZone) đã được thử nghiệm và phục hồi."
Write-Host "   - Toàn bộ ứng dụng vẫn duy trì hoạt động nhờ kiến trúc Multi-AZ."
Write-Host "👉 Hãy nhìn lên Grafana để chụp ảnh biểu đồ Multi-AZ Pod Distribution!" -ForegroundColor Yellow
Write-Host "==========================================================`n" -ForegroundColor Cyan

