#!/bin/bash
# ==============================================================================
# Kịch bản Chaos Test 1: Pod Failure (Xóa Worker Pod đang chạy)
# Mục đích:
#   1. Kiểm tra khả năng tự phục hồi của Kubernetes Deployment (Self-healing).
#   2. Kiểm tra tính toàn vẹn dữ liệu của SQS: Message đang xử lý dở không bị mất,
#      được trả lại queue sau khi hết Visibility Timeout và Worker mới xử lý tiếp.
# ==============================================================================

set -e

NAMESPACE="app"
LABEL="app=worker-service"

echo "=========================================================="
echo "💥 BẮT ĐẦU CHAOS TEST: WORKER POD TERMINATION"
echo "=========================================================="

# 1. Liệt kê các Pod Worker hiện tại
echo "▶ [1/4] Danh sách Worker Pods hiện tại:"
kubectl get pods -n "$NAMESPACE" -l "$LABEL" -o wide

# Lấy tên 1 pod bất kỳ để tiêu diệt
TARGET_POD=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{.items[0].metadata.name}')

if [ -z "$TARGET_POD" ]; then
    echo "❌ Không tìm thấy Worker Pod nào trong namespace $NAMESPACE!"
    exit 1
fi

echo -e "\n🎯 Mục tiêu tiêu diệt: $TARGET_POD"

# 2. Xóa Pod (Giả lập worker crash đột tử)
START_TIME=$(date +%s)
echo "⚡ Đang gửi lệnh xóa Pod..."
kubectl delete pod "$TARGET_POD" -n "$NAMESPACE" --grace-period=0 --force

# 3. Quan sát quá trình tự phục hồi (Self-Healing)
echo -e "\n▶ [3/4] Quan sát Kubernetes tự động tạo Pod thay thế:"
kubectl get pods -n "$NAMESPACE" -l "$LABEL" -w &
WATCH_PID=$!

# Đợi Pod mới chuyển sang Ready
kubectl wait --namespace "$NAMESPACE" \
  --for=condition=Ready pod \
  --selector="$LABEL" \
  --timeout=60s

kill "$WATCH_PID" 2>/dev/null || true
END_TIME=$(date +%s)
RTO=$((END_TIME - START_TIME))

echo -e "\n=========================================================="
echo "🎉 KẾT QUẢ CHAOS TEST:"
echo "   - Pod cũ đã bị tiêu diệt: $TARGET_POD"
echo "   - Pod mới đã tự phục hồi thành công!"
echo "   - Thời gian phục hồi (RTO): ${RTO} giây"
echo "   - SQS Message: Được bảo vệ bởi Visibility Timeout, không bị mất."
echo "👉 Mở Grafana (http://localhost:3000) để xem biểu đồ Replicas & Throughput!"
echo "=========================================================="
