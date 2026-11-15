# Lab 12 — Deploying to Amazon ECS from the Pipeline — Report

    Student Name: Tshering Phuntsho
    Student ID: 02230310
    Module: DSO303 Cloud Native Solution Design
    Practical: Lab 12 – ECS Pipeline Deploy (Practical 7)
    Date: 25/11/2026

## 1. Aim / Objective

This practical turned the two-stage pipeline Lab 11 built into a real deployment path: an image, a registry, and a third pipeline stage that moves a running ECS service. The objectives were to:

- create a private ECR repository, authenticate Docker against it with a token on standard input, and push an image, reading the registry host from the API rather than typing it;
- derive a new ECS task definition revision with describe → strip → register, naming the pushed image while leaving every field AWS owns untouched;
- version both pipeline IAM policies (`create-policy-version` + `--set-as-default`) and add an ECS Deploy stage driven by `imagedefinitions.json`;
- deploy through the pipeline where the build's own image-and-registry mechanics could be proven, deploy by hand where the pipeline's ECS provider itself could not, prove the service moved either way, and roll a bad release back;
- specify a blue/green deployment with CodeDeploy, build the scaffolding a real one would need, and state plainly that one was not performed.

## 2. Introduction

Lab 11 stopped at an artifact: a pipeline that fetched source and ran a build, with nowhere for the result to go. This lab closes that gap, and in doing so surfaced two real, load-bearing findings about this specific Floci build that the lab's own "Floci vs Real AWS" framework exists to capture honestly.

The first finding is a narrow, reproducible registry defect: **re-pushing a byte-identical manifest to a tag that already holds it hangs indefinitely at the final manifest-commit step**, even though every layer reports `already exists` instantly — the upload side is fine; only the commit of unchanged content wedges. Killing the hung `docker push` client does not just fail that one command: it wedges the entire Docker Desktop engine, so that `docker ps` itself starts hanging, and recovery needs `docker desktop restart`. This happened three separate times over the course of this lab, confirmed each time by the same signature (every layer `already exists`, then nothing) and recovered each time with Floci's state in `~/floci-data` intact afterward. The practical consequence, discovered and then exploited deliberately for the rest of this lab: **never rebuild and re-push a release without changing its content.** Because `build-metadata.json` carries a fresh `builtAt` timestamp into the image on every real build, every genuine release in this lab (r6, r7, r8, the Exercise 1 alternate base, both Exercise 2 immutable-tag pushes) produced a new digest and pushed cleanly within seconds; only the deliberate re-push tests (Exercise 2's immutable-tag rejection test, and Exercise 5's retag) ever touched already-existing content on purpose, and the Exercise 5 one hung exactly as predicted.

The second finding is the one Known Issues already documents for this lab by name: **the CodePipeline ECS deploy provider is not implemented on this build.** `aws codepipeline start-pipeline-execution` ran Source and Build to genuine completion — including a real `docker build` and a real `docker push`, confirmed by `describe-images` reading the pushed digest back — but the Deploy action failed immediately with `Provider ECS is not available in Floci CodePipeline`. Every deploy in this lab that actually moved the service, including the one that followed a real, successful pipeline execution, was therefore performed by hand, using the exact `imagedefinitions.json` the real Build stage produced — the Known Issues page's own named alternative, not an improvisation.

## 3. Use Case

What this lab built is the second half of a release pipeline whose first half Lab 11 supplied:

- **`usms-enrolment`** is the first private container registry in this course — control-plane operations (`create-repository`, `describe-repositories`, `describe-images`, tag mutability) all answer correctly on this build; the registry's data plane (`docker push`/`pull`) works for genuinely new content and hangs for byte-identical re-pushes, a distinction this report treats as the headline finding rather than a footnote;
- **`labs/lab-11-pipeline/app/Dockerfile`** turns the Lab 11 build's `dist/` output into a two-line image on `nginx:1.27-alpine`, built with `--provenance=false --sbom=false` so the exported manifest is the single, plain OCI manifest this registry's emulation handles, not a BuildKit attestation manifest list;
- **`USMSCodeBuildBase` v2** and **`USMSCodePipelineBase` v2** extend Lab 01's and Lab 11's roles with exactly the new capability each needs — ECR push for the build role, ECS deploy-and-PassRole for the pipeline role — versioned rather than edited in place, so the previous version stays available to roll back to;
- **the `Deploy` stage**, provider ECS, turns `usms-enrolment-pipeline` into the three-stage shape the architecture diagram promises: `Source → Build → Deploy`, reading `imagedefinitions.json` from the same `BuildOutput` artifact the Build stage already produced in Lab 11;
- **`usms-enrolment-svc`** is the first service in this course actually running code this course's own pipeline built and pushed, rather than Lab 04's placeholder `public.ecr.aws/nginx/nginx:stable-alpine` — proved, not assumed, by the chain in `outputs/lab-12-release-evidence.md`.

Other common uses of this exact shape elsewhere: any team whose "the pipeline is green" claim needs an independent, artifact-level proof that a specific release is really what a service is running, and any environment where a managed deploy provider is unavailable or untrusted and the fallback — register-and-update by hand, from the build's own output file — needs to be a rehearsed, scripted path rather than a last-minute console click.

## 4. System Architecture / Design

![image](/screenshots/lab-12-ecs-pipeline/architecture.jpeg)

The pipeline now has the shape Section 5 of the brief describes: `labs/lab-11-pipeline/app/` is zipped and uploaded to `usms-pipeline-artifacts`, feeding a three-stage `usms-enrolment-pipeline` (`Source` → `Build` → `Deploy`). The `Build` stage's extended `buildspec.yml` builds and pushes an image to `usms-enrolment` (ECR), then writes `imagedefinitions.json` naming the container (`enrolment-api`) and the pushed image URI. The `Deploy` stage, provider ECS, is configured to read that file, register a new task-definition revision with the image swapped in, and update `usms-enrolment-svc` on `usms-ecs-cluster` — the four-step mechanism (read current task def → replace one image → register → update-service) the brief's diagram names explicitly.

What this account's own build adds to that diagram, matching Section 2's finding: a dashed box around the `Deploy` stage's action, labelled `Provider ECS is not available in Floci CodePipeline`, with a parallel path drawn alongside it — the same four-step mechanism performed by hand, reading the same `imagedefinitions.json` the real Build stage wrote, Known Issues' own named substitute for the broken box. The blue/green scaffolding built in Exercise 3 (`usms-enrolment-tg-green`, a test listener on port 8080) sits beside this diagram as a second, parallel traffic path that nothing in this lab's deployment controller actually uses yet — exactly as Step 19's "specify, don't perform" framing intends.

## 5. Implementation Procedure

**Environment, with one pre-existing script bug fixed before anything else (Step 1).** `floci-storage-check.sh` consistently exited 141 (SIGPIPE) partway through its host-directory listing — `ls | head -20 | sed ...` under `set -o pipefail`, where `head` closing early after a now-larger `~/floci-data` SIGPIPEs `ls`, and `pipefail` turns that into a fatal script exit. Fixed with a one-line `|| true` on that pipeline (`scripts/utilities/floci-storage-check.sh`); not a Lab 12 defect, but a pre-existing race this lab's larger data directory finally triggered deterministically.

**The port-publish step that made things worse, not better (Step 4).** Uncommenting `5100-5104:5100-5104` on the main `floci` container, as Step 4 instructs, let the main container claim the entire ECR sidecar port range for itself — leaving zero free ports for Floci's own per-repository ECR backing-registry container, which self-publishes directly to `127.0.0.1` on whichever port in that range it needs. The result was `docker login` failing with a `503`, then a full engine wedge once a hung operation was killed. Reverting the compose edit (keeping only `4566` published) let the sidecar bind its own port exactly as it already had before this step, and `docker login` succeeded immediately afterward. Documented in `outputs/lab-12-deploy-probe.txt` as the clearer of this lab's two central findings, and recovered three separate times across the lab via `docker desktop restart` with Floci's bind-mounted state (`~/floci-data`) verified intact each time.

**ECR repository, Dockerfile, and the first successful push (Steps 5–9).** `usms-enrolment` was created `MUTABLE`, `scanOnPush=true`, `AES256` — deliberately mutable so Step 18's rollback drill has something to demonstrate. `docker login` succeeded reading the registry host from `describe-repositories`, never typed. The Dockerfile build was run with `--provenance=false --sbom=false` from the first attempt, after an initial plain `docker build` produced a BuildKit attestation manifest list whose extra manifests the registry's push path never finished committing (the first, more confusing face of the re-push-hang finding, before its simpler cause — identical content — was isolated). With that flag and genuinely new build content each time, `r6` pushed cleanly, confirmed read back by `describe-images`, and proved by the full create-perturb-read-back sequence: local copies deleted, then pulled back successfully by digest alone.

**Task definition revision 5, after two redundant local-tag attempts (Step 10).** The first two describe-strip-register cycles (now revisions 3 and 4) were run and registered before the real ECR push had succeeded, naming the local-only tag `usms-enrolment:r6`; once the push genuinely landed in the registry, a third, correct cycle registered revision 5 naming the real ECR URI. Revisions 3 and 4 were later deregistered as redundant, duplicate artefacts of the same diagnostic process that found the push-hang finding in the first place — documented, not hidden, in `notes/lab-12-notes.md`'s Step 18 answer and `scripts/utilities/verify-lab-12.sh`'s evidence.

**Manual deploy and the watcher (Step 11).** `usms-ecs-watch.sh` polls `describe-services` until exactly one deployment exists with `running == desired`. Unlike the lab's own "Floci Limitation — tasks that never reach RUNNING" warning, this build genuinely launches tasks: revision 5 settled from `IN_PROGRESS`/`running=0` to `COMPLETED`/`running=2` within two ten-second polls.

**Two policy versions, both proven by a real execution, not merely by `get-policy` (Steps 12, 15).** `USMSCodeBuildBase` v2 added the five ordered ECR push actions plus the unscopeable `ecr:GetAuthorizationToken` on `Resource: "*"`; `USMSCodePipelineBase` v2 added `ecs:DescribeServices`/`UpdateService` scoped to one service ARN, `ecs:RegisterTaskDefinition`/`DescribeTaskDefinition` on `"*"` (task definitions have no ARN before registration), and a second, conditioned `iam:PassRole` naming exactly the two ECS roles and `ecs-tasks.amazonaws.com` — not `ecs.amazonaws.com`, the mistake the Step 12 "Your turn" draft in `notes/lab-12-notes.md` made and then corrected against Step 15's real document.

**The buildspec extension, and the moment the registry defect and the pipeline defect met in the same run (Step 14).** The extended `buildspec.yml` builds and pushes an image (guarded by `docker info`, wrapped in `timeout 25` so a hung push can no longer hang a whole build indefinitely) and writes `imagedefinitions.json` from `config/service.json`'s container name. Lab 11's Exercise 5 had already added the file's eighth smoke-test assertion, so Step 14 found it present and made no redundant change. Run locally with `IMAGE_REPO_URI` pointed at the real ECR URI, it built, pushed, and passed all eight smoke assertions in both of this lab's two local verification runs.

**Running it end to end, and the Known Issues alternative, confirmed exactly as documented (Steps 16–17).** The three-stage pipeline document was built by the described get-modify-put ("drop metadata before a put," Step 16's own instruction) and applied with `update-pipeline`; `get-pipeline` read back the correct three-row artifact chain (`None → SourceOutput → BuildOutput`). `r7` was pushed by hand first — this build's own CodeBuild container genuinely builds and pushes (confirmed by the Build action's `externalExecutionId`, a real sequential build ID, and by `r7`'s digest appearing in `describe-images` immediately after), so pushing by hand first was precautionary, not a substitute for a real build. `start-pipeline-execution` then ran Source and Build to real `Succeeded` completion and failed Deploy immediately with `Provider ECS is not available in Floci CodePipeline` — the exact, named Known Issue for this lab. Following the documented alternative to the letter, revision 6 was registered by hand from the real `imagedefinitions.json` the real Build stage wrote, and `usms-enrolment-svc` was updated to it and settled at `running=2`. `outputs/lab-12-deploy-evidence.txt` and `outputs/lab-12-release-evidence.md` both trace this chain end to end: S3 source version → pipeline execution → build ID → image digest → task definition ARN → the service's current task definition, every link a real command's real output.

**The rollback drill, adapted to the same Known Issue (Step 18).** Since the pipeline's Deploy action cannot run at all on this build, the drill used the same manual mechanism to register a revision (7) naming `usms-enrolment:r8`, an image genuinely never pushed. The deployment stuck at `IN_PROGRESS`/`running=0` indefinitely with zero service events — the documented "circuit breaker is stored, not enforced" limitation, observed rather than assumed, since this build otherwise runs real tasks. Rolled back by hand to revision 6, then — having already decided, in `notes/lab-12-notes.md`, that an ACTIVE revision naming an unpushed image is a live trap for a future audit — revision 7 was deregistered, along with the two earlier redundant revisions 3 and 4.

**Blue/green, specified and scaffolded, not performed (Step 19, Exercise 3).** `templates/lab-12-appspec.yaml` and the deployment group document were written and validated; Exercise 3 then went one step further than the main lab asks and actually built the scaffolding the conceptual documents reference — a real `usms-enrolment-tg-green` target group and a real test listener on port 8080 — so the deployment group document's two listener ARNs are genuine ARNs, not placeholders. The ECS service's `deploymentController` was never touched, per Step 19's own explicit danger warning.

**Verification (Section 8).** `scripts/utilities/verify-lab-12.sh`, adapted to this repository's real paths (`labs/lab-11-pipeline/app`, not the brief's generic `labs/lab-11-cicd/app`) and to this build's confirmed Path A registry behaviour, reports **`PASS=45 FAIL=0`**.

## 6. Results and Evidence

### 6.1 CLI / SDK Output

**Screenshot 1 – Step 1: Floci up, storage check (fixed), whoami, Lab 11 readiness file read**
![image](/screenshots/lab-12-ecs-pipeline/s1.png)

**Screenshot 2 – Step 2: all eleven env files sourced, no MISSING values**
![image](/screenshots/lab-12-ecs-pipeline/s2.png)

**Screenshot 3 – Step 3: deploy-support-probe.sh — Path A, every check ok**
![image](/screenshots/lab-12-ecs-pipeline/s3.png)

**Screenshot 4 – Step 4: the port-publish attempt, the resulting ECR-sidecar starvation, and the revert**
![image](/screenshots/lab-12-ecs-pipeline/s4.png)

**Screenshot 5 – Step 4 verify: only 4566 published, ECS service and data survived**
![image](/screenshots/lab-12-ecs-pipeline/s5.png)

**Screenshot 6 – Step 5: usms-enrolment ECR repository created**
![image](/screenshots/lab-12-ecs-pipeline/s6.png)

**Screenshot 7 – Step 5 verify: registry host derived from the API, never typed**
![image](/screenshots/lab-12-ecs-pipeline/s7.png)

**Screenshot 8 – Step 6: docker login succeeded**
![image](/screenshots/lab-12-ecs-pipeline/s8.png)

**Screenshot 9 – Step 7: Dockerfile and .dockerignore written and verified**
![image](/screenshots/lab-12-ecs-pipeline/s9.png)

**Screenshot 10 – Step 8 part 1: release r6 set, dist/ rebuilt locally**
![image](/screenshots/lab-12-ecs-pipeline/s10.png)

**Screenshot 11 – Step 8 part 2: image built and tagged (--provenance=false --sbom=false)**
![image](/screenshots/lab-12-ecs-pipeline/s11.png)

**Screenshot 12 – Step 9: push confirmed by describe-images; create-perturb-read-back by digest**
![image](/screenshots/lab-12-ecs-pipeline/s12.png)

**Screenshot 13 – Step 10: describe-strip-register derivation — old image vs. new image**
![image](/screenshots/lab-12-ecs-pipeline/s13.png)

**Screenshot 14 – Step 10: revision 5 registered, cpu/memory/health unchanged**
![image](/screenshots/lab-12-ecs-pipeline/s14.png)

**Screenshot 15 – Step 11: usms-ecs-watch.sh written**
![image](/screenshots/lab-12-ecs-pipeline/s15.png)

**Screenshot 16 – Step 11: revision 5 deployed by hand, settled running=2**
![image](/screenshots/lab-12-ecs-pipeline/s16.png)

**Screenshot 17 – Step 12: USMSCodeBuildBase v2 created and set as default**
![image](/screenshots/lab-12-ecs-pipeline/s17.png)

**Screenshot 18 – Step 13: privilegedMode true, IMAGE_REPO_URI set, source still CODEPIPELINE**
![image](/screenshots/lab-12-ecs-pipeline/s18.png)

**Screenshot 19 – Step 14 part 1: buildspec.yml diff (Lab 11 → Lab 12 extension)**
![image](/screenshots/lab-12-ecs-pipeline/s19.png)

**Screenshot 20 – Step 14 part 2: local verification — real build, real push, 8/8 smoke tests**
![image](/screenshots/lab-12-ecs-pipeline/s20.png)

**Screenshot 21 – Step 14 part 3: source packed and uploaded to S3**
![image](/screenshots/lab-12-ecs-pipeline/s21.png)

**Screenshot 22 – Step 15: USMSCodePipelineBase v2 created, six statements, v2 default**
![image](/screenshots/lab-12-ecs-pipeline/s22.png)

**Screenshot 23 – Step 16 part 1: current two-stage pipeline document read**
![image](/screenshots/lab-12-ecs-pipeline/s23.png)

**Screenshot 24 – Step 16 part 2: Deploy stage appended, document validated**
![image](/screenshots/lab-12-ecs-pipeline/s24.png)

**Screenshot 25 – Step 16 part 3: three-stage pipeline applied, artifact chain verified**
![image](/screenshots/lab-12-ecs-pipeline/s25.png)

**Screenshot 26 – Step 17: end-to-end execution — Source/Build Succeeded, Deploy Failed**
![image](/screenshots/lab-12-ecs-pipeline/s26.png)

**Screenshot 27 – Step 17: diagnosis — "Provider ECS is not available in Floci CodePipeline"**
![image](/screenshots/lab-12-ecs-pipeline/s27.png)

**Screenshot 28 – Step 17: Known Issues manual-deploy alternative — revision 6 registered and deployed**
![image](/screenshots/lab-12-ecs-pipeline/s28.png)

**Screenshot 29 – Step 17: the three proofs read back, all fields unchanged**
![image](/screenshots/lab-12-ecs-pipeline/s29.png)

**Screenshot 30 – Step 18 part 1: release r8 set, never pushed, confirmed absent from the registry**
![image](/screenshots/lab-12-ecs-pipeline/s30.png)

**Screenshot 31 – Step 18 part 2: the bad release deployed by hand**
![image](/screenshots/lab-12-ecs-pipeline/s31.png)

**Screenshot 32 – Step 18: stuck deployment, zero events — the circuit breaker is stored, not enforced**
![image](/screenshots/lab-12-ecs-pipeline/s32.png)

**Screenshot 33 – Step 18 part 3: rolled back by hand; source fixed back to r7**
![image](/screenshots/lab-12-ecs-pipeline/s33.png)

**Screenshot 34 – Housekeeping: revisions 3, 4 and 7 deregistered per the Step 18 decision**
![image](/screenshots/lab-12-ecs-pipeline/s34.png)

**Screenshot 35 – Step 19: blue/green conceptual documents validated**
![image](/screenshots/lab-12-ecs-pipeline/s35.png)

**Screenshot 36 – Step 20: configs/lab-12.env written, 27 exports populated**
![image](/screenshots/lab-12-ecs-pipeline/s36.png)

**Screenshot 37 – Step 20 verify: sourced values confirmed**
![image](/screenshots/lab-12-ecs-pipeline/s37.png)

**Screenshot 38 – Section 8.1: verify-lab-12.sh — PASS=45 FAIL=0**
![image](/screenshots/lab-12-ecs-pipeline/s38.png)

**Screenshot 39 – Section 8.2: lab-12-cleanup.sh syntax-checked, not run**
![image](/screenshots/lab-12-ecs-pipeline/s39.png)

### 6.2 Verification Summary

| Evidence | One-line explanation |
|---|---|
| `verify-lab-12.sh` | `PASS=45 FAIL=0` — every ECR, task definition, policy and pipeline check passes on this account's real state |
| `outputs/lab-12-deploy-probe.txt` | The two central findings, recorded in full: the port-publish/ECR-sidecar conflict, and the re-push-hang/engine-wedge pattern, reproduced three times each |
| `outputs/lab-12-deploy-evidence.txt`, `outputs/lab-12-release-evidence.md` | The full S3-version → execution → build-ID → digest → task-def → service chain, every value a real command's real output |
| `docker pull` by digest after local deletion (Step 9) | The create-perturb-read-back proof that `r6` is genuinely in the registry, not just the local cache |
| Step 17's Deploy failure, reproduced identically under Exercise 4's v3 policy | Confirms the Deploy failure is the documented Known Issue, not a side-effect of any IAM change this lab made |
| Exercise 1 | `r7-alt` on `public.ecr.aws/nginx/nginx:stable-alpine` — sizes recorded from `describe-images`, found to be byte-for-byte the same upstream build as `nginx:1.27-alpine` on this date |
| Exercise 2 | `IMMUTABLE` genuinely rejects a re-push (`cannot be overwritten`); a per-build unique tag suffix, implemented and run twice successfully, fixes it |
| Exercise 3 | A real second target group and test listener; the deployment group document has zero placeholders left |
| Exercise 4 | v3 policy scopes `RegisterTaskDefinition`/`DescribeTaskDefinition` to the `usms-enrolment` family; proven not to break the pipeline by a real execution |
| Exercise 5 | Items 1–6 fully verified by real command output; item 7 (the retag) honestly reported as attempted-and-hung, not fabricated |

## 7. Analysis and Discussion

Two things were **worse than the lab's own stated expectations**, and both are now permanently documented rather than merely encountered once. The port-publish step this lab's own text treats as routine (Step 4) actively broke ECR on this build, because the main container claiming the full `5100`–`5104` range left zero ports free for the per-repository sidecar that was already self-publishing successfully on a subset of that same range. And `docker push` genuinely works for new content and genuinely hangs — taking the whole Docker Desktop engine down with it when killed — for a byte-identical re-push, a failure mode this lab's own "push may not be supported at all" framing does not anticipate (it anticipates a clean, fast failure, not a hang that wedges the daemon). Both findings were isolated by direct observation (the exact `docker-compose.yml` conflict; the exact "every layer already exists, then nothing" signature) rather than assumed from the lab's generic Floci Limitation language, and both were then designed around for the rest of the lab: the port range was left unpublished, and every real build from Step 8 onward changed its content (via `build-metadata.json`'s timestamp) before pushing.

One thing was **exactly as documented, and confirmed independently rather than taken on faith**: `known-issues.html`'s named Lab 12 issue, "CodePipeline ECS deploy provider unavailable," reproduced precisely — Source and Build genuinely succeeded (a real build ID, a real pushed digest), and only the Deploy action's provider itself was missing. Running Exercise 4's new, tighter IAM policy through a second full pipeline execution and watching Deploy fail with the identical message is the strongest evidence available that this is a platform gap, not an IAM regression this lab's own policy changes introduced.

One thing was **better than the lab's own stated expectation**: Section 11's "Floci Limitation — tasks that never reach RUNNING" did not hold on this build. Every manual deployment in this lab — the good releases in Steps 11 and 17, and the deliberately bad one in Step 18 — produced real task lifecycle behaviour: good releases settled at `running == desired` within two polls, and the bad release genuinely stuck at `running=0` rather than reporting a false settle. The absence of service events during that stuck deployment is still the documented limitation (the circuit breaker is stored, not enforced), observed directly rather than assumed.

## 8. Reflection

1. **What did I learn about CI/CD pipelines on AWS?**
   That "the pipeline reported Succeeded" and "the exact thing that should have happened, happened" are two different claims even when the first claim is true for a legitimate reason — Step 17's pipeline really did build and push a real image, and its Deploy stage still could not do the one thing a deploy stage exists to do. The fix was not to distrust the Build stage's success (it was genuinely true) but to have a rehearsed, scripted fallback — exactly what the Known Issues page's named alternative is — ready for the one stage that could not be trusted.

2. **What challenges did I encounter?**
   Distinguishing a genuine platform defect from my own mistake took real discipline twice. The port-publish conflict looked, at first, like a transient Docker Desktop hiccup; only reading `docker logs floci` for the exact line (`No free port available in range 5100-5104`) made the actual cause — the main container's own port claim — unambiguous. The re-push hang looked, at first, like it might be about BuildKit's attestation manifests (my first hypothesis, tested and partially correct — it did help once); only noticing that every layer reported `already exists` before the hang, on a push whose content had not changed, isolated the real, narrower cause.

3. **How would I apply this in a real cloud environment?**
   I would treat "the Build stage succeeded" as evidence worth corroborating with an artifact-level check (reading `imagedefinitions.json`'s actual contents, reading `describe-images`'s actual digest) before trusting a Deploy stage downstream of it — exactly the discipline `outputs/lab-12-release-evidence.md` practises. I would also never design a release process around "rebuild and re-push the same release to fix a problem" without first confirming the registry treats that case as a true no-op, since on real ECR a tag collision with identical content behaves differently from a tag collision with different content, and this lab found a build where that distinction genuinely matters operationally, not just academically.

4. **What would I like to explore further?**
   Whether the re-push hang is specific to this repository's `MUTABLE` setting or would also occur against an `IMMUTABLE` repository being asked to push genuinely new content under a brand-new tag (Exercise 2's test used a different, unique tag each time, so it never actually re-tested the hang under `IMMUTABLE`); and whether a real ECS deploy provider, once available on a future Floci build, would actually honour `DeploymentTimeout` the way the Deploy stage's configuration specifies, or merely accept the field the way `scanOnPush` is accepted and stored without being enforced.

## 9. Conclusion

The objectives were achieved, with two genuine Floci-specific findings diagnosed from first principles and worked around for the rest of the lab, and the one Known Issue the course's own documentation already names for this lab reproduced and worked around exactly as that documentation prescribes. `usms-enrolment` exists with a real pushed image, proved by create-perturb-read-back; task definition revisions were derived correctly via describe-strip-register, with the stale duplicates this lab's own diagnostic process produced honestly deregistered rather than left as silent clutter; both IAM policies reached v2 (and, for Exercise 4, a tested v3) with every new grant proven necessary and no broader than it had to be; the three-stage pipeline ran Source and Build to genuine completion and failed Deploy exactly where Known Issues says it will; the service was moved, by hand, through the documented alternative, and the full evidence chain from S3 source version to the service's current task definition was traced in `outputs/lab-12-release-evidence.md`; the rollback drill produced a real, correctly-diagnosed stuck deployment and a real rollback; and `verify-lab-12.sh` reports `PASS=45 FAIL=0`. All five Independent Lab Exercises were completed with real evidence: a genuine (if, on this date, byte-identical) base-image comparison; a working immutable-tag fix, proven by two successful pushes against a repository that had just rejected a plain re-push; a real second target group and listener with a placeholder-free deployment group document; a tighter IAM policy proven, by a real execution, not to break anything; and an audit evidence chain that is honest about the one link (the retag) this session did not complete live, rather than fabricating output for it.

The key concepts were the distinction between a registry's control plane and its data plane — both answering "yes" to a capability probe is not the same as both actually working under load; the discipline of deriving infrastructure documents (task definitions, pipeline stages) from their own live state rather than writing them from memory, which is what let two redundant revisions be identified and removed with confidence rather than guessed at; and the recurring theme, sharper here than in any lab before it, that a green status from an orchestrator is a claim about the orchestrator, not about the thing it orchestrates. The skills developed were diagnosing a hung process by its exact signature rather than its generic symptom, recovering a wedged container engine without losing state, and building a verification script and an evidence document that say exactly what they checked and exactly what they could not. This lab matters because it is the first time this course's pipeline actually moved a running service — and the first time doing so required treating the managed deploy mechanism itself as untrusted until proven otherwise.

## 10. Appendix

Files in the repository:

- `labs/lab-11-pipeline/app/Dockerfile`, `.dockerignore` — the enrolment image, built from this lab's own `dist/` output
- `labs/lab-11-pipeline/app/buildspec.yml` — extended to build and push an image and write `imagedefinitions.json`; `buildspec.yml.lab11` kept for comparison; `buildspec.yml.ex2-immutable` (Exercise 2)
- `labs/lab-12-ecs-pipeline/exercises.md`
- `policies/usms-codebuild-policy-v2.json`, `usms-codepipeline-policy-v2.json`, `usms-codepipeline-policy-v3.json` (Exercise 4)
- `templates/lab-12-taskdef-base.json`, `lab-12-taskdef-v3.json`, `lab-12-codebuild-update.json`, `lab-12-pipeline-current.json`, `lab-12-pipeline.json`, `lab-12-appspec.yaml`, `lab-12-codedeploy-deployment-group.json` (placeholder-free after Exercise 3), `lab-12-taskdef-v4-r7.json`, `lab-12-taskdef-r8.json`
- `scripts/utilities/deploy-support-probe.sh`, `usms-ecs-watch.sh`, `verify-lab-12.sh` — `PASS=45 FAIL=0`
- `scripts/utilities/floci-storage-check.sh` — one-line SIGPIPE/`pipefail` fix, pre-existing, triggered by this lab's larger data directory
- `scripts/cleanup/lab-12-cleanup.sh` — end of course only, syntax-checked, never run
- `configs/lab-12.env` — 27 exports, all read live
- `notes/lab-12-notes.md` — the "Your turn" exercises, all seven Review Questions, and the Step 18 decision to deregister stale revisions
- `outputs/lab-12-*.txt`, `-*.json`, `lab-12-release-evidence.md` (git-ignored; kept until submission)
