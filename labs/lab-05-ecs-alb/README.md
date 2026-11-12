# Lab 05 — ALB — Report

    Student Name: Tshering Phuntsho
    Student ID: 02230310
    Module: DSO303 Cloud Native Solution Design
    Practical: Lab 05 – Putting the ECS Service Behind an Application Load Balancer
    Date: 12/10/2026

## 1. Aim / Objective

This practical put Lab 04's USMS enrolment service (`usms-enrolment-svc`) behind a stable, managed entry point: an Application Load Balancer. The objectives were to:

- create an internet-facing Application Load Balancer in the two public subnets from Lab 02, with its own security group;
- create a target group (`--target-type ip`) with a deliberate health check and deregistration delay, a listener with a default forward action, and one listener rule;
- attach the existing ECS service to the target group, so that ECS registers and deregisters its own tasks;
- **cut over**, so that the load balancer becomes the only thing that can reach the tasks;
- observe a deployment behind the load balancer, prove the configuration survives a restart, and record every ARN in `configs/lab-05.env` for Lab 06.

## 2. Introduction

Elastic Load Balancing (ELB) distributes incoming traffic across many targets and gives clients one stable DNS name in front of them. The **Application Load Balancer (ALB)** works at layer 7 (HTTP/HTTPS).

An ALB is made of four objects:

- the **load balancer** itself, with nodes in at least two Availability Zones and its own security groups;
- **listeners**, each with a port, a protocol and exactly one default action;
- **rules**, each a condition plus an action, evaluated lowest priority number first;
- **target groups**, which hold the targets and the **health check**.

Key features include path- and host-based routing, `forward`/`redirect`/`fixed-response` actions, health checks that keep failed targets out of rotation, connection draining, TLS termination with AWS Certificate Manager, and native integration with Amazon ECS, which registers each task's IP address automatically.

Load balancing matters in cloud computing because it makes elastic, self-healing compute usable. Tasks come and go and change addresses, but clients see one name. Typical uses are fronting web applications and APIs, microservice path routing, blue/green and canary deployments, and terminating HTTPS at the edge.

## 3. Use Case

In USMS, Lab 04's enrolment tasks had private, temporary IP addresses and no name, so the student portal had no stable way to call them. In this lab:

- the **ALB gives the enrolment API a stable DNS name** in front of tasks that keep changing;
- **ECS keeps the target group up to date** as tasks start and stop, so scaling in Lab 06 needs no manual registration;
- **health checks keep a broken task out of rotation**, and the **deregistration delay** lets in-flight requests finish during a deployment;
- the **listener rule** (`/alb-health → fixed 200`) shows how other USMS services (results, transcripts) can share one hostname through path routing;
- **security tiers:** the internet → `usms-alb-sg` → `usms-enrolment-sg`, with the tasks still private.

Other common uses include e-commerce sites routing `/api` and `/static` to different services, and SaaS products doing canary releases with weighted forwarding.

## 4. System Architecture / Design

![iamge](/screenshots/lab-5-alb/architecture.jpeg)

*Figure 1 – USMS enrolment service behind an internet-facing ALB. Lab 06 will add Application Auto Scaling on the same service, using this target group.*

## 5. Implementation Procedure

**Preparation.**

- Resumed Floci, loaded the environment files from Labs 01–04, and confirmed `verify-lab-02`, `-03` and `-04` all reported `FAIL=0`. Saved Lab 04's result as the "before" for the cutover.

**Building the load balancer.**

- Created `usms-alb-sg`, which admits tcp/80 from `0.0.0.0/0` (the course's only deliberate internet-open rule), and added a 443 rule as practice.
- Created the internet-facing ALB `usms-enrolment-alb` across `usms-public-subnet-a` and `-b` (two AZs), and set `idle_timeout` and `drop_invalid_header_fields`.
- Created the target group `usms-enrolment-tg` with `--target-type ip`: health check `GET /` every 30 s, timeout 5 s, thresholds 2/2, matcher 200. Widened the matcher to `200-399` and back to see that health settings are configuration, not identity.
- Set the deregistration delay to 30 s and the algorithm to `least_outstanding_requests`.
- Created an HTTP:80 listener whose default action forwards to the target group.
- Added an ingress rule so `usms-enrolment-sg` admits tcp/80 from `usms-alb-sg`.

**Attaching the service.**

- Attached `usms-enrolment-svc` to the target group (`enrolment-api`, port 80) with a 60 s health-check grace period.
- On Floci 2.0.1 the call was accepted, but the attachment was not returned on read-back (a documented known issue). I recorded the evidence and ran the Known Issues routing demonstration instead of rebuilding the service.
- Read target health and compared it with ECS task health, then scaled 2 → 3 → 2 by hand.
- Tried the data path with `curl` and recorded the five-block control-plane proof chain.

**Cutover.** Revoked the old `usms-app-sg` rule, leaving `usms-alb-sg` as the tasks' only source. Confirmed that `verify-lab-04.sh` then reported exactly one expected failure.

**Observing the system.**

- Forced a new deployment and compared the before and after state.
- Added a priority-10 `fixed-response` rule for `/alb-health`.
- Proved that every object persisted across a Floci stop/start, re-deriving every ARN from the API.
- Audited the security chain (`CUTOVER CONFIRMED`, `LOOP CLOSED`).

**Recording.** Wrote `configs/lab-05.env` (15 exports, 16 after Exercise 5), built `verify-lab-05.sh` and the end-of-course cleanup script (syntax-checked, never run), completed the five exercises, and committed.

## 6. Results and Evidence

### 6.1 CLI / SDK Output

**Screenshot 1 – Environment and earlier labs verified**
![iamge](/screenshots/lab-5-alb/s1.png)
![iamge](/screenshots/lab-5-alb/s2.png)

**Screenshot 2 – ELBv2 support probe**
![iamge](/screenshots/lab-5-alb/s3.png)

**Screenshot 3 – `usms-alb-sg` with ports 80 and 443**
![iamge](/screenshots/lab-5-alb/s4.png)
![iamge](/screenshots/lab-5-alb/s5.png)

**Screenshot 4 – Load balancer created: two AZs, internet-facing, active (Checkpoint 2)**
![iamge](/screenshots/lab-5-alb/s6.png)

**Screenshot 5 – Target group (`ip`, health check) and matcher change/restore**
![iamge](/screenshots/lab-5-alb/s7.png)
![iamge](/screenshots/lab-5-alb/s8.png)

**Screenshot 6 – Target group attributes (deregistration delay 30)**
![iamge](/screenshots/lab-5-alb/s9.png)

**Screenshot 7 – Listener forwarding to the target group (Checkpoint 3)**
![iamge](/screenshots/lab-5-alb/s10.png)

**Screenshot 8 – `usms-enrolment-sg` with both sources before cutover**
![iamge](/screenshots/lab-5-alb/s11.png)

**Screenshot 9 – Service attachment accepted, and the known-issue read-back**
![iamge](/screenshots/lab-5-alb/s12.png)

**Screenshot 10 – Known Issues routing demonstration**
![iamge](/screenshots/lab-5-alb/s13.png)

**Screenshot 11 – Target health vs ECS task health (Checkpoint 4) and manual 2 → 3 → 2**
![iamge](/screenshots/lab-5-alb/s14.png)
![iamge](/screenshots/lab-5-alb/s15.png)

**Screenshot 12 – Step 12 data-path attempt and control-plane proof**
![iamge](/screenshots/lab-5-alb/s16.png)

**Screenshot 13 – Cutover: `verify-lab-04` diff showing exactly one changed check**
![iamge](/screenshots/lab-5-alb/s17.png)

**Screenshot 14 – Forced deployment (Checkpoint 5)**
![iamge](/screenshots/lab-5-alb/s18.png)

**Screenshot 15 – Listener rules: priority 10 + default (Checkpoint 6)**
![iamge](/screenshots/lab-5-alb/s19.png)

**Screenshot 16 – `PERSISTENCE PROVEN` after restart (Checkpoint 7)**
![iamge](/screenshots/lab-5-alb/s20.png)

**Screenshot 17 – Audit: `CUTOVER CONFIRMED` and `LOOP CLOSED`**
![iamge](/screenshots/lab-5-alb/s21.png)

**Screenshot 18 – `configs/lab-05.env` populated, 15 exports**
![iamge](/screenshots/lab-5-alb/s22.png)

**Screenshot 19 – `verify-lab-05.sh` result and cleanup script syntax check**
![iamge](/screenshots/lab-5-alb/s23.png)
![iamge](/screenshots/lab-5-alb/s24.png)

**Screenshot 20 – Exercises 1–5**
![iamge](/screenshots/lab-5-alb/s25.png)
![iamge](/screenshots/lab-5-alb/s26.png)
![iamge](/screenshots/lab-5-alb/s27.png)
![iamge](/screenshots/lab-5-alb/s28.png)
![iamge](/screenshots/lab-5-alb/s29.png)

### 6.2 AWS Management Console Verification

Floci is driven through the CLI, so the console-equivalent evidence is each resource's read-back.

| Evidence | One-line explanation |
|---|---|
| `elbv2 describe-load-balancers` | The ALB is internet-facing, type application, active, in two AZs, carrying `usms-alb-sg` |
| `elbv2 describe-target-groups` + attributes | The target group is `ip`/HTTP/80 with health check `GET /`, matcher 200 and a 30 s deregistration delay |
| `elbv2 describe-rules` | The listener evaluates `/alb-health` (priority 10) before the default forward |
| `ec2 describe-security-groups usms-enrolment-sg` | The tasks admit tcp/80 only from `usms-alb-sg` after the cutover |
| `outputs/lab-05-path-proof.txt` | The listener → target group → service → security group chain is intact |

## 7. Analysis and Discussion

The load balancer layer was fully built and verified. The security group, the ALB in two Availability Zones, the target group with its health check and attributes, the listener and the rule all read back correctly and survived a restart (`PERSISTENCE PROVEN`). The cutover worked exactly as designed: `usms-enrolment-sg` now admits tcp/80 only from `usms-alb-sg`, and Lab 04's verification script reported exactly one, expected, failure. `verify-lab-05.sh` reported `PASS=49 FAIL=0`.

The results only partly matched the expected outcome, and that is the main finding of this lab. On Floci 2.0.1, `update-service` accepted the load balancer attachment and grace period, but `describe-services` did not return them. As a result:

- the target group stayed empty;
- five service-wiring checks in `verify-lab-05.sh` failed.

This is a documented emulator limitation, not a configuration error. A write that does not read back did not happen, so I did not claim it. Following the Known Issues guidance, I did **not** rebuild the service to work around it. I recorded the read-back and ran the routing demonstration. The three affected values in `configs/lab-05.env` are labelled as *declared, not read back*.

Other errors and issues encountered: 
1. the --subnets flag is space-separated, not comma-separated.  
2. an unescaped backtick in the Step 13 query.  
3. OLD_RULE_ID was None until I re-sourced lab-02.env.

Observations:

- **ELBv2 is ARN-first.** Only load balancers and target groups can be looked up by name; listeners and rules must be found by walking down from the load balancer.
- **Health checks live on the target group, not the load balancer.** An unhealthy target can mean a broken application *or* a broken network path; only ECS's own health status and the `Reason` field tell them apart.
- **The migration order matters.** Building the new path (Step 9), proving it (Step 12) and only then removing the old one (Step 13) is what makes this a migration rather than an outage.
- **A load balancer is not free.** By my Exercise 4 estimate, the ALB (about USD 24/month including public IPv4) costs more than the two Fargate tasks behind it (USD 21.26/month).

## 8. Reflection

1. **What did I learn about Elastic Load Balancing?**   
An ALB is four separate objects (load balancer, listener, rules, target group), and the health check belongs to the target group. Fargate tasks require an `ip` target group because they have no instance ID. I also learned that the ECS *service*, not the operator, owns the target group's membership. And three timers decide what happens when a task dies: the deregistration delay (target group), `stopTimeout` (task definition) and the grace period (service).

2. **What challenges did I encounter?**  
The known issue and deciding not to rebuild; JMESPath quoting with backticks inside double quotes; keeping a dozen ARNs alive in one terminal.

3. **How would I apply this in a real cloud environment?**   
I would place each public-facing service behind an ALB with HTTPS (an ACM certificate plus an HTTP→HTTPS redirect), keep the tasks in private subnets admitting only the load balancer's security group, and use path rules to put several microservices behind one hostname. For an API whose only client is inside the VPC, such as the USMS portal, I would choose an **internal** ALB.  

4. **What would I like to explore further?**   
Application Auto Scaling on `ALBRequestCountPerTarget` (Lab 06), HTTPS with ACM, weighted forwarding for blue/green and canary releases, AWS WAF in front of the ALB, ALB access logs to S3, and comparing ALB with an NLB and with Kubernetes ingress on EKS.

## 9. Conclusion

The objectives were achieved at the control-plane level, and the emulator's limits are documented honestly. The USMS enrolment service now has an internet-facing Application Load Balancer, a target group with a deliberate health check and draining configuration, a listener with a path rule, and a completed security cutover. As a result the load balancer is the only thing that can open a connection to a task. Everything persisted across a restart and is recorded in `configs/lab-05.env` for Lab 06. The service's attachment to the target group was accepted but not returned by Floci 2.0.1; I documented that instead of working around it.

The key concepts were the four ELB objects, `ip` targets for `awsvpc` tasks, service-owned target registration, the two health opinions, draining, and staged migrations. The skills I developed were building ELBv2 resources from the CLI with JSON request documents, advanced JMESPath (`||`, `&&`, `sort_by`, escaped literals), writing verification and reporting scripts, and estimating ELB costs. The ALB is important because it turns a set of changing containers into one reliable service, and it provides the request-count signal that Lab 06's auto scaling can use.

## 10. Appendix

Files in the repository:

- `policies/usms-alb-sg-ingress.json`, `policies/usms-alb-sg-ingress-443.json`, `policies/usms-enrolment-sg-ingress-alb.json`
- `templates/lab-05-listener-default-actions.json`, `lab-05-rule-conditions.json`, `lab-05-rule-actions.json`, `lab-05-service-load-balancers.json`, `lab-05-ex1-results-*.json`
- `configs/lab-05.env` – 16 exports, including `USMS_ALB_RESOURCE_LABEL`
- `scripts/utilities/verify-lab-05.sh`, `scripts/utilities/verify-lab-04.sh` (updated in Exercise 2)
- `scripts/utilities/usms-lb-report.sh` (Exercise 3), `scripts/utilities/usms-resource-label.sh` (Exercise 5)
- `scripts/utilities/student-fallback-demo.py` (Known Issues alternative)
- `scripts/cleanup/lab-05-cleanup.sh` – end of course only, not run
- `labs/lab-05-ecs-alb/exercises.md`, `labs/lab-05-ecs-alb/patch-verify-lab-04.py`
- `notes/lab-05-notes.md` – support path, known-issue evidence, benign failures, review questions

