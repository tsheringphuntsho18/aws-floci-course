#!/usr/bin/env bash
# Remove every Lab 08 object, in an order that releases referencing objects
# before the objects they reference, and external infrastructure before AWS.
# End of course only. Requires typing DELETE-LAB-08 to proceed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-07.env" 2>/dev/null || true
export KUBECONFIG="$REPO_ROOT/outputs/lab-07-kubeconfig.yaml"

read -rp "Type DELETE-LAB-08 to proceed: " CONFIRM
if [ "$CONFIRM" != "DELETE-LAB-08" ]; then
  echo "Aborted. Nothing was deleted."
  exit 1
fi

echo "== 1. Ingress (references Services) =="
kubectl delete ingress usms-portal-ingress -n usms --ignore-not-found

echo "== 2. LoadBalancer and NodePort =="
kubectl patch svc usms-gateway -n usms --type=merge -p '{"spec":{"type":"ClusterIP"}}' || true
kubectl delete svc usms-results-np -n usms --ignore-not-found

echo "== 3. Controllers (HPA, then PDBs) =="
kubectl delete hpa usms-enrolment-hpa -n usms --ignore-not-found
kubectl delete pdb usms-gateway-pdb usms-enrolment-pdb -n usms --ignore-not-found

echo "== 4. Workloads =="
kubectl delete deployment usms-loadgen -n usms --ignore-not-found

echo "== 5. AWS side last: restore node group to Lab 07 bounds =="
aws eks update-nodegroup-config \
  --cluster-name "${USMS_EKS_CLUSTER:-usms-eks-cluster}" \
  --nodegroup-name "${USMS_EKS_NODEGROUP:-usms-eks-nodes}" \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  || echo "update-nodegroup-config unsupported on this build - nothing to restore"

echo "Lab 08 cleanup complete. Cluster, namespace and the three microservices were left untouched."
