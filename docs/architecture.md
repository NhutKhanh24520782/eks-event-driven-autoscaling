# Architecture Diagram

```text
Internet
   ↓
ALB
   ↓
API Pods
   ↓
SQS
   ↓
KEDA
   ↓
Worker Pods
   ↓
Processing
```

## Observability
```text
Prometheus → Grafana
       ↓
      Loki
```

## Infrastructure
```text
Terraform
   ↓
VPC + Multi-AZ + EKS + SQS
```

*Note: The project strictly uses EKS with managed node groups. Karpenter or any other node autoscaling is NOT used. KEDA is exclusively used for Pod-level event-driven autoscaling.*
