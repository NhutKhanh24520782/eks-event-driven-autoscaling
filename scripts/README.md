# Scripts

Scripts and runbooks for local development and controlled experiments:

| Path | Purpose | Current status |
| --- | --- | --- |
| [`local/`](local/README.md) | ElasticMQ configuration for local Compose | Configured |
| [`load-test/`](load-test/README.md) | k6 API workload | Configured; sends to the configured queue |
| [`chaos/`](chaos/README.md) | Pod/node/AZ fault scenarios | Shell scripts are placeholders; AZ procedure is a draft |
| [`metrics/`](metrics/README.md) | Control-loop latency collection notes | Placeholder; measurement is not automated |

Run load and failure tests only against a development environment that you
own. The current k6 script submits real jobs to the API's configured queue.
Chaos scripts are not production-ready and must not be executed until they
have explicit target checks and safeguards.

## Follow-up work

- Add parameter validation, bounded duration/rate, and cleanup handling.
- Add an explicit development-cluster/namespace confirmation to chaos tools.
- Save test output and environment metadata in `docs/evidence/`.
- Add CI validation for shell and k6 scripts.
