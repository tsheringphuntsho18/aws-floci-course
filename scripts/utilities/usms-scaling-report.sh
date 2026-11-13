#!/usr/bin/env bash
# Report every scalable target in the ecs namespace whose resource ID names a
# cluster beginning usms-, with a decision table and a computed verdict.
# No arguments. Read-only: this script inspects and changes nothing.
#
# set -uo pipefail, deliberately WITHOUT -e: this is a reporting tool walking
# several levels of API calls (targets -> policies -> alarms -> scheduled
# actions -> ECS), and one failed call (e.g. describe-scheduled-actions
# returning UnsupportedOperation on this build) should degrade that one row
# to "unsupported on this build", not abort the whole report.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true

OUT_JSON="$REPO_ROOT/outputs/lab-06-scaling-report.json"

TARGETS_JSON=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --query "ScalableTargets[?contains(ResourceId, 'usms-')]" --output json 2>/dev/null || echo "[]")

python3 - "$TARGETS_JSON" "$OUT_JSON" << 'PY'
import json, subprocess, sys

targets = json.loads(sys.argv[1])
out_path = sys.argv[2]

def aws(*args):
    try:
        r = subprocess.run(["aws"] + list(args), capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        return r.stdout.strip()
    except Exception:
        return None

def aws_json(*args):
    out = aws(*args, "--output", "json")
    if out is None or out == "":
        return None
    try:
        return json.loads(out)
    except Exception:
        return None

report = []

for t in targets:
    rid = t["ResourceId"]
    dim = t["ScalableDimension"]
    min_c = t.get("MinCapacity")
    max_c = t.get("MaxCapacity")
    susp = t.get("SuspendedState", {}) or {}

    # ECS desired/running, if this is an ECS service target
    desired = running = None
    parts = rid.split("/")
    if parts[0] == "service" and len(parts) == 3:
        cluster, service = parts[1], parts[2]
        svc = aws_json("ecs", "describe-services", "--cluster", cluster, "--services", service)
        if svc and svc.get("services"):
            desired = svc["services"][0].get("desiredCount")
            running = svc["services"][0].get("runningCount")

    policies = aws_json("application-autoscaling", "describe-scaling-policies",
                         "--service-namespace", "ecs", "--resource-id", rid) or {}
    policies = policies.get("ScalingPolicies", [])

    scheduled = aws_json("application-autoscaling", "describe-scheduled-actions",
                          "--service-namespace", "ecs", "--resource-id", rid)
    scheduled_supported = scheduled is not None
    scheduled_actions = (scheduled or {}).get("ScheduledActions", []) if scheduled_supported else []

    activities = aws_json("application-autoscaling", "describe-scaling-activities",
                           "--service-namespace", "ecs", "--resource-id", rid, "--max-items", "1")
    activities_supported = activities is not None
    last_activity = None
    if activities_supported and activities.get("ScalingActivities"):
        a = activities["ScalingActivities"][0]
        last_activity = {"start": a.get("StartTime"), "cause": a.get("Cause")}

    # Verdict, evaluated top to bottom: each rule only fires if every rule
    # above it did not. PINNED first because it is a configuration fact that
    # makes every other label meaningless (nothing can move either way).
    # FROZEN outranks AT-CEILING deliberately: a target sitting at MaxCapacity
    # with DynamicScalingOutSuspended=true is not "fine because it's already
    # at the top" - the frozen switch is the operationally dangerous fact
    # (nobody can scale it out further if demand rises, AND nobody can scale
    # it in either if suspended for scale-in), so it must be surfaced even
    # though the number happens to equal the ceiling. Reporting AT-CEILING
    # instead would hide the suspension from a reader who only reads verdicts.
    verdict = "ELASTIC"
    if min_c is not None and max_c is not None and min_c == max_c:
        verdict = "PINNED"
    elif any(bool(v) for v in susp.values()):
        verdict = "FROZEN"
    elif desired is not None and max_c is not None and desired == max_c:
        verdict = "AT-CEILING"
    elif desired is not None and min_c is not None and desired == min_c and len(policies) > 1:
        verdict = "AT-FLOOR"

    pol_rows = []
    for p in policies:
        name = p["PolicyName"]
        ptype = p["PolicyType"]
        alarm_names = [a.get("AlarmName") for a in p.get("Alarms", [])]
        alarm_states = {}
        if alarm_names:
            desc = aws_json("cloudwatch", "describe-alarms", "--alarm-names", *alarm_names)
            for a in (desc or {}).get("MetricAlarms", []):
                label = "AlarmHigh" if "AlarmHigh" in a["AlarmName"] else (
                        "AlarmLow" if "AlarmLow" in a["AlarmName"] else a["AlarmName"])
                alarm_states[label] = a["StateValue"]
        elif ptype == "StepScaling":
            # Floci does not back-populate a step policy's own Alarms list (a
            # documented limitation), so find the alarm the other way: any
            # CloudWatch alarm whose AlarmActions names this policy's ARN.
            policy_arn = p.get("PolicyARN", "")
            all_alarms = aws_json("cloudwatch", "describe-alarms") or {}
            for a in all_alarms.get("MetricAlarms", []):
                if policy_arn and policy_arn in a.get("AlarmActions", []):
                    alarm_states[a["AlarmName"]] = a["StateValue"]
        if ptype == "TargetTrackingScaling":
            cfg = p.get("TargetTrackingScalingPolicyConfiguration", {})
            metric = cfg.get("PredefinedMetricSpecification", {}).get("PredefinedMetricType")
            pol_rows.append({
                "name": name, "type": "target-track", "metric": metric,
                "target": cfg.get("TargetValue"),
                "out": cfg.get("ScaleOutCooldown"), "in": cfg.get("ScaleInCooldown"),
                "disableScaleIn": cfg.get("DisableScaleIn"),
                "alarms": alarm_states,
            })
        elif ptype == "StepScaling":
            cfg = p.get("StepScalingPolicyConfiguration", {})
            steps = cfg.get("StepAdjustments", [])
            signed = "/".join(f"{s['ScalingAdjustment']:+d}" for s in steps)
            pol_rows.append({
                "name": name, "type": "step", "steps": signed,
                "cooldown": cfg.get("Cooldown"),
                "alarms": alarm_states,
            })

    sched_rows = [{
        "name": s["ScheduledActionName"], "schedule": s.get("Schedule"),
        "timezone": s.get("Timezone"),
        "min": s.get("ScalableTargetAction", {}).get("MinCapacity"),
        "max": s.get("ScalableTargetAction", {}).get("MaxCapacity"),
    } for s in scheduled_actions]

    entry = {
        "resourceId": rid, "dimension": dim, "min": min_c, "max": max_c,
        "desired": desired, "running": running, "suspended": susp,
        "verdict": verdict, "policies": pol_rows,
        "scheduledActionsSupported": scheduled_supported, "scheduledActions": sched_rows,
        "scalingActivitiesSupported": activities_supported, "lastActivity": last_activity,
    }
    report.append(entry)

    # print the text table
    print(f"{rid}   {dim}")
    bounds = f"min={min_c}  max={max_c}   desired={desired}   running={running}   {verdict}"
    print(f"  bounds       {bounds}")
    susp_on = [k for k, v in susp.items() if v]
    print(f"  suspended    {', '.join(susp_on) if susp_on else 'none'}")
    for p in pol_rows:
        if p["type"] == "target-track":
            alarms_str = "  ".join(f"{k.rsplit('-',1)[-2] if '-' in k else k}={v}" for k, v in p["alarms"].items()) or "none"
            print(f"  target-track {p['name']:<40} {p['metric']}/{p['target']}   out={p['out']}  in={p['in']}")
            print(f"                 alarms  {alarms_str}")
        else:
            alarms_str = "  ".join(f"{k}={v}" for k, v in p["alarms"].items()) or "none"
            print(f"  step         {p['name']:<40} {p['steps']}   cooldown={p['cooldown']}")
            print(f"                 alarm   {alarms_str}")
    if scheduled_supported:
        for s in sched_rows:
            print(f"  scheduled    {s['name']:<32} {s['schedule']}  {s['timezone']}  min={s['min']}")
        if not sched_rows:
            print("  scheduled    none")
    else:
        print("  scheduled    unsupported on this build (UnsupportedOperation)")
    if activities_supported:
        if last_activity:
            print(f"  last activity  {last_activity['start']}  {last_activity['cause']}")
        else:
            print("  last activity  none recorded")
    else:
        print("  last activity  describe-scaling-activities unsupported on this build")
    print()

with open(out_path, "w") as f:
    json.dump({"generated": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "targets": report}, f, indent=2)
PY

echo "written: $OUT_JSON ($(wc -c < "$OUT_JSON") bytes)"
