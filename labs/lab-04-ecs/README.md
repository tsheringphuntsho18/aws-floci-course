# Lab 04 – ECS – Report

    Student Name: Tshering Phuntsho
    Student ID: 02230310
    Module: DSO303 Cloud Native Solution Design
    Practical: Lab 04 – Amazon Elastic Container Service
    Date: 05/10/2026

## 1. Aim / Objective

The aim of this practical was to containerise the University Student Management System (USMS) enrolment service onto Amazon ECS using the Fargate launch type, inside the private subnets built in Lab 02. The specific objectives were to:

- create an ECS cluster, a CloudWatch Logs log group, a Fargate task definition and an ECS service that holds a fixed desired count of 2 tasks across two Availability Zones;
- separate the task **execution** role (image pull and logging) from the task **role** (the application's identity), and reuse Lab 01's `USMSStudentDataReadWrite` policy on the task role;
- restrict the service's security group so that only the web tier's `usms-app-sg` can reach it;
- record every name and ARN in `configs/lab-04.env` for Labs 05 and 06.

## 2. Introduction

Amazon Elastic Container Service (ECS) is AWS's fully managed container orchestration service. It runs Docker containers as **tasks**, built from a versioned blueprint called a **task definition**. A **service** keeps a chosen number of those tasks running, and it automatically replaces any task that fails, so nobody has to log in to a server. 

With the **Fargate** launch type there are no EC2 instances to provision, patch or scale. Each task gets its own elastic network interface in the VPC (`awsvpc` mode), along with its own security group and IAM role. The key features are immutable task definition revisions, the service scheduler's reconciliation loop, integration with IAM roles, CloudWatch Logs, load balancers and Application Auto Scaling, and per-second Fargate billing. 

ECS matters in cloud computing because it lets teams run microservices reliably and securely without managing servers. Typical applications are web APIs, background workers, batch jobs and CI/CD-deployed microservices.

## 3. Use Case

In USMS, the enrolment service is the API the student portal calls when a student clicks "Register for this module". Before this lab it would have lived on a single, hand-managed EC2 instance. Running it on ECS Fargate means:

- **High availability:** two tasks in two Availability Zones, so one task or AZ failure does not stop enrolment.
- **Self-healing:** if a task crashes, the service starts a replacement automatically.
- **Least-privilege identity:** the container reads and writes student transcripts in S3 through a task role, with no access keys in the image.
- **Network isolation:** tasks live in private subnets, reachable only from the web tier's security group.
- **Ready to scale:** Lab 05 puts a load balancer in front of the service, and Lab 06 makes its desired count change automatically during enrolment week.

Other common uses of ECS include hosting containerised e-commerce backends, running queue-driven workers, and deploying microservices from a CI/CD pipeline.

## 4. System Architecture / Design

![image](/screenshots/lab-4-ecs/architecture.jpeg)

*Figure 1 – USMS enrolment service on ECS Fargate*

This diagram shows an AWS network (`usms-vpc`) routing internet traffic through `usms-web-01` in a public subnet to private ECS Fargate tasks across two Availability Zones. The ECS cluster manages these tasks, using `usms-ecs-exec-role` for image pulls (via NAT Gateway and S3 endpoints) and CloudWatch logging, while `usms-ecs-task-role` provides application access to `usms-db-01` and S3 storage.

## 5. Implementation Procedure

I started Floci under Docker Compose and loaded the environment files from Labs 01–03. Then I confirmed with `verify-lab-02.sh` and `verify-lab-03.sh` that the VPC, private subnets, NAT gateway and web instance were still intact.

While holding the `usms-developer-role` through `sts assume-role`, I created the ECS cluster `usms-ecs-cluster` with Container Insights requested. Afterwards I unset the temporary credentials to restore my normal identity. I created the log group `/usms/ecs/enrolment` with a 7-day retention policy, because the `awslogs` driver does not create log groups itself.

Next I built the two IAM roles. Both use a trust policy for `ecs-tasks.amazonaws.com`. The execution role `usms-ecs-exec-role` received a least-privilege customer managed policy, `USMSECSTaskExecution`, which allows ECR image pulls and log writes to only the one log group. The task role `usms-ecs-task-role` received Lab 01's existing `USMSStudentDataReadWrite` policy, unchanged.

I created the security group `usms-enrolment-sg`, which allows tcp/80 only from `usms-app-sg` by group reference. Then I wrote the task definition `templates/lab-04-taskdef.json` (Fargate, `awsvpc`, 256 CPU / 512 MiB, an nginx placeholder image, the `awslogs` driver) and registered it as `usms-enrolment:1`.

I created the service `usms-enrolment-svc` with a desired count of 2 across both private subnets, with no public IP. I read back its desired, running and pending counts and its status, then scaled it by hand from 2 to 3 and back to 2 to see what a scaling policy would later do automatically. Finally I recorded all names and ARNs in `configs/lab-04.env` (17 exports) and built the verification script `verify-lab-04.sh` and the end-of-course cleanup script (syntax-checked only, never run).

For the exercises:

- I deployed a second service, `usms-results-svc`.
- I registered revision 2 (1024 MiB, `USMS_LOG_LEVEL=info`) and rolled the service onto it.
- I wrote an inventory script that computes role separation and public-IP risk for every service.
- I produced a capacity and cost plan for enrolment week, then deleted the practice service.
- I resolved the security group reference back to `usms-web-01` and audited the ECS tags.

I then committed the work to Git, with `outputs/` confirmed as ignored.

## 6. Results and Evidence

### 6.1 CLI / SDK Output

**Screenshot 1 – Environment loaded and previous labs verified**
![image](/screenshots/lab-4-ecs/s1.png)
![image](/screenshots/lab-4-ecs/s2a.png)
![image](/screenshots/lab-4-ecs/s2b.png)

**Screenshot 2 – Support probe**
![image](/screenshots/lab-4-ecs/s3.png)

**Screenshot 3 – Cluster created as `usms-developer-role`**
![image](/screenshots/lab-4-ecs/s4png)
![image](/screenshots/lab-4-ecs/s5png)

**Screenshot 4 – Log group with 7-day retention**
![image](/screenshots/lab-4-ecs/s6png)

**Screenshot 5 – Execution and task roles (Checkpoint 2)**
![image](/screenshots/lab-4-ecs/s7.png)
![image](/screenshots/lab-4-ecs/s8.png)


**Screenshot 6 – Enrolment security group sourced from `usms-app-sg`**
![image](/screenshots/lab-4-ecs/s9.png)

**Screenshot 7 – Task definition `usms-enrolment:1` (Checkpoint 3)**
![image](/screenshots/lab-4-ecs/s10a.png)
![image](/screenshots/lab-4-ecs/s10b.png)


**Screenshot 8 – Service created and read back (Checkpoint 4)**
![image](/screenshots/lab-4-ecs/s10c.png)

**Screenshot 9 – Manual scaling 2 → 3 → 2 and service events**
![image](/screenshots/lab-4-ecs/s11.png)

**Screenshot 10 – `configs/lab-04.env` with 17 exports**
![image](/screenshots/lab-4-ecs/s12.png)

**Screenshot 11 – `verify-lab-04.sh` PASS=38 FAIL=0 and cleanup script syntax check**
![image](/screenshots/lab-4-ecs/s13.png)
![image](/screenshots/lab-4-ecs/s14.png)

### 6.2 AWS Management Console Verification

Floci dashboard.

**describe-clusters**
![image](/screenshots/lab-4-ecs/a1.png)
The ECS cluster `usms-ecs-cluster` exists and is ACTIVE

## 7. Analysis and Discussion

The practical achieved its objectives. The cluster, log group, two roles, security group, task definition and service were all created and verified, and `verify-lab-04.sh` reported `PASS=38 FAIL=0`. The service spans both private subnets with `assignPublicIp` disabled, the execution and task role ARNs are different, and the enrolment security group admits traffic only from the web tier's group, never from a CIDR or `0.0.0.0/0`.

The results matched the expected outcome for the control plane: `desiredCount` was modelled correctly and moved from 2 to 3 and back to 2 on request. Where tasks did not run, this is a documented Floci limitation, not a configuration error, and every check in the lab relies on `desiredCount`. The verification only checks control-plane state, so I could observe the cluster, revisions, service placement, roles and group rule directly, but a running container serving traffic, Container Insights metrics and Fargate start latency could only be reasoned about.

**Errors and issues encountered:**   
1. The --network-configuration shorthand rejected quoted IDs; removing the quotes fixed it
2. Verify reported retention None; re-running put-retention-policy fixed it 
3. I forgot to unset the assumed-role variables and got ExpiredToken later; unsetting them fixed it

Observations:

- **Tag syntax differs by service:** ECS uses lower-case `key=/value=`, EC2 and IAM use `Key=/Value=`, and CloudWatch Logs uses a plain map.
- **Revisions are immutable:** a task definition revision cannot be edited, only replaced. Exercise 2 showed that the service's *pointer* to a revision is what changes during a deployment.
- **Drift is real:** the inventory script showed that `usms-results-svc` still ran revision 1 after `usms-enrolment-svc` moved to revision 2.
- **Private tasks depend on Lab 02:** a task in a private subnet depends entirely on Lab 02's NAT gateway and private route table to pull its image. Fargate removes servers, but not networking.

## 8. Reflection

1. **What did I learn about ECS?**  
ECS is built from four objects: the cluster (a namespace), the task definition (an immutable blueprint), the task (a running copy) and the service (which keeps the running count equal to the desired count). Auto scaling will only ever change the service's desired count. I also learned the practical difference between the execution role and the task role: one is used by the platform before my container starts, the other by my code inside it. And the same IAM policy can be delivered to an EC2 instance through an instance profile and to a container through a task role, with no keys stored anywhere.

2. **How would I apply ECS in a real cloud environment?**  
I would run each microservice of a system like USMS as its own ECS service behind an Application Load Balancer, in private subnets, with least-privilege task roles. I would use scheduled plus target-tracking auto scaling for predictable peaks like enrolment week, and deploy new image revisions from a CI/CD pipeline with rolling updates so traffic is never dropped.

3. **What would I like to explore further?**  
Application Auto Scaling on the service (Lab 06), ALB integration (Lab 05), Fargate Spot and capacity providers, ECS Exec for debugging, secrets injection from Secrets Manager through the execution role, blue/green deployments with CodeDeploy, and running the same workload on EKS for comparison.

## 9. Conclusion

The objectives of this practical were achieved. The USMS enrolment service now has a Fargate task definition and an ECS service running two tasks across two Availability Zones in private subnets. It uses separate execution and task roles, a security group that admits only the web tier, and a log group with a retention policy, all recorded in `configs/lab-04.env` and verified by a script.

The key concepts were the cluster–task definition–task–service model, immutable revisions, the two ECS roles, `awsvpc` networking and group-referenced security groups. The skills I developed were writing and registering task definitions from the AWS CLI, using JMESPath queries and waiters, scripting verification and inventory checks, and estimating Fargate costs. ECS is important because it lets an organisation run containerised services that heal themselves and are ready to scale, without managing servers. This lab is the foundation for the load balancer and auto scaling in Labs 05 and 06.

## 10. Appendix

Files in the repository:

- `templates/lab-04-taskdef.json`, `templates/lab-04-taskdef-rev2.json` – task definition revisions 1 and 2
- `policies/trust-ecs-tasks.json` – trust policy shared by both ECS roles
- `policies/usms-ecs-task-execution-policy.json` – least-privilege execution policy
- `policies/usms-enrolment-sg-ingress.json` – security group ingress rule
- `configs/lab-04.env` – 17 exported names and ARNs for Labs 05/06
- `scripts/utilities/verify-lab-04.sh` – verification script
- `scripts/utilities/lab-04-ecs-inventory.sh` – Exercise 3 drift report
- `scripts/cleanup/lab-04-cleanup.sh` – end-of-course cleanup (not run)
- `labs/lab-04-ecs/exercises.md`, `labs/lab-04-ecs/lab-04-lab03-linkage.txt`
- `notes/lab-04-notes.md` – support path, Floci limitations and review question answers

