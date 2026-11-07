# Kubernetes Storage

`ebs-gp3.yaml` defines a non-default EBS CSI `gp3` StorageClass with encrypted
volumes, `WaitForFirstConsumer` binding, and volume expansion. The EKS
`aws-ebs-csi-driver` add-on and its IRSA role are provisioned by Terraform.

Apply the StorageClass only after the CSI add-on is active:

```powershell
kubectl apply -f k8s\storage\ebs-gp3.yaml
kubectl get storageclass gp3
kubectl get pods -n kube-system
```

Prometheus, Grafana, and Loki values explicitly select `gp3`. Claims without
a class can remain Pending if the cluster has no default StorageClass.

## Follow-up work

- Define backup, restore, retention, and deletion policies for monitoring
  volumes.
- Consider a default StorageClass only if its implications for every PVC are
  understood.
