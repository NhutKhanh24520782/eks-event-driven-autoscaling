/**
 * Test Kịch Bản 2: Kiểm Thử Tính Idempotency (Chống xử lý trùng lặp)
 * 
 * Mục đích:
 * - Gửi 2 message có CÙNG một `job_id` vào hệ thống.
 * - SQS có thể chuyển giao message 2 lần (at-least-once delivery).
 * - Worker phải phát hiện được job thứ 2 đã tồn tại trong Deduplication Cache.
 * - Worker chỉ xử lý nghiệp vụ 1 LẦN DUY NHẤT, job thứ 2 bị bỏ qua (IDEMPOTENT SKIP).
 * - Kiểm tra chỉ số Grafana 'worker_jobs_duplicate_total' tăng thêm 1.
 *
 * Cách chạy:
 *   node scripts/local/tests/test-2-idempotency.js
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
  console.log('🧪 TEST 2: KIỂM THỬ TÍNH KHÔNG ĐỔI (IDEMPOTENCY)');
  console.log('=============================================================\n');

  try {
    // 1. Kiểm tra trạng thái Worker trước test
    console.log('[1/4] Kiểm tra trạng thái Worker ban đầu...');
    const initWorkerHealth = await sendHttpRequest(`${WORKER_BASE}/health`);
    const initialProcessed = initWorkerHealth.data.total_processed || 0;
    const initialDuplicates = initWorkerHealth.data.total_duplicates || 0;
    console.log(` -> Số job đã xử lý: ${initialProcessed}`);
    console.log(` -> Số duplicate đã chặn trước đó: ${initialDuplicates}`);

    // 2. Tạo một ID duy nhất và gửi 2 lần cùng một ID
    const duplicateJobId = `job-idem-${Date.now()}`;
    console.log(`\n[2/4] Tạo mã job_id duy nhất: "${duplicateJobId}"`);

    console.log('  -> Gửi LẦN 1 vào API...');
    const res1 = await sendHttpRequest(`${API_BASE}/jobs`, 'POST', {
      job_id: duplicateJobId,
      payload: { action: 'transfer_funds', amount: 500000 },
      processTimeMs: 1000
    });
    console.log(`     ✅ Lần 1 gửi thành công! (HTTP ${res1.status}, job_id: ${res1.data.job_id})`);

    // Gửi ngay LẦN 2 với đúng job_id đó
    console.log('  -> Gửi LẦN 2 (Trùng lặp) vào API...');
    const res2 = await sendHttpRequest(`${API_BASE}/jobs`, 'POST', {
      job_id: duplicateJobId,
      payload: { action: 'transfer_funds', amount: 500000 },
      processTimeMs: 1000
    });
    console.log(`     ✅ Lần 2 gửi thành công! (HTTP ${res2.status}, job_id: ${res2.data.job_id})`);

    // 3. Đợi Worker xử lý cả 2 message
    console.log('\n[3/4] Đang chờ Worker nhận và phân biệt message trùng...');
    const waitSeconds = 5;
    for (let s = 1; s <= waitSeconds; s++) {
      process.stdout.write(`  ⏳ Đang chờ... ${s}/${waitSeconds}s\r`);
      await sleep(1000);
    }
    console.log('\n');

    // 4. Kiểm tra lại Worker metrics
    console.log('[4/4] Xác minh kết quả Idempotency...');
    const afterWorkerHealth = await sendHttpRequest(`${WORKER_BASE}/health`);
    const afterProcessed = afterWorkerHealth.data.total_processed || 0;
    const afterDuplicates = afterWorkerHealth.data.total_duplicates || 0;

    const processedDiff = afterProcessed - initialProcessed;
    const duplicatesDiff = afterDuplicates - initialDuplicates;

    console.log(` -> Tổng số job xử lý thực tế: ${afterProcessed} (+${processedDiff})`);
    console.log(` -> Tổng số message trùng bị chặn: ${afterDuplicates} (+${duplicatesDiff})`);

    if (processedDiff === 1 && duplicatesDiff >= 1) {
      console.log('\n🎉 TEST 2 THÀNH CÔNG VƯỢT TRỘI!');
      console.log('   Worker chỉ xử lý job ĐÚNG 1 LẦN và đã bỏ qua message trùng lặp an toàn.');
      console.log('👉 Hãy nhìn vào Grafana (http://localhost:3002):');
      console.log('   - Thẻ vàng "Duplicate Jobs Skipped" đã tăng lên +1!');
      console.log('   - Biểu đồ "Idempotency: Duplicates Detected" đã nhảy vọt lên đỉnh nhọn!\n');
    } else {
      console.log(`\n⚠️ Kết quả: Processed diff = ${processedDiff}, Duplicates diff = ${duplicatesDiff}`);
    }

  } catch (error) {
    console.error('❌ Lỗi kết nối:', error.message);
    console.error('Đảm bảo bạn đã chạy: docker compose -f docker-compose.local.yml up');
  }
}

runTest();

