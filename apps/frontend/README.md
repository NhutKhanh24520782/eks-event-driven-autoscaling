# Frontend Experiment Dashboard (rca-lab)

The experiment dashboard (`rca-lab`) is an interactive operational console served by Nginx. It provides real-time observability telemetry, control loop visualizers, 1-click reproducible load test commands, and bounded scenario injection for the **Multi-AZ Event-Driven Autoscaling (KEDA + SQS) microservices architecture**.

---

## 1. Features & Capabilities

- **Interactive T0–T6 Control Loop Timeline**:
  Visualizes every step of the event lifecycle from API submission to SQS enqueue, KEDA scaling signal, HPA rescale, Pod creation, readiness, and worker processing.
- **Multi-Category Scenario Catalog**:
  - **Load & Backlog Scenarios**:
    - `traffic-spike`: Rapid HTTP `POST /jobs` ingress burst to stress API Gateway.
    - `sqs-backlog-spike`: Direct batch injection into SQS to immediately breach KEDA `queueLength=5` threshold.
    - `slow-worker-backlog`: Heavy compute tasks (`processTimeMs=12000`) causing persistent backlog accumulation.
  - **Application Resilience**:
    - `poison-pill-dlq`: Faulty job injection (`shouldFail=true`) testing SQS visibility expiration, retries, and DLQ routing.
    - `duplicate-burst`: Idempotency stress test injecting 50% duplicate `job_id` keys to verify worker deduplication cache.
  - **Chaos & Fault Tolerance (Guarded)**:
    - `worker-pod-failure`: Controlled termination of active worker Pod to verify at-least-once delivery with zero message loss.
    - `graceful-drain`: Validates 25-second SIGTERM completion during Pod eviction or rolling update.
    - `multi-az-rebalance`: Validates topology spread constraints across `ap-southeast-1a`, `1b`, and `1c`.
- **Live System Telemetry Bar**:
  Displays real-time SQS queue depth, in-flight jobs, Ready vs Spec worker replicas, HTTP 202 acceptances, and deduplicated counts.
- **Cross-Platform Command Generator**:
  Generates 1-click copyable reproduction commands for both Windows PowerShell (`.ps1`) and Linux/macOS Bash (`.sh`).

---

## 2. Running Locally with Docker Compose

From the repository root:

```powershell
docker compose -f docker-compose.local.yml up --build -d frontend api-service worker-service prometheus grafana
```

Open `http://localhost:8181` in your browser. All scenarios with `transport='api'` or `transport='sqs'` are active against the local ElasticMQ mock.

To stop the stack:
```powershell
docker compose -f docker-compose.local.yml down
```

---

## 3. Building and Deploying to Amazon EKS

The local Nginx configuration maps `/api/` to the Compose port `8080`. For Kubernetes, build the image using `nginx.eks.conf`, which targets the internal cluster Service `http://api-service:80`:

```bash
# 1. Build Docker image with EKS Nginx configuration
docker build --build-arg NGINX_CONFIG=nginx.eks.conf \
  -t <ECR_URL>/multiaz-autoscaling/frontend:latest \
  -f apps/frontend/Dockerfile apps/frontend

# 2. Authenticate and push to Amazon ECR
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin <ECR_URL>
docker push <ECR_URL>/multiaz-autoscaling/frontend:latest

# 3. Trigger rollout on EKS
kubectl rollout restart deployment/frontend-service -n app
kubectl rollout status deployment/frontend-service -n app --timeout=5m
```

---

## 4. Safety & Security Safeguards

1. **Browser Execution Isolation**: The frontend dashboard **never** runs shell or kubectl commands directly in the browser; it provides pre-filled, strictly validated copy-only commands.
2. **Environment Awareness**: The top status badge distinguishes between `LOCAL DOCKER`, `EKS TEST`, and `OFFLINE` modes.
3. **Bounded Injections**: All runnable scenarios have hard-coded caps (10–25 jobs) to prevent uncontrolled AWS SQS cost surges.
