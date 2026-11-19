# Scripts

Scripts and runbooks for local development and controlled experiments:

| Path | Purpose | Current status |
| --- | --- | --- |
| [`local/`](local/README.md) | ElasticMQ configuration for local Compose | Configured |
| [`load-test/`](load-test/README.md) | Bounded configurable k6 smoke, baseline, and load profiles | Configured; use a dev queue |
| [`chaos/`](chaos/README.md) | Pod/node/AZ fault scenarios | Guarded dev-only procedures; review before execution |
| [`metrics/`](metrics/README.md) | Log/SQS/replica collection and T0–T6 analysis | Collector and CSV analyzer available |

Run load and failure tests only against a development environment that you
own. The k6 script submits real jobs to the API's configured queue. Chaos
scripts require a dev environment, explicit target values, and interactive
confirmation; read the scenario runbooks before use.

The collector is read-only. The guarded Pod-failure script can delete one
worker Pod only after its active test job is identified; Node/AZ scripts remain
gated and must not be run without team approval.
