# Lab 10 Exercise 4 — USMS Transcript Delivery Design

Written for: the colleague who will implement it, given the registrar's four requirements. Every AWS feature named below is a real, existing CloudFront/Lambda feature; where I am not certain of its current exact limits I say so and name the command I would run to confirm it.

## 1. Where each piece of logic lives, and why

| Requirement | Tool | Trigger point | Why |
|---|---|---|---|
| Session-token check, no origin request on failure | **CloudFront Function** | `viewer-request` | A signature check against a shared secret (or a JWT's HMAC) is a pure, self-contained computation with no external lookup — exactly the case CloudFront Functions exist for: sub-millisecond, no per-invocation Lambda billing, and still early enough that a reject never reaches the origin. Lambda@Edge's extra cost and ~1–3 ms invocation overhead buy nothing here, since nothing the check needs is outside the request itself. |
| Faculty tag for the refusal report | **Embedded in the token itself**, read by the same CloudFront Function | `viewer-request` | The alternative — looking up a student's faculty from an external store on every request — reintroduces a network call at the one trigger point where a slow or failing call blocks every viewer, cache hits included. The fix is to never need the lookup: the token USMS's own auth system issues already carries the faculty claim, so the edge only reads a field that's already present. |
| Security headers, cache policy | **Lambda@Edge** | `origin-response` | CloudFront Functions cannot run at `origin-request`/`origin-response` at all — only `viewer-request`/`viewer-response` — so this trigger point requires Lambda@Edge regardless of how simple the logic is. Doing it here (not `viewer-response`) also means it runs once per cache miss, not once per request, exactly as Step 12 already established. |
| The Dean's office refusal-by-faculty report | **Not an edge function. A regional, batch process.** | n/a | See point 4 below — this is the one requirement an edge function is the wrong tool for. |
| Surviving one edge location losing the origin | **CloudFront Origin Failover (Origin Groups)**, a distribution-level setting | n/a | Not application logic at all — see point 4. |

## 2. Cache key

**Forward:** the URI (already lowercased at `viewer-request`, exactly as Step 7 does) and the **faculty claim extracted from the token**, not the token itself. No query string, no cookies.

**Deliberately excluded:** the raw session-token header value. Forwarding the full token into the cache key would mean every distinct token value — one per login, or per rotation — creates its own cache entry for the same object, which drives the hit rate toward zero for exactly the content this design is built to cache efficiently. It would also mean session tokens appear in CloudFront's cache-key logging, which is a credential-handling mistake independent of caching. The *decision* the token produces (allow, and which faculty) is what belongs in the cache key or in a short-lived derived header — never the credential that produced it.

## 3. Five-minute correction window vs. not re-fetching unchanged transcripts

These look like a contradiction only if "cache TTL" is the only tool considered. They are reconciled by splitting *when* a cache entry expires from *when* it is forced out:

- **Baseline TTL stays long.** `Cache-Control: public, max-age=300, s-maxage=3600` (Step 12's own header) means CloudFront itself (`s-maxage`) holds an unchanged transcript for an hour, so the overwhelming common case — a transcript nobody has corrected — costs one origin fetch per hour per edge location, not one every five minutes.
- **A correction is the exception, and exceptions get a push, not a shorter universal TTL.** When the registrar corrects a transcript, that write path calls `aws cloudfront create-invalidation --paths /transcripts/<key>` for that one object. Invalidation removes it from every edge cache immediately, well inside the five-minute requirement, without shortening the TTL for every other transcript that was never touched.

**The other defensible answer**, which I did not choose: drop `s-maxage` to something under five minutes everywhere and skip invalidation entirely. This is simpler to implement (no write-path integration) but means every transcript — corrected or not — is re-fetched from the origin at least every five minutes, which is exactly the cost the registrar's second sentence says not to pay. I would only switch to it if invalidation volume turned out to be high (see Section 5).

## 4. Where the refusal report comes from

Section 11's own limitation is the reason this can't be an edge answer: **Lambda@Edge and CloudFront Function logs land in the AWS region nearest the viewer who triggered them**, not in one place. A Dean's-office report needs one number across all regions, which no single edge invocation can produce — this is the requirement an edge function is the wrong tool for; the right tool is CloudFront's own standard access logs (or real-time logs), delivered centrally to one S3 bucket regardless of which edge location served the request, with the faculty claim and the 403 status already present in each log line because the `viewer-request` function put them there. A scheduled regional job (Athena over the log bucket, or a small regional Lambda on an EventBridge schedule) aggregates refusals by faculty on whatever cadence the Dean's office needs. The edge's job stops at making the decision and recording it; centralising many decisions into one report is regional-batch work by nature, independent of whether Floci can demonstrate it.

## 5. What I would measure first

**Correction frequency relative to read volume**: how many `create-invalidation` calls per day the registrar's correction workflow actually generates, against how many transcript reads happen in the same window. CloudFront's first 1,000 invalidation paths per month are free; past that, each path is billed, and a high rate of single-path invalidations during, say, a grade-appeal period could erode the cost advantage Section 3's long `s-maxage` is built to capture. If the measured correction rate turns out to be high enough that invalidation cost approaches or exceeds the cost of simply re-fetching more often, I would switch to the shorter-`s-maxage`-everywhere alternative in Section 3 instead — that is the concrete result that would change my mind, and it's a question of this workload's actual numbers, not of either design being wrong in general.
