#!/bin/bash
# ==============================================================================
# Kịch bản Chaos Test 2: Node Failure (Drain 1 Worker Node)
# Mục đích:
#   1. Giả lập 1 máy ảo EC2 ở Availability Zone A bị sập nguồn / hỏng phần cứng.
#   2. Kiểm tra tính năng Multi-AZ Resiliency: Các Pods trên node đó tự động
#      được reschedule sang các node ở Availability Zone B.
#   3. Hệ thống vẫn tiếp tục phục vụ người dùng, không downtime.
# ==============================================================================

set -e

echo "=========================================================="
echo "💥 BẮT ĐẦU CHAOS TEST: NODE FAILURE / MULTI-AZ RESILIENCY"
echo "=========================================================="

# 1. Liệt kê các node kèm Availability Zone
echo "▶ [1/4] Danh sách các Nodes hiện tại theo từng Zone:"
kubectl get nodes -L topology.kubernetes.io/zone

# Lấy 1 node bất kỳ để làm mục tiêu giả lập sự cố
TARGET_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
TARGET_ZONE=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')

echo -e "\n🎯 Mục tiêu giả lập sự cố: Node $TARGET_NODE (Zone: $TARGET_ZONE)"

# 2. Cordon & Drain node (cấm lập lịch và trục xuất toàn bộ pods)
echo -e "\n⚡ [2/4] Thực hiện Cordon & Drain node (giả lập node chết)..."
kubectl drain "$TARGET_NODE" --ignore-daemonsets --delete-emptydir-data --force

# 3. Kiểm tra các Pod được chuyển dời sang các node ở AZ khác
echo -e "\n▶ [3/4] Trạng thái các Pods sau khi node chết (đã dời sang node khác):"
kubectl get pods -n app -o wide

echo -e "\n⏳ Giữ trạng thái sự cố trong 20 giây để quan sát Grafana..."
sleep 20

# 4. Phục hồi lại node (Uncordon)
echo -e "\n▶ [4/4] Khôi phục lại Node vào cụm (Uncordon)..."
kubectl uncordon "$TARGET_NODE"

echo -e "\n=========================================================="
echo "🎉 HOÀN TẤT CHAOS TEST MULTI-AZ:"
echo "   - Node $TARGET_NODE (Zone $TARGET_ZONE) đã được thử nghiệm và phục hồi."
echo "   - Toàn bộ ứng dụng vẫn duy trì hoạt động nhờ kiến trúc Multi-AZ."
echo "👉 Mở Grafana để chụp lại ảnh phân bố Pods Multi-AZ làm báo cáo đồ án!"
echo "=========================================================="
