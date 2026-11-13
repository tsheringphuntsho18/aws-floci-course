# Lab 08 — EKS Scaling and Service Exposure — Report

    Student Name: Tshering Phuntsho
    Student ID: 02230310
    Module: DSO303 Cloud Native Solution Design
    Practical: Lab 08 – EKS Scaling and Service Exposure
    Date: 25/10/2026

## 1. Aim / Objective

This practical took the three-microservice EKS deployment Lab 07 built and added the two things it deliberately left out: elastic capacity and real network reachability. The objectives were to:

- scale `usms-enrolment` manually, declaratively, and with a real `autoscaling/v2` HorizontalPodAutoscaler, observing both a genuine scale-out and a genuine scale-in under load, and mapping the HPA's two-part reconciliation onto Lab 06's single-integer Application Auto Scaling model;
- change the managed node group's scaling configuration from the AWS side, as a control loop deliberately separate from the HPA's workload-level loop;
- use CPU/memory requests and limits to understand QoS classes and the HPA's own percentage arithmetic, apply PodDisruptionBudgets to two different services, and demonstrate precisely what a PDB does and does not protect against;
- climb the full exposure ladder — ClusterIP/port-forward, NodePort, LoadBalancer, Ingress — on the same three services Lab 07 deployed, and compare Kubernetes' Ingress against Lab 05's hand-built ALB;
- confirm every piece of scaling and exposure configuration survives a Floci restart, and record every identifier Lab 10 needs in `configs/lab-08.env`.

## 2. Introduction

Lab 07 proved Kubernetes' object model works on this platform — Deployments, Services, DNS, rollouts — but deliberately stopped at a fixed replica count and a cluster reachable only from inside itself. This lab adds the two axes every real production cluster needs beyond that starting point. **Elasticity** on Kubernetes is split into two genuinely independent control loops, not one: the **HorizontalPodAutoscaler** decides how many pods a Deployment should have, reading a percentage of each pod's own `resources.requests.cpu`; a separate node-level mechanism (the Cluster Autoscaler or Karpenter on real AWS, `aws eks update-nodegroup-config` by hand here) decides how many nodes exist for those pods to land on. The two loops do not know about each other — an HPA can ask for eight replicas and get four `Pending` forever if nothing is watching the node side, which this lab demonstrates directly rather than merely asserts.

**Reachability** is likewise a ladder, not a single decision: a `ClusterIP` Service is reachable only inside the cluster (or via `kubectl port-forward` from outside it); a `NodePort` opens one fixed port on every node, still fundamentally cluster-internal unless something external publishes that port; a `LoadBalancer` Service asks the cloud for a real external address; and an `Ingress` adds HTTP-aware routing (paths, hosts) on top of whichever Service ultimately serves the request, needing a controller to turn the object into anything real. Each rung trades simplicity for reach, and a workload should sit on the lowest rung that actually satisfies its requirement — exactly the design question Exercise 4 poses directly.

## 3. Use Case

Lab 07's `usms-gateway`, `usms-enrolment` and `usms-results` are still the entire application; this lab changes nothing about what they do and everything about how much capacity they have and who can reach them:

- `usms-enrolment` gets a real `HorizontalPodAutoscaler` (2–8 replicas, 50% CPU target) standing in for the enrolment-period traffic spike USMS actually experiences, with `usms-loadgen` — a disposable `busybox` Deployment generating real HTTP traffic through the gateway — playing the role of that spike on demand;
- `usms-results`, already the read-mostly service Lab 07 cast it as, gets a second, independently-tuned HPA (60% target, Exercise 1) and a `NodePort` Service (Step 14) as a deliberately lower rung of exposure than the one the exercise asks students to build "properly" (Exercise 4, resolved onto the shared Ingress instead);
- `usms-gateway` climbs the exposure ladder end-to-end: it already had a ClusterIP from Lab 07, gains a `NodePort` as a side effect of becoming `LoadBalancer`-typed in Step 15, and finally sits behind `usms-portal-ingress` in Step 16 alongside path rules for the other two services — the single shared load balancer Exercise 4's "do not pay for a second one" constraint is built entirely around;
- two new `PodDisruptionBudget` objects (`usms-gateway-pdb`, `usms-enrolment-pdb`) stand in for the operational guarantee USMS would actually want before anyone runs a node drain or a rolling node replacement in production.

Other common uses of this exact shape elsewhere: an e-commerce checkout service that needs to survive a flash sale (the HPA's job) while its node group needs enough real capacity underneath it (the Cluster Autoscaler's job); a single ALB fronting a dozen microservices by path instead of a dozen separate load balancers (Exercise 4's point generalised).

## 4. System Architecture / Design

![image](/screenshots/lab-8-eks-scaling/architecture.jpeg)

*Figure 1 – two control loops exist inside the box (HPA and, conceptually, a Cluster Autoscaler), but only the workload loop is actually implemented on this build; everything below the dashed line to the host network is recorded by the AWS API but not enacted by Docker.*

## 5. Implementation Procedure

**Environment check and baseline (Steps 1–2).** Confirmed Lab 07's `usms-enrolment` still declares a `50m` CPU request and the cluster still carries the `_lb_ports_=8081,8082` tag, then recorded the full Deployment/Service/endpoint baseline to `outputs/lab-08-baseline.txt` for Step 18's later diff.

**Manual and declarative scaling (Steps 4–5).** Scaled `usms-enrolment` to 5 replicas by hand and confirmed traffic spread across all five pod names through the gateway (11/9/8/7/5 split over 40 requests), then scaled back to 2. Deliberately created drift (scaled to 6 while the manifest still said 2) and showed `kubectl apply` silently overwrites the live drift back to the manifest's value — then used the safe workflow instead (edit the file, `kubectl diff`, apply) to move to 3 replicas and back to 2, leaving the manifest and the live state in agreement throughout.

**Requests, limits, QoS, and the metrics pipeline (Steps 6–7).** Confirmed every pod in `usms` is `Burstable` QoS (`50m`/`200m` CPU) and read the node's own "Allocated resources" table directly. Checked for `metrics-server` before attempting to install it — it was already present and `kubectl top` already returned real numbers, so Step 7's install/patch instructions were unnecessary on this build.

**The HorizontalPodAutoscaler and a real load test (Steps 8–9).** Wrote `manifests/lab-08/10-hpa-enrolment.yaml` (`autoscaling/v2`, 2–8 replicas, 50% CPU target, an asymmetric `behavior` block: instant scale-up, a 300-second scale-down stabilisation window) and applied it. Wrote `scripts/utilities/hpa-watch.sh` and `manifests/lab-08/20-loadgen.yaml` (three `busybox` pods hammering the gateway), then watched the HPA scale `usms-enrolment` from 2 to 3 pods in real time as CPU crossed 63%/50% (`SuccessfulRescale: New size: 3`), removed the load, and watched it scale back down to 2 **almost exactly 300 seconds** after the last high reading (`SuccessfulRescale: New size: 2; reason: All metrics below target`) — both transitions observed live, not inferred from documentation.

**Node group scaling from the AWS side, and nodeSelector enforcement (Steps 10–11).** `aws eks update-nodegroup-config` failed outright with `UnknownOperationException`, confirmed against `known-issues.html` as a documented Floci 2.0.1 limitation before treating it as a bug of my own. Found the node group's `labels` field (`workload=usms`, `tier=app`) had never actually reached the real k3s node — applied the labels by hand with `kubectl label node` — then added a `nodeSelector` to `usms-enrolment`, proved it schedules correctly against the real label, and proved a nonexistent label value leaves the pod `Pending` with `FailedScheduling` before restoring and persisting the correct selector in `manifests/lab-07/20-enrolment.yaml`.

**PodDisruptionBudgets and the eviction API (Step 12).** Created `usms-gateway-pdb` (`minAvailable: 1`) and `usms-enrolment-pdb` (`maxUnavailable: 1`, replacing Lab 07's `minAvailable: 1` version of the same object) in `manifests/lab-08/30-pdb-gateway.yaml`. Proved the Eviction API respects the PDB (`Error: Cannot evict pod as it would violate the pod's disruption budget`) and that a plain `kubectl delete pod` on the identical pod bypasses it completely and succeeds immediately — the voluntary/involuntary distinction demonstrated, not just stated — then confirmed a client-side `kubectl drain --dry-run` would correctly attempt every pod in the namespace.

**The exposure ladder (Steps 13–16).** Confirmed `usms-gateway`'s ClusterIP is unreachable directly from the host, then reached it correctly through `kubectl port-forward` on all three routes. Created `usms-results-np` (`NodePort`, pinned to `30080`) and proved it answers from inside the cluster by any node's internal IP but not from the host (`docker port` shows only `6500` published, never `30080`). Converted `usms-gateway`'s Service to `LoadBalancer` — `EXTERNAL-IP` resolved to a real address (`172.17.0.4`, better than the general expectation that it stays `<pending>`), but that address is the k3s container's own Docker-bridge IP, confirmed reachable in-cluster and confirmed **not** reachable from the host even via the cluster's own `_lb_ports_` tag (`8081`/`8082` never published by Docker at all). Created `usms-portal-ingress` with three path rules (`/enrolment`, `/results`, `/`) — correctly resolved to live backend endpoints in `describe ingress`, but with `Address:` permanently blank, since no ingress controller (Traefik, ingress-nginx, or the AWS Load Balancer Controller) is installed anywhere in the cluster.

**Comparison, persistence, and the env file (Steps 17–19).** Filled in both comparison tables (scaling and exposure) and two prose paragraphs comparing ECS+Application Auto Scaling against Kubernetes+HPA, and Lab 05's ALB against this lab's Ingress — in `notes/lab-08-notes.md`. Recorded HPA/PDB/Service/Ingress/node-group state before a Floci stop/start, confirmed the state is byte-identical afterward (`PERSISTENCE PROVEN`) — the underlying k3s cluster container was never actually interrupted by `floci-down.sh`/`floci-up.sh`, since it is not part of the same Docker Compose project as the Floci API container, a finding recorded honestly rather than claimed as a true restart recovery. Wrote `configs/lab-08.env` (19 exports, all read live, including the honest unmodified node-group bounds) and built `scripts/utilities/verify-lab-08.sh` (`PASS=33 FAIL=1`, the one failure being the documented node-group limitation) and `scripts/cleanup/lab-08-cleanup.sh` (syntax-checked only, never run).

## 6. Results and Evidence

### 6.1 CLI / SDK Output

**Screenshot 1 – Step 1: Lab 07's CPU request and `_lb_ports_` tag both confirmed present**
![image](/screenshots/lab-8-eks-scaling/s1.png)

**Screenshot 2 – Step 2: baseline Deployments, Services and endpoints recorded**
![image](/screenshots/lab-8-eks-scaling/s2.png)

**Screenshot 3 – Step 4: manual scale to 5 replicas**
![image](/screenshots/lab-8-eks-scaling/s3.png)

**Screenshot 4 – Step 4: traffic spreads across all 5 enrolment pods**
![image](/screenshots/lab-8-eks-scaling/s4.png)

**Screenshot 5 – Step 4: scaled back down to 2, 2 endpoints**
![image](/screenshots/lab-8-eks-scaling/s5.png)

**Screenshot 6 – Step 5: drift created (live=6, manifest=2)**
![image](/screenshots/lab-8-eks-scaling/s6.png)

**Screenshot 7 – Step 5: `kubectl apply` silently overwrites the drift back to 2**
![image](/screenshots/lab-8-eks-scaling/s7.png)

**Screenshot 8 – Step 5: safe workflow — edit to 3, `kubectl diff`, apply**
![image](/screenshots/lab-8-eks-scaling/s8.png)

**Screenshot 9 – Step 5: manifest restored to baseline replicas=2**
![image](/screenshots/lab-8-eks-scaling/s9.png)

**Screenshot 10 – Step 6: QoS classes, CPU requests/limits, node allocation**
![image](/screenshots/lab-8-eks-scaling/s10.png)

**Screenshot 11 – Step 7: metrics-server already present, metrics API available**
![image](/screenshots/lab-8-eks-scaling/s11.png)

**Screenshot 12 – Step 7: `kubectl top nodes`/`top pods` return real numbers**
![image](/screenshots/lab-8-eks-scaling/s12.png)

**Screenshot 13 – Step 8: HPA created, dry run then real, reporting 2%/50%**
![image](/screenshots/lab-8-eks-scaling/s13.png)

**Screenshot 14 – Step 9: `usms-loadgen` deployed**
![image](/screenshots/lab-8-eks-scaling/s14.png)

**Screenshot 15 – Step 9: HPA scale-out event captured (New size: 3)**
![image](/screenshots/lab-8-eks-scaling/s15.png)

**Screenshot 16 – Step 9: load generator scaled to zero**
![image](/screenshots/lab-8-eks-scaling/s16.png)

**Screenshot 17 – Step 9: HPA scale-in event captured ~300s later (New size: 2)**
![image](/screenshots/lab-8-eks-scaling/s17.png)

**Screenshot 18 – Step 10: node group scaling config read before the attempt**
![image](/screenshots/lab-8-eks-scaling/s18.png)

**Screenshot 19 – Step 10: `update-nodegroup-config` fails with `UnknownOperationException`**
![image](/screenshots/lab-8-eks-scaling/s19.png)

**Screenshot 20 – Step 11: node group's labels never reached the real node; applied by hand**
![image](/screenshots/lab-8-eks-scaling/s20.png)

**Screenshot 21 – Step 11: nodeSelector applied, pods schedule correctly**
![image](/screenshots/lab-8-eks-scaling/s21.png)

**Screenshot 22 – Step 11: nonexistent label value leaves a pod Pending**
![image](/screenshots/lab-8-eks-scaling/s22.png)

**Screenshot 23 – Step 11: `FailedScheduling` event confirmed on the Pending pod**
![image](/screenshots/lab-8-eks-scaling/s23.png)

**Screenshot 24 – Step 11: correct selector restored, all pods Running**
![image](/screenshots/lab-8-eks-scaling/s24.png)

**Screenshot 25 – Step 11: manifest now matches live state (clean `kubectl diff`)**
![image](/screenshots/lab-8-eks-scaling/s25.png)

**Screenshot 26 – Step 12: both PodDisruptionBudgets created**
![image](/screenshots/lab-8-eks-scaling/s26.png)

**Screenshot 27 – Step 12: Eviction API blocked by the PDB (`TooManyRequests`)**
![image](/screenshots/lab-8-eks-scaling/s27.png)

**Screenshot 28 – Step 12: plain `kubectl delete pod` bypasses the PDB entirely**
![image](/screenshots/lab-8-eks-scaling/s28.png)

**Screenshot 29 – Step 12: client-side drain dry run**
![image](/screenshots/lab-8-eks-scaling/s29.png)

**Screenshot 30 – Step 13: ClusterIP unreachable directly from the host**
![image](/screenshots/lab-8-eks-scaling/s30.png)

**Screenshot 31 – Step 13: all three routes reachable through `kubectl port-forward`**
![image](/screenshots/lab-8-eks-scaling/s31.png)

**Screenshot 32 – Step 14: NodePort Service `usms-results-np` created**
![image](/screenshots/lab-8-eks-scaling/s32.png)

**Screenshot 33 – Step 14: NodePort reachable in-cluster, not from the host**
![image](/screenshots/lab-8-eks-scaling/s33.png)

**Screenshot 34 – Step 15: `usms-gateway` converted to LoadBalancer**
![image](/screenshots/lab-8-eks-scaling/s34.png)

**Screenshot 35 – Step 15: `_lb_ports_` host ports 8081/8082 do not actually work**
![image](/screenshots/lab-8-eks-scaling/s35.png)

**Screenshot 36 – Step 15: EXTERNAL-IP resolves to a real (Docker-internal) address**
![image](/screenshots/lab-8-eks-scaling/s36.png)

**Screenshot 37 – Step 15: that address is reachable in-cluster; Docker publishes only port 6500**
![image](/screenshots/lab-8-eks-scaling/s37.png)

**Screenshot 38 – Step 16: Ingress created, backends resolved, no controller present**
![image](/screenshots/lab-8-eks-scaling/s38.png)

**Screenshot 39 – Step 16: Ingress status confirmed empty (`{"loadBalancer":{}}`)**
![image](/screenshots/lab-8-eks-scaling/s39.png)

**Screenshot 40 – Step 18: before-restart scaling/exposure state recorded**
![image](/screenshots/lab-8-eks-scaling/s40.png)

**Screenshot 41 – Step 18: connectivity re-established after Floci restart**
![image](/screenshots/lab-8-eks-scaling/s41.png)

**Screenshot 42 – Step 18: `PERSISTENCE PROVEN` — before/after diff is clean**
![image](/screenshots/lab-8-eks-scaling/s42.png)

**Screenshot 43 – Section 8.1: `verify-lab-08.sh`, PASS=33 FAIL=1**
![image](/screenshots/lab-8-eks-scaling/s43.png)

### 6.2 Verification Summary

| Evidence | One-line explanation |
|---|---|
| `kubectl get hpa` events | Real scale-up (2→3 at 63%/50%) and scale-in (3→2, ~300s later) both observed live |
| `aws eks update-nodegroup-config` | `UnknownOperationException` — confirmed as a documented Floci 2.0.1 limitation, not a script bug |
| `kubectl get pdb` + Eviction API | Eviction blocked (`TooManyRequests`); plain `delete` bypasses it completely |
| `kubectl get ingress -o jsonpath='{.status}'` | `{"loadBalancer":{}}` — Ingress stored, backends resolved, never enacted (no controller) |
| `verify-lab-08.sh` | `PASS=33 FAIL=1` (the one documented node-group failure) |
| `outputs/lab-08-before-restart.txt` / `-after-restart.txt` | Byte-identical diff after a Floci stop/start |

## 7. Analysis and Discussion

`verify-lab-08.sh` reports `PASS=33 FAIL=1`, and the one failure is the same genuine, already-documented Floci limitation named throughout this lab (`update-nodegroup-config`), not a surprise discovered by the script — a cleaner outcome than it might look, since every other check, including seven HPA-specific assertions and eight exposure-ladder assertions, passed against live, re-derived state.

Several things were **better than expected**. First, `metrics-server` and the full `metrics.k8s.io` API were already present and working before Step 7 began, removing an entire install step the lab allows for but does not require here. Second, the HPA's scale-down stabilisation window behaved with genuine precision: the scale-in event landed almost exactly 300 seconds after the last high CPU reading, matching the configured `stabilizationWindowSeconds: 300` far more exactly than "eventually" — a real control loop caught doing real arithmetic, not a canned demo. Third, `usms-gateway`'s `LoadBalancer` Service actually resolved a non-`<pending>` `EXTERNAL-IP`, better than Section 11's general expectation; the catch, covered below, is that the address is not useful from outside the container.

Several things were **worse than expected**, each a genuine Floci limitation rather than an environment artefact, each checked against `known-issues.html` before being treated as a platform gap: `update-nodegroup-config` fails outright with `UnknownOperationException` rather than silently no-opping; the node group's own `labels` field is recorded by the AWS API but never actually applied to the real k3s node, discovered only because `kubectl get nodes --show-labels` disagreed with `describe-nodegroup`; a `NodePort`'s host-port promise and the cluster's own `_lb_ports_` tag both fail to translate into anything Docker actually publishes, confirmed directly with `docker port`; and no ingress controller exists anywhere on this build, so `usms-portal-ingress`'s correctly-resolved backends never receive an `Address` at all. None of these are documentation gaps on my part — each was confirmed with a direct command against the live API or the Docker daemon, not inferred.

One finding changed my own assumption mid-exercise and is worth stating precisely because the lesson generalises beyond this lab: Exercise 3's supplied `usms-reports` manifest sets only `resources.limits` with no `requests`, which I initially expected to leave the HPA permanently `<unknown>` — instead, the Kubernetes API server's own admission-time defaulting (copying `limits` into `requests` when no `LimitRange` says otherwise) silently resolved it within one scrape interval. This is standard, documented core Kubernetes behaviour, not a Floci quirk, and the only fault that genuinely never self-corrected was the Deployment's `minReplicas` equal to its `maxReplicas` — a distinction only visible by running the exercise and reading the live object's state, not by reading the YAML, exactly as the exercise's own instructions insisted on.

## 8. Reflection

1. **What did I learn about EKS?**  
   Elasticity on Kubernetes is genuinely two separate control loops with no shared knowledge of each other, and this lab is the first place in the course where that split actually bit: the HPA scaled `usms-enrolment` correctly and on schedule, while the node-group side of the same picture (Step 10) failed outright, and nothing in the HPA's own output would ever have told me that — I had to query the AWS side separately to find it. I also learned that Kubernetes' own defaulting behaviour (requests defaulting to limits) is strong enough to mask an intentionally "broken" exercise manifest, which is a useful thing to know before ever assuming a missing field will fail the way documentation implies it should.

2. **What challenges did I encounter?**  
   Distinguishing "this build doesn't do X" from "I configured X wrong" took real discipline on every exposure-ladder step — the NodePort, the LoadBalancer's `EXTERNAL-IP`, and the `_lb_ports_` tag all *partially* worked (correct in-cluster behaviour, wrong host-level behaviour), which is a more subtle failure mode to diagnose than an outright error. Getting Exercise 3's two faults right required abandoning my first assumption entirely once the running pod's own resource spec contradicted it — a good reminder that the exercise's instruction to diagnose "using commands, not by reading the YAML" was not a stylistic preference but the only way to catch that the YAML's apparent fault had already been healed by the cluster itself.

3. **How would I apply this in a real cloud environment?**  
   I would never treat a workload-level autoscaler as sufficient on its own — the Cluster Autoscaler or Karpenter is not optional infrastructure, it is the other half of the same promise the HPA alone cannot keep, a conclusion this lab reached by watching the AWS-side half fail outright rather than by reading about it. I would also treat "the Service has an `EXTERNAL-IP`" as necessary but not sufficient evidence that an application is actually reachable, since this lab's own LoadBalancer Service proved that wrong directly.

4. **What would I like to explore further?**  
   Installing a real ingress controller (Traefik ships with vanilla k3s outside Floci's build, so it may simply be disabled here) to see whether `usms-portal-ingress`'s already-correct backend resolution would immediately produce a working `Address` with zero manifest changes; and running Exercise 3's exact scenario against a cluster with a `LimitRange` object present, to see the genuinely different failure mode a `LimitRange` that forbids missing `requests` would produce instead of silent defaulting.

## 9. Conclusion

The objectives were achieved with one honestly-documented, already-known gap: `usms-enrolment` scales correctly on a real HPA with observed scale-out and scale-in events, two PodDisruptionBudgets correctly distinguish voluntary from involuntary disruption, and the full exposure ladder from ClusterIP to Ingress was built and tested rung by rung, with every limitation specific to this build named and verified rather than assumed. The one AWS-side scaling step (Step 10) could not be completed live, confirmed as a documented Floci 2.0.1 limitation rather than a configuration error, and `verify-lab-08.sh` reports exactly that single failure (`PASS=33 FAIL=1`). Every identifier Lab 10 needs is recorded in `configs/lab-08.env`, re-derived from the live API rather than hard-coded.

The key concepts were the genuine independence of the HPA's workload-level control loop from any node-level capacity control loop, the exposure ladder as a sequence of increasingly expensive and increasingly capable rungs rather than a single on/off decision, and the sharp distinction — demonstrated, not merely stated — between a PodDisruptionBudget's governance of the Eviction API and its total inapplicability to a direct object deletion. The skills developed were diagnosing an autoscaler's state entirely from live `kubectl describe` output rather than from the manifest that created it, distinguishing a platform limitation from a misconfiguration by checking a specific, falsifiable claim (a published Docker port, a node's actual labels, an Ingress's actual status) rather than assuming either, and revising an initial diagnosis mid-exercise once live evidence contradicted it. This lab matters because it is where USMS's deployment stopped being a fixed-size demo and became a system that has to answer "what happens under load" and "who can actually reach this" — the two questions a production system cannot avoid indefinitely.

## 10. Appendix

Files in the repository:

- `manifests/lab-08/10-hpa-enrolment.yaml`, `11-hpa-results.yaml` (Exercise 1), `20-loadgen.yaml`, `30-pdb-gateway.yaml`, `40-service-nodeport.yaml`, `50-service-loadbalancer.yaml`, `60-ingress.yaml`
- `manifests/lab-07/20-enrolment.yaml` — `nodeSelector` persisted (Step 11), embedded PDB removed (now owned by `manifests/lab-08/30-pdb-gateway.yaml`)
- `manifests/lab-07/40-gateway.yaml` — scaled to 2 replicas with an advisory `topologySpreadConstraints` (Exercise 2), embedded Service removed (now owned by `manifests/lab-08/50-service-loadbalancer.yaml`)
- `configs/lab-08.env` – 19 exports, all read live
- `scripts/utilities/verify-lab-08.sh` — `PASS=33 FAIL=1`
- `scripts/utilities/hpa-watch.sh` — Step 9
- `scripts/cleanup/lab-08-cleanup.sh` — end of course only, syntax-checked, never run
- `labs/lab-08-eks-scaling/exercises.md`
- `notes/lab-08-notes.md` — Floci-specific findings, Step 17's comparison tables and prose, all seven Review Questions, Exercise 5 Part 3
- `outputs/lab-08-baseline.txt`, `-nodegroup-before.json`, `-nodegroup-after.json`, `-eviction.json`, `-before-restart.txt`, `-after-restart.txt`, `-scaling-evidence.json`, `-lab06-readiness.txt` (git-ignored; kept until submission)
