# Lab 05 Notes – ECS Service Behind an Application Load Balancer

**Support path (Step 3): A – full.** On Floci server **2.4.0** every ELBv2 probe answered, Step 5 returned an ARN with state `active`, the ECS service registered its own targets, real health checks moved them `initial → healthy`, and the listener served real HTTP requests (rule evaluation included). The one gap in the data path is name resolution: the ALB's DNS name (`usms-enrolment-alb-99a7b3736e494f3d.elb.floci`) does not resolve on the host, and the compose file publishes only port 4566. The served requests were therefore made **from `usms-web-01` inside the Floci Docker network**, which is the real client in the USMS story (Step 12, Step 15, Exercise 1).

The Lab 05 known issue for Floci **2.0.1** ("the ECS service does not retain `loadBalancers` on readback") **did not occur on 2.4.0**. `describe-services` returned the `loadBalancers` entry and `healthCheckGracePeriodSeconds: 60`, so the Known Issues fallback demo was not needed.

## Environment repair before starting (prerequisite, Section 2)

Before Step 1, Floci's state no longer matched Labs 02–04, so Step 2 could not reach `FAIL=0`.

- **Lab 02 – `configs/lab-02.env` held only 3 of its 17 exports.** Regenerated with Lab 2 Step 24. Floci 2.4.0 ignores tag filters on `describe-network-acls`, so `USMS_PRIVATE_NACL` came back as `acl-default`; I set it to the real `usms-private-nacl` (`acl-863f7c4f903d6b6ab`). The script's "every resource carries Project=USMS" check used `describe-tags --filters Name=tag:Project`. `tag:` is not a valid DescribeTags filter (the valid ones are `key`, `value`, `resource-id`, `resource-type`), so I rewrote it as `Name=key,Values=Project Name=value,Values=USMS`. Result: `PASS=33 FAIL=0`.
- **Lab 03 – `usms-web-01` and `usms-db-01` were `stopped`.** Started them. Result: `PASS=36 FAIL=0`.
- **Lab 04 – the cluster, roles, log group, `usms-enrolment-sg`, both task definition revisions and the service no longer existed.** `ecs-*.json` in `~/floci-data` was empty. I rebuilt them with Lab 04's own commands (Steps 4–10 and Exercise 2's revision 2). Both `templates/lab-04-taskdef*.json` had `"taskRoleArn": ""` (an empty `$TASK_ROLE_ARN` at write time), so I filled in `usms-ecs-task-role`'s ARN. Then I regenerated `configs/lab-04.env` with Lab 4 Step 12 (17 exports). Result: `PASS=38 FAIL=0`. This repository's `verify-lab-04.sh` has 38 checks, not the 49 the Lab 05 text quotes.
- Backup taken before Lab 05: `~/floci-data-pre-lab-05.tar.gz`.

## Corrections to the lab text (found while running it)

1. **Step 14 loop:** `aws ecs describe-services ... --query 'length(deployments)'` errors (`invalid type for value: None`), because `deployments` lives under `services[0]`. Corrected to `length(services[0].deployments)`. Floci also always reports **one** deployment (it replaces tasks in place), so I changed the stop condition to "rollout `COMPLETED` and every target `healthy`".
2. **Step 18 heredoc:** `--query 'Listeners[?Port==\`80\`]...'` inside `$( )` in an unquoted heredoc passes the backslashes through literally, because single quotes inside the command substitution still protect them. JMESPath then rejects it and `USMS_ALB_LISTENER_ARN` is written empty. The unescaped `` `80` `` is correct there. (The escape is needed only inside **double** quotes, as in Step 13.)
3. **Step 17 block 3:** Floci 2.4.0 ignores the `instance.group-id` filter, so a non-existent group still returned both running instances and printed `NOTE: usms-app-sg is carried by usms-db-01`. I replaced it with a client-side JMESPath filter, `Reservations[].Instances[?SecurityGroups[?GroupId=='$USMS_APP_SG']]`, which is equivalent and also correct on real AWS. Result: `LOOP CLOSED`.

## Step 4 – Your turn (HTTPS)

A security group rule only opens port 443. Nothing listens on it until I create an **HTTPS:443 listener**, and that listener cannot exist without a **TLS certificate** for the site's domain name. AWS Certificate Manager issues the public certificate for free; the **domain name** it certifies has to be obtained from somewhere else (a registrar, or the university's DNS administrators), and I must prove control of it with a DNS validation record.

## Step 6 – Your turn (matcher)

`200-399` read back immediately and `200` restored immediately, with nothing recreated (screenshot `s8.png`).

- **(a)** Any application whose `/` redirects to a login page, such as a student portal or WordPress/Moodle-style application that answers `GET /` with `302 → /login`, would be reported unhealthy forever by a strict `200` matcher while working perfectly.
- **(b)** It would be a bug in **my work**, not in the script. The verification script exists to detect drift from the declared design (Section 4 fixes the matcher at 200). A deliberate change of design has to change the specification and the script in the same commit, not silently diverge from them.

## Step 11 – Your turn (2 → 3 → 2)

`describe-target-health` went from 2 targets to 3 and back to 2 with no `register-targets` or `deregister-targets` call (screenshot `s15.png`). Without service-managed registration, I would have had to **register every new task's IP into the target group (and deregister every stopped task's IP) by hand after every single scaling event**.

## Step 11 – Diagnosis table (ECS health vs target health)

| ECS `healthStatus` | Target health | Diagnosis |
|---|---|---|
| HEALTHY | healthy | Working |
| HEALTHY | unhealthy | The network path is broken: security group, subnet, or the health check path returning the wrong code |
| UNHEALTHY | unhealthy | The application is broken; read the container logs |
| UNKNOWN | healthy | Not a fault: the task definition has no container health check |
| anything | unused | Nothing forwards to this target group |

**My build:** ECS `UNKNOWN` (revision 2 has no container `healthCheck`) with target `healthy` → *not a fault* (`s14.png`).

## Observations specific to Floci 2.4.0

- **Target IDs are Docker-network addresses** (`172.21.0.x`). ECS reports each task's VPC ENI address separately (`10.0.3.14`, `10.0.3.16` in `usms-private-subnet-a`). Step 12's block 3 therefore prints "NOT in a Lab 02 private subnet - investigate"; the investigation is in `s17.png`. On real AWS the target ID *is* the ENI address.
- **Both tasks were placed in `usms-private-subnet-a`.** Floci does not spread awsvpc tasks across AZs, and target `AvailabilityZone` reads `None`.
- **Security groups are stored but not enforced.** The 200 responses prove routing, not the firewall. That is why `verify-lab-05.sh` asserts Step 9's rule rather than testing it.
- `describe-security-groups` lists the two port-80 sources (Step 9) as **two** `IpPermissions` entries; real AWS merges them into one.
- `describe-listeners` returns `"SslPolicy": ""` for HTTP rather than `null`.
- `describe-rules` stores path patterns in `PathPatternConfig.Values` and leaves the legacy `Values` empty.
- **A forced deployment replaces every task at once.** I saw `initial → healthy` on the new targets, but **`draining` was never observed**: the old targets disappear immediately.
- Restarting Floci (Step 16) leaves EC2 instance containers exited while the API still says `running`. A stop/start through the EC2 API recreated `usms-web-01`'s container (`e1b.png`).

## Section 11 – Observed vs reasoned about, on this build

| Item | On my build |
|---|---|
| Every ELBv2 object, the 0 → 1 attachment count, rule ordering, the cutover, the restart proof | **Observed** |
| Service-registered targets, and 2 → 3 → 2 registration and deregistration | **Observed** |
| Real health checks (`initial` → `healthy`, `Elb.RegistrationInProgress`) | **Observed** |
| A served request through the listener (HTTP 200 from nginx in a task) | **Observed**, from `usms-web-01` inside the Floci network; not from the host (DNS does not resolve) |
| Rule evaluation (`/alb-health` → fixed 200, `/results` → 503 with no targets) | **Observed**, same client |
| Forced deployment: new addresses, same task definition and counts | **Observed** |
| Connection **draining** with the 30 s deregistration delay | **Reasoned about** – not observable (all tasks swapped at once) |
| Security group **enforcement** on ALB or task traffic | **Reasoned about** – Floci does not enforce SGs |
| Targets in the tasks' own ENI addresses, spread across 2 AZs | **Reasoned about** – Floci uses Docker IPs and one AZ |
| HTTPS listener, ACM certificate, TLS policy | **Reasoned about** (Exercise 4 plan) |
| `AWS/ApplicationELB` metrics, `ALBRequestCountPerTarget` scaling | **Reasoned about** (Exercise 5 builds only the label) |
| X-Forwarded-For headers, access logs, cost, quotas | **Reasoned about** |

## Section 8 – verify-lab-05.sh

`PASS=49 FAIL=0`, with no benign failures to explain (`s26.png`). After Exercise 2, `verify-lab-04.sh` is `PASS=39 FAIL=0`. Before Exercise 2 it was `PASS=37 FAIL=1`, the one expected failure from Step 13 (`s19.png`).

# Review Questions

**1. Lab 04 sourced a security group rule from a group because the tasks have no stable addresses; this lab put a load balancer in front of them for arguably the same reason. In a paragraph, say what the two have in common, what general problem both solve, and name a third solution to it elsewhere in computing.**  
**Answer:** Both replace an address with a **stable name for a changing set of members**, and resolve that name to concrete addresses only at the moment they are needed. The security group rule says "whatever currently carries `usms-app-sg`" (now `usms-alb-sg`) instead of listing IPs, and the load balancer says "whatever is currently registered in `usms-enrolment-tg`" instead of handing clients task IPs. The general problem is **naming ephemeral endpoints**: tasks are created, replaced and scaled with new private addresses every time, so anything bound to an address goes stale at the next deployment. The fix in both cases is a level of indirection, with membership kept up to date by the system rather than by a person. A third solution is **DNS-based service discovery**: AWS Cloud Map or a Kubernetes `Service`, where a name such as `enrolment.usms.local` resolves to whichever pods or tasks are currently healthy. At a lower level, DNS itself does the same job for every host on the internet.

**2. "The load balancer's health check says the task is unhealthy, so the application is broken." Why is that unsound? Which two states can the target group health check not distinguish, which field does, and what diagnostic sequence would you follow?**  
**Answer:** The target group's health check is a request sent **over the network** from the load balancer. A failure only means "this probe did not get the expected answer", and that has many causes besides a broken application: a missing security group rule, a wrong port, a health check path that redirects, or a too-strict matcher. The probe cannot tell **"the application is broken"** apart from **"the application is fine but the network path to it is broken"**; both read `unhealthy`. The field that separates them is ECS's own **`healthStatus`** on the task, produced by the container health check run *inside* the task. `HEALTHY` + target `unhealthy` points at the path; `UNHEALTHY` + target `unhealthy` points at the application. `TargetHealth.Reason` (`Target.Timeout` vs `Target.FailedHealthChecks`/`ResponseCodeMismatch`) narrows it further. My sequence:
1. Read `describe-target-health` `State`, `Reason` and `Description`.
2. Compare with `describe-tasks` `healthStatus`.
3. If the path is suspect, check, in order, that `usms-enrolment-sg` admits `usms-alb-sg`, that the target group port and `containerPort` agree, and that the health check path returns the matcher's code.
4. Only if ECS also says `UNHEALTHY`, read the container logs in `/usms/ecs/enrolment`.

**3. There is no update-target-group-target-type. What does that say about a target group's configuration versus its identity? Connect it to Lab 04's immutable task definition revisions, name two other fields in this lab that behave the same way, and one that looks like it should but does not.**  
**Answer:** Some fields are part of what the object **is**, not settings on it. Target type determines how every registration is interpreted (instance ID vs IP vs Lambda), so changing it would silently invalidate every existing target. AWS makes you create a new target group and repoint the listener (`modify-listener`) and the service at it. That is the same pattern as Lab 04's task definitions: you never edit `usms-enrolment:1`, you register `:2` and move the service's pointer, so the old identity stays intact and rollback is just moving the pointer back. Two other identity fields here:
- the load balancer's **`--scheme`** (internet-facing vs internal) and **`--type`** (application vs network), which cannot change after `create-load-balancer`;
- the target group's **`--vpc-id`** (and its protocol/port), which binds it to `usms-vpc` permanently.

One that looks as if it should be fixed but is not: the **service's `loadBalancers` entry**. Which target group a running service registers into feels structural, yet `update-service --load-balancers` changed it in place in Step 10 (it triggers a deployment rather than requiring a new service). The **ALB's security groups** are similar: they are changeable with `set-security-groups`.

**4. A request arrives at the exact moment ECS decides to stop the task that would serve it. Name every timer involved and where it is configured, and say whether the request succeeds. What changes if deregistration_delay.timeout_seconds were left at 300?**  
**Answer:** The timers are:

| Timer | Where it is configured | What it does |
|---|---|---|
| `deregistration_delay.timeout_seconds` = 30 | target group attribute (Step 7) | how long a deregistered target is `draining`, finishing in-flight requests |
| `stopTimeout` | container definition in the task definition | time between SIGTERM and SIGKILL; unset in `usms-enrolment:2`, so the Fargate default of 30 s applies |
| `idle_timeout.timeout_seconds` = 60 | load balancer attribute (Step 5) | how long the ALB keeps an idle connection |
| health check interval (30 s) × healthy threshold (2) | target group | how soon the *replacement* task receives traffic |
| `healthCheckGracePeriodSeconds` = 60 | service | how long ECS ignores the new task's target health |
| `minimumHealthyPercent` / `maximumPercent` | service deployment configuration | whether the replacement starts before the old task stops |

ECS first **deregisters** the task. If the load balancer had already chosen this target, the request is in flight; the target goes `draining` and the request has up to 30 s to finish **before** ECS sends SIGTERM, then `stopTimeout` more before SIGKILL. If it arrived a moment later, the ALB simply routes it to another healthy target. Either way **the request succeeds**, provided it completes within 30 s and at least one other target is healthy (guaranteed by `minimumHealthyPercent` 100). At **300 s** the request still succeeds, but every stopped task lingers as `draining` for up to five minutes. Each deployment batch and each scale-in becomes five minutes slower, and Lab 06's scale-in would hold, and bill, capacity long after it was needed. That is pointless for a millisecond API whose slowest legitimate request is a few seconds.

**5. Step 13 made Lab 04's verification script fail. Argue for updating it immediately, then for leaving it failing and documented. Which would you do with four other engineers on the system, and why might one engineer change the answer?**  
**Answer:**
- **For updating immediately:** the architecture changed on purpose, so a check still asserting the old source is now wrong. A permanently red script teaches everyone to ignore red, and the next *real* failure gets lost in it. The fix belongs in the same commit as the change that caused it.
- **For leaving it failing and documented:** Lab 04's script is a record of what Lab 04 built. Rewriting it to go green edits history and hides that the system was changed underneath it. The visible failure plus a note is honest evidence of a deliberate migration.

With **four other engineers** I would **update it immediately** (as in Exercise 2), keeping the property and changing only the expected group, plus a check that the old source is gone. A shared script is the team's definition of "correct", and four people cannot each be expected to remember which failure is expected. **One engineer can change the answer:** someone who still has a caller reaching the tasks directly (for example a batch job on `usms-web-01` not yet moved to the ALB DNS name). For that person the failing check is a *true* signal that their migration is incomplete, and greening the script before they finish would hide a real outage.

**6. The load balancer is internet-facing and the tasks have no public address. Explain how both are true, naming every Lab 2 resource involved. What could an attacker who compromised the load balancer's configuration reach, and what would differ had the tasks had public addresses?**  
**Answer:** The ALB's nodes live in **`usms-public-subnet-a`** and **`usms-public-subnet-b`**, which are associated with **`usms-public-rt`**. That route table's `0.0.0.0/0` route points to **`usms-igw`**, which is attached to **`usms-vpc`**, so the nodes get public addresses and are reachable from the internet. The tasks run in **`usms-private-subnet-a`** and **`usms-private-subnet-b`**, behind **`usms-private-rt`**. That table has no IGW route; its default route goes to **`usms-nat`** (outbound only, for image pulls) and **`usms-s3-endpoint`**, and **`usms-private-nacl`** guards the private subnet. Nothing on the internet can therefore open a connection to a task. The ALB reaches the tasks over the VPC's **local route** (10.0.0.0/16) on their private addresses: it **terminates** the client connection in the public subnet and opens a new one inside the VPC. The firewall chain is **`usms-alb-sg`** (80/443 from anywhere) → **`usms-enrolment-sg`** (80 from `usms-alb-sg` only).

An attacker who controlled the ALB's configuration could add listeners and rules and, because `ip` target groups accept any private address in the VPC, register **any VPC address** as a target and publish it to the internet. However, the ALB's own security group is the source of that traffic, so they could only reach what admits `usms-alb-sg` (today only the enrolment tasks on port 80) or anything that admits the whole VPC CIDR. They could also serve fixed responses or redirects on USMS's hostname, for phishing.

Had the tasks had **public addresses**, they would need to be in public subnets with an IGW route. They would then be directly addressable and scannable from the internet, bypassing the listener and its rules, with `usms-enrolment-sg` as the **only** barrier. Compromising the ALB would matter less, but the attack surface would be every task's address rather than one managed entry point.

**7. Why is requests per target a better scaling signal than CPU for a web API? Name the one situation where CPU is better, and what would have to be true of the enrolment application for ALBRequestCountPerTarget to scale it badly.**  
**Answer:** For a web API, demand *is* requests. `ALBRequestCountPerTarget` measures that demand directly at the front door, before it becomes load, and divides it by capacity, so it reacts as traffic arrives. CPU is a lagging, indirect proxy. It depends on how expensive each request happens to be, and for an I/O-bound API that mostly waits on a database (as enrolment does with `usms-db-01`), CPU stays low even while the tasks are saturated with waiting requests. CPU is the better signal when **work is CPU-bound and the cost per request varies widely**, for example generating transcripts as PDFs or processing images. It is also the only signal for tasks that are not behind a load balancer at all (queue workers). `ALBRequestCountPerTarget` would scale enrolment badly if the **requests were very unequal in cost**: if a few heavy operations (submitting an enrolment, with transactions against the database) are mixed with many trivial ones, a target value tuned for the average under-provisions during the heavy ones. The same applies if the real bottleneck is downstream. If `usms-db-01` saturates first, adding tasks because request counts rose only adds more connections to an overloaded database and makes things worse.
