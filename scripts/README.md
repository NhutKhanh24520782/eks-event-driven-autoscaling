# Scripts

Scripts and runbooks for local development and controlled experiments:

| Path | Purpose | Current status |
| --- | --- | --- |
| [`local/`](local/README.md) | ElasticMQ configuration for local Compose | Configured |
| [`load-test/`](load-test/README.md) | k6 API workload with run IDs, client timestamps, and CSV output | Configured; use a dev queue |
| [`chaos/`](chaos/README.md) | Pod/node/AZ fault scenarios | Guarded dev-only procedures; review before execution |
| [`metrics/`](metrics/README.md) | Control-loop latency collection notes | T0–T6 method and collection procedure documented |

Run load and failure tests only against a development environment that you
own. The k6 script submits real jobs to the API's configured queue. Chaos
scripts require a dev environment, explicit target values, and interactive
confirmation; read the scenario runbooks before use.

## Remaining work

- Add explicit k6 thresholds and a configurable request-rate limit for
  non-smoke profiles.
- Automate a sanitized collector bundle containing correlated application,
  KEDA, and Kubernetes observations.
- Add CI validation for shell and k6 scripts.
