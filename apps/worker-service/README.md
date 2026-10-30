# Worker Service — Background Worker Service

**Phân công thực hiện:** Phát (Backend Engineer)  
**Chức năng chính:** Poll jobs từ AWS SQS (`jobs-queue`), xử lý idempotent, ghi log chi tiết, xử lý retry/redelivery và graceful shutdown khi scale-down.

---

## 1. Cơ chế hoạt động & Tính năng kỹ thuật

### 1.1 Long Polling SQS
- Sử dụng `ReceiveMessageCommand` với `WaitTimeSeconds = 20s` để giảm số lượng request rỗng và tiết kiệm chi phí AWS SQS.
- Batch size nhận tối đa 5-10 messages mỗi lần poll để tối ưu throughput.

### 1.2 Xử lý trùng lặp (Idempotent Processing)
- AWS SQS cam kết chuẩn **at-least-once delivery**, do đó message có thể bị gửi lặp lại trong trường hợp lỗi mạng hoặc timeout.
- Worker tích hợp bộ nhớ cache **In-Memory Idempotency Cache với TTL (Time-To-Live = 10 phút)**:
  - Khi nhận message, kiểm tra `job_id` trong cache.
  - Nếu đã xử lý thành công trước đó: ghi log cảnh báo `[IDEMPOTENT SKIP]`, thực hiện xóa message khỏi SQS (`DeleteMessageCommand`) ngay lập tức để tránh lặp vô tận, và không xử lý lại.
  - Sau khi hoàn thành một job mới: ghi nhận `job_id` vào cache cùng timestamp hiện tại.
  - Tự động dọn dẹp các bản ghi quá hạn TTL theo chu kỳ 60s để tránh memory leak.

### 1.3 Retry & Redelivery
- Đọc thuộc tính hệ thống `ApproximateReceiveCount` từ SQS.
- Nếu `ApproximateReceiveCount > 1`: cảnh báo message đang được giao lại (redelivery do worker trước đó bị crash hoặc timeout).
- Nếu việc xử lý job thất bại (ném exception):
  - Worker **KHÔNG xóa message** khỏi SQS.
  - Message sẽ tự động quay trở lại hàng đợi sau khi hết `VisibilityTimeout`.
  - Nếu số lần thất bại vượt quá `maxReceiveCount` (được cấu hình trong SQS Redrive Policy), AWS SQS sẽ tự động chuyển message sang Dead Letter Queue (`jobs-queue-dlq`).

### 1.4 Tắt ứng dụng an toàn (Graceful Shutdown)
- Worker theo dõi số lượng job đang được xử lý (`inFlightJobs`).
- Khi Kubernetes gửi tín hiệu `SIGTERM` (scale-down hoặc pod eviction):
  1. Đặt cờ `isShuttingDown = true` để vòng lặp polling **ngưng nhận message mới** từ SQS.
  2. Đóng cổng HTTP `/health` để Kubernetes báo Pod Unhealthy.
  3. Chờ toàn bộ các job đang xử lý dở (`inFlightJobs === 0`) hoàn thành sạch sẽ và xóa khỏi SQS.
  4. Nếu quá thời gian an toàn (25s), tiến hành force exit để tránh bị Kubernetes SIGKILL đột ngột.

### 1.5 Health Check & Metrics Server
- Mở server HTTP nhẹ tại port `8081`:
  - `GET /health` hoặc `GET /healthz`: Trả về trạng thái worker, số job đang xử lý, tổng số job thành công, trùng lặp và lỗi.
  - `GET /metrics`: Trả về định dạng Prometheus text format để hệ thống giám sát cào dữ liệu (scrape).

---

## 2. Biến môi trường (Environment Variables)

| Tên biến | Mặc định | Mô tả |
| :--- | :--- | :--- |
| `AWS_REGION` | `ap-southeast-1` | AWS Region chứa SQS |
| `QUEUE_URL` | *(Bắt buộc)* | URL đầy đủ của SQS Queue |
| `AWS_ENDPOINT_URL` | *(Trống)* | URL LocalStack khi test local |
| `HEALTH_PORT` | `8081` | Port HTTP của Health check / Metrics |
| `WORKER_PROCESS_TIME_MS` | `1000` | Thời gian giả lập xử lý mỗi job (ms) |
| `WAIT_TIME_SECONDS` | `20` | Thời gian chờ Long Polling SQS (giây) |
| `MAX_MESSAGES` | `5` | Số lượng message tối đa nhận mỗi batch (1-10) |
| `DEDUPLICATION_TTL_MS` | `600000` | Thời gian lưu cache phát hiện trùng lặp (10 phút) |

---

## 3. Quyền hạn AWS IAM (SQS Permissions)

Worker Service sử dụng IAM Roles for Service Accounts (IRSA).  
Quyền tối thiểu cần cấp cho Worker Service:
```json
{
  "Effect": "Allow",
  "Action": [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:GetQueueAttributes"
  ],
  "Resource": "arn:aws:sqs:ap-southeast-1:<ACCOUNT_ID>:jobs-queue"
}
```

---

## 4. Hướng dẫn chạy và kiểm thử

### 4.1 Chạy trực tiếp với Node.js (Local)

1. Cài đặt dependencies:
   ```bash
   cd apps/worker-service
   npm install
   ```

2. Tạo file `.env`:
   ```env
   AWS_REGION=ap-southeast-1
   QUEUE_URL=https://sqs.ap-southeast-1.amazonaws.com/123456789012/jobs-queue
   HEALTH_PORT=8081
   WORKER_PROCESS_TIME_MS=1000
   ```

3. Khởi chạy:
   ```bash
   npm start
   ```

### 4.2 Chạy bằng Docker

1. Build Docker image:
   ```bash
   docker build -t worker-service:latest -f apps/worker-service/Dockerfile apps/worker-service
   ```

2. Chạy container:
   ```bash
   docker run -d --name worker-service \
     -p 8081:8081 \
     -e AWS_REGION=ap-southeast-1 \
     -e QUEUE_URL=https://sqs.ap-southeast-1.amazonaws.com/123456789012/jobs-queue \
     worker-service:latest
   ```

### 4.3 Kiểm tra Worker Health & Metrics

- **Kiểm tra Health:**
  ```bash
  curl http://localhost:8081/health
  ```
  *Ví dụ kết quả:*
  ```json
  {
    "status": "healthy",
    "service": "worker-service",
    "worker_id": "ip-10-0-1-55.ap-southeast-1.compute.internal-1",
    "in_flight_jobs": 0,
    "total_received": 42,
    "total_processed": 42,
    "total_duplicates": 0,
    "total_errors": 0,
    "uptime_seconds": 320
  }
  ```

- **Kiểm tra Prometheus Metrics:**
  ```bash
  curl http://localhost:8081/metrics
  ```
