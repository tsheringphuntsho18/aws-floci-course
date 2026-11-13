#!/usr/bin/env bash
# Verify every Lab 08 artefact. Exit 1 if anything is missing.
# Works from any directory. Never assumes a shell variable is already set.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-07.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-08.env" 2>/dev/null || true
export KUBECONFIG="$REPO_ROOT/outputs/lab-07-kubeconfig.yaml"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "kubectl reaches an API server" "kubectl version --request-timeout=10s"
check "namespace usms exists" "kubectl get namespace usms"

echo "== Lab 07 dependencies =="
check "usms-enrolment has at least 2 ready replicas" \
  "test \"\$(kubectl get deploy usms-enrolment -n usms -o jsonpath='{.status.readyReplicas}')\" -ge 2"
check "usms-enrolment declares a cpu request" \
  "kubectl get deploy usms-enrolment -n usms -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' | grep -q 'm'"
check "cluster carries the _lb_ports_ tag" \
  "aws eks describe-cluster --name \"\$USMS_EKS_CLUSTER\" --query 'cluster.tags._lb_ports_' --output text | grep -q '8081'"
check "manifests/lab-07/20-enrolment.yaml carries nodeSelector" \
  "grep -q 'workload: usms' manifests/lab-07/20-enrolment.yaml"

echo "== Autoscaling (HPA) =="
check "usms-enrolment-hpa exists" "kubectl get hpa usms-enrolment-hpa -n usms"
check "HPA is autoscaling/v2 with a behavior block" \
  "kubectl get hpa usms-enrolment-hpa -n usms -o jsonpath='{.spec.behavior}' | grep -q scaleDown"
check "HPA targets usms-enrolment" \
  "test \"\$(kubectl get hpa usms-enrolment-hpa -n usms -o jsonpath='{.spec.scaleTargetRef.name}')\" = usms-enrolment"
check "HPA minReplicas is 2" \
  "test \"\$(kubectl get hpa usms-enrolment-hpa -n usms -o jsonpath='{.spec.minReplicas}')\" = 2"
check "HPA maxReplicas is 8" \
  "test \"\$(kubectl get hpa usms-enrolment-hpa -n usms -o jsonpath='{.spec.maxReplicas}')\" = 8"
check "HPA CPU target is 50" \
  "test \"\$(kubectl get hpa usms-enrolment-hpa -n usms -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}')\" = 50"
check "HPA scale-in stabilization window is 300s" \
  "test \"\$(kubectl get hpa usms-enrolment-hpa -n usms -o jsonpath='{.spec.behavior.scaleDown.stabilizationWindowSeconds}')\" = 300"

echo "== Disruption budgets =="
check "usms-gateway-pdb exists with minAvailable 1" \
  "test \"\$(kubectl get pdb usms-gateway-pdb -n usms -o jsonpath='{.spec.minAvailable}')\" = 1"
check "usms-enrolment-pdb exists with maxUnavailable 1" \
  "test \"\$(kubectl get pdb usms-enrolment-pdb -n usms -o jsonpath='{.spec.maxUnavailable}')\" = 1"
check "eviction API is governed by a PDB (allowed disruptions key present)" \
  "kubectl get pdb usms-gateway-pdb -n usms -o jsonpath='{.status.disruptionsAllowed}' | grep -qE '^[0-9]+$'"

echo "== Exposure ladder =="
check "usms-results-np is NodePort" \
  "test \"\$(kubectl get svc usms-results-np -n usms -o jsonpath='{.spec.type}')\" = NodePort"
check "usms-results-np is pinned to 30080" \
  "test \"\$(kubectl get svc usms-results-np -n usms -o jsonpath='{.spec.ports[0].nodePort}')\" = 30080"
check "usms-results-np selects usms-results pods" \
  "test \"\$(kubectl get svc usms-results-np -n usms -o jsonpath='{.spec.selector.app}')\" = usms-results"
check "usms-gateway is type LoadBalancer" \
  "test \"\$(kubectl get svc usms-gateway -n usms -o jsonpath='{.spec.type}')\" = LoadBalancer"
check "usms-gateway kept a nodePort" \
  "kubectl get svc usms-gateway -n usms -o jsonpath='{.spec.ports[0].nodePort}' | grep -qE '^[0-9]+$'"
check "usms-portal-ingress exists" "kubectl get ingress usms-portal-ingress -n usms"
check "Ingress carries three paths" \
  "test \"\$(kubectl get ingress usms-portal-ingress -n usms -o jsonpath='{.spec.rules[0].http.paths[*].path}' | wc -w)\" = 3"
check "Ingress carries the target-type annotation" \
  "kubectl get ingress usms-portal-ingress -n usms -o jsonpath='{.metadata.annotations}' | grep -q 'target-type'"

echo "== Data plane (expect FAIL here: update-nodegroup-config is unsupported on this build) =="
check "nodegroup maxSize is 6" \
  "test \"\$(aws eks describe-nodegroup --cluster-name \"\$USMS_EKS_CLUSTER\" --nodegroup-name \"\$USMS_EKS_NODEGROUP\" --query 'nodegroup.scalingConfig.maxSize' --output text)\" = 6"

echo "== Files and Git hygiene =="
check "configs/lab-08.env exists" "test -f configs/lab-08.env"
check "configs/lab-08.env records HPA bounds" "grep -q 'USMS_HPA_MAX=8' configs/lab-08.env"
check "configs/lab-08.env has 19 exports" \
  "test \"\$(grep -c '^export' configs/lab-08.env)\" = 19"
check "six or more lab-08 manifests present" \
  "test \"\$(ls manifests/lab-08/*.yaml 2>/dev/null | wc -l)\" -ge 6"
check "lab-08 HPA manifest passes a client-side dry run" \
  "kubectl apply --dry-run=client -f manifests/lab-08/10-hpa-enrolment.yaml"
check "hpa-watch.sh is executable" "test -x scripts/utilities/hpa-watch.sh"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/'"

echo
echo "PASS=$PASS  FAIL=$FAIL"
test "$FAIL" -eq 0
