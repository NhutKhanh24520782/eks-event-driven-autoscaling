/**
 * Test Kịch Bản 1: Gửi Job Bình Thường (Normal Job Flow)
 * 
 * Mục đích:
 * - Kiểm tra API POST /jobs nhận request và trả về mã 202 Accepted.
 * - Kiểm tra Worker Service poll được message từ SQS và xử lý thành công.
 * - Kiểm tra chỉ số Grafana 'worker_jobs_processed_total' tăng lên.
 *
 * Cách chạy:
 *   node scripts/local/tests/test-1-normal.js
 * hoặc nếu chạy qua Docker:
 *   docker compose -f docker-compose.local.yml exec api-service node /scripts-test/test-1-normal.js
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
  console.log('🧪 TEST 1: GỬI JOB BÌNH THƯỜNG (NORMAL WORKFLOW)');
  console.log('=============================================================\n');

  try {
    // 1. Kiểm tra Worker health trước khi test
    console.log('[1/4] Kiểm tra trạng thái Worker ban đầu...');
    const initWorkerHealth = await sendHttpRequest(`${WORKER_BASE}/health`);
    const initialProcessed = initWorkerHealth.data.total_processed || 0;
    console.log(` -> Worker ID: ${initWorkerHealth.data.worker_id}`);
    console.log(` -> Số job đã xử lý trước đó: ${initialProcessed}`);

    // 2. Gửi 3 Job bình thường vào API
    const jobCount = 3;
    console.log(`\n[2/4] Gửi ${jobCount} job bình thường vào API (POST ${API_BASE}/jobs)...`);

    for (let i = 1; i <= jobCount; i++) {
      const payload = {
        payload: {
          task: 'calculate_matrix',
          index: i,
          timestamp: new Date().toISOString()
        },
        processTimeMs: 800 // Worker xử lý trong 800ms
      };

      const res = await sendHttpRequest(`${API_BASE}/jobs`, 'POST', payload);
      if (res.status === 202) {
        console.log(`  ✅ Job ${i} gửi thành công! (HTTP 202 Accepted, Job ID: ${res.data.job_id})`);
      } else {
        console.error(`  ❌ Job ${i} thất bại! Status: ${res.status}`, res.data);
      }
    }

    // 3. Đợi Worker xử lý xong
    console.log('\n[3/4] Đang chờ Worker xử lý các jobs trong hàng đợi SQS...');
    const waitSeconds = 4;
    for (let s = 1; s <= waitSeconds; s++) {
      process.stdout.write(`  ⏳ Đang chờ... ${s}/${waitSeconds}s\r`);
      await sleep(1000);
    }
    console.log('\n');

    // 4. Kiểm tra lại Worker health sau khi xử lý
    console.log('[4/4] Xác nhận kết quả trên Worker...');
    const afterWorkerHealth = await sendHttpRequest(`${WORKER_BASE}/health`);
    const afterProcessed = afterWorkerHealth.data.total_processed || 0;
    const processedDiff = afterProcessed - initialProcessed;

    console.log(` -> Tổng số job xử lý hiện tại: ${afterProcessed} (+${processedDiff})`);

    if (processedDiff >= jobCount) {
      console.log('\n🎉 TEST 1 THÀNH CÔNG! Worker đã xử lý đủ tất cả job.');
      console.log('👉 Hãy nhìn vào Grafana (http://localhost:3002):');
      console.log('   - Cột "Total Jobs Processed" đã tăng lên.');
      console.log('   - Biểu đồ "Worker Processing Throughput" xuất hiện sóng nhô lên!\n');
    } else {
      console.log(`\n⚠️ Worker mới xử lý được ${processedDiff}/${jobCount} jobs. Có thể worker đang xử lý nốt.`);
    }

  } catch (error) {
    console.error('❌ Lỗi kết nối:', error.message);
    console.error('Đảm bảo bạn đã chạy: docker compose -f docker-compose.local.yml up');
  }
}

runTest();

