# Frontend

The Failure Scenarios dashboard is served by Nginx. Use the local Compose
stack to enable its scenario controls; the Nginx `/api/` route proxies requests
to the API service.

Run from the repository root:

```powershell
docker compose -f docker-compose.local.yml up --build -d frontend api-service
```

Open `http://localhost:8181`. Only `traffic-spike` and
`sqs-backlog-spike` are enabled, with fixed job/time limits. Scenarios that
require services not present in the local stack remain unavailable.

```powershell
docker compose -f docker-compose.local.yml stop frontend api-service
```

## Build the EKS frontend image

The local Nginx config targets the Compose API port (`8080`). Build the EKS
image with `nginx.eks.conf`, which targets the Kubernetes `api-service` port
(`80`):

```bash
docker build --build-arg NGINX_CONFIG=nginx.eks.conf \
  -t multiaz-autoscaling/frontend:latest \
  -f apps/frontend/Dockerfile apps/frontend
```

Tag and push that image to the ECR repository, then update the frontend
Deployment. Because the manifest uses the mutable `latest` tag, restart the
Deployment after pushing so its pods pull the new image:

```bash
kubectl rollout restart deployment/frontend-service -n app
kubectl rollout status deployment/frontend-service -n app --timeout=5m
```

The Chaos controls are intentionally local-only; deploying this frontend to
EKS does not enable them.
