# Lab 07 — EKS — Report

    Student Name: Tshering Phuntsho
    Student ID: 02230310
    Module: DSO303 Cloud Native Solution Design
    Practical: Lab 07 – Deploying a Microservices Application on Amazon EKS
    Date: 25/10/2026

## 1. Aim / Objective

This practical moved the USMS application from Lab 04's ECS/Fargate model onto Amazon EKS, inside Lab 02's own VPC. The objectives were to:

- create `usms-eks-cluster` and the managed node group `usms-eks-nodes`, each backed by its own IAM role (`usms-eks-cluster-role` trusting `eks.amazonaws.com`, `usms-eks-node-role` trusting `ec2.amazonaws.com`), and attach Lab 01's `USMSStudentDataReadWrite` to the node role unchanged, as its third holder;
- point `kubectl` at the cluster and deploy three microservices — `usms-gateway`, `usms-enrolment`, `usms-results` — from declarative manifests into namespace `usms`;
- prove the services discover each other by DNS name alone, then perform a rolling update, a rollback, and three deliberate failure diagnoses (`ImagePullBackOff`, `Pending`/`FailedScheduling`, `CrashLoopBackOff`);
- use a ConfigMap and a Secret, and demonstrate concretely what a Kubernetes Secret does **not** protect;
- prove the whole cluster survives a Floci restart, and record every identifier in `configs/lab-07.env` for Lab 08.

## 2. Introduction

**Amazon EKS** separates a Kubernetes cluster into two halves with very different ownership. The **control plane** — `kube-apiserver`, `etcd`, the schedulers and controllers — is run entirely by AWS inside an AWS-owned account; the operator never logs into it, and `describe-cluster`'s `status` field reports only this half's health. The **data plane** — the EC2 instances a managed node group supplies, their kubelets, and every pod scheduled onto them — is run by the operator, in the operator's own account, under the operator's own IAM role. The two halves trust different principals (`eks.amazonaws.com` for the control plane, `ec2.amazonaws.com` for the nodes) and are never interchangeable.

On top of that split, Kubernetes itself provides a small set of durable objects: a **Deployment** manages a ReplicaSet, which manages pods, which run containers; a **Service** gives a stable virtual address (a ClusterIP) that never moves regardless of which pods are currently behind it; **ConfigMaps** and **Secrets** inject configuration and credentials without baking them into an image; and **CoreDNS** gives every Service a predictable `<name>.<namespace>.svc.cluster.local` record, resolved by `kube-proxy` to a live pod address on every request. None of this half of the picture is AWS-specific — it is the same object model on any conformant Kubernetes cluster, which is the portability claim this lab sets out to test rather than assume.

EKS matters in cloud-native design precisely because it trades ECS's simplicity (almost no data plane to manage, as Lab 04 showed) for a richer, more portable application model and a second, Kubernetes-native control surface (HorizontalPodAutoscaler, NetworkPolicy, PodDisruptionBudget) that Lab 08 and Lab 09 build directly on. Typical real-world uses are workloads that must run identically across clouds or on-prem, teams that already have Kubernetes expertise, and applications that need Kubernetes-specific primitives ECS has no equivalent for.

## 3. Use Case

In USMS, Lab 04 deployed the enrolment service as a single ECS task definition behind a hand-built target group. This lab rebuilds the same functional shape — a gateway in front of an enrolment and a results service — but as three Kubernetes Deployments:

- `usms-gateway` (1 replica) is an nginx reverse proxy whose configuration contains **two DNS names and no IP addresses** (`usms-enrolment.usms.svc.cluster.local`, `usms-results.usms.svc.cluster.local`) — the same "nothing in the gateway is an address" property Lab 05's ALB target groups approximated with a resolvable name, now built into the platform itself;
- `usms-enrolment` and `usms-results` (2 replicas each) are nginx pods serving small JSON documents that name their own pod, built from a ConfigMap template processed with `envsubst` at container start, so a request answered through the gateway can be traced to the exact backend pod that served it;
- a shared `usms-app-config` ConfigMap and a per-service `usms-enrolment-secret` Secret stand in for the kind of environment-specific configuration and credentials USMS's enrolment service would need in production (a database password, an API token);
- everything in this lab is reachable **only from inside the cluster** — there is no NodePort, LoadBalancer or Ingress yet, which is deliberately left as Lab 08's subject.

Other common uses of this exact shape elsewhere: a checkout gateway proxying to inventory and payment services by Kubernetes DNS name; a BFF (backend-for-frontend) pattern where the "gateway" is a dedicated API aggregation layer; any system that wants a rolling-update/rollback story independent of any one cloud's deployment API.

## 4. System Architecture / Design

![image](/screenshots/lab-7-eks/architecture.jpeg)

*Figure 1 – kubectl talks to the cluster's own API server (port 6500 on this build), the AWS CLI talks to Floci on 4566, and the only thing connecting them is that one created the other. Nothing inside the namespace `usms` box mentions AWS at all.*

## 5. Implementation Procedure

**Preparation and probing.** Sourced `configs/course.env` through `configs/lab-04.env`, confirmed `verify-lab-02.sh` (`PASS=33 FAIL=0`) and `verify-lab-04.sh` (`PASS=39 FAIL=0`), and confirmed all four Lab 02 subnets across two Availability Zones. Built `scripts/utilities/eks-support-probe.sh`: `aws eks list-clusters` answered cleanly and `kubectl` was already installed, giving **support Path A** — `aws eks` throughout, no k3d fallback needed.

**Trust and permissions policies.** Wrote `policies/trust-eks-cluster.json` (`eks.amazonaws.com`) and `policies/trust-eks-node.json` (`ec2.amazonaws.com`) with quoted heredocs, then `policies/usms-eks-cluster-policy.json` (ENI and load-balancer management, three statements) and `policies/usms-eks-node-policy.json` (cluster describe, VPC CNI, ECR read, log writes, five statements) as local stand-ins for the AWS managed policies this build may not carry. Both validated as JSON and read back correctly.

**IAM roles, policy, and the cluster security group.** Created `usms-eks-cluster-role` and attached `USMSEKSClusterPolicy`; created `usms-eks-cluster-sg` in `usms-vpc` (not the default VPC) admitting tcp/443 from the VPC CIDR only. Created `usms-eks-node-role`, attached `USMSEKSNodePolicy`, and attached Lab 01's `USMSStudentDataReadWrite` unchanged — `list-entities-for-policy` confirmed it now has three holders (`usms-ec2-app-role`, `usms-ecs-task-role`, `usms-eks-node-role`).

**Cluster creation.** Built `templates/lab-07-create-cluster.json` with an unquoted heredoc (all four Lab 02 subnets, the cluster security group, the `_lb_ports_: "8081,8082"` tag Lab 08 needs) and created the cluster while holding `usms-developer-role` credentials from `sts assume-role`, then restored the default identity. The first two `create-cluster` attempts timed out client-side while Floci pulled the `rancher/k3s` control-plane image in the background (recorded precisely in `notes/lab-07-notes.md`); a retry with a longer CLI read timeout, followed by a deliberately idempotent re-run that correctly returned `ResourceInUseException`, confirmed the cluster had in fact reached `ACTIVE` the whole time. `describe-cluster` confirmed all four subnets, the right VPC, the `_lb_ports_` tag, and — better than the lab's general expectation — a real, non-`None` OIDC issuer URL.

**Managed node group.** Built `templates/lab-07-create-nodegroup.json` (min 2 / max 4 / desired 2, the two private subnets only, labels `workload=usms,tier=app`) and created it; it reported `ACTIVE` immediately, with no waiter needed.

**Connecting kubectl.** `aws eks update-kubeconfig` wrote the context correctly, but the exec-plugin token path does not authenticate on this build (`the server has asked for the client to provide credentials`, even though `aws eks get-token` itself returns a valid token in isolation). Built a certificate-based kubeconfig instead, by reading the k3s container's own `/etc/rancher/k3s/k3s.yaml` and rewriting its `server:` field to the cluster's published port — `outputs/lab-07-kubeconfig.yaml`, chmod 600, confirmed git-ignored by the `outputs/*` rule, and used for every `kubectl` command for the rest of the lab. `kubectl get nodes` showed exactly one node, with no taints, serving as both control plane and the entire data plane on this build.

**Namespace and the three microservices.** Created namespace `usms` and set it as the context default. Deployed `usms-enrolment` (2 replicas, `maxUnavailable: 0/maxSurge: 1`, readiness **and** liveness probes, CPU/memory requests and limits) and proved it served correctly from a `busybox` pod. Deployed `usms-results` (2 replicas, default rolling-update strategy, readiness only) and `usms-gateway` (1 replica, proxying to both by DNS name) — five pods running with no `emerg` lines in the gateway's log.

**Service discovery and resilience.** Resolved both backend Services' DNS names from inside a pod to their ClusterIPs (not pod IPs), proxied through the gateway to all backends successfully, and tallied twelve requests through `/enrolment/` across two distinct pod names (7/5 split). Deleted one `usms-enrolment` pod and confirmed, with the gateway untouched, that a replacement appeared within seconds and requests never failed — the ReplicaSet's event log named it as the actor, not the Deployment and not me.

**ConfigMaps and Secrets.** Created `usms-enrolment-secret` from literals, decoded its `ENROLMENT_API_TOKEN` on screen with nothing but `base64 -d` to demonstrate it is an encoding, then wired both secret keys into the enrolment Deployment with `kubectl set env --from=secret/...` and confirmed them as plaintext inside the running container via `printenv`.

**Rollout, rollback, and three deliberate failures.** Bumped `APP_VERSION` in the shared ConfigMap, confirmed running pods kept serving `1.0.0` until a `rollout restart` picked up the change, then rolled back and confirmed the pod template reverted while the ConfigMap's `1.1.0` did not — observed directly, not assumed. Repeated the same lesson on `usms-results` with an image-tag change instead of a config change, observing the peak pod count differ because `usms-results` uses the default 25%/25% strategy rather than `usms-enrolment`'s stricter one. Then produced, in order: an `ImagePullBackOff` (bad tag, old pods kept serving under `maxUnavailable: 0`), a `Pending`/`FailedScheduling` pod (`cpu: "64"`, `memory: "256Gi"` against one small node), and a `CrashLoopBackOff` (a container that logs to stderr and exits 1, diagnosed with `logs --previous`) — each cleaned up afterward.

**ECS comparison, IRSA, persistence, and the env file.** Queried both platforms side by side with both running (Step 20's table, filled in from direct observation, is in `notes/lab-07-notes.md`). For IRSA (Step 21), found — again better than the general expectation — a real OIDC issuer, successfully registered it as an IAM OIDC provider, and created the `usms-enrolment-sa` ServiceAccount; Floci's own log named the one link that still cannot complete (`EKS Pod Identity injection is off ... Floci serves HTTP with floci.tls.enabled=false`). Proved persistence by recording cluster/node-group/Deployment/Service state, stopping and starting Floci, and re-deriving every identifier from `list-clusters`/`list-nodegroups` rather than from a shell variable — cluster, node group, all three Deployments, and all three ClusterIPs were byte-identical afterward. Wrote `configs/lab-07.env` (21 exports, no empty values) and built `scripts/utilities/verify-lab-07.sh` (`PASS=30 FAIL=0`) and `scripts/cleanup/lab-07-cleanup.sh` (syntax-checked only, never run).

## 6. Results and Evidence

### 6.1 CLI / SDK Output

**Screenshot 1 – Environment sourced, Labs 02/04 verified, four subnet IDs, kubectl installed**
![image](/screenshots/lab-7-eks/s1.png)

**Screenshot 2 – Step 2: support probe, Path A confirmed**
![image](/screenshots/lab-7-eks/s2.png)

**Screenshot 3 – Step 4: both trust policies written and validated**
![image](/screenshots/lab-7-eks/s3.png)

**Screenshot 4 – Step 5: both permissions-policy documents written and validated**
![image](/screenshots/lab-7-eks/s4.png)

**Screenshot 5 – Step 6: cluster role and security group created and verified**
![image](/screenshots/lab-7-eks/s5.png)

**Screenshot 6 – Step 7: node role created, carrying both USMSEKSNodePolicy and Lab 01's policy**
![image](/screenshots/lab-7-eks/s6.png)

**Screenshot 7 – Step 8: assumed usms-developer-role, idempotent create-cluster confirms it already exists, identity restored**
![image](/screenshots/lab-7-eks/s7.png)

**Screenshot 8 – Step 9: cluster ACTIVE, four subnets, _lb_ports_ tag present, version + OIDC issuer**
![image](/screenshots/lab-7-eks/s8.png)

**Screenshot 9 – Step 10: managed node group ACTIVE, min 2 / max 4 / desired 2**
![image](/screenshots/lab-7-eks/s9.png)

**Screenshot 10 – Step 11: kubectl connected via the certificate-based fallback kubeconfig, no taints, auth confirmed**
![image](/screenshots/lab-7-eks/s10.png)

**Screenshot 11 – Step 12: namespace usms created and set as the context default**
![image](/screenshots/lab-7-eks/s11.png)

**Screenshot 12 – Step 13 (Checkpoint 4): usms-enrolment 2/2, two endpoints, serving correctly**
![image](/screenshots/lab-7-eks/s12.png)

**Screenshot 13 – Step 14: usms-results deployed, strategy table shows the maxUnavailable difference**
![image](/screenshots/lab-7-eks/s13.png)

**Screenshot 14 – Step 15: gateway deployed, five pods running, clean nginx log**
![image](/screenshots/lab-7-eks/s14.png)

**Screenshot 15 – Step 16: twelve requests through the gateway split across two enrolment pods**
![image](/screenshots/lab-7-eks/s15.png)

**Screenshot 16 – Step 16 "Your turn": a deleted pod is replaced by the ReplicaSet, not the Deployment**
![image](/screenshots/lab-7-eks/s16.png)

**Screenshot 17 – Step 17: Secret created, decoded on screen with plain base64 -d**
![image](/screenshots/lab-7-eks/s17.png)

**Screenshot 18 – Step 17: Secret wired into the Deployment, plaintext confirmed inside the container**
![image](/screenshots/lab-7-eks/s18.png)

**Screenshot 19 – Step 18: rollout history and ReplicaSet revisions after the version bump and restart**
![image](/screenshots/lab-7-eks/s19.png)

**Screenshot 20 – Step 18 "Your turn": usms-results image-tag rollback, two revisions**
![image](/screenshots/lab-7-eks/s20.png)

**Screenshot 21 – Step 19 Failure 1: ImagePullBackOff diagnosed (Failed to pull image, ErrImagePull, BackOff)**
![image](/screenshots/lab-7-eks/s21.png)

**Screenshot 22 – Step 19 Failure 2: Pending/FailedScheduling, insufficient cpu and memory**
![image](/screenshots/lab-7-eks/s22.png)

**Screenshot 23 – Step 19 Failure 3: CrashLoopBackOff, diagnosed with logs --previous**
![image](/screenshots/lab-7-eks/s23.png)

**Screenshot 24 – Step 20: ECS and EKS queried side by side, both running**
![image](/screenshots/lab-7-eks/s24.png)

**Screenshot 25 – Step 21: IRSA — real OIDC issuer, registered OIDC provider, ServiceAccount created**
![image](/screenshots/lab-7-eks/s25.png)

**Screenshot 26 – Step 22: PERSISTENCE PROVEN after a Floci stop/start, every identifier re-derived**
![image](/screenshots/lab-7-eks/s26.png)

**Screenshot 27 – Step 23: configs/lab-07.env populated, 21 exports**
![image](/screenshots/lab-7-eks/s27.png)

**Screenshot 28 – Section 8.1: verify-lab-07.sh, PASS=30 FAIL=0**
![image](/screenshots/lab-7-eks/s28.png)

**Screenshot 29 – Section 8.1: end-to-end smoke test through the gateway, SMOKE TEST PASSED**
![image](/screenshots/lab-7-eks/s29.png)

### 6.2 Verification Summary

Floci is driven entirely through the CLI on this build, so console-equivalent evidence is each resource's own read-back, already shown above:

| Evidence | One-line explanation |
|---|---|
| `eks describe-cluster` | `usms-eks-cluster`, ACTIVE, k8s 1.30, four subnets, `_lb_ports_=8081,8082`, a real OIDC issuer |
| `eks describe-nodegroup` | `usms-eks-nodes`, ACTIVE, both private subnets only, min 2 / max 4 / desired 2 |
| `kubectl get deploy,svc -n usms` | Three (four after Exercise 1) Deployments and Services, all ClusterIP, no external address |
| `verify-lab-07.sh` | `PASS=30 FAIL=0` |
| `outputs/lab-07-before-restart.txt` / `-after-restart.txt` | Cluster, node group, Deployments and Service ClusterIPs identical before and after a Floci stop/start |

## 7. Analysis and Discussion

The full control-plane and data-plane build succeeded, and `verify-lab-07.sh` reports a clean `PASS=30 FAIL=0` with no documented benign failure to carry — a different outcome from Lab 06, where three failures were expected and explained. Every object the lab asks for exists, is correctly configured, and was verified against the live API rather than assumed.

Three things were **better than expected**. First, the lab's own text sets the general expectation that `cluster.identity.oidc.issuer` is "usually absent" on Floci and that IRSA is therefore mostly conceptual here; on this build the issuer is a real, well-formed URL, and `aws iam create-open-id-connect-provider` against it succeeded cleanly, taking IRSA further than the lab anticipates before the one genuine stopping point (Floci's log names it directly: pod-identity injection needs an HTTPS admission webhook, and this build runs HTTP). Second, `metrics.k8s.io/v1beta1` is present and `kubectl top` returns real numbers (1m CPU, 9Mi memory per enrolment pod against a 50m request — about 2%), which the lab treats as something that might not be observable at all. Third, the custom `PodDisruptionBudget` built for Exercise 4 behaved exactly as real Kubernetes documents it should: draining the cluster's only node evicted every unprotected pod but genuinely stalled on the last protected `usms-enrolment` pod with `Cannot evict pod as it would violate the pod's disruption budget`, a clean, observed proof of enforcement rather than a claim taken on faith.

Two things were **worse than expected**, and both are environment-specific rather than Floci API limitations: `aws eks update-kubeconfig`'s exec-plugin authentication path does not work on this build (worked around with a certificate-based kubeconfig extracted directly from the cluster's own container, the same category of fix the lab names for the k3d-based Path B, adapted here for Path A), and this sandbox's container network cannot resolve Docker Hub's blob-storage CDN at all (`ip_forward=0` on the host plus a specific DNS failure for `production.cloudfront.docker.com`), which made every cold image pull from inside the cluster hang indefinitely rather than fail. Both are recorded in full, with the exact log lines and error messages, in `notes/lab-07-notes.md`.

One genuine Floci-specific limitation showed up and is worth naming precisely: the managed node group's `scalingConfig` (min 2 / max 4 / desired 2) is recorded and returned correctly by `describe-nodegroup`, but the data plane it actually provisions is a single all-in-one container that is simultaneously the control plane and the only node — `kubectl get nodes` never showed more than one, with no taint. This is consistent with Section 11's general note that a managed node group is "recorded as an object; nodes are local containers" on this platform, but it is a stronger version of that limitation than the general note implies, and it directly shaped Exercise 4: real multi-node pod spread could not be demonstrated, so the exercise instead demonstrated what the single-node cluster genuinely allows — a `PodDisruptionBudget` correctly blocking a drain's final eviction — and said so honestly rather than fabricating a second node.

Other errors encountered and fixed, beyond the two environment-specific ones above: (1) two concurrent `create-cluster` attempts (my own client-side timeout retry) produced a 409 container-name conflict inside Floci's own log, resolved on its own once the slower attempt's image pull finished; (2) `kubectl set env --from=secret/...` on this kubectl version (v1.34.1) generates individual `secretKeyRef` environment entries rather than the single `envFrom.secretRef` block the lab's prose describes, a cosmetic difference that does not change the lab's own point about plaintext-inside-the-container; (3) `nginx:1.27` (no `-alpine` suffix) needed a second, separate image preload for the "Your turn" exercise in Step 18, using the same containerd-import technique as the main nginx image.

## 8. Reflection

1. **What did I learn about EKS?**  
   The control-plane/data-plane split is not just a diagram — it explains concretely why an `ACTIVE` cluster can run nothing (no node group, or a tainted lone control-plane node) and why upgrading is genuinely two separate operations. I also learned how much of what a Kubernetes cluster does is not AWS-specific at all: once the cluster, roles and node group existed, every single command for the rest of the lab — Deployments, Services, DNS, rollouts, probes, PodDisruptionBudgets — never touched an AWS API again.

2. **What challenges did I encounter?**  
   Distinguishing a genuine Floci limitation from an artefact of this specific sandboxed environment took real care: the exec-plugin kubeconfig failure and the blocked Docker Hub CDN are both environment-specific, not Floci behaviour, and conflating them with real platform deviations (like the single-node data plane, or the betterthan-expected OIDC issuer) would have misrepresented what this build actually does. Getting a cold image into a cluster with no internet access — via `docker save | ctr images import`, with the `--platform` flag needed specifically for `busybox`'s multi-arch index — was the single most time-consuming technical problem in the lab.

3. **How would I apply this in a real cloud environment?**  
   I would treat the managed node group's IAM role and the cluster's IAM role as genuinely different security boundaries from day one, since on real AWS a swapped trust policy fails loudly at `create-cluster` rather than silently succeeding the way it would here; I would also never generate a Secret manifest into a committed path, use IRSA for any pod that needs AWS permissions rather than the node role's blanket grant, and enable KMS envelope encryption of Secrets as a baseline, not an afterthought.

4. **What would I like to explore further?**  
   Running this lab's manifests, unchanged, against a real EKS cluster to see exactly how much of this Floci build's behaviour (the OIDC issuer, the PDB enforcement, the probe semantics) matches real AWS versus how much was build-specific; and comparing this lab's manual `PodDisruptionBudget` demonstration against Lab 08's `HorizontalPodAutoscaler`, since both are Kubernetes-native controllers reacting to cluster state with no AWS API in the loop at all.

## 9. Conclusion

The objectives were achieved in full, with no documented gap carried forward — `usms-eks-cluster` and `usms-eks-nodes` exist with their own IAM roles, three microservices run and discover each other by DNS name alone, a rolling update and rollback were both exercised and their limits honestly described, three failure modes were produced and diagnosed on purpose, a Secret's lack of confidentiality was demonstrated rather than asserted, and the whole system was proven to survive a Floci restart by re-deriving every identifier from the live API. `verify-lab-07.sh` reports `PASS=30 FAIL=0`, and every identifier Lab 08 needs is recorded in `configs/lab-07.env`.

The key concepts were the control-plane/data-plane split as the organising idea behind nearly every symptom in this lab, the Service as a stable name over a moving set of pods, the Deployment/ReplicaSet pair as the self-healing mechanism that replaced a deleted pod without any operator action, and the honest limits of both a Secret (confidentiality in transit and at rest in the API, not inside the container) and a rollback (the pod template only, never a separately-referenced ConfigMap). The skills developed were building a Kubernetes application from manifests rather than imperative commands, diagnosing a cluster with `describe`/`logs`/`events` in the right order, and — a skill this lab specifically demanded — telling apart a real platform limitation from an artefact of the sandboxed environment it happened to run in, and recording each honestly rather than conflating them. This lab matters because it is the first point in the course where the application's own object model, not just its AWS wrapper, has to be understood on its own terms.

## 10. Appendix

Files in the repository:

- `policies/trust-eks-cluster.json`, `trust-eks-node.json`, `usms-eks-cluster-policy.json`, `usms-eks-node-policy.json`
- `templates/lab-07-create-cluster.json`, `lab-07-create-nodegroup.json`
- `manifests/lab-07/00-namespace.yaml`, `10-configmap-app.yaml`, `20-enrolment.yaml` (with PodDisruptionBudget and topologySpreadConstraints from Exercise 4), `30-results.yaml`, `40-gateway.yaml` (with the `/timetable/` route from Exercise 2), `50-secret.yaml`, `60-serviceaccount.yaml`, `70-timetable.yaml` (Exercise 1)
- `configs/lab-07.env` – 21 exports
- `scripts/utilities/verify-lab-07.sh` — `PASS=30 FAIL=0`
- `scripts/utilities/eks-support-probe.sh` — Step 2
- `scripts/cleanup/lab-07-cleanup.sh` — end of course only, syntax-checked, never run
- `labs/lab-07-eks/exercises.md`
- `notes/lab-07-notes.md` — support path, environment-specific findings, Step 3/Step 20 answers, all seven Review Questions, Exercise 5 Part 3
- `outputs/lab-07-support-probe.txt`, `-cluster.json`, `-nodegroup.json`, `-before-restart.txt`, `-after-restart.txt`, `-kubeconfig.yaml`, `-cpu-baseline.txt`, `-lab06-readiness.txt` (git-ignored; kept until submission)
