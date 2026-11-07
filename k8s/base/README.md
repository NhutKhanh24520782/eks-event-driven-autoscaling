# Base Workloads

`kustomization.yaml` groups the namespace, API/worker Deployments and
Services, service accounts, and API Ingress. The parent Kustomize overlay adds
the shared ConfigMap and topology-spread patches.

Deployment images are placeholders until replaced with pushed ECR images.
The ConfigMap is maintained in `../config/`; set its queue URL before applying
the parent `k8s` bundle.

The API and worker use dedicated service accounts for IRSA. Annotate those
accounts with the Terraform role outputs and restart pods after changing the
annotation. Never inject static AWS access keys.

## Follow-up work

- Add PodDisruptionBudgets, network policies, and autoscaling-safe termination
  tests.
- Move image selection to Kustomize `images` transforms or a release overlay.
- Consider separating local, dev, and production overlays.
