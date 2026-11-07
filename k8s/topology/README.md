# Topology Spread

The two patches apply topology-spread constraints to API and worker pods. They
use node zone labels to distribute replicas across the EKS Availability Zones
where capacity is available.

Spread constraints do not create nodes or guarantee placement when replicas,
taints, capacity, or topology labels prevent scheduling. Verify actual
placement with:

```powershell
kubectl get pods -n app -o wide
kubectl get nodes -L topology.kubernetes.io/zone
```

## Follow-up work

- Test behavior with one unavailable zone and limited spare capacity.
- Review `whenUnsatisfiable`, `maxSkew`, and scheduler behavior for each
  workload's availability requirements.
