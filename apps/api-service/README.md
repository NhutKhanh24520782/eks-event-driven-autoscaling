# API Service — Backend Service

**Phân công thực hiện:** Phát (Backend Engineer)  
**Chức năng chính:** Nhận HTTP request từ Client / Load Balancer, validate payload và đẩy job vào AWS SQS (`jobs-queue`).

---

## 1. API Endpoints

### 1.1 `GET /health`
Kiểm tra tình trạng hoạt động của service (dùng cho Kubernetes Liveness / Readiness probes).

- **Method:** `GET`
- **Response (200 OK):**
```json
{
  "status": "healthy",
  "service": "api-service",
  "uptime": 120,
  "timestamp": "2026-10-28T14:00:00.000Z",
  "queueConfigured": true
}
```

---

### 1.2 `POST /jobs`
Tạo job mới và đẩy vào AWS SQS.

- **Method:** `POST`
- **Headers:** `Content-Type: application/json`
- **Request Body:**
```json
{
  "job_id": "optional-custom-uuid-or-id",
  "payload": {
    "taskId": 12345,
    "action": "PROCESS_IMAGE"
  },
  "processTimeMs": 1500,
  "shouldFail": false
}
```
> *Ghi chú:* 
> - Nếu `job_id` bị bỏ trống, hệ thống sẽ tự sinh bằng `uuidv4()`.
> - `processTimeMs`: Thời gian giả lập xử lý của worker (mặc định: `1000ms`).
> - `shouldFail`: Dùng để test kịch bản retry / DLQ (nếu `true`, worker sẽ throw error).

- **Response (202 Accepted):**
```json
{
  "status": "accepted",
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "message_id": "85dc3997-b847-4977-802a-97a66f542981",
  "processTimeMs": 1500,
  "timestamp": "2026-10-28T14:00:01.000Z"
}
```

- **Error Responses:**
  - `400 Bad Request`: Payload không phải JSON hợp lệ.
  - `500 Internal Server Error`: Thiếu biến môi trường `QUEUE_URL`.
  - `503 Service Unavailable`: Gặp lỗi khi gửi message đến AWS SQS.

---

## 2. Biến môi trường (Environment Variables)

| Tên biến | Mặc định | Mô tả |
| :--- | :--- | :--- |
| `PORT` | `8080` | Port lắng nghe của HTTP server |
| `AWS_REGION` | `ap-southeast-1` | AWS Region chứa SQS |
| `QUEUE_URL` | *(Bắt buộc)* | URL đầy đủ của SQS Queue |
| `AWS_ENDPOINT_URL` | *(Trống)* | Chỉ định khi test với LocalStack (vd: `http://localhost:4566`) |
| `NODE_ENV` | `production` | Môi trường chạy (development / production) |

---

## 3. Quyền hạn AWS IAM (SQS Permissions)

Service chạy trên EKS sử dụng IAM Roles for Service Accounts (IRSA).  
Quyền tối thiểu cần cấp cho API Service:
```json
{
  "Effect": "Allow",
  "Action": [
    "sqs:SendMessage"
  ],
  "Resource": "arn:aws:sqs:ap-southeast-1:<ACCOUNT_ID>:jobs-queue"
}
```

---

## 4. Hướng dẫn chạy và kiểm thử

### 4.1 Chạy trực tiếp với Node.js (Local)

1. Cài đặt dependencies:
   ```bash
   cd apps/api-service
   npm install
   ```

2. Tạo file `.env`:
   ```env
   PORT=8080
   AWS_REGION=ap-southeast-1
   QUEUE_URL=https://sqs.ap-southeast-1.amazonaws.com/123456789012/jobs-queue
   # AWS_ENDPOINT_URL=http://localhost:4566 # Bỏ comment nếu dùng LocalStack
   ```

3. Khởi chạy:
   ```bash
   npm start
   ```

### 4.2 Chạy bằng Docker

1. Build Docker image:
   ```bash
   docker build -t api-service:latest -f apps/api-service/Dockerfile apps/api-service
   ```

2. Chạy container:
   ```bash
   docker run -d --name api-service \
     -p 8080:8080 \
     -e AWS_REGION=ap-southeast-1 \
     -e QUEUE_URL=https://sqs.ap-southeast-1.amazonaws.com/123456789012/jobs-queue \
     api-service:latest
   ```

### 4.3 Kiểm tra hoạt động bằng `curl`

- **Kiểm tra Health:**
  ```bash
  curl -i http://localhost:8080/health
  ```

- **Gửi Job:**
  ```bash
  curl -i -X POST http://localhost:8080/jobs \
    -H "Content-Type: application/json" \
    -d '{"payload": {"sampleData": "test-123"}, "processTimeMs": 500}'
  ```

---

## 5. Xử lý tắt ứng dụng an toàn (Graceful Shutdown)

Khi nhận tín hiệu `SIGTERM` (từ Kubernetes khi Pod bị scale-down hoặc terminate):
1. Không nhận kết nối HTTP mới.
2. Hoàn thành toàn bộ request HTTP đang xử lý.
3. Đóng HTTP server và thoát sạch với mã `0`.
