# ECR Module

Creates one ECR repository for each configured repository name under the
specified prefix. Repositories currently allow mutable tags, enable image
scanning on push, and retain at most the ten newest images through a lifecycle
policy.

The dev environment creates `api` and `worker` repositories. Use immutable
version tags for reproducible deployments; the current mutable configuration
is convenient for development but can make rollbacks ambiguous.

## Follow-up work

- Enable immutable tags for release workflows.
- Review ECR scanning mode, retention exceptions, and vulnerability response.
- Add lifecycle and repository-policy tests.
