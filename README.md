# Multi-AZ Fault-Tolerant Event-Driven Autoscaling for Microservices on Amazon EKS

## Overall Objectives
- Build a highly available, event-driven microservices architecture on AWS.
- Use Amazon EKS as the Kubernetes platform (focus on Pod-level scaling, NO Karpenter, NO Node scaling).
- Implement robust event-driven autoscaling using KEDA based on Amazon SQS queue depth.
- Establish fault tolerance in a Multi-AZ environment.
- Implement comprehensive Observability using Prometheus, Grafana, and Loki.
- Perform control-loop latency measurement (T0 to T6).
- Set up an automated Chaos Engineering Pipeline using GitHub Actions.

## Architecture Diagram
```text
Internet -> ALB -> API Pods -> SQS -> KEDA -> Worker Pods -> Processing
```
*(Observability: Prometheus -> Grafana | Loki)*

## Tech Stack
| Layer | Technology | Role |
| --- | --- | --- |
| Infrastructure | Terraform, AWS | VPC, Multi-AZ, EKS, SQS, ALB, IAM |
| Routing & Ingress | AWS ALB | Route external traffic to API service |
| Messaging | Amazon SQS | Asynchronous message queue for jobs |
| Compute | Amazon EKS, Docker | Host API and Worker containers |
| Autoscaling | KEDA, HPA | Scale worker pods based on SQS (HPA used as baseline comparison) |
| Observability | Prometheus, Grafana, Loki | Metrics, logs, control-loop latency tracking |
| Automation & Chaos | GitHub Actions, k6 | Load testing and fault injection pipeline |

## Directory Structure
Refer to the directory tree in the project root. Key directories:
- `apps/`: Node.js API and Worker services.
- `k8s/`: Kubernetes manifests (Deployments, Services, ConfigMaps, Secrets, KEDA/HPA, Topology Spread).
- `terraform/`: Infrastructure as Code (VPC, EKS, SQS, ALB, IAM). No Karpenter.
- `observability/`: Prometheus, Grafana, Loki configurations.
- `scripts/`: Chaos engineering and load testing scripts.
- `docs/`: Architecture, Control-Loop Latency, Fault Tolerance, Experiments.

## Setup Instructions
1. **Configure AWS Credentials**
   - TODO: to be completed
2. **Terraform Init & Apply**
   - TODO: to be completed
3. **Build & Push Images**
   - TODO: to be completed
4. **Deploy to K8s**
   - TODO: to be completed
5. **Run Load Test & Chaos Pipeline**
   - TODO: to be completed
