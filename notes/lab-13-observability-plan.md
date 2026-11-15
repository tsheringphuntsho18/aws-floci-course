# USMS Observability Plan — response to the registrar's office

Written for Lab 13 Exercise 4. No commands; this is a design document, cross-checked against
what Lab 13's own implementation actually built and actually proved on this Floci build.

## 1. The four complaints, each assigned to the right layer

**"Nobody noticed for six hours that transcripts had stopped being delivered — the dashboard
was all green because the graphs were empty."** This is a **metrics** problem with no log or
trace fix. A dashboard graphing `NotifyCount` over time shows an empty line during an outage —
not a red line, an *absent* one — because a line chart with no data points renders as "nothing
happened here," indistinguishable from "nothing happened here because everything is fine." Logs
cannot fix this either: `filter-log-events` on an empty window also returns nothing, and nothing
is not an alert, it's a null result a human has to think to go looking for. The only layer that
can turn "nothing happened" into an active signal is a metric **alarm configured to treat missing
data as breaching** — exactly `usms-notify-silence` (Step 19), built for this specific failure
mode. Traces are irrelevant here: there is no trace to analyse when nothing ran.

**"We could not tell whether it was the upload, the function, or the bucket."** This is a
**traces** problem, and specifically a service-graph problem, not a logs-and-greps-harder
problem. A log line from the function says what the function did; it says nothing about whether
S3 delivered the event in the first place, or how long the S3 call inside the function took
relative to everything else. The trace layer this lab built (Steps 15–17) is designed exactly for
this: `usms-student-data` and `usms-transcript-notifier` as two segments of one trace, joined by
`trace_id`, with the S3 call as a `namespace: aws` subsegment carrying its own `http.response.status`
— so a fault localises to one segment or one subsegment, not to "somewhere in the pipeline."
Metrics cannot answer "which component," because a metric has no causal structure between
services; it is a number, not a call graph.

**"The audit office asked who had downloaded a particular transcript in March and we could not
answer, because the logs were gone."** This is a **logs retention** problem, not a metrics or
traces problem — metrics and traces answer "is it healthy" and "where did this one request go,"
neither of which is "who did this, and can I still prove it eight months later." Section 2 below
proposes the retention tier this specific complaint needs.

**"Our AWS bill for monitoring is now larger than our bill for the thing being monitored."** This
is a **cardinality and retention cost** problem across all three layers at once, addressed
directly in Section 5.

## 2. Log group taxonomy and retention

| Log group | Holds | Retention | Who may read it | Why that number |
|---|---|---|---|---|
| `/usms/central/application` | structured `USMS_EVENT` lines from any compute tier | 30 days | platform team, on-call | long enough to debug "what happened last month," short enough that storage cost stays trivial — this is Lab 13's own number (Step 6), chosen for exactly this reason |
| `/aws/lambda/usms-transcript-notifier` | one function's runtime stdout/stderr | 14 days | platform team | debugging noise (`START`/`END`/`REPORT` lines); if nobody looked in two weeks, nobody will — Lab 13's own number |
| `/usms/ecs/enrolment` | the enrolment service's container stdout | 30 days | platform team | same class of data as the central group, same answer |
| `/usms/audit/transcript-access` *(new, this plan)* | one line per transcript **read** (who, which student's record, when, from which IP) — written by the enrolment service at the point of access, not derived from infrastructure logs | **400 days** | **compliance officer and registrar only, via a separate IAM role with no write access** | the March audit question needs a retention window that outlives a single academic year's grievance/appeal cycle; 400 is the nearest valid CloudWatch retention value above 365 (the valid set is 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, ... — there is no "13 months," so 400 is the honest nearest step up from one year, not a round number chosen for its own sake) |

The audit group is the one Section 1's third complaint needs and nothing else in this table
provides: 14- and 30-day groups answer "what happened recently," and an audit question about
March needs a group nobody is incentivised to shorten for cost reasons, which is also why it gets
restricted read access rather than being folded into the 30-day central group everyone already
reads.

## 3. Three service level indicators

| SLI | Definition | Target | Alarm or graph only? |
|---|---|---|---|
| Transcript notification latency | `TranscriptLagSeconds`, Maximum, per 60s | < 2s for 2 of any 3 consecutive minutes | **Alarm** — `usms-transcript-lag-high`, already built (Step 19) |
| Pipeline liveness | `NotifyCount`, Sum, per 300s | ≥ 1 notification per 5-minute window during business hours | **Alarm** — `usms-notify-silence`, treat-missing-data=breaching |
| Transcript rejection rate | `CentralErrorCount` ÷ (`CentralErrorCount` + `NotifyCount`), per hour | < 2% of attempts | **Graph only** |

Why an SLI a student would actually notice, not "CPU utilisation": the first two are literally
what a student waiting for their transcript experiences — "did it arrive, and how fast" — and the
third is what a registrar reviewing a batch run would ask. CPU utilisation is a *cause* a platform
engineer investigates after one of these three already told them something is wrong; it is never
the thing a stakeholder outside the platform team would ask about directly, so it does not belong
on this list at all, alarmed or not.

**Why the rejection-rate SLI is graphed but not alarmed, and why that is not waste:** an
un-alarmed SLI still answers two questions an alarm cannot: "is this number drifting upward over
weeks," which a single-point alarm threshold never detects because gradual drift never crosses a
fixed line fast enough to trigger `evaluation-periods`/`datapoints-to-alarm` in the way Step 19's
alarms are tuned; and "when the *other* two alarms fire, was it preceded by rising rejections,"
which is exactly the kind of correlation a human looks for during an incident review and which
only exists if someone was graphing it the whole time. An alarm answers "should someone be paged
right now"; a graph answers "what should the next design review talk about" — alarming everything
either produces alarm fatigue (thresholds chosen arbitrarily just to have *a* number) or, worse,
a false sense that anything un-alarmed is unmonitored, when un-alarmed and ungraphed are very
different states.

## 4. Which alarm catches the six-hour outage, and why the other kind structurally cannot

Of the three alarms this lab built, **`usms-notify-silence`** (missing-data=breaching) is the one
that would have caught the described six-hour outage; **`usms-transcript-lag-high`**
(missing-data=notBreaching) could not have, by construction, not by bad luck. A threshold alarm on
a *value* — `usms-transcript-lag-high` watches `TranscriptLagSeconds` for "too high" — has no
opinion about a metric that stops reporting altogether; `notBreaching` for missing data is the
correct choice for that alarm specifically *because* at 3am with zero transcripts being processed,
zero data points is the expected, healthy state, and an alarm that breached on silence there would
page someone every night for nothing (Step 19's own stated reasoning). The structural reason a
threshold-on-value alarm cannot catch an outage of silence is that "greater than 2 seconds" and
"the metric does not exist right now" are two different predicates over two different domains —
one is defined over real numbers, the other over the presence or absence of a time series — and
no choice of threshold closes that gap, only a deliberate `--treat-missing-data breaching` choice
on a *different* alarm does, which is the entire justification for building `usms-notify-silence`
as a second, separate alarm rather than tuning the first one harder.

During that six-hour window, the dashboard this lab built (`usms-overview`) would have shown: the
"Transcripts processed, by faculty" time series flat/empty, the latency chart also empty (no data,
not a spike — exactly the "all green because the graphs were empty" trap the registrar described),
the alarm widget showing `usms-transcript-pipeline-down` in ALARM (driven by `usms-notify-silence`,
with `usms-transcript-lag-high` still OK), and the single-value "Notifications in the last 5
minutes" widget pinned at zero — which is the one widget on this dashboard that a glance would
actually catch, because a single-value widget showing "0" reads as a fact, where an empty line
chart reads as "no data yet," which is precisely the ambiguity Section 1 point 1 is about.

## 5. Where the monitoring bill goes, and the cardinality of every proposed dimension

Order-of-magnitude breakdown for USMS's actual telemetry footprint (not real AWS pricing figures,
since this is Floci and has no real bill — estimated from AWS's published CloudWatch pricing model
applied to this lab's own metric and alarm count):

- **Custom metrics** (`USMS/Application`'s five metrics plus this plan's rejection-rate ratio,
  each multiplied by its dimension cardinality) — the single largest line item, because AWS
  bills per metric *per unique dimension combination*, not per metric name.
- **Alarms** (currently 3; this plan adds none) — a small, flat per-alarm cost, negligible next
  to metric cardinality at USMS's scale.
- **Logs Insights query cost** (billed per GB scanned per query) — currently zero on this Floci
  build because Insights is unsupported here (Step 4's probe), but on real AWS this is the
  second-largest likely line item if Insights became the default way to answer "how many" instead
  of a metric filter, because every ad-hoc query re-scans the whole window instead of reading one
  pre-aggregated number.
- **Log storage** (retention × volume) — smallest of the four at USMS's current volume, because
  log ingestion/storage is cheap per GB compared to per-metric-series billing, until retention
  windows (this plan's 400-day audit group) start multiplying it.

**The two changes with the largest effect:** (1) never derive a dimension from a per-student or
per-request identifier — Step 11's own warning, restated here because it is the actual cost
driver: `Faculty` has roughly eight values and is safe; `StudentId` has on the order of 30,000
values and would turn one metric into 30,000 billed metrics, which dwarfs every other line above
combined. (2) answer "how many of X happened" with a metric filter (evaluated once at ingestion,
billed only for the resulting metric) rather than a routine, repeated Logs Insights query
(billed per scan, every single time someone runs it) — Step 9's filters already follow this rule;
the discipline is to keep following it rather than reaching for Insights out of habit once it is
available.

**Cardinality of every dimension this plan proposes or that Lab 13 already published:**

| Dimension | Approx. cardinality | Safe? |
|---|---|---|
| `Faculty` (TranscriptsProcessed, EdgeDenyCount) | ~8 (USMS's faculty count) | yes |
| `Stage` (TranscriptLagSeconds, TranscriptsProcessed) | ~3 (`notify`, `render`, `viewer-request`) | yes |
| none (NotifyCount, CentralErrorCount — the filter-produced metrics) | 1 | yes, trivially |
| *(rejected)* `StudentId` as a dimension | ~30,000 | **no** — this is why the audit trail lives in the new log group instead, not in a metric |

## 6. One thing not to build yet, and the observation that would change that

**Not building yet: a per-faculty breakdown of the rejection-rate SLI as its own alarm (eight
separate alarms, one per faculty).** The composite-alarm pattern this lab already proved
(`usms-transcript-pipeline-down`, Step 21) makes this cheap to add mechanically, but eight
threshold alarms on a metric this plan currently only graphs is exactly the alarm-fatigue risk
Section 3 warns against, before there is any evidence any single faculty's rejection rate behaves
differently from the aggregate.

**The observation that would change this decision:** if the graphed, aggregate rejection-rate SLI
is ever seen to mask a problem concentrated in one faculty — for example, an aggregate rate under
2% that is actually 0% for seven faculties and 14% for one, discovered only by someone manually
slicing the graph after a complaint — that is the concrete trigger to split it into a
per-faculty metric (cardinality 8, still well inside the "safe" row of Section 5's table) and
alarm on the worst-performing faculty specifically, rather than the aggregate. Until that
observation exists, building the eight-way split is optimising for a failure mode that has not
yet been shown to occur, which is the same mistake Section 1's dashboard-is-green complaint
describes in miniature: building something that looks like coverage without evidence it would
catch the thing it is meant to catch.
