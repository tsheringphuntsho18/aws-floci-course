#!/usr/bin/env bash
# Lab 13 Exercise 3: for every alarm whose name begins usms-, report its
# configuration plus the observed min/avg/max/sample-count of its metric
# over the last 24 hours, and whether the threshold was ever breached.
# Valid JSON on stdout and nothing else; diagnostics go to stderr.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env" >&2

python3 << 'PY'
import json
import subprocess
import sys


def aws(*args):
    out = subprocess.run(["aws", *args], capture_output=True, text=True)
    if out.returncode != 0:
        print("aws %s failed: %s" % (" ".join(args), out.stderr.strip()), file=sys.stderr)
        return None
    return out.stdout


def aws_json(*args):
    raw = aws(*args, "--output", "json")
    return json.loads(raw) if raw else None


def window_24h():
    now_out = aws("logs", "describe-log-groups", "--limit", "1")  # noqa: F841 - not timing-critical
    import datetime
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    start = now - datetime.timedelta(hours=24)
    return start.strftime("%Y-%m-%dT%H:%M:%SZ"), now.strftime("%Y-%m-%dT%H:%M:%SZ")


names_raw = aws("cloudwatch", "describe-alarms",
                 "--query", "MetricAlarms[].AlarmName", "--output", "text")
metric_names = [n for n in (names_raw or "").split() if n.startswith("usms-")]

composite_raw = aws("cloudwatch", "describe-alarms", "--alarm-types", "CompositeAlarm",
                     "--query", "CompositeAlarms[].AlarmName", "--output", "text")
composite_names = [n for n in (composite_raw or "").split() if n.startswith("usms-")]

start, end = window_24h()
report = []

for name in metric_names:
    doc = aws_json("cloudwatch", "describe-alarms", "--alarm-names", name)
    alarm = doc["MetricAlarms"][0]

    dims = ["Name=%s,Value=%s" % (d["Name"], d["Value"]) for d in alarm.get("Dimensions", [])]
    stats_args = [
        "cloudwatch", "get-metric-statistics",
        "--namespace", alarm["Namespace"],
        "--metric-name", alarm["MetricName"],
        "--start-time", start, "--end-time", end,
        "--period", "3600",
        "--statistics", "Minimum", "Average", "Maximum", "SampleCount",
    ]
    if dims:
        stats_args += ["--dimensions"] + dims
    stats = aws_json(*stats_args) or {"Datapoints": []}
    points = stats.get("Datapoints", [])

    if points:
        observed = {
            "min": min(p["Minimum"] for p in points),
            "avg": round(sum(p["Average"] for p in points) / len(points), 4),
            "max": max(p["Maximum"] for p in points),
            "samples": int(sum(p["SampleCount"] for p in points)),
        }
    else:
        observed = {"min": None, "avg": None, "max": None, "samples": 0}

    op = alarm["ComparisonOperator"]
    threshold = alarm["Threshold"]
    breached = False
    if observed["max"] is not None:
        if op in ("GreaterThanThreshold", "GreaterThanOrEqualToThreshold"):
            breached = observed["max"] > threshold if op == "GreaterThanThreshold" else observed["max"] >= threshold
        elif op in ("LessThanThreshold", "LessThanOrEqualToThreshold"):
            breached = observed["min"] < threshold if op == "LessThanThreshold" else observed["min"] <= threshold

    report.append({
        "alarm": name,
        "namespace": alarm["Namespace"],
        "metric": alarm["MetricName"],
        "statistic": alarm["Statistic"],
        "period": alarm["Period"],
        "evaluation_periods": alarm["EvaluationPeriods"],
        "datapoints_to_alarm": alarm.get("DatapointsToAlarm", alarm["EvaluationPeriods"]),
        "threshold": threshold,
        "operator": op,
        "missing_data": alarm.get("TreatMissingData", "missing"),
        "observed": observed,
        "threshold_ever_breached": breached,
    })

for name in composite_names:
    doc = aws_json("cloudwatch", "describe-alarms", "--alarm-names", name, "--alarm-types", "CompositeAlarm")
    alarm = doc["CompositeAlarms"][0]
    report.append({
        "alarm": name,
        "namespace": None,
        "metric": None,
        "statistic": None,
        "period": None,
        "evaluation_periods": None,
        "datapoints_to_alarm": None,
        "threshold": None,
        "operator": alarm.get("AlarmRule"),
        "missing_data": None,
        "observed": None,
        "threshold_ever_breached": None,
    })

print(json.dumps(report, indent=2, sort_keys=True))
PY
