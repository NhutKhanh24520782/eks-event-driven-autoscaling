# Loki

`values.yaml` configures Loki's single-binary mode with a persistent filesystem
volume and seven-day retention. `promtail-values.yaml` sends Kubernetes
container logs to the Loki service from the `observability` namespace.

Install both charts using the commands in the
[`observability README`](../README.md#install). Check that the Loki and Promtail
pods are ready and that the Loki datasource is healthy in Grafana. The
dashboard's log panel filters to the `app` namespace and `worker` container.

This single-replica, filesystem-backed setup is intended for development and
experiments. It is not highly available and should not be used as a production
logging backend without a durable shared object store, backups, and a
production deployment configuration.

## Follow-up work

- Verify PVC binding and test restore behavior after pod recreation.
- Pin the Loki and Promtail chart versions and validate their values.
- Plan object storage, backups, access control, and production retention.
