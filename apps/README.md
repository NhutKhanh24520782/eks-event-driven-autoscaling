# Báo Cáo Triển Khai Backend (API Service & Worker Service)

> **Người thực hiện:** Phát (Backend Engineer)  
> **Nhiệm vụ:** Xây dựng hoàn chỉnh API Service, Worker Service, Dockerfile, cấu hình dependencies, cơ chế Idempotency, Graceful Shutdown và kiểm thử tích hợp SQS.

---

## 📑 Mục lục
1. [Tổng quan kiến trúc Backend](#1-tổng-quan-kiến-trúc-backend)
2. [Chi tiết các thay đổi & mã nguồn đã thực hiện](#2-chi-tiết-các-thay-đổi--mã-nguồn-đã-thực-hiện)
   - [2.1 API Service (`apps/api-service`)](#21-api-service-appsapi-service)
   - [2.2 Worker Service (`apps/worker-service`)](#22-worker-service-appsworker-service)
   - [2.3 Cấu hình môi trường chạy Local Mock](#23-cấu-hình-môi-trường-chạy-local-mock)
3. [Bảng hợp đồng tích hợp (Integration Contract)](#3-bảng-hợp-đồng-tích-hợp-integration-contract)
4. [Kết quả kiểm thử thực tế (Evidence)](#4-kết-quả-kiểm-thử-thực-tế-evidence)
5. [Hướng dẫn vận hành & kiểm thử](#5-hướng-dẫn-vận-hành--kiểm-thử)

---

## 1. Tổng quan kiến trúc Backend

```text
[Client / k6 / Ingress]
         │
         ▼ (HTTP POST /jobs)
┌─────────────────────────────────┐
│     API Service (Port 8080)     │
│ - Validate JSON payload         │
│ - Generate / Preserve Job UUID  │
│ - AWS SDK v3: SendMessage       │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│     AWS SQS (jobs-queue)        │
│  (Dead Letter Queue: ...-dlq)   │
└────────────────┬────────────────┘
                 │ (Long Polling: 20s)
                 ▼
┌─────────────────────────────────┐
│   Worker Service (Port 8081)    │
│ - In-Memory Idempotency Cache   │
│ - Configurable Workload (ms)    │
│ - Retry & Redelivery Detection  │
│ - Graceful Shutdown (SIGTERM)   │
│ - Health & Prometheus Metrics   │
└─────────────────────────────────┘
```

---

## 2. Chi tiết các thay đổi & mã nguồn đã thực hiện

### 2.1 API Service (`apps/api-service`)

| File | Thay đổi / Tính năng mới |
| :--- | :--- |
| `api-service/package.json` | Khởi tạo dự án Node.js với các thư viện: `@aws-sdk/client-sqs` (v3), `express`, `uuid`, `dotenv`. |
| `api-service/src/main.js` | **Code hoàn chỉnh toàn bộ logic API:**<br>• `POST /jobs`: Tiếp nhận job, kiểm tra body hợp lệ, tự động gán UUID nếu client không truyền, đẩy message vào SQS bằng `SendMessageCommand` kèm Message Attributes (`JobId`, `CreatedAt`), trả về HTTP `202 Accepted`.<br>• `GET /health`: Cung cấp health check chuẩn cho Kubernetes Liveness/Readiness probe.<br>• `autoCreateQueueIfMock()`: Tự động khởi tạo queue khi chạy với mock local giúp test tiện lợi không cần cấu hình thủ công.<br>• **Graceful Shutdown**: Bắt tín hiệu `SIGTERM`/`SIGINT`, đóng HTTP server sạch sẽ trước khi thoát. |
| `api-service/Dockerfile` | Multi-stage build (Stage 1 deps, Stage 2 runner), cài đặt `dumb-init` làm PID 1 để chuyển tiếp tín hiệu ngắt chính xác, chạy bằng non-root user `node` để đảm bảo an toàn bảo mật container. |
| `api-service/README.md` | Tài liệu hướng dẫn đầy đủ cho API Service: API contract, các mã lỗi, biến môi trường, IAM policy cần thiết và lệnh curl kiểm thử. |

---

### 2.2 Worker Service (`apps/worker-service`)

| File | Thay đổi / Tính năng mới |
| :--- | :--- |
| `worker-service/package.json` | Cấu hình dependencies: `@aws-sdk/client-sqs` (v3) và `dotenv`. |
| `worker-service/src/main.js` | **Code hoàn chỉnh toàn bộ logic Worker:**<br>• **SQS Long Polling**: Sử dụng `WaitTimeSeconds` (mặc định 20s, local 5s) và batch size linh hoạt để giảm số lượng request rỗng.<br>• **Idempotent Processing**: Tích hợp lớp `IdempotencyCache` lưu các `job_id` đã xử lý thành công với thời gian sống (TTL = 10 phút), tự động giải phóng bộ nhớ. Khi phát hiện message trùng lặp (do cơ chế at-least-once của SQS), worker log `[IDEMPOTENT SKIP]` và xóa message ngay lập tức mà không xử lý lại.<br>• **Retry & Redelivery**: Đọc `ApproximateReceiveCount`. Nếu xử lý thất bại, không xóa message để SQS chuyển giao lại hoặc đẩy sang DLQ sau khi vượt quá `maxReceiveCount`.<br>• **Configurable Workload**: Nhận `processTimeMs` từ payload hoặc biến môi trường để giả lập thời gian xử lý; nhận `shouldFail: true` để chủ động kiểm thử kịch bản lỗi.<br>• **Graceful Shutdown**: Theo dõi biến đếm `inFlightJobs`. Khi nhận `SIGTERM` từ Kubernetes (scale down), worker ngưng nhận job mới, chờ toàn bộ job đang xử lý dở hoàn tất sạch sẽ rồi mới exit.<br>• **HTTP Health & Metrics Server**: Mở cổng `8081` cung cấp `GET /health` (trạng thái JSON) và `GET /metrics` (chuẩn Prometheus text format). |
| `worker-service/Dockerfile` | Multi-stage build, tích hợp `dumb-init`, non-root user `node`, mở cổng `8081`. |
| `worker-service/README.md` | Tài liệu chi tiết cơ chế hoạt động, bảng biến môi trường, chính sách retry, IAM policy và hướng dẫn kiểm thử. |

---

### 2.3 Cấu hình môi trường chạy Local Mock

| File | Mô tả |
| :--- | :--- |
| `docker-compose.local.yml` | Cấu hình Docker Compose chạy toàn bộ hệ thống cục bộ gồm **ElasticMQ SQS Mock + API Service + Worker Service**. Đã xử lý tránh xung đột dải cổng Hyper-V trên Windows (map API ra cổng `3000` và Worker Health ra cổng `3001`). |
| `scripts/local/elasticmq.conf` | Định nghĩa sẵn 2 hàng đợi: `jobs-queue` và `jobs-queue-dlq` kèm chính sách chuyển vào DLQ (`maxReceiveCount = 3`). |

---

## 3. Bảng hợp đồng tích hợp (Integration Contract)

| Tiêu chí | Giá trị quy định |
| :--- | :--- |
| **API Endpoint tạo job** | `POST /jobs` |
| **API Health check** | `GET /health` (Port 8080) |
| **Worker Health & Metrics** | `GET /health`, `GET /metrics` (Port 8081) |
| **Tên hàng đợi SQS** | `jobs-queue` |
| **Hàng đợi lỗi (DLQ)** | `jobs-queue-dlq` |
| **AWS Region mặc định** | `ap-southeast-1` |
| **Cấu trúc Message Body** | `JSON: { "job_id": "uuid", "payload": { ... }, "processTimeMs": 1000, "createdAt": "..." }` |
| **Quyền SQS của API** | `sqs:SendMessage` |
| **Quyền SQS của Worker** | `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` |

---

## 4. Kết quả kiểm thử thực tế (Evidence)

Hệ thống đã được build container và chạy thử nghiệm thực tế thành công:

### Test 1: Gửi Job thành công
```powershell
Invoke-RestMethod -Uri http://localhost:3000/jobs -Method Post -ContentType "application/json" -Body '{"payload": {"task": "demo"}, "processTimeMs": 1200}'
```
- **API Response:** `status: accepted`, `job_id: beedb708-...`, `message_id: e790cfd2-...` (HTTP 202).
- **Worker Log:**
  ```text
  [WORKER] [POLL] Received 1 message(s) from SQS.
  [WORKER] [JOB START] job_id=beedb708-... process_time_ms=1200
  [WORKER] [JOB SUCCESS] duration_ms=1201 total_processed=1
  [WORKER] [DELETED] message_id=e790cfd2-... removed from queue.
  ```

### Test 2: Chống xử lý lặp lại (Idempotency)
Gửi 2 request có cùng `job_id: "test-idempotent-999"`:
- Request 1: Worker xử lý bình thường (`total_processed: 2`).
- Request 2: Worker phát hiện trùng lặp:
  ```text
  [WORKER] [IDEMPOTENT SKIP] Duplicate detected for job_id=test-idempotent-999. Deleting without reprocessing.
  [WORKER] [DELETED] message_id=... removed from queue.
  ```
- **Worker Health Metric:** Báo cáo chính xác `total_received: 3, total_processed: 2, total_duplicates: 1`.

---

## 5. Hướng dẫn vận hành & kiểm thử

### Khởi động hệ thống
```powershell
# Chạy ở chế độ nền
docker compose -f docker-compose.local.yml up -d

# Hoặc vừa chạy vừa xem log trực tiếp:
docker compose -f docker-compose.local.yml up
```

### Xem log theo thời gian thực
```powershell
# Xem log toàn bộ hệ thống
docker compose -f docker-compose.local.yml logs -f

# Hoặc chỉ xem riêng Worker
docker compose -f docker-compose.local.yml logs -f worker-service
```

### Dừng hệ thống
```powershell
docker compose -f docker-compose.local.yml down
```
