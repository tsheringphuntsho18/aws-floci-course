#!/usr/bin/env bash
# usms-resource-label.sh [LB_NAME] [TG_NAME]
#
# Prints the ResourceLabel that Application Auto Scaling's ALBRequestCountPerTarget
# predefined metric needs:
#     app/<lb-name>/<lb-id>/targetgroup/<tg-name>/<tg-id>
# derived from the ELBv2 API every time - never from a hard-coded identifier and never
# from configs/lab-05.env. Defaults to Lab 05's two objects. Exit 1 if the result is
# not plausible. Read-only. Contains, reads and references no access key.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"     # profile + endpoint only; no ARNs are read from configs/
export AWS_PAGER=""

LB_NAME="${1:-usms-enrolment-alb}"
TG_NAME="${2:-usms-enrolment-tg}"

die() { echo "usms-resource-label: $*" >&2; exit 1; }

LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB_NAME" \
           --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null) || die "load balancer $LB_NAME not found"
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
           --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) || die "target group $TG_NAME not found"

# The two suffixes need DIFFERENT treatment:
#   LB ARN  arn:aws:elasticloadbalancing:<region>:<acct>:loadbalancer/app/<name>/<id>
#           -> the label wants "app/<name>/<id>": the resource-type word "loadbalancer/"
#              must be DROPPED, so strip the shortest prefix ending in ":loadbalancer/".
#   TG ARN  arn:aws:elasticloadbalancing:<region>:<acct>:targetgroup/<name>/<id>
#           -> the label wants "targetgroup/<name>/<id>": the resource-type word must be
#              KEPT, so strip only up to the last ":" (the ARN's resource field).
LB_SUFFIX="${LB_ARN#*:loadbalancer/}"
TG_SUFFIX="${TG_ARN##*:}"
LABEL="${LB_SUFFIX}/${TG_SUFFIX}"

# Plausibility: both names present, exactly six slash-separated segments, first is "app"
IFS='/' read -r -a SEG <<< "$LABEL"
[ "${#SEG[@]}" -eq 6 ]              || die "expected 6 segments, got ${#SEG[@]}: $LABEL"
[ "${SEG[0]}" = "app" ]             || die "first segment is '${SEG[0]}', not 'app' (is $LB_NAME an ALB?)"
[ "${SEG[1]}" = "$LB_NAME" ]        || die "segment 2 is not the load balancer name: $LABEL"
[ "${SEG[3]}" = "targetgroup" ]     || die "segment 4 is not 'targetgroup': $LABEL"
[ "${SEG[4]}" = "$TG_NAME" ]        || die "segment 5 is not the target group name: $LABEL"

echo "$LABEL"
