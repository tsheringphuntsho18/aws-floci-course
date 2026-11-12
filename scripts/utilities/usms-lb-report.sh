#!/usr/bin/env bash
# usms-lb-report.sh - print the decision table of every ALB whose name starts with usms-
#
# For each load balancer: scheme, type, state, AZ count, SG count; for each listener its
# rules in EVALUATION order (default last) and, for forward actions, the target group with
# its target / healthy counts. Also writes outputs/lab-05-lb-report.json.
#
# Read-only. No arguments. Works from any directory.
#
# Why set -uo pipefail WITHOUT -e: this is a reporting tool that walks four levels of
# API calls. One failed call (a listener deleted mid-walk, an empty target group, an
# unsupported describe on an emulator build) must degrade to a "-" in one row, not kill
# the whole report. Every call below is guarded with `|| echo <fallback>` instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
export AWS_PAGER=""
OUT_JSON="$REPO_ROOT/outputs/lab-05-lb-report.json"

PREFIX="usms-"   # the only name this script knows

# Level 1 - load balancers, filtered by prefix in JMESPath (there is no --name-prefix flag)
LBS=$(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?starts_with(LoadBalancerName, '$PREFIX')]" --output json 2>/dev/null || echo '[]')

REPORT='[]'
for LB_ARN in $(jq -r '.[].LoadBalancerArn' <<< "$LBS"); do
  LB=$(jq --arg a "$LB_ARN" '.[] | select(.LoadBalancerArn==$a)
        | {name: .LoadBalancerName, arn: .LoadBalancerArn, scheme: .Scheme, type: .Type,
           state: .State.Code, azs: (.AvailabilityZones | length), sgs: ((.SecurityGroups // []) | length),
           listeners: []}' <<< "$LBS")

  # Level 2 - listeners (none is a valid state: the LB then answers nothing)
  LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" \
                --query 'Listeners' --output json 2>/dev/null || echo '[]')
  for L_ARN in $(jq -r 'sort_by(.Port)[].ListenerArn' <<< "$LISTENERS"); do
    L=$(jq --arg a "$L_ARN" '.[] | select(.ListenerArn==$a) | {protocol: .Protocol, port: .Port, rules: []}' <<< "$LISTENERS")

    # Level 3 - rules. Priority is a STRING ("10", "20") and the default rule's is the
    # literal "default", so a plain sort would order "10" < "2" < "default" lexically.
    # Map "default" to a number larger than the 50000 maximum and the rest to numbers.
    RULES=$(aws elbv2 describe-rules --listener-arn "$L_ARN" --query 'Rules' --output json 2>/dev/null || echo '[]')
    RULES=$(jq 'sort_by(if .Priority == "default" then 999999 else (.Priority | tonumber) end)' <<< "$RULES")

    for idx in $(jq -r 'keys[]' <<< "$RULES"); do
      R=$(jq ".[$idx]" <<< "$RULES")
      ACTION=$(jq -r '.Actions[0].Type // "-"' <<< "$R")
      TG_ARN=$(jq -r '.Actions[0].TargetGroupArn // (.Actions[0].ForwardConfig.TargetGroups[0].TargetGroupArn) // empty' <<< "$R")
      TG_JSON='null'
      if [ -n "$TG_ARN" ]; then
        # Level 4 - target health; an empty target group is a normal, reportable state
        TOTAL=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
                  --query 'length(TargetHealthDescriptions)' --output text 2>/dev/null || echo 0)
        HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
                  --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text 2>/dev/null || echo 0)
        TG_JSON=$(jq -n --arg arn "$TG_ARN" --argjson t "${TOTAL:-0}" --argjson h "${HEALTHY:-0}" \
                    '{name: ($arn | sub(".*:targetgroup/"; "") | sub("/.*"; "")), arn: $arn, targets: $t, healthy: $h}')
      fi
      ROW=$(jq --argjson tg "$TG_JSON" --arg action "$ACTION" '{
              priority: .Priority,
              condition: ((.Conditions[0].Field) // "-"),
              values: ((.Conditions[0].PathPatternConfig.Values // .Conditions[0].Values // []) ),
              action: $action,
              fixed_status: (.Actions[0].FixedResponseConfig.StatusCode // null),
              redirect: (if .Actions[0].RedirectConfig then (.Actions[0].RedirectConfig.StatusCode + " " + (.Actions[0].RedirectConfig.Protocol // "#{protocol}") + "://" + (.Actions[0].RedirectConfig.Host // "#{host}")) else null end),
              target_group: $tg }' <<< "$R")
      L=$(jq --argjson row "$ROW" '.rules += [$row]' <<< "$L")
    done
    LB=$(jq --argjson l "$L" '.listeners += [$l]' <<< "$LB")
  done
  REPORT=$(jq --argjson lb "$LB" '. += [$lb]' <<< "$REPORT")
done

mkdir -p "$(dirname "$OUT_JSON")"
jq --arg at "$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')" \
   '{generated_at: $at, load_balancers: .}' <<< "$REPORT" > "$OUT_JSON"

# Presentation in python3: column alignment and per-action summaries are clearer there.
python3 -I - "$OUT_JSON" << 'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
lbs = doc["load_balancers"]
if not lbs:
    print("no load balancer whose name starts with usms- was found")
for lb in lbs:
    print(f'{lb["name"]:<20} {lb["scheme"]:<16} {lb["type"]:<12} {lb["state"]:<7} AZs={lb["azs"]}  SGs={lb["sgs"]}')
    if not lb["listeners"]:
        print("  (no listeners - this load balancer refuses every connection)")
    for l in lb["listeners"]:
        print(f'  {l["protocol"]}:{l["port"]}')
        if not l["rules"]:
            print("    (no rules returned)")
        for r in l["rules"]:
            vals = ",".join(r["values"]) if r["values"] else "-"
            cond = r["condition"] if r["priority"] != "default" else "-"
            a = r["action"]
            if a == "forward" and r["target_group"]:
                tg = r["target_group"]
                summary = f'{tg["name"]:<18} ({tg["targets"]} targets, {tg["healthy"]} healthy)'
            elif a == "fixed-response":
                summary = f'fixed-response {r["fixed_status"]}'
            elif a == "redirect":
                summary = f'redirect {r["redirect"]}'
            else:
                summary = a
            print(f'    prio  {r["priority"]:<8} {cond:<13} {vals:<27} -> {summary}')
PY
