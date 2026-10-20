# Infrastructure – Terraform cho EKS Event-Driven Autoscaling

Terraform code triển khai hệ thống microservices Multi-AZ trên Amazon EKS (ap-southeast-1).  
Architecture: **Client → ALB → API Pods → SQS → Worker Pods (KEDA autoscaling)**

---

## Cấu trúc thư mục

```
infra/
├── bootstrap/          # Tạo S3 bucket + DynamoDB lock (chạy 1 lần, state local)
├── envs/dev/           # Root module chính – gọi tất cả module bên dưới
└── modules/
    ├── sqs/            # Main queue + DLQ
    ├── ecr/            # ECR repositories (api, worker)
    ├── irsa/           # Reusable IRSA role module
    └── budget/         # AWS Budget cảnh báo chi phí
```

---

## Yêu cầu cài đặt

| Tool | Phiên bản khuyến nghị | Cài đặt |
|------|----------------------|---------|
| Terraform | >= 1.6 | [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) |
| AWS CLI | >= 2.x | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| kubectl | >= 1.28 | [kubernetes.io/docs](https://kubernetes.io/docs/tasks/tools/) |
| Helm | >= 3.x | [helm.sh](https://helm.sh/docs/intro/install/) |

### Cấu hình AWS Credentials

```bash
# Cách 1: AWS CLI configure
aws configure
# AWS Access Key ID: <key>
# AWS Secret Access Key: <secret>
# Default region: ap-southeast-1

# Cách 2: AWS SSO (dùng chung account nhóm)
aws sso configure
aws sso login --profile <profile-name>
export AWS_PROFILE=<profile-name>

# Xác nhận credentials
aws sts get-caller-identity
```

> **Lưu ý:** Không hardcode Access Key vào file Terraform. Credentials đọc từ environment hoặc `~/.aws/credentials`.

---

## Các bước triển khai

### Bước 1: Bootstrap Remote State (chạy 1 lần duy nhất)

```bash
cd infra/bootstrap

terraform init
terraform apply
# Ghi lại output: state_bucket_name và lock_table_name
```

### Bước 2: Cấu hình Backend cho envs/dev

Sau khi bootstrap xong, sửa file `infra/envs/dev/versions.tf`, phần `backend "s3"`:

```hcl
backend "s3" {
  bucket         = "<state_bucket_name từ output bootstrap>"
  key            = "envs/dev/terraform.tfstate"
  region         = "ap-southeast-1"
  dynamodb_table = "<lock_table_name từ output bootstrap>"
  encrypt        = true
}
```

### Bước 3: Chuẩn bị tfvars

```bash
cd infra/envs/dev
cp terraform.tfvars.example terraform.tfvars
# Sửa terraform.tfvars: thêm email, admin_principal_arns của nhóm
```

### Bước 4: Init, Plan, Apply

```bash
cd infra/envs/dev

# Init – tải providers và modules
terraform init

# Plan – xem trước thay đổi (KHÔNG tạo tài nguyên thực)
terraform plan -out=tfplan

# Apply – tạo hạ tầng (cần xác nhận hoặc chờ giảng viên/nhóm review plan)
terraform apply tfplan
```

> ⏱️ `terraform apply` mất khoảng **15–20 phút** (EKS cluster + node group mất nhiều thời gian nhất).

### Bước 5: Cập nhật kubeconfig

```bash
# Lấy lệnh từ output Terraform
terraform output kubeconfig_command

# Hoặc chạy thẳng:
aws eks update-kubeconfig --name multiaz-eks --region ap-southeast-1
```

### Bước 6: Kiểm tra Node Multi-AZ

```bash
# Xem node và zone của từng node
kubectl get nodes -L topology.kubernetes.io/zone

# Kết quả mong đợi: node phân bổ ở cả ap-southeast-1a VÀ ap-southeast-1b
# NAME                                   STATUS   ROLES    AGE   VERSION   ZONE
# ip-10-0-x-x.ap-southeast-1.compute.internal   Ready    <none>   5m    v1.30.x   ap-southeast-1a
# ip-10-0-y-y.ap-southeast-1.compute.internal   Ready    <none>   5m    v1.30.x   ap-southeast-1b
```

---

## Kiểm tra ALB Controller

```bash
# Kiểm tra pod đang chạy
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Xem log của controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

### Test nhanh bằng Nginx + Ingress

```bash
# Tạo deployment nginx test
kubectl create deployment nginx-test --image=nginx --port=80
kubectl expose deployment nginx-test --type=ClusterIP --port=80

# Tạo Ingress (ALB)
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-test
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-test
            port:
              number: 80
EOF

# Đợi ALB provision (1-2 phút)
kubectl get ingress nginx-test -w

# Lấy DNS của ALB và curl
ALB_DNS=$(kubectl get ingress nginx-test -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$ALB_DNS
```

---

## Kiểm tra IRSA (Không dùng Access Key)

```bash
# Annotate service account với role ARN từ Terraform output
API_ROLE=$(terraform output -raw api_role_arn)
kubectl annotate serviceaccount -n app api \
  eks.amazonaws.com/role-arn=$API_ROLE

# Chạy pod test với aws cli để xác minh IRSA hoạt động
kubectl run irsa-test -n app \
  --image=amazon/aws-cli \
  --serviceaccount=api \
  --restart=Never \
  -- sqs get-queue-attributes \
     --queue-url $(terraform output -raw queue_url) \
     --attribute-names All \
     --region ap-southeast-1
kubectl logs irsa-test -n app
kubectl delete pod irsa-test -n app
```

---

## Cách Destroy đúng thứ tự

> ⚠️ **QUAN TRỌNG:** Phải xóa ALB/Ingress trước khi destroy Terraform để tránh kẹt ENI/SecurityGroup.

```bash
# Bước 1: Xóa tất cả Ingress (ALB) trong cluster
kubectl delete ingress --all --all-namespaces

# Bước 2: Đợi ALB được xóa hoàn toàn (30-60 giây)
# Kiểm tra trên AWS Console > EC2 > Load Balancers

# Bước 3: Xóa service type LoadBalancer nếu có
kubectl delete svc --all -n app --field-selector spec.type=LoadBalancer

# Bước 4: Chạy terraform destroy
cd infra/envs/dev
terraform destroy

# Bước 5: Verify không còn tài nguyên tính phí
aws ec2 describe-instances --filters Name=tag:Project,Values=multiaz-autoscaling \
  --query 'Reservations[].Instances[].InstanceId'
aws sqs list-queues --queue-name-prefix jobs
```

> **Lưu ý:** Bootstrap resources (S3, DynamoDB) có `prevent_destroy = true`. Không cần destroy bucket này trừ khi muốn dọn hẳn.

---

## Ước tính chi phí (ap-southeast-1)

| Tài nguyên | Chi phí/giờ | Chi phí/ngày |
|-----------|------------|-------------|
| EKS Cluster | $0.10 | $2.40 |
| 2x t3.medium (ON_DEMAND) | 2 × $0.0464 = $0.093 | $2.23 |
| 1x NAT Gateway | $0.045 + data | ~$1.10 |
| SQS (ít request) | ~$0.0004 | ~$0.01 |
| ALB (khi có request) | $0.008 | ~$0.19 |
| ECR (storage 10 image) | ~$0.001 | ~$0.03 |
| **Tổng ước tính** | **~$0.24/giờ** | **~$5.96/ngày** |

> 🚨 **LUÔN DESTROY SAU MỖI BUỔI LÀM VIỆC!** Để máy chạy qua đêm = ~$6/ngày = ~$180/tháng (vượt budget $50).

---

## Bảng biến quan trọng

| Biến | Mặc định | Mô tả |
|------|----------|-------|
| `region` | `ap-southeast-1` | AWS region |
| `cluster_name` | `multiaz-eks` | Tên EKS cluster |
| `kubernetes_version` | `1.30` | Phiên bản Kubernetes |
| `azs` | `["ap-southeast-1a", "ap-southeast-1b"]` | 2 AZ |
| `instance_types` | `["t3.medium"]` | EC2 instance type cho node |
| `capacity_type` | `ON_DEMAND` | `ON_DEMAND` hoặc `SPOT` |
| `node_min_size` | `2` | Số node tối thiểu |
| `node_max_size` | `4` | Số node tối đa |
| `install_keda` | `false` | Bật ở Phase 3 |
| `monthly_budget_usd` | `"50"` | Ngưỡng budget USD |
| `admin_principal_arns` | `[]` | ARN của thành viên nhóm |
| `alert_emails` | `[]` | Email nhận cảnh báo cost |

---

## Phase 3 – Bật KEDA

Khi sẵn sàng thử KEDA autoscaling:

```hcl
# terraform.tfvars
install_keda = true
```

```bash
terraform apply
# KEDA sẽ được cài và IRSA role đã chuẩn bị sẵn từ Phase 1
```

Sau đó tạo `ScaledObject` trong `k8s/` pointing đến SQS queue.

---

## Troubleshooting

| Lỗi | Nguyên nhân | Giải pháp |
|-----|------------|-----------|
| `Error: Kubernetes cluster unreachable` | EKS chưa ready hoặc kubeconfig chưa update | Chạy `aws eks update-kubeconfig` trước |
| `ENI attachment failed` | Node group không đủ IP trong subnet | Kiểm tra CIDR subnet, tăng nếu cần |
| ALB không tạo được | ALB Controller chưa có IAM quyền | Kiểm tra IRSA annotation của SA |
| `terraform destroy` bị treo | ALB/ENI chưa được xóa | Xóa Ingress/LoadBalancer K8s trước |
| Pod không gọi được SQS | IRSA chưa được annotate | Annotate SA với `eks.amazonaws.com/role-arn` |
