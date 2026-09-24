import os

files = {
    "terraform/modules/vpc/main.tf": "# TODO: Implement Multi-AZ VPC resource\nresource \"aws_vpc\" \"placeholder\" {\n  # ...\n}\n",
    "terraform/modules/vpc/variables.tf": "# TODO: Define variables for Multi-AZ VPC\nvariable \"vpc_cidr\" {\n  # ...\n}\n",
    "terraform/modules/vpc/outputs.tf": "# TODO: Define outputs for Multi-AZ VPC\noutput \"vpc_id\" {\n  # ...\n}\n",
    "terraform/modules/eks/main.tf": "# TODO: Implement EKS cluster Multi-AZ + IRSA resource\nresource \"aws_eks_cluster\" \"placeholder\" {\n  # ...\n}\n",
    "terraform/modules/eks/variables.tf": "# TODO: Define variables for EKS cluster\nvariable \"cluster_name\" {\n  # ...\n}\n",
    "terraform/modules/eks/outputs.tf": "# TODO: Define outputs for EKS cluster\noutput \"cluster_endpoint\" {\n  # ...\n}\n",
    "terraform/modules/alb/main.tf": "# TODO: Implement AWS Load Balancer Controller/ALB resource\nresource \"aws_lb\" \"placeholder\" {\n  # ...\n}\n",
    "terraform/modules/sqs/main.tf": "# TODO: Implement SQS queue + DLQ resource\nresource \"aws_sqs_queue\" \"placeholder\" {\n  # ...\n}\n",
    "terraform/modules/dynamodb/main.tf": "# TODO: Implement dedup table for idempotency\nresource \"aws_dynamodb_table\" \"placeholder\" {\n  # ...\n}\n",
    "terraform/environments/dev/main.tf": "# TODO: Call modules (vpc, eks, alb, sqs, dynamodb) for dev environment\nmodule \"vpc\" {\n  source = \"../../modules/vpc\"\n  # ...\n}\n",
    "terraform/environments/dev/terraform.tfvars.example": "# TODO: Provide example values for variables in dev environment\nvpc_cidr = \"10.0.0.0/16\"\n",
    "terraform/README.md": "# Terraform Configuration\n\nTODO: Explains how to run terraform init/plan/apply (DO NOT run it yet)\n",
    
    "apps/api-service/Dockerfile": "# TODO: Placeholder Dockerfile for API Service\nFROM alpine:latest\n# ...\n",
    "apps/api-service/src/main.js": "// TODO: Placeholder entrypoint for API Service (receive HTTP requests, push jobs to SQS)\nfunction main() {\n  // ...\n}\n",
    "apps/api-service/README.md": "# API Service\n\nRole: Receive HTTP requests, push jobs to SQS.\n",

    "apps/worker-service/Dockerfile": "# TODO: Placeholder Dockerfile for Worker Service\nFROM alpine:latest\n# ...\n",
    "apps/worker-service/src/main.js": "// TODO: Placeholder entrypoint for Worker Service (consume SQS, idempotent processing, graceful SIGTERM shutdown)\nfunction main() {\n  // ...\n}\n",
    "apps/worker-service/README.md": "# Worker Service\n\nRole: Consume SQS, idempotent processing, graceful SIGTERM shutdown.\n",

    "k8s/base/deployment-api.yaml": "# TODO: Placeholder Deployment for API Service\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: api-service\n# ...\n",
    "k8s/base/deployment-worker.yaml": "# TODO: Placeholder Deployment for Worker Service\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: worker-service\n# ...\n",
    "k8s/base/service.yaml": "# TODO: Placeholder Service for API Service\napiVersion: v1\nkind: Service\nmetadata:\n  name: api-service\n# ...\n",
    "k8s/base/ingress.yaml": "# TODO: Placeholder Ingress for API Service\napiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: api-ingress\n# ...\n",
    "k8s/autoscaling/keda-scaledobject.yaml": "# TODO: Placeholder ScaledObject for KEDA autoscaling\napiVersion: keda.sh/v1alpha1\nkind: ScaledObject\nmetadata:\n  name: worker-scaledobject\n# ...\n",
    "k8s/autoscaling/hpa-baseline.yaml": "# TODO: Placeholder HPA for baseline autoscaling\napiVersion: autoscaling/v2\nkind: HorizontalPodAutoscaler\nmetadata:\n  name: api-hpa\n# ...\n",
    "k8s/topology/README.md": "# Topology Spread Constraints / Pod AntiAffinity\n\nTODO: Note topologySpreadConstraints / podAntiAffinity - not yet applied\n",

    "observability/prometheus/values.yaml": "# TODO: Placeholder values.yaml for Prometheus Helm chart\nprometheus:\n  # ...\n",
    "observability/prometheus/README.md": "# Prometheus Configuration\n\nTODO: Describe Prometheus setup\n",
    "observability/grafana/dashboards/README.md": "# Grafana Dashboards\n\nTODO: List of dashboards to build:\n- Queue Length\n- Replicas\n- T0-T5 latency\n- Recovery Time\n",
    "observability/loki/README.md": "# Loki Configuration\n\nTODO: Placeholder for Loki setup\n",

    "scripts/load-test/k6-workload.js": "// TODO: Placeholder script for k6 load test\n// Load levels: 100 / 500 / 1000 / burst 5000 msg/s\nexport default function () {\n  // ...\n}\n",
    "scripts/chaos/pod-failure.sh": "#!/bin/bash\n# TODO: Placeholder script describing pod failure scenario\n# ...\n",
    "scripts/chaos/node-failure.sh": "#!/bin/bash\n# TODO: Placeholder script describing node failure scenario\n# ...\n",
    "scripts/chaos/az-failure.md": "# AZ Failure Scenario\n\nTODO: Placeholder describing AZ failure scenario\n",
    "scripts/metrics/collect-control-loop-latency.md": "# Collect Control-Loop Latency\n\nTODO: Describe how to measure T0->T5\n",

    ".github/workflows/chaos-pipeline.yml": "# TODO: Placeholder GitHub Actions workflow\n# Steps:\n# 1. deploy\n# 2. load test\n# 3. inject failure\n# 4. collect metrics\n# 5. report\nname: Chaos Pipeline\non: [push]\njobs:\n  chaos:\n    runs-on: ubuntu-latest\n    steps:\n      - name: TODO deploy\n        run: echo \"deploy\"\n",

    "docs/architecture.md": "# Architecture Diagram\n\nClient -> AWS ALB -> API Service -> Amazon SQS -> Worker Pods (KEDA + HPA autoscaling)\n",
    "docs/control-loop-latency.md": "# Control-Loop Latency\n\nTODO: Explain T0-T5 and the latency formulas\n",
    "docs/experiments.md": "# Experiments\n\nTODO: Table of experiments grouped by the 3 priority tiers: Must-have / Nice-to-have / Wow feature\n",
    "docs/evidence/.gitkeep": "",

    ".gitignore": \"\"\"# Terraform
.terraform/
*.tfstate
*.tfstate.backup

# Node
node_modules/
dist/

# Python
__pycache__/
*.pyc

# Docker
.docker/

# IDE
.vscode/
.idea/
*.swp
\"\"\"
}

readme_content = \"\"\"# Multi-AZ Fault-Tolerant Event-Driven Autoscaling: Control-Loop Latency Analysis for Microservices on AWS
**Phân tích Độ trễ Vòng lặp Điều khiển cho Microservices trên AWS (Tự động mở rộng quy mô Hướng sự kiện, Chịu lỗi Đa vùng sẵn sàng)**

## Overall Objectives
- Build a highly available, event-driven microservices architecture on AWS.
- Implement robust autoscaling using KEDA and HPA based on queue metrics.
- Perform control-loop latency analysis (T0 to T5).
- Establish an automated Chaos Engineering Pipeline to test fault tolerance (Pod, Node, AZ failures).
- Ensure idempotency in message processing using DynamoDB and SQS.

## Architecture Diagram
```text
Client -> AWS ALB -> API Service -> Amazon SQS -> Worker Pods (KEDA + HPA autoscaling)
```

## Tech Stack
| Layer | Technology | Role |
| --- | --- | --- |
| Infrastructure | Terraform, AWS (VPC, EKS) | Provision network and Kubernetes cluster |
| Routing & Ingress | AWS ALB | Route external traffic to API service |
| Messaging | Amazon SQS | Queue events for asynchronous processing |
| Deduplication | Amazon DynamoDB | Ensure idempotent processing for workers |
| Compute | Kubernetes (EKS), Docker | Host API and Worker containers |
| Autoscaling | KEDA, HPA | Scale worker pods based on SQS queue length |
| Observability | Prometheus, Grafana, Loki | Monitor metrics, latency, and logs |
| Automation & Chaos | GitHub Actions, k6 | CI/CD, load testing, fault injection pipeline |

## Directory Structure
- `terraform/`: Infrastructure as Code for VPC, EKS, ALB, SQS, DynamoDB.
- `apps/`: Source code for the API Service and Worker Service.
- `k8s/`: Kubernetes manifests for deployment, services, ingress, and autoscaling.
- `observability/`: Configurations for Prometheus, Grafana, and Loki.
- `scripts/`: Automation scripts for load testing, chaos injection, and metrics collection.
- `.github/workflows/`: CI/CD pipelines including the automated chaos engineering pipeline.
- `docs/`: Project documentation covering architecture, latency analysis, and experiments.
- `docs/evidence/`: Directory to store screenshots and logs of results per phase.

## Setup Instructions
1. **Configure AWS Credentials**
   - TODO: to be completed in Phase 1
2. **Terraform Init & Apply**
   - TODO: to be completed in Phase 2
3. **Build & Push Image**
   - TODO: to be completed in Phase 3
4. **Deploy to K8s**
   - TODO: to be completed in Phase 4
5. **Run Load Test**
   - TODO: to be completed in Phase 5

## Roadmap
| Phase | Duration | Description |
| --- | --- | --- |
| Phase 1 | 2 Weeks | Architecture Design & AWS Setup |
| Phase 2 | 3 Weeks | Infrastructure as Code (Terraform) |
| Phase 3 | 2 Weeks | Microservices Development |
| Phase 4 | 3 Weeks | Kubernetes Deployment & Autoscaling |
| Phase 5 | 2 Weeks | Observability Implementation |
| Phase 6 | 2 Weeks | Chaos Engineering & Load Testing |
| Phase 7 | 2 Weeks | Latency Analysis & Final Report |

## Team Assignment
| Member | Primary Role |
| --- | --- |
| Member 1 | Cloud Infrastructure & Terraform |
| Member 2 | Microservices & Kubernetes |
| Member 3 | Observability & Autoscaling |
| Member 4 | Chaos Engineering & Testing |

## Links
- [Architecture](docs/architecture.md)
- [Control-Loop Latency](docs/control-loop-latency.md)
- [Experiments](docs/experiments.md)
\"\"\"

files["README.md"] = readme_content

base_dir = r"d:\distributed_system"
for path, content in files.items():
    full_path = os.path.join(base_dir, path)
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    with open(full_path, "w", encoding="utf-8") as f:
        f.write(content)

print("Scaffold created successfully.")
