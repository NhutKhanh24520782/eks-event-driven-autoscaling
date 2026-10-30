import http from 'k6/http';
import { check, sleep } from 'k6';

// Lấy URL API từ biến môi trường khi chạy lệnh
const API_URL = __ENV.API_URL || 'http://localhost:8080'; 

export const options = {
  // Thiết lập các giai đoạn (stages) để test KEDA
  stages: [
    { duration: '30s', target: 10 }, // Tăng lên 10 user ảo trong 30s
    { duration: '1m', target: 10 },  // Giữ nguyên tải
    { duration: '30s', target: 50 }, // Tăng vọt lên 50 user để ép KEDA scale
    { duration: '1m', target: 50 },  // Giữ tải cao
    { duration: '30s', target: 0 },  // Giảm tải về 0
  ],
};

export default function () {
  // Payload phải khớp với Contract trong file PDF (có job_id và payload)
  const payload = JSON.stringify({
    job_id: `job-${__VU}-${__ITER}-${Date.now()}`, 
    payload: { example: "test data" }
  });

  const params = {
    headers: { 'Content-Type': 'application/json' },
  };

  // Gửi request đến API
  const res = http.post(`${API_URL}/jobs`, payload, params);

  // Kiểm tra xem API có trả về thành công không
  check(res, {
    'status is 200 or 202': (r) => r.status === 200 || r.status === 202,
  });

  sleep(1); // Nghỉ 1 giây giữa các request
}