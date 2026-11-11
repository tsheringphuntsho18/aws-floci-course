# Review Questions

**1. A colleague says "I put auto scaling on the task definition." Explain every way that is wrong: what auto scaling will be attached to in Lab 06, what it modifies, and which ECS object makes reality match. What observable consequence follows from ECS itself knowing nothing about the scalable target?**  
**Answer:** That statement is wrong in three ways.

First, auto scaling is not attached to a task definition at all. In Lab 06 it is attached to the service. Application Auto Scaling, a separate AWS service, registers a scalable target whose resource ID is service/usms-ecs-cluster/usms-enrolment-svc and whose scalable dimension is ecs:service:DesiredCount, and the scaling policies hang off that target.

Second, a task definition is an immutable, versioned blueprint. It has no count to scale, and nothing can modify a registered revision; you can only register a new one.

Third, auto scaling never starts or stops tasks itself. The only thing it writes is the service's desiredCount. It is the ECS service scheduler, the reconciliation loop, that notices runningCount no longer equals desiredCount and launches or stops tasks from the task definition until they match.

Because ECS itself knows nothing about the scalable target, describe-services shows no min, max or policy, only a desiredCount that changes with no explanation other than service events. If I run update-service --desired-count by hand outside the min/max range, Application Auto Scaling simply overwrites my number at its next evaluation. And deleting the service or cluster does not remove the scalable target: it is left orphaned in Application Auto Scaling. That is why lab-06-cleanup.sh must run before lab-04-cleanup.sh.
    
**2. Lab 1 wrote USMSStudentDataReadWrite for a bucket that did not exist; Lab 3 attached it to an EC2 instance via an instance profile; this lab attached it, unchanged, to a Fargate task via a task role. In a full paragraph, explain what each delivery mechanism does at runtime, why neither needs a key on disk, and what changes for both the moment the bucket exists.**  
**Answer:** USMSStudentDataReadWrite is just a permissions document naming arn:aws:s3:::usms-student-data. Lab 1 could write it before the bucket existed because IAM evaluates resource ARNs as strings at request time and never checks that they exist.

In Lab 3 the policy reaches code through an instance profile. The profile wraps usms-ec2-app-role, EC2 assumes that role for the instance, and the instance metadata service (169.254.169.254) hands the application short-lived STS credentials, which the SDK's default credential chain finds and refreshes automatically.

In this lab the same policy reaches a container through a task role. The task definition names usms-ecs-task-role in taskRoleArn, the ECS/Fargate agent assumes it through the ecs-tasks.amazonaws.com trust, and it exposes the temporary credentials on a task-local endpoint (169.254.170.2) whose path is in AWS_CONTAINER_CREDENTIALS_RELATIVE_URI. The SDK checks this before the instance metadata endpoint.

Neither needs a key on disk, because in both cases the credentials are temporary STS tokens fetched at runtime from a local endpoint and rotated before they expire. There is no long-lived access key to leak, commit or rotate by hand.

The moment Lab 10 creates usms-student-data, both mechanisms start working at the same instant with no change to the policy, either role, the instance or the task definition. The ARN they have always named now matches a real resource, so GetObject, PutObject and ListBucket succeed, and the explicit deny on DeleteBucket now protects something real. Any later edit to that one policy also changes what both compute types can do.
    
**3. Give a one-sentence failure symptom for the task execution role and for the task role that a colleague could use to tell them apart, and explain why both share an identical trust policy despite doing different jobs.**  
**Answer:** Execution role symptom: the task never reaches RUNNING, and stoppedReason mentions pulling the image, the registry or creating the log stream (for example CannotPullContainerError or ResourceInitializationError).

Task role symptom: the task starts and runs normally, but the application's own calls to S3 (or any AWS API) fail with AccessDenied.

Both roles have an identical trust policy because a trust policy only answers who may assume this role, and in both cases the answer is the same principal, ecs-tasks.amazonaws.com. What separates them is not who assumes them but what they are allowed to do (their attached permission policies: ECR pull plus one log group, versus the student-data S3 policy) and when they are used (executionRoleArn by the platform before the container starts, taskRoleArn by my code inside it). That is why one trust file, policies/trust-ecs-tasks.json, serves both.

**4. Step 8 sources the enrolment group's only inbound rule from usms-app-sg, not a CIDR block. Explain why this is correct even if the task count never changed, and the additional reason it becomes close to mandatory once Lab 06 lets the count change.**  
**Answer:** Even with a fixed task count, a group reference is more correct than a CIDR because it states the actual intent: "the web tier may call the enrolment API". It does not say "anything with an address in 10.0.1.0/24 may call it". A CIDR rule would also admit every other ENI in that subnet, including the NAT gateway and any unrelated future instance. It would miss a web server launched in public subnet b. And it would silently break if the web tier moved subnets. The group reference follows membership: whatever carries usms-app-sg is allowed, wherever its address is, and nothing else is.

Once Lab 06 lets the count change, group references become close to mandatory, because tasks have no stable addresses. Every task auto scaling launches gets a fresh ENI and a new private IP, and each one disappears on scale-in. Any downstream rule that must admit the enrolment tasks, such as a database group, cannot list IPs that change by the minute. It must reference usms-enrolment-sg, which every new task automatically carries because the service's network configuration attaches it. The same logic applies upstream in Lab 05, where load balancer nodes also have changing IPs.

**5. What does Fargate remove from Lab 3's EC2 model, and what does it not remove? Use the fact that an awsvpc task still has its own security group and obeys Lab 2's route tables.**  
**Answer:** Fargate removes the instances: choosing an AMI and instance type, patching the OS, running and updating the ECS agent, SSH access, bin-packing tasks onto hosts, and the second scaling layer (EC2 Auto Scaling for the cluster's capacity). I only declare a CPU/memory pair and AWS supplies the compute.

It does not remove the network or the identity model. An awsvpc task gets its own ENI with a private IP in my subnet, protected by my security group (usms-enrolment-sg), and its traffic follows my route tables. That is exactly why a task in Lab 2's private subnets can only pull its image because usms-private-rt sends 0.0.0.0/0 to usms-nat (plus the S3 endpoint for layers). Without them the service would create successfully and every task would fail with an image-pull timeout. IAM (two roles), logging (the log group must exist), Availability Zone placement, right-sizing and cost also remain my responsibility.
    
**6. Lab 1 Step 14 showed that an unchanged account identity after a restart is not evidence of persistence. Name one command against this lab's resources that would look identical in memory and hybrid mode, one that would not, and explain the difference.**  
**Answer:** aws sts get-caller-identity would look identical in both modes, even after a restart. It always returns account 000000000000 because the account ID is fixed emulator configuration, not stored state, so it proves nothing about persistence. (The same is true of any read taken before a restart.)

A command that would differ is aws ecs describe-clusters --clusters usms-ecs-cluster --query 'clusters[0].status' run after floci-down.sh / floci-up.sh. In hybrid mode the cluster was written to disk and comes back ACTIVE. In memory mode it vanished with the old container, so the call returns nothing (a MISSING failure). The same applies to verify-lab-04.sh, which would fail most of its ECS checks.

The difference is that the identity is computed from configuration every time, while the cluster is data that only survives if the storage mode persisted it. Only a check against a resource I created, run across a restart, is evidence of persistence.