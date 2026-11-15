# Lab 09 — Securing the USMS Application with IAM Roles and Security Groups — Report

    Student Name: Tshering Phuntsho
    Student ID: 02230310
    Module: DSO303 Cloud Native Solution Design
    Practical: Lab 09 – Securing the USMS Application with IAM Roles and Security Groups
    Date: 25/10/2026

## 1. Aim / Objective

This practical audited and then hardened the two access-control axes every earlier lab had left informally correct at best: **who can call what** (IAM) and **what can reach what** (security groups and routing). The objectives were to:

- inventory and audit every IAM role and every security group in the account with read-only scripts that compute findings from documents and rules rather than from names, before changing anything;
- fix the identity findings the audit turned up: a read-only split of the transcripts policy, confused-deputy trust conditions on four roles, a scoped `iam:PassRole` with a permissions boundary, a session policy whose intersection with an identity policy was computed by hand and cross-checked against `simulate-principal-policy`, an access-key rotation with no outage window, and IMDSv2 on the web instance;
- fix the network findings: written egress on three security groups (replacing the default allow-all) and a bastion-sourced SSH rule, then prove the data tier is unreachable by five independent controls rather than by assuming any single one holds;
- prove every control survives a Floci restart and that none of the five earlier labs' own verification scripts changed their result, and record every identifier Lab 10 and the CloudFormation lab need in `configs/lab-09.env`.

## 2. Introduction

Every lab from 01 to 08 built working infrastructure; none of them, on its own terms, proved that infrastructure was *safe* — a role that trusts its service principal unconditionally, a security group whose egress is still AWS's own default allow-all, an SSH rule open to an entire VPC, a single access key that has never rotated since Lab 01 created it. This lab is the first one whose subject is **access control as its own deliverable**, reviewed on two axes that, as the lab's own architecture diagram insists, do not know about each other: an API call is decided entirely by **IAM** (identity policies, resource policies, boundaries, session policies, in a strict evaluation order where an explicit Deny anywhere always wins); a network packet is decided entirely by **routing, security groups and NACLs**. An error message means IAM failed the call before it ran; a hang means the network never carried the packet. Confusing the two is, in the lab's own words, "a case where somebody assumed one of those two boxes had answered for the other."

Two concepts recur through almost every step. The **confused deputy problem** is a trust policy naming a service principal with no condition, letting that service assume the role on behalf of *anyone* who can get the service to act for them — fixed by pinning `aws:SourceAccount`/`aws:SourceArn` where the service actually sends them, and accepted-with-a-reason where it does not (EC2 instance profiles, which never send `aws:SourceArn`). **Defence in depth** is the discipline this lab applies to the network side: a claim like "the database is unreachable from the internet" is proven by enumerating every control that would each have to fail *independently* for the claim to be false — no public address, no subnet auto-assignment, no internet-gateway route, a security group admitting only one other group, a non-default NACL — rather than by trusting any single one of them.

## 3. Use Case

Nothing this lab built changes what USMS *does*; Section 4 of the lab brief states this directly, and Step 18's regression proof (Section 6.2) is how that claim gets checked rather than assumed. What changed is who may do it and from where:

- the **transcripts bucket's** access was split along the line Step 6 found: `usms-ec2-app-role`, `usms-ecs-task-role` and (a finding this lab's own audit surfaced, not assumed) `usms-eks-node-role` keep full read/write via `USMSStudentDataReadWrite`, while a new `usms-transcripts-reader-role` — the identity a future reporting task would actually run as — gets `USMSStudentDataReadOnly`, with every write explicitly denied, not merely unlisted;
- a new **deployment identity**, `usms-deploy-role`, exists for the first time in this course: every prior lab ran every AWS CLI command as account root, and this role — trusted only by `usms-admin-01`, carrying a scoped `iam:PassRole` to exactly three named roles, and capped by a permissions boundary that grants nothing on its own — is what a real CI/CD pipeline or the CloudFormation lab would actually deploy as;
- the **network's egress**, previously AWS's own default allow-all on every group, now states exactly what each tier is allowed to initiate: the enrolment tasks to the S3 prefix list and HTTPS generally (image pulls, log shipping, Lab 10's transcripts), the load balancer to the enrolment tasks only (a group reference, not an address, so it survives every future scaling event the same way Lab 06's scaling policy does not touch it), and the database tier to HTTPS only (OS updates, and nothing else);
- **SSH to the web tier** no longer admits the entire VPC (`10.0.0.0/16`, a rule that would have let a compromised Fargate task reach it) — it admits only `usms-bastion-sg`, a group that already existed in this account from earlier administrative-tier work and needed only its one stale CIDR rule removed to be correctly idempotent going forward;
- the **access credential** this entire course has run on since Lab 01 — `usms-dev-01`'s single access key — was rotated for the first time, with the create-move-deactivate-delete sequence that guarantees no window in which nothing works.

Other common uses of this exact shape elsewhere: a university's own identity team running the same "audit before you change anything" discipline against years of accumulated IAM drift before a compliance review; any service that holds personal data (here, academic transcripts) needing to answer, with evidence rather than assertion, exactly which identities can read it and how that list is known to be complete.

## 4. System Architecture / Design

![image](/screenshots/lab-9-security/architecture.jpeg)

*Figure 1 – two independent decision systems: the network diagram (top) answers "can a packet physically arrive"; the IAM diagram (bottom) answers "is this specific API call permitted." Every control this lab added sits in exactly one of the two boxes, and the lab's own point is that a reviewer must check both, because neither box's correctness implies anything about the other.*

## 5. Implementation Procedure

**Environment, baseline, and the build's own capabilities (Steps 1–3).** Resumed Floci and sourced seven env files, confirming seventeen values non-empty. Recorded the baseline: `verify-lab-02.sh` through `verify-lab-05.sh` at `PASS/FAIL=0`, and `verify-lab-06.sh` at `PASS=41 FAIL=3` — a pre-existing, already-documented condition (`notes/lab-06-notes.md`: `describe-scheduled-actions`/`put-scheduled-action` unsupported on this build), not something this lab introduced, confirmed by re-reading that lab's own notes before accepting it as the baseline Step 18 would later need to match exactly. Probed every IAM/EC2 capability this lab could need: this build answered **Path A — full**, including `iam simulate-principal-policy` and `accessanalyzer list-analyzers` (both `SUPPORTED`), with only `iam get-credential-report` absent.

**Identity inventory and the IAM audit (Steps 4–5).** Captured every role's trust policy, attached and inline policies into `outputs/lab-09-identity-inventory.json` (8 roles, including the EKS/autoscaling roles Section 3 places out of scope) and wrote `scripts/utilities/usms-iam-audit.sh`, a read-only, four-check scanner (wildcard actions, wildcard resources on mutating actions, unscoped `iam:PassRole`, unconditioned service trust). First run: `HIGH=7 MED=30`, four of the seven `HIGH` findings being the identical confused-deputy shape on four different roles — a systematic mistake made by a convention, not four unrelated bugs.

**The transcripts policy, read and split (Steps 6–7).** Read `USMSStudentDataReadWrite`'s document directly: a bucket-level `ListBucket` statement, an object-level `GetObject`/`PutObject`/`DeleteObject` statement, and an explicit `Deny` on `DeleteBucket`. Confirmed the bucket does not exist yet (`head-bucket` → clean `404`) and that the policy is carried by **three** roles, not two as the lab's own illustrative example assumes (`usms-ec2-app-role`, `usms-ecs-task-role`, and `usms-eks-node-role` — the third only visible by actually running `list-entities-for-policy` rather than assuming the lab's own worked example). Wrote `USMSStudentDataReadOnly` (Get + List, explicit Deny on every write) and a new `usms-transcripts-reader-role` trusted by a scoped `ecs-tasks.amazonaws.com` condition, then rewrote `usms-ecs-task-role`'s own trust policy additively — same principal, new `aws:SourceAccount`/`aws:SourceArn` conditions, confirmed with a before/after diff that reads `SAME PRINCIPAL, NEW CONDITION`.

**A deployment identity, scoped PassRole, and the first permissions boundary (Step 8).** Wrote `USMSPermissionsBoundary` (a ceiling: a broad Allow capped by an explicit Deny on every identity-changing action and on deleting the course network) and `USMSDeployBase` (ECS deploy calls, plus `iam:PassRole` scoped to exactly three named role ARNs with `iam:PassedToService: ecs-tasks.amazonaws.com`, plus an explicit Deny on passing anything to `ec2.amazonaws.com`). Created `usms-deploy-role`, trusted only by `usms-admin-01`, **with** the boundary attached at creation — confirmed stored (`PermissionsBoundaryType: Policy`, the correct ARN), not silently dropped, and confirmed attached to nothing as an ordinary policy.

**A session policy, computed and cross-checked (Step 9).** Wrote a session policy narrower than `usms-developer-role`'s own identity policy, discovering mid-step that this account's `USMSDeveloperBase` already explicitly grants `sts:GetCallerIdentity` (unlike the lab's own assumption), so the session policy's fourth action was swapped to `logs:FilterLogEvents` — an action genuinely absent from the identity policy — to get a real, demonstrable denial. Assumed `usms-developer-role` via the `usms-dev` profile with `--policy`, computed the identity∩session intersection by hand in Python, and cross-checked it against `iam simulate-principal-policy` (supported on this Path-A build): both methods agreed exactly — `ec2:DescribeVpcs` allowed, `logs:FilterLogEvents` an implicit deny, `iam:CreateUser` an explicit deny. Restored root identity and deleted the session credential file immediately.

**Access-key rotation, with no outage window (Step 10).** Confirmed `usms-dev-01` held exactly one key, then ran the four-step sequence in full: create a second key (two active, nothing changed yet), repoint the `usms-dev` profile and confirm it still answers as `usms-dev-01` under the *new* key, deactivate the old key and re-confirm the profile still works, delete the old key only after that confirmation. Final state: exactly one key, created today, active.

**IMDSv2 (Step 11, and the "Your turn").** Read `usms-web-01`'s metadata options before changing anything (`HttpTokens: optional`, the SSRF-exposed default), then required tokens with a hop limit of 1; read back `HttpTokens: required` immediately. For `usms-db-01`, which Lab 03 deliberately left with no instance profile, applied the strictly stronger setting available only to a roleless instance — `--http-endpoint disabled` — turning the metadata service off entirely, since there is no instance profile for anything to steal in the first place; applying the same setting to `usms-web-01` would break its instance-profile credential refresh outright, which is precisely why the two instances get different treatment.

**The security-group audit, and three lab-text defects found and fixed (Step 12 onward).** Wrote `scripts/utilities/usms-sg-audit.sh` (four questions per group: who can reach me, what can I reach, group-or-address, attached-to-anything) — first run: `HIGH=4 MED=12 LOW=8` across 11 groups in this VPC (which, unlike the lab's five-group illustration, also carries four `eks-cluster-sg-*` groups from Labs 7/8). While running the lab's own copy-paste CLI snippets against this account, three independent JMESPath/quoting defects in the lab text itself were found and fixed, confirmed each time by testing the corrected query standalone before trusting it: Step 15 and Step 18's queries were missing a `SecurityGroups[0].` prefix before indexing into a field; Step 16's bastion-group lookup piped an already-scalar `GroupId` through a redundant `| [0]`; and `verify-lab-09.sh`'s own boundary-attachment check broke under `eval`'s second parsing pass, fixed with a dedicated helper function. None required `known-issues.html` — each was a plain scripting defect, not a Floci limitation, confirmed by testing in isolation before accepting the fix.

**Written egress on three groups, and the SSH cutover (Steps 13–16).** Authorised the S3-prefix-list-plus-HTTPS egress on `usms-enrolment-sg`, the group-referenced HTTP egress on `usms-alb-sg` (to `usms-enrolment-sg`, surviving every future scaling event because it names a role, not an address), and the HTTPS-only egress on `usms-db-sg` — each time authorising the replacement *before* revoking the default, and each time confirming the matching three-zero result (`allow-all egress rules remaining: 0`). For Step 16, discovered that `usms-bastion-sg` and a group-sourced SSH rule on `usms-app-sg` **already existed** in this Floci backend's persisted state — apparently left over from earlier work against this exact lab before any Lab 09 file existed on disk — alongside the *original* `10.0.0.0/16` rule, which had never actually been removed; Step 16's own idempotent "find or create" design correctly reused the existing group, and Part 3's revoke still had real, necessary work to do.

**The reachability matrix and the negative proof (Step 17).** Wrote `scripts/utilities/usms-reachability-matrix.sh`, computing every group's ingress/egress purely from rules (never names), surfacing `usms-app-sg` as a second internet-facing entry point (Exercise 4's subject) and eight groups — including, correctly, `usms-enrolment-sg` — as protected by exactly one ingress rule. Proved `usms-db-01`'s internet-unreachability with five independently-failing controls: no public address, no subnet auto-assignment, no IGW route, a security group admitting only `usms-app-sg`, and a non-default NACL — all five confirmed with live queries, not asserted.

**Persistence, regression, the env file, and Section 8 (Step 18 onward).** Recorded nine identity/network facts, stopped and restarted Floci, and re-derived every identifier from the live API. The first attempt reported `PERSISTENCE FAILED` — traced directly to this account carrying **seven** stray `usms-web-01`-tagged EC2 instances from earlier, uncleaned Lab 03 runs, six of them `stopped`/`terminated`; the lab's own `instance-state-name=running,stopped` filter matched a different, stopped duplicate after the restart than the one actually checked before it. Narrowing the filter to `running` only resolved to the correct, single instance, and the diff then came back clean: `PERSISTENCE PROVEN`. Re-ran all five earlier verification scripts: identical to the Step 2 baseline, `NOTHING BROKE`. Wrote `configs/lab-09.env` (17 exports after Exercise 5, all read live — fixing, along the way, the same JMESPath-inside-a-heredoc escaping fragility the lab text itself warns about and offers a fallback for), and built `scripts/utilities/verify-lab-09.sh` (`PASS=49 FAIL=1`, the one failure a pre-existing, correctly-identified false positive from Lab 01's legitimate `${aws:username}` IAM policy variable) and `scripts/cleanup/lab-09-cleanup.sh` (syntax-checked only, never run).

## 6. Results and Evidence

### 6.1 CLI / SDK Output

**Screenshot 1 – Step 1: seven env files sourced, seventeen values populated**
![image](/screenshots/lab-9-security/s1.png)

**Screenshot 2 – Step 2: security baseline recorded — Labs 02/03/04/05 at FAIL=0, Lab 06 at the documented PASS=41 FAIL=3**
![image](/screenshots/lab-9-security/s2.png)

**Screenshot 3 – Step 3: Floci capability probe — Path A (full) confirmed**
![image](/screenshots/lab-9-security/s3.png)

**Screenshot 4 – Step 4 Part 1: role, user and policy inventory**
![image](/screenshots/lab-9-security/s4.png)

**Screenshot 5 – Step 4 Part 2: machine-readable identity inventory, 8 roles**
![image](/screenshots/lab-9-security/s5.png)

**Screenshot 6 – Step 5: usms-iam-audit.sh first run — HIGH=7 MED=30**
![image](/screenshots/lab-9-security/s6.png)

**Screenshot 7 – Step 6: the transcripts policy read, and the bucket's 404**
![image](/screenshots/lab-9-security/s7.png)

**Screenshot 8 – Step 7 Parts 1–4: read-only policy, scoped trust, new role created**
![image](/screenshots/lab-9-security/s8.png)

**Screenshot 9 – Step 7 Parts 5–6: usms-ecs-task-role's trust rewritten — SAME PRINCIPAL, NEW CONDITION**
![image](/screenshots/lab-9-security/s9.png)

**Screenshot 10 – Step 8 Parts 1–4: permissions boundary, deploy policy, deploy role created**
![image](/screenshots/lab-9-security/s10.png)

**Screenshot 11 – Step 8 Part 5: deploy role verified — boundary attached, PassRole scoped to 3 ARNs**
![image](/screenshots/lab-9-security/s11.png)

**Screenshot 12 – Step 9: session policy assumed, hand-computed intersection matches simulate-principal-policy**
![image](/screenshots/lab-9-security/s12.png)

**Screenshot 13 – Step 10 Part 1: usms-dev-01's single pre-existing access key**
![image](/screenshots/lab-9-security/s13.png)

**Screenshot 14 – Step 10 Parts 2–4: new key created, profile moved, old key deactivated**
![image](/screenshots/lab-9-security/s14.png)

**Screenshot 15 – Step 10 Part 5: old key deleted — exactly one active key remains**
![image](/screenshots/lab-9-security/s15.png)

**Screenshot 16 – Step 11: IMDSv2 required, hop limit 1, confirmed before and after**
![image](/screenshots/lab-9-security/s16.png)

**Screenshot 17 – Step 12: usms-sg-audit.sh first run — HIGH=4 MED=12 LOW=8 across 11 groups**
![image](/screenshots/lab-9-security/s17.png)

**Screenshot 18 – Step 13: usms-enrolment-sg egress written (S3 prefix list + HTTPS), default revoked**
![image](/screenshots/lab-9-security/s18.png)

**Screenshot 19 – Step 14: usms-alb-sg egress written as a group reference to usms-enrolment-sg**
![image](/screenshots/lab-9-security/s19.png)

**Screenshot 20 – Step 15: usms-db-sg egress written (HTTPS only); all three groups confirmed at zero allow-all rules**
![image](/screenshots/lab-9-security/s20.png)

**Screenshot 21 – Step 16 Parts 1–2: usms-bastion-sg found pre-existing; both old and new SSH rules visible**
![image](/screenshots/lab-9-security/s21.png)

**Screenshot 22 – Step 16 Part 3: the stale 10.0.0.0/16 SSH rule removed; only the bastion-group rule remains**
![image](/screenshots/lab-9-security/s22.png)

**Screenshot 23 – Step 17 Part 1: the reachability matrix — ingress, egress, and single-point-of-control groups**
![image](/screenshots/lab-9-security/s23.png)

**Screenshot 24 – Step 17 Part 2: five independent controls proving usms-db-01 unreachable from the internet**
![image](/screenshots/lab-9-security/s24.png)

**Screenshot 25 – Step 18 Part 1: nine identity/network facts recorded before the restart**
![image](/screenshots/lab-9-security/s25.png)

**Screenshot 26 – Step 18 Part 2: Floci stopped and restarted**
![image](/screenshots/lab-9-security/s26.png)

**Screenshot 27 – Step 18 Part 3: PERSISTENCE PROVEN after fixing the stray-instance filter**
![image](/screenshots/lab-9-security/s27.png)

**Screenshot 28 – Step 18 Part 4: all five earlier verification scripts unchanged — NOTHING BROKE**
![image](/screenshots/lab-9-security/s28.png)

**Screenshot 29 – Step 19: configs/lab-09.env written and verified, 16 exports (17 after Exercise 5)**
![image](/screenshots/lab-9-security/s29.png)

**Screenshot 30 – Section 8.1: verify-lab-09.sh — PASS=49 FAIL=1, the one documented exception**
![image](/screenshots/lab-9-security/s30.png)

### 6.2 Verification Summary

| Evidence | One-line explanation |
|---|---|
| `usms-iam-audit.sh`, before vs. after Exercise 2 | `HIGH` 7 → 3; the 3 remaining are the EKS/autoscaling roles Section 3 places explicitly out of scope |
| Step 7's before/after trust diff | `SAME PRINCIPAL, NEW CONDITION` — the confused-deputy fix changed circumstances, not who may assume the role |
| Step 9's intersection | Hand-computed Python result and `simulate-principal-policy`'s live evaluation agree exactly on all three test actions |
| `usms-sg-audit.sh` | Written egress confirmed on `usms-enrolment-sg`, `usms-alb-sg`, `usms-db-sg`, and (Exercise 1) `usms-app-sg`; zero allow-all rules remain on all four |
| Step 17's negative proof | Five independent controls on `usms-db-01`, each individually sufficient against internet reachability |
| `outputs/lab-09-pre-restart.txt` vs. `-post-restart.txt` | Byte-identical after a genuine Floci stop/start, once the stray-duplicate-instance filter was corrected |
| `outputs/lab-09-pre-verify.txt` vs. `-post-verify.txt` | Identical — all five earlier labs' own verification scripts report exactly what they did before this lab |
| `verify-lab-09.sh` | `PASS=49 FAIL=1` (the one documented, pre-existing false positive) |

## 7. Analysis and Discussion

`verify-lab-09.sh` reports `PASS=49 FAIL=1`, and that one failure is not a defect this lab introduced: it is Lab 01's own, entirely correct use of the IAM policy variable `${aws:username}` in `policies/usms-self-manage-credentials.json`, which the verify script's blanket `grep -l '\$' policies/*.json` check cannot distinguish from a genuinely unexpanded shell variable in a *new* document. Every document this lab itself wrote was individually confirmed at zero unexpanded variables the moment it was written — a materially stronger claim than the one failing check initially suggests, and the honest thing to do was record the false positive precisely rather than either hiding it or leaving it unexplained.

Several things were **better than expected**. First, this build answered Path A — full — including `iam simulate-principal-policy`, which the lab's own expected-output table treats as the less common outcome; Step 9's intersection therefore has an independent, live cross-check, not only a hand-computed one, and the two agreed exactly. Second, `--permissions-boundary` was not silently ignored: `usms-deploy-role`'s boundary was stored correctly and survived the Step 18 restart unchanged, removing an entire fallback branch the lab allows for but did not need here.

Several things were **worse than expected**, and all three were genuine defects found and fixed by actually running the lab's own commands rather than by reading them. Three separate JMESPath/quoting bugs existed in the lab text's copy-paste snippets — a missing `SecurityGroups[0].` indexing prefix (twice, in Step 15 and Step 18), a redundant `| [0]` pipe on an already-scalar field (Step 16), and an `eval`-hostile nested-quote combination in `verify-lab-09.sh`'s own boundary check — each confirmed as a plain scripting defect, not a Floci limitation, by testing the corrected query standalone before trusting the fix. None needed `known-issues.html`, and treating every one of them as a potential platform bug *first*, as Section 2's instruction to check known issues implies for API failures, would have wasted time on three bugs that were never about Floci at all.

One finding changed what the lab's own example led me to expect, and is worth recording precisely because it generalises: Step 6's worked example assumes `USMSStudentDataReadWrite` is carried by exactly two roles, but this account's own history (Labs 7 and 8 having added an EKS node role) meant it was carried by **three**, confirmed only by actually running `list-entities-for-policy` rather than trusting the lab's illustrative count. Exercise 5 extended that lesson further: scanning every policy document's every statement for any `s3:` action naming the bucket — rather than only checking who carries the two policies by name — surfaced a **fifth** access-granting principal, `usms-lambda-exec-role`, whose own `USMSLambdaBasic` policy carries a completely separate, Lab-01-era statement granting direct read access. Neither the lab's own worked example nor Step 6's manual reading would have found this; only the exhaustive, statement-level scan Exercise 5 specifically asked for did.

## 8. Reflection

1. **What did I learn about IAM and network security on AWS?**
   The two axes genuinely do not know about each other, and this lab is the first place in the course where that independence mattered operationally rather than just conceptually: `usms-app-sg`'s HIGH findings (public ingress on 80/443) are entirely a network-layer fact that no amount of IAM hardening touches, while the confused-deputy fix on four roles' trust policies is entirely an identity-layer fact that no security-group rule could ever express. I also learned that a negative claim ("this is unreachable") is only as strong as the number of *independent* controls behind it — Step 17's five-control proof on `usms-db-01` is a genuinely different, stronger kind of evidence than a single passing check, and the reachability matrix's "single point of control" finding on `usms-enrolment-sg` is a real, specific weakness in that one axis, not a judgment on the workload's overall safety (Review Question 5).

2. **What challenges did I encounter?**
   Distinguishing a genuine Floci limitation from a plain scripting bug in the lab's own text took real discipline, since both present identically at first (a command fails or returns something unexpected) — three separate JMESPath/quoting defects in the lab's own copy-paste snippets turned out to be ordinary bugs, confirmed by testing the corrected query in isolation before accepting the fix, not by assuming the platform was at fault. A second, unrelated challenge was that this specific account's history (seven stray, uncleaned `usms-web-01` instances from earlier Lab 03 runs) actively broke Step 18's own "re-derive by tag" persistence check by matching the wrong duplicate after the restart — a reminder that a tag is not a unique key, and that this lab's own discipline of re-deriving rather than reusing a variable is only as trustworthy as the filter actually being selective.

3. **How would I apply this in a real cloud environment?**
   I would never treat "the command succeeded" as evidence that a security control is correct on a platform, real or emulated, that does not actually enforce what it is told — Floci's complete non-enforcement (Section 2) is an extreme version of a risk that exists even on real AWS whenever a policy is *written* but never actually *exercised* by live traffic, which is exactly why this lab insists on reading documents and computing findings mechanically rather than trusting a lack of errors. I would also build the "who has access" question as an exhaustive, statement-level scan from day one (as Exercise 5's script does), rather than as a lookup by the two or three policy names a design document happens to mention — this account's own fifth principal, found only by the exhaustive version, is the concrete argument for why.

4. **What would I like to explore further?**
   Running this exact audit against a real AWS account with IAM Access Analyzer actually available, to see whether its findings for `usms-student-data` match the hand-assembled access table in Exercise 4 exactly, or surface a sixth principal this manual approach still missed; and building the one network control this course cannot demonstrate at all — AWS Network Firewall with hostname-level egress filtering — against a cluster that actually carries traffic, to see the specific attacker behaviour (data exfiltration over the one permitted HTTPS channel) that Steps 13–15's port-level egress control cannot stop.

## 9. Conclusion

The objectives were achieved, with every genuine Floci-era or account-history complication found, fixed, and recorded rather than hidden: the identity audit went from `HIGH=7` to `HIGH=3` (the three remaining explicitly out of scope per Section 3), with the one unfixable confused-deputy finding (`usms-ec2-app-role`) formally accepted with a reason and a compensating control rather than left as an unexplained gap; the network audit's three hardened security groups carry zero allow-all egress rules and SSH is narrowed to a named administrative group; and the data tier's unreachability from the internet rests on five independently-failing controls, verified live rather than assumed. Every one of the five earlier labs' own verification scripts reports exactly what it reported before this lab touched anything (`NOTHING BROKE`), and every control this lab added survived a genuine Floci restart (`PERSISTENCE PROVEN`), once a stray-instance filtering issue specific to this account's own history was found and corrected. `verify-lab-09.sh` reports `PASS=49 FAIL=1`, and that one failure is a documented, pre-existing false positive, not a defect in this lab's own work.

The key concepts were the strict independence of the IAM and network decision systems and the evaluation order within IAM itself (an explicit Deny always wins; a boundary and a session policy can only subtract, never grant); the confused-deputy problem and the specific case (EC2 instance profiles) where its usual fix has no equivalent at all; and defence in depth as a precise, falsifiable claim about independent control failure, not a vague preference for "more security." The skills developed were auditing an account's actual IAM and network posture from live API calls rather than from what a design document claims, distinguishing a genuine platform limitation from a plain scripting defect by testing the corrected form in isolation before trusting it, and scanning exhaustively for "who has access" rather than accepting the answer a lookup by two or three expected policy names would give. This lab matters because it is where USMS's system stopped being judged only by whether it works, and started being judged by whether the access to it is something a reviewer could actually defend — the question every one of the earlier labs built toward without yet being asked to answer.

## 10. Appendix

Files in the repository:

- `policies/usms-student-data-ro-policy.json`, `usms-deploy-policy.json`, `usms-permissions-boundary.json`, `trust-ecs-tasks-scoped.json`, `trust-deploy.json`, `usms-alb-sg-egress.json`, `usms-enrolment-sg-egress.json`, `usms-db-sg-egress.json`, `usms-egress-allow-all.json`, `usms-app-sg-ssh-bastion.json` — the ten Step-by-Step documents
- `policies/usms-app-sg-egress.json` (Exercise 1), `trust-breakglass.json`, `usms-breakglass-policy.json`, `trust-ecs-exec-scoped.json`, `trust-lambda-scoped.json`, `usms-iam-accepted-findings.json` (Exercise 2)
- `configs/lab-09.env` — 17 exports, all read live (16 after Step 19, +1 after Exercise 5)
- `scripts/utilities/usms-iam-audit.sh` — read-only, re-runnable, now reads an accepted-findings file (Exercise 2)
- `scripts/utilities/usms-sg-audit.sh`, `usms-reachability-matrix.sh` — read-only, re-runnable
- `scripts/utilities/usms-exposure-report.sh` (Exercise 3), `usms-bucket-policy-draft.sh` (Exercise 5)
- `scripts/utilities/verify-lab-09.sh` — `PASS=49 FAIL=1`
- `scripts/cleanup/lab-09-cleanup.sh` — end of course only, syntax-checked, never run
- `labs/lab-09-security/exercises.md`
- `notes/lab-09-notes.md` — Floci-specific and lab-text findings, Step 17's two "what if" answers, Exercise 4's full written review, all seven Review Questions
- `outputs/lab-09-*.json`, `-*.txt` (git-ignored; kept until submission)
