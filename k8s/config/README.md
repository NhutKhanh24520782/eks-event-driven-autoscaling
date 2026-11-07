# Application Configuration

`configmap.yaml` supplies non-secret runtime settings to both application
Deployments, including `AWS_REGION` and `QUEUE_URL`. Replace the Terraform
queue URL placeholder before applying the parent Kustomize bundle.

Do not store AWS keys or passwords in this ConfigMap. Application pods use
IRSA service accounts for AWS access.

## Follow-up work

- Add schema validation or deployment-time generation for environment values.
- Separate environment-specific queue settings into Kustomize overlays.
- Add explicit configuration checks for required values before rollout.
