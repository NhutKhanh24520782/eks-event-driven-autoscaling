/**
 * Script Tổng Hợp: Chạy Toàn Bộ Các Bài Test Local cho Phát (Backend)
 * 
 * Cách chạy:
 *   node scripts/local/tests/run-all.js
 */

const { fork } = require('child_process');
const path = require('path');

const tests = [
  { name: 'Test 1: Gửi Job Bình Thường', file: 'test-1-normal.js' },
  { name: 'Test 2: Kiểm Thử Idempotency (Trùng job_id)', file: 'test-2-idempotency.js' },
  { name: 'Test 3: Kiểm Thử Lỗi & DLQ (Dead Letter Queue)', file: 'test-3-dlq-retry.js' }
];

function runScript(filePath) {
  return new Promise((resolve) => {
    const child = fork(filePath);
    child.on('close', (code) => {
      resolve(code);
    });
  });
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function main() {
  console.clear();
  console.log('╔══════════════════════════════════════════════════════════════════╗');
  console.log('║   BỘ KIỂM THỬ TÍCH HỢP TOÀN DIỆN CHO BACKEND (PHÁT)             ║');
  console.log('║   Môi trường: Docker Compose + ElasticMQ (SQS) + Grafana         ║');
  console.log('╚══════════════════════════════════════════════════════════════════╝\n');
  console.log('💡 HÃY MỞ TRÌNH DUYỆT TẠI: http://localhost:3002');
  console.log('   (Để quan sát các biểu đồ trên Grafana nhảy số trong lúc chạy)\n');

  for (let i = 0; i < tests.length; i++) {
    const t = tests[i];
    console.log(`\n▶ [${i + 1}/${tests.length}] Đang thực thi ${t.name}...`);
    const fullPath = path.join(__dirname, t.file);
    await runScript(fullPath);
    if (i < tests.length - 1) {
      console.log('⏳ Nghỉ 3 giây trước bài test tiếp theo...');
      await sleep(3000);
    }
  }

  console.log('\n=============================================================');
  console.log('🎯 HOÀN TẤT TẤT CẢ CÁC BÀI TEST!');
  console.log('=============================================================');
  console.log('Bây giờ bạn có thể chụp ảnh màn hình Grafana (http://localhost:3002)');
  console.log('để làm bằng chứng thực nghiệm (evidence) cho báo cáo đồ án!\n');
}

main();

