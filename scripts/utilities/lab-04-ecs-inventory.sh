#!/usr/bin/env bash
# Lab 04 Exercise 3 - ECS configuration drift report for usms-ecs-cluster.
# For every service in the cluster prints one line:
#   <service>  desired=N  running=N  taskdef=<family>:<rev>  roles=SAME|SEPARATE  publicip=OK|RISK|N/A
# and writes the same data as JSON to outputs/lab-04-ecs-inventory.json.
# Read-only. Safe to run at any time, from any directory.
#
# Why no "set -e": this is a report, not a build. One service whose task
# definition cannot be described (deregistered, typo, emulator gap) must not
# abort the whole report and hide every other service. Each AWS call is
# checked explicitly instead, and a failed lookup prints an explicit verdict
# (N/A / UNKNOWN) rather than an empty field. -u and pipefail stay on so an
# unset variable or a failing pipeline is still caught.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true

CLUSTER="${USMS_ECS_CLUSTER:-usms-ecs-cluster}"
OUT_DIR="$REPO_ROOT/outputs"
OUT_JSON="$OUT_DIR/lab-04-ecs-inventory.json"
mkdir -p "$OUT_DIR"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

# 1. List services from the cluster - no hard-coded names.
if ! service_arns=$(aws ecs list-services --cluster "$CLUSTER" \
                      --query 'serviceArns[]' --output text 2>/dev/null); then
  echo "could not list services in cluster $CLUSTER" >&2
  exit 1
fi

if [ -z "$service_arns" ] || [ "$service_arns" = "None" ]; then
  echo "no services in cluster $CLUSTER"
  echo '[]' > "$OUT_JSON"
  exit 0
fi

rows='[]'

for arn in $service_arns; do
  svc_json=$(aws ecs describe-services --cluster "$CLUSTER" --services "$arn" \
               --query 'services[0]' --output json 2>/dev/null) || svc_json='null'

  if [ -z "$svc_json" ] || [ "$svc_json" = "null" ]; then
    name="${arn##*/}"
    printf '%-22s ERROR: describe-services returned nothing\n' "$name"
    rows=$(jq --arg n "$name" '. + [{service:$n, error:"describe-services failed"}]' <<<"$rows")
    continue
  fi

  name=$(jq -r '.serviceName // "UNKNOWN"' <<<"$svc_json")
  desired=$(jq -r '.desiredCount // "N/A"' <<<"$svc_json")
  running=$(jq -r '.runningCount // "N/A"' <<<"$svc_json")
  td_arn=$(jq -r '.taskDefinition // empty' <<<"$svc_json")

  # publicip: computed from assignPublicIp. No networkConfiguration at all
  # (EC2 launch type, bridge mode) -> N/A instead of an error.
  has_awsvpc=$(jq -r 'if .networkConfiguration.awsvpcConfiguration then "yes" else "no" end' <<<"$svc_json")
  assign=$(jq -r '.networkConfiguration.awsvpcConfiguration.assignPublicIp // empty' <<<"$svc_json")
  if [ "$has_awsvpc" = "no" ]; then
    publicip="N/A"
  elif [ "$assign" = "ENABLED" ]; then
    publicip="RISK"
  else
    # DISABLED, or absent (the API default for awsvpc is DISABLED)
    publicip="OK"
  fi

  # roles + taskdef: computed from the task definition the service points at.
  taskdef="N/A"; roles="N/A"; exec_arn=""; task_arn=""
  if [ -n "$td_arn" ]; then
    taskdef="${td_arn##*/}"   # family:revision
    if td_json=$(aws ecs describe-task-definition --task-definition "$td_arn" \
                   --query 'taskDefinition' --output json 2>/dev/null) \
       && [ "$td_json" != "null" ]; then
      exec_arn=$(jq -r '.executionRoleArn // empty' <<<"$td_json")
      task_arn=$(jq -r '.taskRoleArn // empty' <<<"$td_json")
      if [ -z "$exec_arn" ] && [ -z "$task_arn" ]; then
        roles="NONE"
      elif [ -z "$exec_arn" ] || [ -z "$task_arn" ]; then
        roles="PARTIAL"
      elif [ "$exec_arn" = "$task_arn" ]; then
        roles="SAME"
      else
        roles="SEPARATE"
      fi
    else
      roles="UNKNOWN"
    fi
  fi

  printf '%-22s desired=%-3s running=%-3s taskdef=%-20s roles=%-9s publicip=%s\n' \
    "$name" "$desired" "$running" "$taskdef" "$roles" "$publicip"

  rows=$(jq --arg n "$name" --arg d "$desired" --arg r "$running" --arg t "$taskdef" \
            --arg ro "$roles" --arg p "$publicip" --arg e "$exec_arn" --arg tr "$task_arn" \
            '. + [{service:$n, desired:$d, running:$r, taskdef:$t, roles:$ro, publicip:$p,
                   executionRoleArn:$e, taskRoleArn:$tr}]' <<<"$rows")
done

jq --arg c "$CLUSTER" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '{cluster:$c, generatedAt:$at, services:.}' <<<"$rows" > "$OUT_JSON"
echo
echo "JSON written to ${OUT_JSON#$REPO_ROOT/}"