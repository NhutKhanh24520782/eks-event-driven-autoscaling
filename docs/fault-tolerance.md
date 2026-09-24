# Fault Tolerance Scenarios

## 1. Pod Failure
- Terminate/delete Worker Pod.
- Observe Kubernetes reschedule/recreate Pod.
- Check message redelivery & duplicate processing.
- Measure recovery time.

## 2. Node Failure
- Cordon/drain or simulate node unavailable.
- Worker Pods are rescheduled to other nodes.
- Measure recovery time and SQS processing impact.

## 3. AZ Failure
- Simulate loss of an Availability Zone.
- Verify Worker replicas in remaining AZs handle the load.
- Measure recovery, message loss, duplicates, and throughput.
