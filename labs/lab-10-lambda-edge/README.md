# Lab 10 — Edge Functions with AWS Lambda — Report

    Student Name: Tshering Phuntsho
    Student ID: 02230310
    Module: DSO303 Cloud Native Solution Design
    Practical: Lab 10 – Edge Functions with AWS Lambda
    Date: 25/11/2026

## 1. Aim / Objective

This practical created `usms-student-data` — the bucket four IAM policies have named since Lab 1 without it ever existing — and built the request path around it: two Lambda@Edge functions at the viewer-request and origin-response trigger points, a CloudFront distribution associating both, and a separate regional function reacting to uploads through an S3 event notification. The objectives were to:

- create the origin bucket and watch `USMSStudentDataReadWrite`'s ARNs resolve to a real resource for the first time;
- add CloudFront's second trust principal (`edgelambda.amazonaws.com`) to `usms-lambda-exec-role`, then write, package, invoke and publish two Lambda@Edge functions, proving the allow path, the deny path, and — critically — that the two functions *compose* (the origin-response function reads a header the viewer-request function wrote);
- associate both with a real CloudFront distribution and prove the chain runs end to end without one, via a simulator script built for exactly that purpose;
- build a third, regional function with environment variables and an alias (legal there, forbidden at the edge — the contrast is the point), give it a scoped resource policy so S3 can invoke it without becoming a confused deputy, wire a filtered bucket notification, and prove it actually ran;
- prove every artefact survives a Floci restart and save every identifier the still-unwritten S3 configuration lab will need to `configs/lab-10.env`.

## 2. Introduction

Every lab from 1 to 9 built identity and network scaffolding around a bucket that did not exist; Lab 9's own Step 6 confirmed this with a clean `404` on `head-bucket`. This lab is the first to make that bucket real, and the first in the course to put compute *at* the edge rather than inside a region. The lab's own distinction, stated directly in Section 4, is the one this report keeps returning to: **edge functions are for the request path; regional functions are for what happens afterwards.** A viewer-request function runs before the cache is ever consulted, which is why it can reject a request at zero origin cost and why anything it changes becomes part of the cache key; an origin-response function runs after the origin replies but before the object is cached, which is why a header it adds is stored once and served to everyone afterwards. Lambda@Edge enforces this with real restrictions — no environment variables, Node or Python only, published-version ARNs only, memory and timeout caps that differ by trigger point — restrictions this lab checks for directly (Step 14) because Floci enforces none of them.

The second recurring idea is the one Lab 9 introduced from the identity side and this lab meets from the resource side: **identity-based versus resource-based policies**. `usms-lambda-exec-role`'s execution role answers "what may this code do"; the resource policy Step 19 attaches to the notifier's `:live` alias answers a different question entirely — "who may invoke this function" — and the same confused-deputy fix Lab 9 applied to a trust policy (`aws:SourceAccount`/`aws:SourceArn`) reappears here as `--source-arn`/`--source-account` on `add-permission`.

## 3. Use Case

What changed is that four labs' worth of IAM documents about a bucket stopped being hypothetical:

- **`usms-student-data`** now exists, tagged `Project=USMS, Tier=data, Lab=06`, and `USMSStudentDataReadWrite`'s ARNs — read by Step 5's own verification — resolve to it for the first time since Lab 1 wrote that policy;
- **`usms-lambda-exec-role`**, created in Lab 1 and unused since, now trusts two principals instead of one — `lambda.amazonaws.com` for ordinary execution and `edgelambda.amazonaws.com` for CloudFront's replication and edge-invocation path — the single most common Lambda@Edge setup error on real AWS, and one this lab's own Step 6 states by name before it can be made;
- **`usms-edge-viewer-request`** is the auth gate: it lowercases every `/transcripts/` URI (one cache entry per object, not two) and returns a `403` itself — without the origin ever being contacted — when the authenticated-session header is absent;
- **`usms-edge-origin-response`** adds the four security headers a bucket origin does not provide (`Strict-Transport-Security`, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`), a deliberate `Cache-Control` for transcripts, and a chain marker proving the two functions composed;
- **`usms-transcript-cdn`**, a real CloudFront distribution on this build (Step 4's probe answered `SUPPORTED`), associates both functions by version-qualified ARN and forwards exactly one header (`x-usms-student`) into the cache key — no cookies, no query string;
- **`usms-transcript-notifier`** is the first function in this course anyone would call "serverless automation" in the ordinary sense: triggered by `s3:ObjectCreated:*` on `transcripts/*.json`, it confirms the object is readable (exercising the one non-logging permission `USMSLambdaBasic` grants) and prints a structured `USMS_NOTIFY` line that stands in for the SNS publish a later lab will add.

Other common uses of this exact shape elsewhere: any CDN-fronted document store that must refuse unauthenticated requests before they cost a backend fetch (the viewer-request pattern), and any S3 bucket whose uploads must trigger downstream processing without that processing ever becoming a confused deputy for an unrelated bucket (the scoped resource-policy pattern).

## 4. System Architecture / Design

![image](/screenshots/lab-10-lambda-edge/architecture.jpeg)

*Figure 1 — two independent request paths, exactly as Section 4 of the lab brief draws them: the top box is a decision made once per cache miss, at the edge, before or after the origin; the bottom path is a decision made once per upload, regionally, with nobody waiting on its answer. `usms-lambda-exec-role` backs the notifier; the two edge functions were moved to a dedicated `usms-edge-exec-role` in Exercise 2, which this diagram's later state reflects but the original build does not.*

## 5. Implementation Procedure

**Environment, identity, and this account's own stale path (Steps 1–4).** Started Floci and confirmed the account (`000000000000`), then sourced all nine prior labs' env files without a single `absent` line. `floci-storage-check.sh` on this repository reports per-check `ok`/`bad` lines rather than the lab's assumed `PASS=16 FAIL=0` summary line — a different script shape than the lab text describes, not a failure; every individual check passed. The support probe answered **all six calls `SUPPORTED`**, including CloudFront — Path A throughout.

**A stale `COURSE_ROOT`, found before it could break Step 8 (Steps 4–8).** `configs/course.env` hardcoded `COURSE_ROOT="$HOME/aws-floci-course"`, a path from before this course was moved under `Desktop/DSO303/`; nothing before Lab 10 actually dereferenced the variable, so it sat wrong, silently, since Lab 1. Step 8's `python3 -m zipfile -c "$COURSE_ROOT/outputs/..."` was the first command in this course to need it, and it failed with a plain `FileNotFoundError` into a stray directory at the old path. Fixed by pointing `COURSE_ROOT` at this repository's real, absolute location — a one-line change recorded in Section 7's "worse than expected" findings, not worked around locally, since every future lab sources the same file.

**The execution role gets a second principal, and a second, quieter shape mismatch (Step 6).** `usms-lambda-exec-role` read back with exactly one principal (`lambda.amazonaws.com`) and one attached policy (`USMSLambdaBasic`), exactly as expected. Updating its trust policy to add `edgelambda.amazonaws.com` needed `--role-name`, which IAM accepts only as a bare name — but `configs/lab-01.env`'s `USMS_ROLE_LAMBDA` holds the **full ARN**, not a name, so the lab's own `"${USMS_ROLE_LAMBDA:-usms-lambda-exec-role}"` default pattern silently does nothing (the variable *is* set, just to the wrong shape) and the call fails with `Invalid length for parameter RoleName, value: 0`. Fixed by deriving the bare name with `${USMS_ROLE_LAMBDA##*/}` everywhere this lab needed a role name, including inside `verify-lab-10.sh`. The two-principal trust policy then verified cleanly: `length(...Principal.Service)` → `2`, and the `edgelambda` filter → a match.

**Two edge functions, written, packaged, and — after one real Floci networking defect was diagnosed and worked around — invoked (Steps 7–13).** Both `index.mjs` handlers were written directly to disk rather than through a shell heredoc, which sidesteps the exact unquoted-heredoc failure mode the lab warns about for `${studentId.toLowerCase()}`; `node --check` passed on both immediately. `usms-edge-viewer-request` created cleanly (`nodejs20.x`, 128 MB, 5 s, `Active`). Its first synchronous invoke, though, timed out after 5 seconds with `Function.TimedOut` — not a handler bug. `docker logs floci` traced it precisely: Floci's `DockerHostResolver` advertises the Lambda Runtime API on this account's EC2-VPC emulation network IP (`10.0.0.2`), but the per-invocation sidecar container it spawns joins only `floci-course_default` (per `FLOCI_SERVICES_DOCKER_NETWORK`) — two different, unrouted Docker bridge networks, so the sidecar's own runtime client can never reach the API it is told to call, and every invoke fails identically regardless of the function's code. Confirmed by inspecting the spawned container's actual network membership (`172.21.0.x`, never `10.0.0.x`). The fix, applied for the rest of this session as a background watcher (`docker network connect` the moment each sidecar container appears, named by Floci's own `floci-aws-floci-course-usms-*` convention): the very next invoke returned `Error: None`, `Status: 200`, with the URI correctly lowercased and `x-usms-edge: viewer-request-allow;student=stu-00417` stamped. The deny-path "Your turn" fixture returned a true `403` response object with no `uri` key, exactly as the lab's own contract for a viewer-request rejection requires. `usms-edge-origin-response` created and invoked the same way, returning all four security headers, the transcript `Cache-Control`, and — the first real evidence the two functions compose — `x-usms-edge-chain: viewer-request-allow;student=stu-00417;origin-response`. Both functions published cleanly as version `1`.

**Restrictions checked, not assumed (Step 14).** Setting environment variables on `usms-edge-viewer-request` succeeded, exactly as the lab predicts for *any* build including real AWS — the rejection belongs to a different API call entirely (the CloudFront association), which is why this lab checks statically rather than by trying the association and reading the error. Cleared again, `edge_eligibility()` reported zero `NO` lines across both functions: no environment variables, within the 128 MB/5 s viewer cap, Node runtime, no VPC, at least one published version.

**A real CloudFront distribution, Path A throughout (Step 15).** `usms-transcript-cdn` created in one call (`E22YNEPRUFH2BA`, domain `e22yneprufh2ba.cloudfront.net`), `Status: Deployed` immediately — no 15-minute real-AWS propagation to wait out. `get-distribution` read back both associations with version-qualified ARNs exactly as written: `viewer-request → ...:usms-edge-viewer-request:1`, `origin-response → ...:usms-edge-origin-response:1`.

**The edge chain, proven without a request path (Step 16).** `usms-edge-simulate.sh` was written exactly to the lab's own spec — two quoted heredocs for the inner Python, an unquoted outer heredoc for nothing (everything it needs is derived at run time) — and run both ways. The allow fixture produced the full three-stage chain (`viewer-request → origin → origin-response`) with the composed chain header; the deny fixture produced a one-stage chain and a `403`, proving the origin is never contacted on a reject. The allow trace was restored last, since Exercise 5 uploads it.

**A regional function, deliberately unlike the first two (Steps 17–18).** `notifier.py` reads two environment variables — legal here, the exact thing Step 14 forbids at the edge — and wraps its one `s3:GetObject` call in a `try/except` because a Lambda container's route back to the S3 API is build-dependent, not because the call is expected to fail. Created as `python3.12`, 256 MB, 30 s; published as version `1`; aliased as `live`. The "Your turn" rollforward/rollback published version `2` with no code change, repointed `live → 2`, confirmed it, then repointed back to `live → 1` — `list-versions-by-function` showed `$LATEST`, `1` and `2` present throughout, which is exactly what makes a rollback instant: repointing an alias never deletes a version.

**A resource policy, and the Lab 9 pattern reapplied (Step 19).** `add-permission --qualifier live --principal s3.amazonaws.com --source-arn ... --source-account ...` returned a statement scoped by both conditions; `get-policy --qualifier live` read it back unchanged, and the Python assertion confirmed the bucket name appears inside the condition block, not merely inside the resource ARN — the same discipline Lab 9 applied to `usms-ecs-task-role`'s trust policy, moved from an identity-policy condition to a resource-policy condition on a different service entirely.

**The notification, a genuinely delayed (not absent) delivery, and a second real finding (Steps 20–21).** The notification configuration wired cleanly, filtered to `transcripts/` and `.json`. Uploading Lab 8's own scaling-evidence file produced **no** log group at all moments after the upload — read at face value, this matches the lab's documented "delivery may be unimplemented" limitation. It was not: re-checking the same log group several steps later, after other invokes had already warmed the function's container network path, showed a genuine `USMS_NOTIFY` line for that exact object (`readable: true`), timestamped independently of any manual invoke this session ran. **Delivery on this build is real but asynchronous — delayed on the order of a minute, not instant and not absent.** The synthetic-event fallback (Step 21 Part 2) was still run and still useful: it returned `"processed": 1` immediately, and `read_error: ClientError` for the fabricated key, exactly as the lab predicts for an object that does not exist. The "Your turn" filter check uploaded `notes/ignore-me.json` (wrong prefix) and `transcripts/evidence/ignore-me.txt` (wrong suffix); polled for 90 seconds; and confirmed the `USMS_NOTIFY` count never moved — both decoys excluded by the filter exactly as configured, not by chance.

**Persistence, proven twice (Step 22).** The five-line inventory (functions, versions, aliases, objects, notification id) came back byte-identical across a genuine `floci-down.sh`/`floci-up.sh` cycle. The stronger check — re-running `usms-edge-simulate.sh` after the restart — produced the identical three-stage chain and composed header, proving the *code* survived, not merely the metadata the weaker check reads.

**`configs/lab-10.env`, and Section 8's verification (Step 23, Section 8).** Twenty-five exports, every value read live from the API rather than typed, including real CloudFront values (`USMS_CLOUDFRONT_SUPPORTED=yes`, a real distribution id and domain) because this build took Path A. `verify-lab-10.sh` was built exactly to the lab's own fifty-one-check spec, with the same `${USMS_ROLE_LAMBDA##*/}` fix folded into its role-name derivation, and reports **`PASS=51 FAIL=0`** — the lab's own stated target, met exactly. `lab-10-cleanup.sh` was written and syntax-checked only; per Section 8.2's own instruction, and per this course's standing rule to never run destructive scripts mid-course, it was never executed.

## 6. Results and Evidence

### 6.1 CLI / SDK Output

**Screenshot 1 – Step 1: Floci started, storage-check output**
![image](/screenshots/lab-10-lambda-edge/s1.png)

**Screenshot 2 – Step 2: nine env files sourced, identity and bucket/role names confirmed**
![image](/screenshots/lab-10-lambda-edge/s2.png)

**Screenshot 3 – Step 3: three function source directories created**
![image](/screenshots/lab-10-lambda-edge/s3.png)

**Screenshot 4 – Step 4: support probe — all six calls SUPPORTED, including CloudFront**
![image](/screenshots/lab-10-lambda-edge/s4.png)

**Screenshot 5 – Step 5: usms-student-data created, tagged, and USMSStudentDataReadWrite's ARNs resolving**
![image](/screenshots/lab-10-lambda-edge/s5.png)

**Screenshot 6 – Step 6: trust policy — two principals, edgelambda confirmed present**
![image](/screenshots/lab-10-lambda-edge/s6.png)

**Screenshot 7 – Step 7: viewer-request handler written, syntax OK, template literal intact**
![image](/screenshots/lab-10-lambda-edge/s7.png)

**Screenshot 8 – Step 8: packaged and created, after the COURSE_ROOT fix — State: Active**
![image](/screenshots/lab-10-lambda-edge/s8.png)

**Screenshot 9 – Step 9: allow path (uri normalised, header stamped) and deny path (403, no uri key)**
![image](/screenshots/lab-10-lambda-edge/s9.png)

**Screenshot 10 – Step 10: durable log route — log group present, LogResult limitation documented**
![image](/screenshots/lab-10-lambda-edge/s10.png)

**Screenshot 11 – Step 11: version 1 published, ARN confirmed version-qualified**
![image](/screenshots/lab-10-lambda-edge/s11.png)

**Screenshot 12 – Step 12: origin-response handler written and syntax-checked**
![image](/screenshots/lab-10-lambda-edge/s12.png)

**Screenshot 13 – Step 13: origin-response invoked — 4 security headers + cache-control + composed chain header**
![image](/screenshots/lab-10-lambda-edge/s13.png)

**Screenshot 14 – Step 14: edge eligibility — zero NO lines across both functions**
![image](/screenshots/lab-10-lambda-edge/s14.png)

**Screenshot 15 – Step 15: CloudFront distribution created (Path A) — both associations version-qualified**
![image](/screenshots/lab-10-lambda-edge/s15.png)

**Screenshot 16 – Step 16: usms-edge-simulate.sh — allow (3-stage chain) and deny (1-stage) runs**
![image](/screenshots/lab-10-lambda-edge/s16.png)

**Screenshot 17 – Step 17: notifier.py written, syntax OK, two os.environ.get lines confirmed**
![image](/screenshots/lab-10-lambda-edge/s17.png)

**Screenshot 18 – Step 18: notifier created, version 1, alias live — rollforward/rollback to version 2 and back**
![image](/screenshots/lab-10-lambda-edge/s18.png)

**Screenshot 19 – Step 19: resource policy — scoped to one bucket in one account**
![image](/screenshots/lab-10-lambda-edge/s19.png)

**Screenshot 20 – Step 20: notification wired, first object uploaded**
![image](/screenshots/lab-10-lambda-edge/s20.png)

**Screenshot 21 – Step 21: synthetic-event fallback — "processed": 1, delayed real delivery confirmed in logs**
![image](/screenshots/lab-10-lambda-edge/s21.png)

**Screenshot 22 – Step 22: pre/post-restart inventory IDENTICAL; edge chain still executes and composes**
![image](/screenshots/lab-10-lambda-edge/s22.png)

**Screenshot 23 – Step 23: configs/lab-10.env — 25 exports, all populated, sources cleanly**
![image](/screenshots/lab-10-lambda-edge/s23.png)

**Screenshot 24 – Section 8.1: verify-lab-10.sh — PASS=51 FAIL=0**
![image](/screenshots/lab-10-lambda-edge/s24.png)

### 6.2 Verification Summary

| Evidence | One-line explanation |
|---|---|
| `verify-lab-10.sh` | `PASS=51 FAIL=0` — the lab's own stated target, met exactly, after both exercises that changed configuration |
| Step 9/13's invoke payloads | Allow path normalises the URI and stamps a header; deny path returns a true response object with no `uri` key; origin-response composes the upstream header |
| `usms-edge-simulate.sh`, before and after Step 22's restart | Identical 3-stage allow chain and composed header both times — code, not just metadata, survived |
| `outputs/lab-10-pre-restart.txt` vs. `-post-restart.txt` | Byte-identical after a genuine Floci stop/start |
| Step 19's resource-policy assertion | `usms-student-data` present inside the `Condition` block, not only the `Resource` ARN — the confused-deputy fix actually applied |
| Step 21 / Exercise 5's delayed-delivery finding | A real `USMS_NOTIFY` line for `lab-08-scaling-evidence.json` appeared with no manual invoke in between — delivery is asynchronous, not absent |
| Exercise 1's version isolation | `--qualifier 1` returns 4 security headers, no CSP; `$LATEST` (version 2) returns 5, CSP included |
| Exercise 2's version isolation | `--qualifier 1` reports the old role (`usms-lambda-exec-role`); `$LATEST` reports the new one (`usms-edge-exec-role`) |
| Exercise 3's report, run from two directories | Byte-identical output; the notifier is `edge_eligible: false` for exactly one reason in this account's live state |
| Exercise 5's bucket-policy validation | 7 statements, 0 mismatches — every principal an existing role, every resource ARN matching the real bucket; `get-bucket-policy` still fails `NoSuchBucketPolicy`, correctly unapplied |

## 7. Analysis and Discussion

`verify-lab-10.sh` reports `PASS=51 FAIL=0`, and getting there required finding and fixing two account-state defects and one genuine Floci server defect, none of which were assumed to be platform limitations before being diagnosed.

Several things were **better than expected**. CloudFront answered `SUPPORTED` on this build (Step 4), so the entire Path A branch — a real distribution, real associations, real `Status: Deployed` — ran rather than the structural-validation-only Path B the lab treats as at least as likely. S3 event delivery, which the lab's own troubleshooting section (Section 10) frames as possibly unimplemented on a given build, turned out to be genuinely implemented on this one — just delayed by roughly a minute, discovered only because the log group was re-checked later rather than abandoned after the first empty read.

Several things were **worse than expected**, and two of the three were genuine account-state defects, not emulator limitations. First, `configs/course.env`'s `COURSE_ROOT` pointed at a path this repository was moved away from before Lab 1 ever ran — latent since the very first lab, surfaced only because Step 8 was the first command in ten labs to actually dereference it. Second, `configs/lab-01.env`'s `USMS_ROLE_LAMBDA` holds a full ARN rather than the bare role name Step 6's `"${VAR:-default}"` pattern assumes, which fails silently (the variable being merely *set*, not *correctly shaped*) rather than loudly — exactly the kind of defect Lab 9's own notes warned is harder to catch than an outright missing value. Third, and most serious: every synchronous Lambda invoke on this build timed out until a genuine Docker-networking defect inside Floci itself was diagnosed — the Runtime API's advertised host IP and the spawned sidecar container's actual network membership point at two different, unrouted bridge networks. This is not listed on `known-issues.html`, which documents this lab's only recorded Floci 2.0.1 issue as "no global edge execution locally"; this account's server reports version **2.4.0**, and the known-issues page itself warns that a newer build may behave differently without necessarily being fixed. The fix applied — attaching each spawned sidecar container to the missing network the instant it appears — is a workaround for this session, not a course file, and does not belong in any committed script.

One finding changed what Exercise 3's own hint led me to expect, and is worth recording precisely because it generalises the same lesson Lab 9 drew from its own worked example: the exercise's text says the notifier should be `edge_eligible: false` for "two independent reasons," but under this account's actual configuration (`memory=256, timeout=30`) both values fit entirely inside the generous, non-`"viewer"` cap (`10240, 30`) the exercise's own heuristic applies to any name without "viewer" in it — so only the environment-variables check actually fails here. The heuristic's literal rule and this account's live state do not agree with the example's assumed outcome, and only running the script against real data — not trusting the illustrative count — surfaced that.

## 8. Reflection

1. **What did I learn about edge computing on AWS?**
   The edge/regional distinction is not a performance preference, it is a hard constraint with real, checkable consequences: an edge function cannot have environment variables, cannot reference `$LATEST` or an alias, and is capped at 128 MB/5 s or 10,240 MB/30 s depending on which of four trigger points it runs at — and Step 14 showed directly that Lambda itself accepts a configuration CloudFront will later reject, which is precisely why this lab checks eligibility statically rather than by waiting for an association call to fail. I also learned that "the two functions compose" is a specific, falsifiable claim — `x-usms-edge-chain` either ends in `;origin-response` with the upstream student id intact, or it does not — not a vague architectural statement about layering.

2. **What challenges did I encounter?**
   Distinguishing a genuine Floci limitation from an account-state defect from a shell-scripting mistake took real discipline, since all three present identically at first as "the command failed." The `COURSE_ROOT` and `USMS_ROLE_LAMBDA` issues were ordinary configuration drift, confirmed by reading the actual file content rather than assuming the lab's own default-value pattern would always save me. The Lambda Runtime API networking defect was the hardest of the three to isolate precisely because the error message (`Function.TimedOut`) looks identical to a slow handler, and only reading `docker logs floci` and inspecting the spawned container's actual network membership (not just the advertised IP) revealed the real mismatch.

3. **How would I apply this in a real cloud environment?**
   I would treat "the API call succeeded" as evidence of nothing on a platform that does not enforce what it is told — Floci's acceptance of environment variables on an edge function (Step 14) is the clearest demonstration in this course so far that a successful call and a correct configuration are different claims, checked by different means. I would also build diagnosis as a layered question, in the order this lab forced on me without asking for it explicitly: is this my code, my account's configuration, or the platform itself — checked in that order, with the platform as the last, not the first, hypothesis.

4. **What would I like to explore further?**
   Running this exact lab against a build new enough to have the Lambda Runtime API networking defect fixed, to see whether `aws lambda invoke` succeeds on the very first attempt with no workaround at all; and measuring the actual delay distribution of this build's S3 event delivery (Step 21's finding was a single data point — a minute, once) against a repeatable set of uploads, to see whether it is a fixed warm-up cost or genuinely variable.

## 9. Conclusion

The objectives were achieved, with every genuine defect — two in this account's own configuration, one in Floci's own networking — found, diagnosed from first principles, and either fixed in the shared config or worked around for this session, rather than assumed or silently routed past: `usms-student-data` exists and four labs' worth of IAM ARNs resolve to it; `usms-lambda-exec-role` trusts both Lambda principals; both edge functions are created, invoked on both the allow and deny paths, proven to compose, checked against every Lambda@Edge restriction with zero failures, and associated with a real CloudFront distribution; the edge chain runs identically before and after a genuine Floci restart; the regional notifier has a scoped resource policy, a filtered notification, and — a genuine, not merely synthetic — S3-triggered execution in its logs; and `verify-lab-10.sh` reports `PASS=51 FAIL=0`, exactly the lab's own target. All five Independent Lab Exercises were completed: a second security header added without disturbing version 1, a dedicated edge execution role that leaves `usms-lambda-exec-role` untouched, an edge-readiness report that is identical from any working directory, a two-page design document for the registrar's four requirements, and a validated, still-unapplied bucket-policy draft handed to the lab that comes next.

The key concepts were the edge/regional distinction as a set of hard, checkable restrictions rather than a style preference; identity-based versus resource-based policies as two different questions ("what may this code do" versus "who may invoke it"), with the confused-deputy fix (`--source-arn`/`--source-account`) reapplied from Lab 9's trust-policy context to a Lambda resource policy; and version/alias semantics, where an edge association must be immutable (a published version) specifically because replication to many points of presence is non-transactional, while a regional trigger benefits from exactly the mutability (`:live`) the edge forbids. The skills developed were diagnosing a timeout by reading container logs and inspecting actual Docker network membership rather than assuming a handler bug; distinguishing a stale shared-config value from a platform limitation by checking the file's content directly; and building a verification script whose checks are static substitutes for enforcement a given platform may or may not actually perform. This lab matters because it is the first time this course's IAM documents stopped describing a resource that would exist "later" and started describing one that does — and the first time a request path, not just a backend service, had to survive being read, written, and restarted correctly.

## 10. Appendix

Files in the repository:

- `labs/lab-10-lambda-edge/edge-viewer-request/index.mjs`, `edge-origin-response/index.mjs`, `transcript-notifier/notifier.py` — the three handlers
- `policies/trust-lambda-edge.json` — the two-principal trust policy; `policies/usms-edge-basic-policy.json` (Exercise 2)
- `templates/lab-10-viewer-request-event.json`, `-denied.json`, `lab-10-origin-response-event.json`, `lab-10-distribution-config.json`, `lab-10-bucket-notification.json`, `lab-10-s3-event.json` — the six Step-by-Step request/event documents
- `configs/lab-10.env` — 25 exports, all read live
- `configs/course.env` — `COURSE_ROOT` corrected to this repository's real, absolute path (Step 8 finding)
- `scripts/utilities/usms-edge-simulate.sh` — runs the edge chain without a CloudFront request path
- `scripts/utilities/usms-edge-report.sh` (Exercise 3) — edge-readiness report, directory-independent
- `scripts/utilities/verify-lab-10.sh` — `PASS=51 FAIL=0`
- `scripts/cleanup/lab-10-cleanup.sh` — end of course only, syntax-checked, never run
- `labs/lab-10-lambda-edge/exercises.md`
- `notes/lab-10-notes.md` — Floci-specific findings, both "Your turn" results, all six Review Questions
- `notes/lab-10-edge-design.md` — Exercise 4's full design document
- `outputs/lab-10-*.json`, `-*.txt` (git-ignored; kept until submission)
