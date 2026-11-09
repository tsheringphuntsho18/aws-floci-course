# Lab 03 – EC2 – Report

    Student Name: Tshering Phuntsho
    Student ID: 02230310
    Module: DSO303 Cloud Native Solution Design
    Date: 05/10/2026

## 1. Aim / Objective

Deploy a two-tier EC2 compute layer (public web tier with EBS/EIP and private DB tier) via the AWS CLI, verify data persistence across restarts, and capture a golden AMI.

## 2. Introduction

Amazon Elastic Compute Cloud (EC2) provides resizable virtual servers in the cloud. An instance is built from an Amazon Machine Image (AMI, the root-disk template), an instance type (the CPU and memory profile), and optional user data (a script run by cloud-init at first boot). It runs inside a VPC subnet, is protected by security groups, can assume an IAM role through an instance profile, and can use EBS volumes for durable block storage. EC2 is the foundation of AWS compute and is used to host web applications, databases, batch workloads, and the building blocks for Auto Scaling and container services.

### Key Features

- Choice of AMIs, instance types and purchasing options
- User data bootstrap at first boot (runs once, as root, up to 16 KB)
- Key pairs for SSH access
- IAM instance profiles for credential-free access to AWS services
- Elastic IP addresses (stable public addresses)
- EBS volumes (durable block storage within one Availability Zone)
- AMIs captured from configured instances

## 3. Use Case

| Need | EC2 component |
|---|---|
| Host the student portal on a public server | `usms-web-01` in the public subnet, `usms-app-sg` |
| Stable address that survives stop/start | Elastic IP `usms-web-eip` |
| Web server reads/writes transcripts in S3 with no stored credentials | Instance profile `usms-ec2-app-profile` |
| Keep student data when the instance is terminated | Separate EBS volume with `DeleteOnTermination = False` |
| Database tier unreachable from the internet | `usms-db-01` in the private subnet with `usms-db-sg`, no public IP |
| Rapid, identical rebuilds and future Auto Scaling | Golden AMI `usms-web-golden` |

## 4. System Architecture 

![image](/screenshots/lab-3-ec2/architecture.jpeg)

Data flow: browser to Elastic IP to `usms-web-01` (TCP 80); `usms-web-01` to `usms-db-01` (TCP 5432, allowed by security group reference); `usms-db-01` outbound via `usms-nat`.

## 5. Implementation Procedure

The practical started by resuming Floci and sourcing `course.env`, `lab-01.env` and `lab-02.env`, then confirming Lab 2's network with `verify-lab-02.sh`. An AMI was selected programmatically, an RSA key pair `usms-app-key` was created with the private key written straight to `outputs/` (chmod 600) and proven git-ignored. A user-data script was written, syntax-checked, and referenced from a `--cli-input-json` request file used to launch `usms-web-01` in the public subnet with `usms-app-sg` and `usms-ec2-app-profile`.  

After the instance reached `running`, its fields were read back, the permission chain instance → profile → role → policy was traced, and the stored user data was decoded and compared byte-for-byte with the source. An Elastic IP was allocated and associated, the application was tested (with a six-point configuration fallback), an 8 GiB gp3 data volume was attached, and `usms-db-01` was launched into the private subnet without a public address or profile. 

Wiring between tiers was proven by reading back security groups and routes, a stop/start test showed which address survives, Floci was restarted to prove persistence, a golden AMI was created, resources were audited by tag, and all IDs were saved to `configs/lab-03.env`.

| # | Action | Key command |
|---|---|---|
| 1–2 | Resume, load env files, verify Lab 2 | `floci-up.sh`, `verify-lab-02.sh` |
| 3 | Choose AMI | `describe-images` |
| 4–5 | Key pair, prove git-ignored | `create-key-pair`, `git check-ignore -v` |
| 6 | Bootstrap script | `user-data.sh`, `bash -n` |
| 7–8 | Request file, launch web server | `run-instances --cli-input-json` |
| 9–10 | Wait for running, read back | `wait instance-running`, `describe-instances` |
| 11 | Trace permission chain | `get-instance-profile`, `list-attached-role-policies` |
| 12 | Prove user data stored | `describe-instance-attribute`, `openssl base64 -d`, `diff` |
| 13 | Elastic IP | `allocate-address`, `associate-address` |
| 14 | Test application / fallback checks | `curl`, six reachability checks |
| 15 | EBS volume | `create-volume`, `attach-volume` |
| 16–17 | Database-tier instance, prove wiring | `run-instances`, `describe-security-groups` |
| 18 | Stop/start, watch addresses | `stop-instances`, `start-instances` |
| 19 | Persistence proof | `floci-down.sh`, `floci-up.sh`, `diff` |
| 20 | Golden AMI | `create-image` |
| 21–23 | Audit, save IDs, commit | `describe-*` by tag, `configs/lab-03.env`, `git commit` |

## 6. Results and Evidence

### 6.1 CLI Output

**Screenshot 1** – Resume check: three env files loaded, six values non-empty, `verify-lab-02.sh` `FAIL=0`

![image](/screenshots/lab-3-ec2/s1.png)

**Screenshot 2** – AMI selection and which option was used (`describe-images` / `register-image` / placeholder)

![image](/screenshots/lab-3-ec2/s2.png)

**Screenshot 3** – Key pair created, file permissions `-rw-------`, `git check-ignore -v` output

![image](/screenshots/lab-3-ec2/s3.png)

**Screenshot 4** – `user-data.sh` syntax OK and `run-instances` request JSON validated

![image](/screenshots/lab-3-ec2/s4.png)

**Screenshot 5** – Launch of `usms-web-01` and `wait instance-running`

![image](/screenshots/lab-3-ec2/s5.png)

**Screenshot 6** – `describe-instances` table (Checkpoint 2)

![image](/screenshots/lab-3-ec2/s6.png)

**Screenshot 7** – Permission chain trace (Step 11)

![image](/screenshots/lab-3-ec2/s7.png)

**Screenshot 8** – `USER DATA PROVEN` (Checkpoint 3)

![image](/screenshots/lab-3-ec2/s8.png)

**Screenshot 9** – Elastic IP allocate, associate and describe

![image](/screenshots/lab-3-ec2/s9.png)

**Screenshot 10** – Application test and the six reachability checks (Step 14)

![image](/screenshots/lab-3-ec2/s10.png)

**Screenshot 11** – EBS volume attached, two volumes with `DeleteOnTermination` values

![image](/screenshots/lab-3-ec2/s11.png)

**Screenshot 12** – `usms-db-01` private, no public address, no profile (Step 16)

![image](/screenshots/lab-3-ec2/s12.png)

**Screenshot 13** – `WIRING PROVEN` (Checkpoint 5)

![image](/screenshots/lab-3-ec2/s13.png)

**Screenshot 14** – Stop/start address behaviour (Step 18)

![image](/screenshots/lab-3-ec2/s14.png)

**Screenshot 15** – `PERSISTENCE PROVEN` (Checkpoint 6)

![image](/screenshots/lab-3-ec2/s15.png)

**Screenshot 16** – Golden AMI `available`

![image](/screenshots/lab-3-ec2/s16.png)

**Screenshot 17** – `verify-lab-03.sh` result (`FAIL=0`, or the documented benign failures)

![image](/screenshots/lab-3-ec2/s17.png)

### 6.2 AWS Console / API Verification

Floci has no AWS Management Console, so verification uses `describe-*` output. 

**Instances (`usms-web-01`, `usms-db-01`)**  
Running, correct subnets, security groups, tags
![image](/screenshots/lab-3-ec2/a1.png)

**Key pair `usms-app-key`**  
Exists; fingerprint returned, no private key
![image](/screenshots/lab-3-ec2/a2.png)

**Elastic IP `usms-web-eip`**  
Allocated and associated with `usms-web-01`

**Volumes**  
Root and data volume; data volume survives termination

**AMI `usms-web-golden`**  
State `available`, tagged `Project=USMS`



## 7. Analysis and Discussion

The practical produced a working two-tier compute layer. The web server was launched into the public subnet with the application security group and Lab 1's instance profile; the permission chain from instance to profile, role and `USMSStudentDataReadWrite` was traced and confirmed. The database tier was placed in the private subnet with no public address or instance profile, and its security group admits PostgreSQL only from the web tier's group, which was proven by comparing group IDs. A stop/start test and a Floci restart showed that instances, volumes, addresses and associations persist.

Observations specific to Floci:

- User data was stored and round-tripped byte-for-byte, but it does not execute: Floci boots no operating system, and the lab notes the AMI is Amazon Linux 2 (`yum`) while the script uses `dnf`. 
- Instances reached `running` almost instantly, unlike the 30–60 seconds on real AWS.
- The instance cannot fetch IAM credentials from the metadata service (IMDS is not served), so only the association is verifiable.

Errors encountered and how they were resolved:

- No significant errors were encountered.

## 8. Reflection

1. **What did I learn about EC2?**  
An instance is the combination of AMI, type, subnet, security group, key pair, instance profile and user data; user data runs once at first boot; auto-assigned public IPs change on stop/start while Elastic IPs do not; EBS volumes live in one AZ and have their own lifecycle.

2. **Challenges encountered:**   
Building the request JSON with an unquoted heredoc, quoting in JMESPath, keeping variables consistent across terminals, Floci not running the bootstrap.

3. **Real-world application:**  
The same pattern deploys a web tier and a private data tier, with IAM roles instead of stored keys, Elastic IPs for stable endpoints, and golden AMIs for repeatable launches and Auto Scaling.

4. **What I would like to explore next:**  
Auto Scaling groups and launch templates, Application Load Balancers, EBS snapshots and Data Lifecycle Manager, Systems Manager Session Manager instead of SSH, and IMDSv2 enforcement.

## 9. Conclusion

The objectives of this practical were achieved. The USMS web and data tiers were deployed with the AWS CLI, using resources from Labs 1 and 2, and each property (placement, firewall, identity, user data, storage, persistence) was verified by reading it back from the API. A golden AMI and a populated `configs/lab-03.env` were produced for later labs.

The practical built skills in reviewable request files with `--cli-input-json`, waiters, JMESPath queries on nested EC2 data, secret handling for private keys, and distinguishing what an emulator can prove (configuration) from what only real AWS can (a running process). Compute is the layer every later lab builds on.

## 10. Appendix

### Additional Files

- `labs/lab-03-ec2/user-data.sh`
- `templates/lab-03-run-instances.json`
- `templates/lab-03-run-instances-full.json`
- `configs/lab-03.env`
- `outputs/lab-03-instance-policy.json`
- `outputs/lab-03-post-restart.txt`
- `outputs/lab-03-pre-restart.txt`
- `outputs/lab-03-exposure-report.txt`
- `outputs/lab-03-userdata.b64`
- `outputs/lab-03-userdata.sh`
- `scripts/utilities/verify-lab-03.sh`
- `scripts/cleanup/lab-03-cleanup.sh` (not run)
- `notes/lab-03-notes.md`
- `labs/lab-03-ec2/exercises.md`
- `screenshots/lab-3-ec2`

