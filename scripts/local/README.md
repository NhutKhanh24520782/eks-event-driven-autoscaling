# Môi Trường Local Integration & Giám Sát (Phát - Backend)

Môi trường giả lập hoàn chỉnh cho Backend bao gồm:
- **SQS Mock (ElasticMQ)**: Giả lập AWS SQS với `jobs-queue` và `jobs-queue-dlq` (Port 9324).
- **API Service**: Nhận job tại `POST /jobs` (Port 3000).
- **Worker Service**: Poll message, Idempotency Deduplication, xử lý và xuất metrics (Port 3001).
- **Prometheus**: Tự động cào metrics từ Worker mỗi 2 giây (Port 9090).
- **Grafana Dashboard**: Giám sát trực quan realtime các chỉ số nghiệp vụ (Port 3002).

---

## 1. Khởi động môi trường

Từ thư mục gốc dự án, chạy lệnh:

```powershell
docker compose -f docker-compose.local.yml up --build
```

Sau khi khởi động xong:
- **Grafana Dashboard:** Mở trình duyệt tại [http://localhost:3002](http://localhost:3002) (đã cấu hình tự động đăng nhập và tải sẵn dashboard `Worker Service & SQS Event Monitoring`).
- **Prometheus:** [http://localhost:9090](http://localhost:9090)
- **API Health:** [http://localhost:3000/health](http://localhost:3000/health)
- **Worker Health & Metrics:** [http://localhost:3001/health](http://localhost:3001/health) và [http://localhost:3001/metrics](http://localhost:3001/metrics)

---

## 2. Các Script Node.js Test 3 Kịch Bản

Nhóm scripts kiểm thử nằm tại thư mục `scripts/local/tests/`:

### Cách chạy:
Nếu máy bạn đã cài Node.js (v16 trở lên):
```powershell
# Chạy từng kịch bản
node scripts/local/tests/test-1-normal.js
node scripts/local/tests/test-2-idempotency.js
node scripts/local/tests/test-3-dlq-retry.js

# Hoặc chạy toàn bộ cả 3 kịch bản liên tiếp
node scripts/local/tests/run-all.js
```

*(Nếu máy chưa cài Node.js trên host, bạn có thể chạy thẳng qua container api-service đã có sẵn môi trường Node):*
```powershell
docker compose -f docker-compose.local.yml exec api-service node -e "require('http').get('http://worker-service:8081/health', r => r.pipe(process.stdout))"
```

---

## 3. Các kịch bản kiểm thử chi tiết

1. **Test 1 — Normal Workflow (`test-1-normal.js`):**
   - Bắn 3 job bình thường vào API.
   - Quan sát Worker xử lý và Grafana nhảy số thẻ **`Total Jobs Processed`**.

2. **Test 2 — Idempotency / Chống trùng lặp (`test-2-idempotency.js`):**
   - Bắn 2 request mang cùng 1 mã `job_id`.
   - Worker chỉ xử lý 1 lần, job thứ 2 bị `IdempotencyCache` chặn lại.
   - Thẻ **`Duplicate Jobs Skipped`** trên Grafana tăng +1 và xuất hiện đỉnh sóng nhọn.

3. **Test 3 — Xử lý lỗi & DLQ (`test-3-dlq-retry.js`):**
   - Bắn 1 job có cờ `shouldFail: true`.
   - Worker ghi nhận lỗi, không xóa message khỏi SQS.
   - Thẻ đỏ **`Failed Jobs (DLQ Candidates)`** trên Grafana tăng +1.
