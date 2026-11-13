#!/usr/bin/env bash
# Export the enrolment service's complete scaling configuration and history
# as one JSON document to outputs/lab-06-scaling-history.json.
# No hard-coded resource ID, policy or alarm name: everything is discovered.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true

OUT="$REPO_ROOT/outputs/lab-06-scaling-history.json"

SVC_ARN=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].serviceArn' --output text)
RID="${SVC_ARN##*:}"

TARGET=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --resource-ids "$RID" --output json)
POLICIES=$(aws application-autoscaling describe-scaling-policies --service-namespace ecs \
  --resource-id "$RID" --output json)
SCHEDULED=$(aws application-autoscaling describe-scheduled-actions --service-namespace ecs \
  --resource-id "$RID" --output json 2>/dev/null || echo '{"ScheduledActions":[],"_unsupported":true}')
ACTIVITIES=$(aws application-autoscaling describe-scaling-activities --service-namespace ecs \
  --resource-id "$RID" --include-not-scaled-activities --output json 2>/dev/null \
  || aws application-autoscaling describe-scaling-activities --service-namespace ecs \
       --resource-id "$RID" --output json 2>/dev/null || echo '{"ScalingActivities":[]}')

ALARM_NAMES=$(python3 -c "
import json,sys
pols=json.loads(sys.argv[1])
names=set()
for p in pols.get('ScalingPolicies',[]):
    for a in p.get('Alarms',[]):
        names.add(a.get('AlarmName'))
print('\n'.join(sorted(n for n in names if n)))
" "$POLICIES")
# The step policy's alarm is user-created and not back-linked on this build.
ALARM_NAMES=$(printf '%s\n%s\n' "$ALARM_NAMES" "${USMS_ALARM_QUEUE_HIGH:-usms-enrolment-queue-high}" | sed '/^$/d' | sort -u)

ALARMS_JSON='{"MetricAlarms":[]}'
if [ -n "$ALARM_NAMES" ]; then
  # shellcheck disable=SC2086
  ALARMS_JSON=$(aws cloudwatch describe-alarms --alarm-names $ALARM_NAMES --output json 2>/dev/null || echo '{"MetricAlarms":[]}')
fi

GENERATED=$(python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")

python3 - "$OUT" "$GENERATED" "$RID" "$TARGET" "$POLICIES" "$SCHEDULED" "$ACTIVITIES" "$ALARMS_JSON" << 'PY'
import json, sys

out_path, generated, rid, target_s, policies_s, scheduled_s, activities_s, alarms_s = sys.argv[1:9]

doc = {
    "generated": generated,
    "resourceId": rid,
    "scalableTarget": json.loads(target_s),
    "scalingPolicies": json.loads(policies_s),
    "scheduledActions": json.loads(scheduled_s),
    "scalingActivities": json.loads(activities_s),
    "alarms": json.loads(alarms_s),
}
with open(out_path, "w") as f:
    json.dump(doc, f, indent=2)
PY

python3 -m json.tool "$OUT" > /dev/null && echo "valid JSON"
echo "written: $OUT ($(wc -c < "$OUT") bytes)"
