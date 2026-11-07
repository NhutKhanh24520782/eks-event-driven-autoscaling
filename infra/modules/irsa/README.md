# IRSA Module

Creates an IAM role trusted by one Kubernetes service account through the
cluster's OIDC provider and attaches the supplied inline policy. The caller
provides the role name, OIDC provider ARN/URL, namespace, service account name,
and policy JSON.

The dev environment uses this module for the API, worker, and KEDA operator.
Each role should contain only the permissions needed by that workload and
should be scoped to the intended queue ARN.

## Follow-up work

- Add input validation and examples for policy structure and OIDC issuer URLs.
- Add policy tests ensuring roles cannot be assumed by other service accounts.
- Consider separate reusable policy documents and permissions boundaries.
