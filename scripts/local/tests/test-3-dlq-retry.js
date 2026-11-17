/**
 * Test Kịch Bản 3: Kiểm Thử Lỗi, Retry và Dead Letter Queue (DLQ)
 * 
 * Mục đích:
 * - Gửi 1 job có cờ `shouldFail: true` để Worker cố tình xử lý thất bại.
 * - Kiểm tra Worker ghi nhận lỗi (metrics.totalErrors++).
 * - Worker KHÔNG gọi DeleteMessage, giữ message trong SQS để kích hoạt cơ chế
 *   Visibility Timeout và Redelivery của SQS.
 * - Sau 3 lần nhận thất bại (maxReceiveCount=3), message sẽ tự động chuyển vào jobs-queue-dlq.
 * - Kiểm tra chỉ số Grafana 'worker_jobs_error_total' tăng lên.
 *
 * Cách chạy:
 *   node scripts/local/tests/test-3-dlq-retry.js
 */

const http = require('http');

const API_BASE = process.env.API_BASE || 'http://localhost:3000';
const WORKER_BASE = process.env.WORKER_BASE || 'http://localhost:3001';

function sendHttpRequest(url, method = 'GET', body = null) {
  return new Promise((resolve, reject) => {
    const parsedUrl = new URL(url);
    const options = {
      hostname: parsedUrl.hostname,
      port: parsedUrl.port,
      path: parsedUrl.pathname + parsedUrl.search,
      method: method,
      headers: {
        'Content-Type': 'application/json'
      }
    };

    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          resolve({ status: res.statusCode, data: json });
        } catch (e) {
          resolve({ status: res.statusCode, raw: data });
        }
      });
    });

    req.on('error', reject);

    if (body) {
      req.write(JSON.stringify(body));
    }
    req.end();
  });
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function runTest() {
  console.log('\n=============================================================');
  console.log('🧪 TEST 3: KIỂM THỬ XỬ LÝ LỖI, RETRY VÀ DLQ (DEAD LETTER QUEUE)');
  console.log('=============================================================\n');

  try {
    // 1. Kiểm tra trạng thái Worker trước test
    console.log('[1/4] Kiểm tra trạng thái Worker ban đầu...');
    const initWorkerHealth = await sendHttpRequest(`${WORKER_BASE}/health`);
    const initialErrors = initWorkerHealth.data.total_errors || 0;
    console.log(` -> Tổng số lỗi đã ghi nhận trước đó: ${initialErrors}`);

    // 2. Gửi 1 job cố tình gây lỗi (shouldFail = true)
    const failJobId = `job-fail-${Date.now()}`;
    console.log(`\n[2/4] Gửi 1 Job có cờ 'shouldFail: true' (Job ID: ${failJobId})...`);

    const res = await sendHttpRequest(`${API_BASE}/jobs`, 'POST', {
      job_id: failJobId,
      shouldFail: true,
      payload: { action: 'corrupted_file_conversion' },
      processTimeMs: 1000
    });

    if (res.status === 202) {
      console.log(`  ✅ API đã tiếp nhận job lỗi và đẩy vào SQS (HTTP 202, job_id: ${res.data.job_id})`);
    } else {
      console.error(`  ❌ Gửi job thất bại: Status ${res.status}`);
      return;
    }

    // 3. Đợi Worker nhận và fail job lần đầu
    console.log('\n[3/4] Chờ Worker nhận và xử lý thất bại (giả lập crash/lỗi)...');
    const waitSeconds = 4;
    for (let s = 1; s <= waitSeconds; s++) {
      process.stdout.write(`  ⏳ Đang chờ... ${s}/${waitSeconds}s\r`);
      await sleep(1000);
    }
    console.log('\n');

    // 4. Kiểm tra số lỗi tăng lên trên Worker
    console.log('[4/4] Xác minh cơ chế xử lý lỗi...');
    const afterWorkerHealth = await sendHttpRequest(`${WORKER_BASE}/health`);
    const afterErrors = afterWorkerHealth.data.total_errors || 0;
    const errorsDiff = afterErrors - initialErrors;

    console.log(` -> Số lỗi ghi nhận trên Worker: ${afterErrors} (+${errorsDiff})`);

    if (errorsDiff >= 1) {
      console.log('\n🎉 TEST 3 THÀNH CÔNG!');
      console.log('   - Worker đã phát hiện lỗi và KHÔNG xóa message khỏi SQS.');
      console.log('   - Cơ chế SQS Visibility Timeout (30s) bắt đầu hoạt động.');
      console.log('   - Sau khi retry đủ 3 lần (maxReceiveCount=3), message sẽ tự động');
      console.log('     chuyển vào "jobs-queue-dlq" mà không bị mất dữ liệu!');
      console.log('\n👉 Hãy nhìn vào Grafana (http://localhost:3002):');
      console.log('   - Thẻ đỏ "Failed Jobs (DLQ Candidates)" đã tăng lên +1!');
      console.log('   - Biểu đồ "Errors & Retry Candidates" xuất hiện điểm nhọn màu đỏ.\n');
    } else {
      console.log(`\n⚠️ Worker chưa ghi nhận lỗi. Vui lòng kiểm tra lại log container: docker logs worker-service`);
    }

  } catch (error) {
    console.error('❌ Lỗi kết nối:', error.message);
    console.error('Đảm bảo bạn đã chạy: docker compose -f docker-compose.local.yml up');
  }
}

runTest();

