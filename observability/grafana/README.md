# Grafana Dashboards

This directory contains Grafana Dashboard configurations (JSON files) and instructions for importing them into Grafana.

## List of Built Dashboards

### 1. KEDA Scaling Demo (Custom)
- **Purpose:** Monitor the number of Worker Pods in real-time to prove KEDA automatically scales when there is load.
- **PromQL Query:** `kube_deployment_status_replicas_available{deployment="worker-service"}`
- **Evidence:** The line chart jumps from 1 to 4 when running K6.

### 2. Worker Service & SQS Event Monitoring (Created by Phat)
- **Purpose:** Monitor detailed operations of the Worker and SQS.
- **Included Panels:**
  - **Total Jobs Processed:** Total number of successfully processed jobs (`worker_jobs_processed_total`).
  - **Duplicate Jobs Skipped:** Number of duplicate jobs skipped (`worker_jobs_duplicate_total`).
  - **Active In-Flight Jobs:** Number of jobs currently being processed (`worker_in_flight_jobs`).
  - **Failed Jobs (DLQ Candidates):** Number of failed jobs (`worker_jobs_error_total`).
  - **Worker Processing Throughput:** Job processing rate (`rate(worker_jobs_processed_total[15s])`).
  - **Idempotency: Duplicates Detected Over Time:** Number of duplicate jobs over time.
  - **Errors & Retry Candidates (DLQ Path):** Number of errors over time.

## How to Import Dashboards
1. Open Grafana (access `http://localhost:3000` after port-forwarding).
2. Go to **Dashboards** -> **New** -> **Import**.
3. Upload the corresponding JSON file (e.g., `worker-monitoring.json`).
4. Select **Prometheus** as the Data Source.
5. Click **Import**.

## Notes
- The `worker-monitoring.json` file is configured with `"refresh": "5s"` to avoid the "Dashboard refresh interval is too low" error.
- For Prometheus to scrape metrics from the Worker, a **ServiceMonitor** must be created pointing to the `metrics` port (8081) of the `worker-service`.