# Lab 13 Notes — Centralized Logging and Monitoring with CloudWatch and X-Ray

## Step 7 — "Your turn": a fifth, non-matching event

A plain health-check line (`health-check: ok scheduler heartbeat`, no `USMS_EVENT` or `ERROR`
token) was appended to the same stream, timestamped after the four Step 7 events. `rejectedLog
EventsInfo` was `null` again, and `filter-log-events` on the group returned 5 rows, up from 4 —
confirmed in screenshot `s13.png`. The point of sending it: Step 9's two metric filters watch for
`USMS_NOTIFY` and `ERROR` respectively, and this line contains neither, so it is the negative case
that proves the filters are selective rather than simply "every line in this group counts" — a
filter that matched everything would have been just as easy to build wrong, and this line is the
cheapest possible check against that mistake.

## Step 8 — "Your turn": the ERROR pattern, and the false positive it predicted

`test-metric-filter` with pattern `ERROR` against the four Step 7 messages matched exactly message
4 (`ERROR USMS_EVENT {"event":"transcript.failed",...}`), the single line the filter was meant to
catch. The predicted false-positive line, `USMS_EVENT {"event":"transcript.processed","reason":"no
ERROR here"}`, **did** match — confirmed in `s15.png`. The text dialect matches `ERROR` as a bare,
case-sensitive, whitespace-delimited token anywhere in the message, with no concept of "inside a
quoted string value" versus "a real severity marker" — it tokenises the raw text, not the JSON
structure the text happens to contain. **Would I accept this in production?** Not as-is, for a
shared log group other teams write unstructured, free-text fields into (a `reason` string is
exactly the kind of field a developer might later write `"reason":"retry after ERROR from
upstream"` into, meaning to describe someone else's error, not report one of their own). The fix
that costs nothing extra is a stricter pattern anchored to this lab's own line shape — `ERROR
USMS_EVENT` as a two-term pattern (both terms required) — since every real error line this
notifier emits is `ERROR USMS_EVENT {...}` as a prefix, never buried mid-string, and the `?`/`-`
exclusion syntax is unavailable without a determinable universe of counter-examples. For this lab's
specific, narrow central group with only this one `reason` field as a current risk, I accepted the
simpler `ERROR` pattern because the exercise's own purpose was to surface the false positive
honestly, not to defend against every hypothetical misuse of a free-text field.

## Step 10 — "Your turn": proving `defaultValue` is doing something

A window ending six hours before any upload today returned a genuinely **empty** `Datapoints` list
— the metric filter did not exist that far back (it was deployed in Step 9, this session), so there
is nothing to default. A window spanning today's activity returned a real data point with
`SampleCount: 288.0, Sum: 0.0` for one period alongside the real match — confirmed in `s21.png`.
**What an empty list means versus a list full of zeroes:** an empty list means the metric series
itself does not exist for that window — no filter was active, or the metric has never once
published, even a zero; a list of (mostly) zeroes means the filter *is* active and *is* evaluating
every period, and `defaultValue=0` is filling every period with no match rather than leaving a gap.
This build produced the second case for the active window and the first case for the historical
one — i.e. the honest, real distinction the exercise asks for, not a hypothetical.

## Step 13 — "Your turn": rollback, confirm, roll forward

`update-alias --function-version 1` pointed `live` back at the original Lab 10 handler;
`get-function-configuration --qualifier live` confirmed `Version: "1"` immediately afterward.
`update-alias --function-version 3` then moved it forward again, and `list-versions-by-function`
showed `$LATEST 1 2 3` throughout — nothing deleted at any point. Because direct `aws lambda
invoke` is broken on this build for the reason the README's Section 2 documents in full, the
real-AWS version of this check — invoking through the alias and observing the payload's shape
change (losing `trace_id` on v1, regaining it on v3) — could not be performed directly; the
substitute used was `get-function-configuration`, which proves the alias *points* at the right
version even though it cannot prove what invoking that version would actually *return*. **How
long would a real rollback of this deployment take, compared to Lab 10 Step 11's Lambda@Edge
rollback?** An `update-alias` call against a regional function is a single, synchronous API call
that takes effect for every future invocation the instant it returns — on the order of a second,
end to end. Lab 10 Step 11's Lambda@Edge rollback is categorically slower: CloudFront replicates a
function to edge locations worldwide, and a version change has to propagate through that same
replication before every edge location is serving the new version, which AWS documents in minutes,
not seconds — the same "where is this function actually running" distinction Lab 10 built the edge
simulator specifically to work around, now relevant again from the deployment-speed angle rather
than the local-testing angle.

## Section 14 — Review Questions

**1. A colleague says "we have logs, so we do not need metrics". Give the two strongest technical
arguments against, in terms of what each is cheap and expensive to do, and the one situation in
which they are right.**

*Argument one — aggregation over time is cheap for a metric and expensive for logs.* A metric is
already a pre-aggregated number per period; asking "how many notifications happened in the last
five minutes" against `NotifyCount` is one `get-metric-statistics` call reading a handful of stored
data points. The equivalent question against logs alone means scanning every log event in the
window and counting matches yourself — exactly what Step 23's Path B does when Logs Insights is
unavailable — which is `O(events)` work repeated every time anyone asks, versus the metric's
`O(1)` read of a number CloudWatch already computed once, at ingestion, via the metric filter.

*Argument two — alarming on an absence is structurally impossible from logs alone.* `usms-notify-
silence` (Review Question 3 expands this) depends on a metric's own missing-data semantics —
`--treat-missing-data breaching` makes "the metric did not report" itself the alarm condition.
There is no equivalent "alarm when nothing matched a log query in the last N minutes" primitive
built on logs directly; you would have to build your own scheduled query plus your own absence
logic, which is exactly a worse, hand-rolled version of what a metric alarm already does for free
once a metric filter exists.

*The one situation where the colleague is right:* a question that is fundamentally about *this one
specific request* — "why did student stu-00417's transcript take 9 seconds" — is a question logs
(or better, traces) answer and a metric cannot, because a metric has already discarded every
individual event's identity in exchange for the aggregation that makes argument one cheap. If every
question in a system were of that form, metrics would add nothing; the actual answer is that real
systems need both, because the two kinds of question (how many / how fast, on average, right now —
versus what exactly happened to this one request) are genuinely different questions.

**2. Step 9 created a metric filter and Step 11 published a metric directly. Compare them on
retroactivity, cost, what must change to add a measurement, and what happens when the emitting
code is not yours. Which would you use for "how many transcript downloads happened" and which for
"how long the render took", and why do the answers differ?**

| | Metric filter (Step 9) | Direct `put-metric-data` (Step 11) |
|---|---|---|
| Retroactivity | Never — evaluated only at ingestion, confirmed by Step 9's own "not retroactive" warning; cannot recover a count for a week before the filter existed | N/A in the same sense — but the *code* has to already exist and run during the window you care about either way |
| Cost | Filter evaluation itself is free; only the resulting metric is billed | The `PutMetricData` call itself has a (small) cost per call, in addition to the resulting metric |
| What must change to add a measurement | Nothing in the application — a new filter on an existing log line is a config-only change, proven by this lab adding `usms-notify-count` and `usms-central-errors` with zero code edits | The emitting code itself must be changed and redeployed, as Step 13's whole instrumentation exercise demonstrates |
| When the emitting code is not yours | Still measurable — the only requirement is that *something* already writes a matchable log line, which is exactly why `usms-notify-count` could be built against Lab 10's already-existing `USMS_NOTIFY` print statement without touching that code | Not measurable at all without either owning the code or wrapping/proxying its output some other way |

**"How many transcript downloads happened"** is a counting question over an event some component
already logs (or could trivially be made to log) — a metric filter is the right tool: it is free
to evaluate, needs no code change if the log line already exists, and survives even if the
component is someone else's. **"How long the render took"** needs a *value*, not a count, measured
at the one point in the code that actually knows the duration — the render function itself starts
and stops a timer that nothing outside that function can observe after the fact from a log line
alone (unless the code is changed to print the duration, at which point a metric filter extracting
it, as Exercise 1 does, becomes possible too, but only because the code was changed first). The
answers differ because one question is about *frequency of an observable event* and the other is
about *a value only the instrumented code itself possesses* — exactly the distinction Exercise 1's
own closing paragraph reaches independently, comparing `TranscriptSecondsFromLogs` against
`TranscriptLagSeconds`.

**3. `usms-transcript-lag-high` treats missing data as `notBreaching` and `usms-notify-silence` as
`breaching`. Explain why each setting would be wrong on the other alarm, describe one incident the
second catches and the first cannot, and say what the dashboard would have looked like during it.**

Swapping the two would break both. `usms-transcript-lag-high` with `breaching` missing data would
page someone every single night the transcript pipeline is correctly idle — Step 19's own stated
reasoning for choosing `notBreaching` on this alarm specifically. `usms-notify-silence` with
`notBreaching` missing data would mean the one scenario the alarm exists to catch — the pipeline
going completely silent — produces *no alarm at all*, because "no data" would be read as "nothing
wrong" rather than "the thing I am watching for has stopped happening."

**The incident `usms-notify-silence` catches that `usms-transcript-lag-high` structurally cannot:**
the notifier's S3 trigger silently stops firing — a misconfigured bucket notification, a detached
event source mapping, anything that means the function simply never runs again. `TranscriptLag
Seconds` never receives another data point, ever, because the code path that would publish it
never executes. A threshold alarm on a value that never arrives again sits exactly where it last
was (`OK`, if the pipeline was healthy when it stopped) **forever**, because there is nothing for
"greater than 2 seconds" to evaluate against — the predicate is simply never asked the question
again. `usms-notify-silence`, watching `NotifyCount` with `breaching` missing data, is the only one
of the two that treats "no data for 15 minutes" as itself the signal, which is exactly what this
incident produces.

**What the dashboard would have shown:** on `usms-overview`, the "Transcripts processed, by
faculty" and latency time-series widgets would both render as flat, empty lines — not red, not a
spike, simply nothing — which Lab 13's own real experience during this lab confirms is genuinely
ambiguous at a glance (Section 1 of the registrar's complaints in Exercise 4 is this exact
scenario, not a hypothetical). The one widget that would actually read as wrong is the single-value
"Notifications in the last 5 minutes" widget, pinned at a literal `0` — a fact a viewer reads
immediately, unlike an empty chart a viewer has to notice is empty rather than merely "not yet
populated." The alarm widget would show `usms-transcript-lag-high` still `OK` (correctly, and
uselessly) and `usms-notify-silence` moving to `ALARM`, dragging the composite with it — which this
lab's own real Step 21 narrative reproduces almost exactly, caused honestly by the Lambda-invoke
defect rather than staged for the exercise.

**4. Distinguish a metric dimension from an X-Ray annotation: what each is indexed for, what
happens as distinct values grow, and what you can ask of each. Then place each of these, with a
sentence of justification: the transcript's faculty; the student's id; the origin's HTTP status;
the name of the renderer that produced the PDF.**

A **dimension** is indexed to define a *separate, independently-billed metric series* — Step 11's
own framing: namespace + name + the complete dimension set is the metric's identity, and every new
distinct combination is a new billed series, which is why cardinality is a direct cost concern. An
**annotation** is indexed for *search across traces* — `get-trace-summaries --filter-expression`
can find every trace where `annotation.faculty = "science"` — but it never creates a new billed
object merely by existing; the cost model is entirely different, and so is the question each
answers: a dimension lets you *aggregate* ("how many transcripts, broken down by faculty, in the
last hour"); an annotation lets you *find* ("show me every trace of a specific, individual slow or
failed request matching this criterion"). Neither can safely hold unbounded-cardinality data for
its own reason: a dimension because unbounded cardinality becomes unbounded metric billing; an
annotation less because of direct cost and more because an index over a near-unique value (like a
student id) stops being a useful *search* tool — searching for exactly one trace by its own unique
id is not a filter, it is a lookup, and a trace id already serves that purpose.

- **Faculty** — a **dimension**: small (~8), the exact shape Step 11 recommends, and the natural
  axis to aggregate transcript counts and latency by.
- **Student id** — an **annotation**, never a dimension: Step 11's own cardinality warning names
  this exact field as the wrong kind of dimension value (~30,000 distinct values); as an
  annotation it supports "find this one student's slow trace" without creating 30,000 billed
  metric series.
- **The origin's HTTP status** — neither, strictly: it belongs in the segment's own `http.response
  .status` field (Step 16), which X-Ray classifies into `ok`/`error`/`fault`/`throttle` natively;
  duplicating it as an annotation would only be useful if you specifically wanted to *search* by
  status code across many traces, which is a real but secondary use, not the field's primary home.
- **The renderer's name** — **metadata**, not an annotation: it is useful context when looking at
  one specific trace (Step 16's own `render-pdf` subsegment carries exactly this in its
  `metadata.usms.renderer` field) but there is no realistic need to *search* across every trace for
  "which ones used wkhtmltopdf" — it almost never varies, so indexing it for search buys nothing.

**5. Step 13 published version 2 and repointed an alias; Step 14 published version 3 for only a
configuration change. Why did that change need its own version, and what would have happened if
you changed `TracingConfig` and left the alias on version 2? Relate it to Lab 10 Step 11's claim
that a version freezes code and configuration.**

Lab 10 Step 11's claim is that a *version* is an immutable snapshot of **both** code and
configuration together, not code alone — publishing a version freezes whatever
`TracingConfig`, environment variables, and code `$LATEST` held at that instant. Step 14's active-
tracing change is a configuration-only edit, but it still has to land on a *new* version, because
version 2 was already published (frozen) with `TracingConfig: PassThrough` the moment Step 13
called `publish-version` — editing `$LATEST`'s tracing mode afterward does not retroactively change
what version 2 is defined to be. **If the alias had been left on version 2** after turning on
active tracing at `$LATEST`, the alias — and therefore every real trigger (S3 notifications,
direct invokes) — would keep running version 2's frozen configuration, i.e. `PassThrough` tracing,
while `$LATEST` quietly diverged to `Active`. The function would behave as if tracing were still
off for every real invocation, with no error anywhere to indicate the mismatch — exactly the
"partial traces with nothing visibly wrong" failure mode Step 14's own text warns about, produced
here by an alias pointed at a stale version rather than by getting the tracing mode itself backwards.

**6. Step 20 forced an alarm into `ALARM`. What does that prove and not prove? What would an
equivalent test prove on real AWS that it cannot here, and why test what happens after an alarm
fires even when confident in the threshold? Relate it to the rule that a command appearing to
succeed is not evidence it did what you meant.**

`set-alarm-state` proves the alarm is **addressable and records history** — the call succeeded,
`describe-alarms` reflected the new state, and `describe-alarm-history` recorded a real
`StateUpdate` entry with the exact reason text given. It does **not**, by itself, prove the
*threshold* is correctly tuned, because the state was forced, not reached by the metric genuinely
crossing 2 seconds. This lab's own experience went one step further than the brief's expected
result and accidentally demonstrated the limit of what forcing a state proves: nine seconds after
the forced `ALARM`, this build's live evaluator transitioned the alarm back to `OK` on its own,
because the real metric was not actually breaching — a forced state is provisional, overwritable by
reality the instant real evaluation runs again, which is itself evidence that `set-alarm-state`
tests *wiring*, not *correctness of the threshold*.

**What an equivalent test would prove on real AWS that it cannot here:** on real AWS, forcing
`ALARM` would additionally test the alarm's **configured actions** — whether an SNS notification
actually fires, whether a subscribed Lambda or Auto Scaling action actually triggers — because
`--alarm-actions` are genuinely invoked on a real state transition, forced or not. This lab's
alarms have no actions attached yet (Exercise 5's draft is explicitly unapplied), so there is
nothing downstream to observe even if actions existed and this build evaluated them, which Section
11's limitation notes it does not.

**Why test what happens after an alarm fires even when confident in the threshold:** because the
threshold is only half the mechanism — the other half is "and then something actually happens,"
and that half has its own failure modes entirely independent of whether 2 seconds is the right
number (a missing SNS subscription, a Lambda permission error, a wrong topic ARN). This is a direct
instance of the rule that **a command appearing to succeed is not evidence it did what you meant**:
`put-metric-alarm` returning nothing (success) only proves the alarm *object* was created correctly,
not that the *system of alarm plus action* behaves as intended end to end — exactly the same gap
Lab 12's report named between "the pipeline reported Succeeded" and "the exact thing that should
have happened, happened." The only way to close that gap is the same one this lab used throughout:
a real create → perturb → read-back cycle through an independent API, which is what `set-alarm-
state` plus `describe-alarm-history` actually is, one level up from the metric data itself.

## Key takeaways

- **Verify by reading back through a third, independent API, never by trusting the call that
  configured the thing.** The single most repeated pattern in this lab — proving a filter with
  `get-metric-statistics`, proving an alarm with `describe-alarm-history`, proving a dashboard with
  `get-dashboard` plus a structural Python check — is the same discipline every time, and it is
  what caught the JMESPath `||`-binding bug in the lab's own example query (`labs/lab-13-
  monitoring/README.md`, Section 2): a `--output text` convenience query looked wrong, a direct
  `--output json` read-back showed the real data was fine all along.
- **A platform's documented limitations are a hypothesis for this specific build, not a given.**
  X-Ray and Insights were exactly as documented (entirely absent); alarm and metric-filter
  evaluation was the opposite of documented (genuinely live, not merely stored) — both facts had to
  be established by direct, repeated observation, not assumed from either the brief's text or from
  what "Floci Limitation" boxes generically warn about.
- **A broken invocation path can cascade into a broken control plane**, and the only way to notice
  that boundary is to keep testing with the smallest, cheapest call available (a `--description`
  update) before trusting a larger one (a full code deploy) again after a recovery.
