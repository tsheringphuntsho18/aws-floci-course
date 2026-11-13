# Lab 06 — Auto Scaling — Report

    Student Name: Tshering Phuntsho
    Student ID: 02230310
    Module: DSO303 Cloud Native Solution Design
    Practical: Lab 06 – Implementing Auto Scaling for an ECS-Based Application
    Date: 12/11/2026

## 1. Aim / Objective

This practical added Application Auto Scaling to Lab 05's `usms-enrolment-svc`, so that the task count reacts to demand instead of being set by hand. The objectives were to:

- register `usms-enrolment-svc` as a scalable target (`ecs:service:DesiredCount`, min 2, max 10) and read the AWS-managed service-linked role that writes `desiredCount` on the operator's behalf;
- add two **target tracking** policies — CPU at 50% and `ALBRequestCountPerTarget` at 1000, using the `ResourceLabel` Lab 05 Exercise 5 built — plus a **step scaling** policy driven by a hand-written CloudWatch alarm on a custom metric, for the piecewise requirement target tracking cannot express;
- create two **scheduled actions** for a predictable morning/evening demand curve;
- **fire the alarm and prove that something other than the operator moved `desiredCount`**; suspend and resume scaling without deleting any policy;
- prove the whole scaling configuration survives a Floci restart, and record every name and ARN in `configs/lab-06.env` for later labs.

## 2. Introduction

**AWS Application Auto Scaling** is a control-plane service that writes exactly one number on a target resource — here, an ECS service's `desiredCount` — and leaves every other mechanism (ECS starting/stopping tasks, the target group registering/deregistering them, the load balancer health-checking them) exactly as it already was. It is built from four kinds of object:

- a **scalable target**: a registration that a given dimension of a given resource may move between a floor and a ceiling (`MinCapacity`/`MaxCapacity`);
- **scaling policies**, which decide the number. **Target tracking** picks a metric with a target value and computes the capacity that would bring the metric back to target; **step scaling** maps ranges of an alarm breach to fixed capacity adjustments;
- **scheduled actions**, which move the floor and ceiling at a known time rather than reacting to a metric;
- a **service-linked role**, `AWSServiceRoleForApplicationAutoScaling_ECSService`, which the service assumes to call `ecs:UpdateService` — created by name, never configured.

Every reactive decision is made by a **CloudWatch alarm**. Target tracking creates its own two alarms (high/low) automatically; step scaling is driven by an alarm the operator writes and points at the policy's ARN.

Auto scaling matters in cloud-native design because it turns a fixed guess about capacity into a feedback loop: the floor absorbs the first minutes of a spike (because every reactive signal is late — a metric must be published, aggregated, alarmed on, and only then does ECS start a task and the load balancer health-check it), while the ceiling bounds the blast radius of a runaway policy or a scraping bot. Typical uses are web/API tiers behind a load balancer (request-count-driven), queue-depth-driven worker fleets, and calendar-driven capacity for known events (exam results, Black Friday, a product launch).

## 3. Use Case

In USMS, Lab 04 fixed the enrolment service at a hand-picked `desiredCount` of 2, and Lab 05 put it behind a load balancer that could, in principle, carry far more. This lab closes that gap:

- the **CPU target tracking policy** reacts to the metric Lab 04's Container Insights setting already publishes, with no new configuration;
- the **request-count target tracking policy** reacts to the signal that actually matters for a web API — requests per task — using the `ALBRequestCountPerTarget` label Lab 05 built from the ALB's and target group's own ARNs;
- the **step scaling policy** answers a requirement neither target tracking policy can express: "if the enrolment work queue is 100 deep, add one task; if it is 200 deep, add three" — a piecewise response to a custom metric, `USMS/Enrolment EnrolmentQueueDepth`, published by the enrolment application (simulated here with `put-metric-data`, since no real queue exists yet);
- the **scheduled actions** raise the floor to 4 tasks every weekday morning (enrolment traffic is predictable by time of day) and lower it back to 2 in the evening, so the service is never caught flat-footed by a spike it could have seen coming;
- **suspension** gives an operator a single, reversible switch to hold capacity steady during an incident or a deployment, without deleting any policy.

Other common uses elsewhere: an e-commerce checkout service scaling on request count during a sale; a video-encoding worker fleet scaling on SQS queue depth; a reporting service with a scheduled floor raised before a known month-end batch run.

## 4. System Architecture / Design

![image](/screenshots/lab-6-autoscaling/architecture.jpeg)

*Figure 1 – Application Auto Scaling sits entirely above Lab 04's ECS service and Lab 05's load balancer, and changes nothing about either: it only ever writes `desiredCount`.*

## 5. Implementation Procedure

**Preparation.** Resumed Floci (Docker Desktop's `docker-desktop` systemd user service had to be started first — it was not running at the start of this session), loaded `configs/course.env` through `configs/lab-05.env`, and confirmed `verify-lab-02.sh`/`-03.sh`/`-05.sh` all reported `FAIL=0` and `verify-lab-04.sh` reported `PASS=39 FAIL=0` (Lab 05's Exercise 2 patch already applied, so there was no outstanding documented failure to carry forward). Confirmed the service was at its baseline: `desiredCount` 2, one deployment, one load balancer.

**Probing the build.** Ran the Step 3 probe. Every Application Auto Scaling and CloudWatch call answered except `describe-scheduled-actions`, which returned `UnsupportedOperation`. Confirmed with a direct `put-scheduled-action` call (also `UnsupportedOperation`, both with and without `--timezone`) that this is the whole operation, not a flag — matching the documented Floci Known Issue for this lab exactly. Everything else on the probe is **support path A**.

**Service-linked role.** `create-service-linked-role` for `ecs.application-autoscaling.amazonaws.com` returned a **different** role name than AWS's own documented one: `AWSServiceRoleForEcsApplicationAutoscaling` instead of `AWSServiceRoleForApplicationAutoScaling_ECSService`. `get-role` on the AWS-documented name fails with `NoSuchEntity`.

**Registering the scalable target.** Derived the resource ID from the service's own ARN (`${SVC_ARN##*:}`), validated it as three slash-separated segments starting with `service`, and registered it with min 2 / max 10. Oddly, `describe-scalable-targets` reports `RoleARN` using the AWS-documented role name — the one that does **not** exist under `get-role` — so this field is cosmetic on this build, not a real link. Changed the ceiling to 12 and back to confirm the re-registration model (an omitted parameter is left unchanged, not reset). Did the "Your turn": re-registered with `MinCapacity=5` while the service ran 2 tasks — `desiredCount` stayed at 2 (a Floci limitation: raising the floor alone does not push the count when no policy evaluates), then restored it.

**Target tracking policies.** Created `usms-enrolment-cpu-target-tracking` (CPU, target 50, out/in cooldowns 60/300) and confirmed Application Auto Scaling created its two managed alarms automatically — except on this build both alarms report `Threshold: 50.0` (no 45/50 dead band) and `MetricName`/`Namespace` are the literal predefined-metric-type string and `AWS/ECS`, not the real CloudWatch metric (`CPUUtilization`). Built the `ResourceLabel` from Lab 05 Exercise 5's recorded value (`app/usms-enrolment-alb/99a7b3736e494f3d/targetgroup/usms-enrolment-tg/399fd5d0493541f2`, validated at six segments), and created `usms-enrolment-requests-target-tracking` (`ALBRequestCountPerTarget`, target 1000) — fully supported here, unlike the Floci-vs-AWS table's general caution that this metric is "often unsupported".

**Step scaling.** Published the custom metric `USMS/Enrolment EnrolmentQueueDepth`, which indexed into `list-metrics` immediately. Wrote the two-step table (0–100 → +1, 100+ → +3, open-ended top interval) and created `usms-enrolment-queue-step-out`, then the alarm `usms-enrolment-queue-high` (`>= 100`, `notBreaching`) pointing at the policy's ARN. Confirmed the policy's own `Alarms` field is empty on this build — Floci does not back-populate the reverse link the way real AWS does.

**Scheduled actions.** Both `put-scheduled-action` attempts failed with `UnsupportedOperation` (confirmed above). Followed the Known Issues page's **Alternative 2** (manual `update-service --desired-count`, then restore) as the fallback proof that the service converges to a new count; Alternative 1 was not usable because `scripts/utilities/student-fallback-demo.py`, referenced by Lab 05's own appendix, does not actually exist anywhere in this repository.

**Firing the alarm.** Pushed the queue-depth metric to 260 (a breach of 160 against the threshold of 100, selecting the +3 step) and watched the alarm with a polling loop. **The alarm evaluated for real and transitioned to `ALARM` on its own in about 45 seconds** — no `set-alarm-state` needed, better than the Known Issues page's general expectation for Lab 06. `desiredCount` then moved **autonomously**: `describe-scaling-activities` recorded `Cause: "monitor alarm usms-enrolment-queue-high in state ALARM triggered policy usms-enrolment-queue-step-out"` three times in a row (2→5→8→10, 10 seconds apart), clamped at `MaxCapacity=10`. The 10-second spacing — well inside the policy's own 60-second `Cooldown` — shows the cooldown is **not enforced** on this build, while the ceiling **is**. Pushed the metric back down, then reset `desiredCount` to 2 (metric first, count second, per the lab's own warning that a live policy will re-fight a manual reset otherwise).

**Suspension.** Suspended scale-in only (`DynamicScalingInSuspended=true`) via `--suspended-state`, confirmed all three policies and four managed alarms were untouched, then resumed and confirmed `SuspendedState.*` piped through `grep -ci true` returns `0`.

**Persistence.** Recorded seven facts (target bounds+suspension, three policies' full configuration, the custom alarm), ran `floci-down.sh`/`floci-up.sh`, re-derived every identifier from the API with no shell variable reused, and got an empty `diff`: **PERSISTENCE PROVEN**.

**Closing the loop.** Traced the nine-line chain from a metric to a served request (Section 14, Review Question 1) and confirmed this lab touched only the first three lines — the scalable target, the policies, and the alarms — while the task definition, the load balancer and the service's `loadBalancers` entry are exactly as Lab 05 left them.

**Recording.** Wrote `configs/lab-06.env` (22 exports, 24 after Exercise 5), built `verify-lab-06.sh` and the end-of-course cleanup script (syntax-checked, never run), repaired the two stale `lab-04-cleanup.sh` hint strings in `lab-05-cleanup.sh` (precisely, not by blind find-and-replace — see Section 7), completed the five exercises, and committed.

## 6. Results and Evidence

### 6.1 CLI / SDK Output

**Screenshot 1 – Environment resumed, six env files sourced, 14 values populated**
![image](../../screenshots/lab-6-autoscaling/s1.png)

**Screenshot 2 – Labs 02–05 verified (`FAIL=0`/`PASS=39`), service at baseline**
![image](../../screenshots/lab-6-autoscaling/s2.png)

**Screenshot 3 – Step 3 probe: every call SUPPORTED except `describe-scheduled-actions`**
![image](../../screenshots/lab-6-autoscaling/s3.png)

**Screenshot 4 – Service-linked role: Floci creates a DIFFERENT role name than AWS documents**
![image](../../screenshots/lab-6-autoscaling/s4.png)

**Screenshot 5 – Scalable target registered; `RoleARN` names a role that `get-role` cannot find**
![image](../../screenshots/lab-6-autoscaling/s5.png)

**Screenshot 6 – Bounds changed and restored (Checkpoint 2); "Your turn" MinCapacity=5**
![image](../../screenshots/lab-6-autoscaling/s6.png)

**Screenshot 7 – CPU target tracking policy created, with its two managed alarms**
![image](../../screenshots/lab-6-autoscaling/s7.png)

**Screenshot 8 – The two managed alarms read back (no dead band on this build)**
![image](../../screenshots/lab-6-autoscaling/s8.png)

**Screenshot 9 – `ResourceLabel` derived and validated; requests policy created (Checkpoint 3)**
![image](../../screenshots/lab-6-autoscaling/s9.png)

**Screenshot 10 – Custom metric published; step policy and its alarm created (Checkpoint 4)**
![image](../../screenshots/lab-6-autoscaling/s10.png)

**Screenshot 11 – Scheduled actions: confirmed `UnsupportedOperation`; Known Issues fallback**
![image](../../screenshots/lab-6-autoscaling/s11.png)

**Screenshot 12 – The alarm fires for real; `desiredCount` moves autonomously to 10 (Checkpoint 5)**
![image](../../screenshots/lab-6-autoscaling/s12.png)

**Screenshot 13 – Restored to baseline: metric down first, then the count**
![image](../../screenshots/lab-6-autoscaling/s13.png)

**Screenshot 14 – Suspend scale-in, policies untouched, resume, `grep -ci true` = 0 (Checkpoint 6)**
![image](../../screenshots/lab-6-autoscaling/s14.png)

**Screenshot 15 – `PERSISTENCE PROVEN` after a Floci stop/start (Checkpoint 7)**
![image](../../screenshots/lab-6-autoscaling/s15.png)

**Screenshot 16 – Step 15: the nine-line chain traced in seven blocks**
![image](../../screenshots/lab-6-autoscaling/s16.png)

**Screenshot 17 – `configs/lab-06.env` populated, 22 exports, matches the live API**
![image](../../screenshots/lab-6-autoscaling/s17.png)

**Screenshot 18 – `verify-lab-06.sh`: `PASS=41 FAIL=3` (three documented benign failures)**
![image](../../screenshots/lab-6-autoscaling/s18.png)

**Screenshot 19 – The two stale cleanup-script hint strings, precisely repaired (Checkpoint 8)**
![image](../../screenshots/lab-6-autoscaling/s19.png)

### 6.2 AWS Management Console Verification

Floci is driven entirely through the CLI, so the console-equivalent evidence is each resource's own read-back:

![image](/screenshots/lab-6-autoscaling/autoscaling.png)

| Evidence | One-line explanation |
|---|---|
| `application-autoscaling describe-scalable-targets` | One target, `service/usms-ecs-cluster/usms-enrolment-svc`, `ecs:service:DesiredCount`, min 2 max 10, all suspension switches false |
| `application-autoscaling describe-scaling-policies` | Three policies: two `TargetTrackingScaling` (CPU 50, requests 1000) and one `StepScaling` (+1/+3) |
| `cloudwatch describe-alarms --alarm-name-prefix TargetTracking-...` | Four managed alarms (two per target tracking policy), created automatically |
| `cloudwatch describe-alarms --alarm-names usms-enrolment-queue-high` | The hand-written alarm, invoking the step policy's ARN |
| `outputs/lab-06-scaling-proof.txt` equivalent (captured live, Step 12) | `describe-scaling-activities` names both the alarm and the policy in `Cause` |
| `outputs/lab-06-pre-restart.txt` / `-post-restart.txt` | Byte-identical after a Floci stop/start |

## 7. Analysis and Discussion

The control-plane configuration was built in full and verified against the live API at every step. `verify-lab-06.sh` reports `PASS=41 FAIL=3`, and all three failures are the same documented, benign cause: `describe-scheduled-actions`/`put-scheduled-action` return `UnsupportedOperation` on this Floci 2.4.0 build, exactly as the course's own Known Issues page predicts for this lab. This is a control-plane limitation, not a configuration error — the morning/evening scheduled actions are correctly specified in this report and in `exercises.md`, but there is nothing to read back on this build, so I did not claim an activity I did not observe.

What was **better than expected**: the Known Issues page's general statement for Lab 06 is "forcing an alarm does not change the ECS service's desired count." On this build that was not true for the custom alarm — `usms-enrolment-queue-high` evaluated the published datapoints for real, transitioned to `ALARM` on its own, and the step policy moved `desiredCount` autonomously, recorded with a `Cause` string naming both the alarm and the policy. `set-alarm-state` was never needed for the primary proof. `ALBRequestCountPerTarget`, which the Floci-vs-AWS comparison in Section 11 also flags as "often unsupported", worked cleanly here too.

What was **worse than expected**, and genuinely informative: the step policy's 60-second `Cooldown` is **not enforced** — three `+3` adjustments landed 10 seconds apart (2→5→8→10) instead of one `+3` every 60 seconds, confirming Section 11's listed limitation empirically rather than by assumption. The `MaxCapacity` ceiling, by contrast, **was** enforced — the climb stopped exactly at 10, not 13. Two other concrete deviations are worth recording because they would mislead a reader who trusted the field at face value: the scalable target's `RoleARN` names `AWSServiceRoleForApplicationAutoScaling_ECSService`, but `create-service-linked-role` actually provisioned a different name (`AWSServiceRoleForEcsApplicationAutoscaling`) — the field is populated but not backed by a real role under that name; and the managed CPU alarms report `MetricName: ECSServiceAverageCPUUtilization` and `Namespace: AWS/ECS` for *both* the CPU and the request-count policies, rather than resolving to the real CloudWatch metric (`CPUUtilization`/`RequestCountPerTarget`) and namespace (`AWS/ApplicationELB` for the latter) the way real AWS does, and the managed alarms carry no dead band (both High and Low thresholds read 50.0, not 50/45).

Other errors encountered and fixed:
1. `grep -c '$'` on a just-written JSON template returns exit status 1 when the count is 0 (correctly, nothing matched) — this breaks a `&&`-chained screenshot command that expects success; wrapped in `(... || true)`.
2. `python3 scripts/capture.py` runs commands under `/bin/sh`, not `bash`, so `source file` must be written as `. file`.
3. The capture script buffers `stdout` and `stderr` separately and prints `stdout` first, then `stderr` — a screenshot that deliberately triggers an error (to document a limitation) shows the error message grouped at the end, not interleaved where it actually occurred; noted so the screenshots are read correctly.
4. `scripts/utilities/student-fallback-demo.py`, which Lab 05's own appendix lists as a committed file, does not exist anywhere in this repository; used the Known Issues page's Alternative 2 instead and recorded the discrepancy.

**Floci vs Real AWS**, summarised from what this build actually did:

| Area | Real AWS | Observed here |
|---|---|---|
| Scalable target, policies, managed alarms | Full | **Implemented** — created, read back, and persisted correctly |
| `ALBRequestCountPerTarget` | Full | **Implemented** here (Section 11 generally flags it as often unsupported) |
| Alarm evaluation on custom metrics | Every period | **Implemented** — the queue alarm evaluated and alarmed for real |
| Scaling policy invocation from an alarm | Real, within seconds | **Implemented** — `desiredCount` moved with a correct `Cause` string |
| `MaxCapacity` enforcement | Every decision | **Implemented** — clamped the climb at exactly 10 |
| `Cooldown` / `ScaleOutCooldown` enforcement | Enforced | **Floci Limitation** — three adjustments fired 10s apart, not 60s |
| Service-linked role identity | Real, assumable | **Floci Limitation** — created under a different name than the target's own `RoleARN` claims |
| Managed alarm metric resolution & dead band | Real metric/namespace, 45/50 split | **Floci Limitation** — literal type string as `MetricName`, `AWS/ECS` for both, no dead band |
| `put-scheduled-action` / `describe-scheduled-actions` | Full | **Floci Limitation** — `UnsupportedOperation`, matches the documented Known Issue |
| `MinCapacity` alone raising `desiredCount` | Immediate | **Floci Limitation** — did not move the count without a policy evaluating |

## 8. Reflection

1. **What did I learn about Application Auto Scaling?**
   It writes exactly one integer and nothing else — every other mechanism (task placement, health checks, target group registration) already existed from Labs 04 and 05 and needed no change. The scalable target's three-part address (namespace, resource ID, dimension) is derived from the service's own ARN, never typed. Target tracking creates its own alarms; step scaling needs the operator to write one, and the direction of creation matters (policy before alarm, or the alarm's action names nothing).

2. **What challenges did I encounter?**
   Distinguishing a real Floci limitation from a mistake in my own commands — the `Cooldown` not being enforced, and the `RoleARN` naming a role that does not exist, both needed cross-checking (re-running the probe, re-deriving IDs from the API) before I was confident they were platform behaviour and not my error. The `/bin/sh` vs `bash` difference in the screenshot tool, and `grep -c`'s exit-status-on-zero-matches quirk breaking a `&&` chain, cost a few retries.

3. **How would I apply this in a real cloud environment?**
   I would start every new service with a conservative target tracking policy (CPU or request count) covering the common case, add step scaling only for a genuinely piecewise requirement that a single target value cannot express, and use scheduled actions only for demand I can actually predict (never as a substitute for a real alarm). I would load-test before trusting any of the numbers in this lab — target 50, target 1000, threshold 100 and ceiling 10 are all provisional, as the lab itself says, until measured against real traffic.

4. **What would I like to explore further?**
   Reading the scaling activities and the managed alarms from the CloudWatch lab that follows this one, since this lab's custom alarm and metric are explicitly built to be reused there; comparing ECS service auto scaling with the EKS Horizontal Pod Autoscaler in Lab 08, which scales pods rather than tasks; and finding out whether a real AWS account reproduces the asymmetric alarm thresholds (50/45) that this Floci build does not.

## 9. Conclusion

The objectives were achieved at the control-plane level, with the one documented exception (scheduled actions) recorded honestly rather than worked around. `usms-enrolment-svc` now has a scalable target bounded 2–10, two target tracking policies and a step scaling policy backed by a hand-written alarm, and a demonstrated, autonomous scale-out from 2 to 10 tasks driven entirely by a CloudWatch alarm — not by the operator. Suspension and resumption were exercised without disturbing any policy, and the whole configuration was proven to survive a Floci restart by re-deriving every identifier from the API and diffing seven facts to an empty result. Every name and ARN is recorded in `configs/lab-06.env` for the CloudWatch and CloudFormation labs that follow.

The key concepts were the scalable target as a floor-and-ceiling registration, target tracking versus step scaling as two different ways of turning a metric into a capacity, the service-linked role as the identity behind every automated change, and the asymmetry between eager scale-out and reluctant scale-in. The skills developed were building Application Auto Scaling and CloudWatch alarm request documents from the CLI, deriving every identifier from the API rather than typing it, writing a verification script that degrades a known-unsupported operation to a documented benign failure instead of crashing, and distinguishing a platform limitation from a configuration mistake by cross-checking against the API rather than assuming. This lab matters because it is the first point in the course where a system changes itself in response to load, with no operator in the loop at the moment it happens.

## 10. Appendix

Files in the repository:

- `templates/lab-06-target-tracking-cpu.json`, `lab-06-target-tracking-requests.json`, `lab-06-step-scaling-out.json`, `lab-06-suspended-state.json`
- `templates/lab-06-target-tracking-memory.json`, `lab-06-step-scaling-in.json` (Exercise 1/2 practice documents)
- `configs/lab-06.env` – 24 exports (22 from the main implementation, 2 from Exercise 5)
- `scripts/utilities/verify-lab-06.sh` — `PASS=41 FAIL=3`, all three failures documented as benign (scheduled actions unsupported on this build)
- `scripts/utilities/usms-scaling-report.sh` (Exercise 3), `scripts/utilities/usms-scaling-history.sh` (Exercise 5)
- `scripts/cleanup/lab-06-cleanup.sh` – end of course only, syntax-checked, never run
- `scripts/cleanup/lab-05-cleanup.sh` – two stale hint strings repaired (precisely, not by blind replace; see Section 7)
- `labs/lab-06-ecs-autoscaling/exercises.md`
- `notes/lab-06-notes.md` — support path, Floci deviations, review questions
- `outputs/lab-06-pre-restart.txt`, `-post-restart.txt`, `-pre-verify-05.txt`, `-post-verify-05.txt`, `-scaling-history.json`, `-scale-latency.txt`, `-lab10-readiness.txt`, `-scaling-report.json` (git-ignored; kept until submission/Lab 10)
