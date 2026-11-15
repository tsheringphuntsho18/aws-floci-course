#!/usr/bin/env bash
# END OF COURSE ONLY. Reverses Lab 09, dependencies first.
# Order: detach and delete roles -> delete policies -> restore the rules this lab changed.
# Run FIRST of the teardown scripts. See Lab 09 Section 8.2.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-09.env"

cat <<'WARN'
============================================================
  This DELETES the Lab 09 roles and policies, and RESTORES
  the allow-all egress rule on three security groups plus
  the 10.0.0.0/16 SSH rule on usms-app-sg.

  It does NOT undo the access key rotation (the old key is
  gone and cannot come back) and it does NOT undo the IMDSv2
  requirement, because neither of those should ever be undone.

  Run this FIRST, before lab-06-cleanup.sh.
============================================================
WARN

read -r -p 'Type exactly: UNDO USMS SECURITY REVIEW  > ' answer
[ "$answer" = "UNDO USMS SECURITY REVIEW" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "detach policies from the Lab 09 roles"
for r in usms-deploy-role usms-transcripts-reader-role; do
  for p in $(aws iam list-attached-role-policies --role-name "$r" \
               --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$p" || true
  done
done

say "restore usms-ecs-task-role's original (unconditioned) trust policy"
if [ -f outputs/lab-09-ecs-task-role-trust-before.json ]; then
  aws iam update-assume-role-policy --role-name "$USMS_ECS_TASK_ROLE" \
    --policy-document file://outputs/lab-09-ecs-task-role-trust-before.json || true
else
  echo "no saved before-trust document found - skipping the task role trust restore"
fi

say "delete the Lab 09 roles"
for r in usms-deploy-role usms-transcripts-reader-role; do
  aws iam delete-role --role-name "$r" || true
done

say "delete the Lab 09 customer managed policies"
for p in USMSStudentDataReadOnly USMSDeployBase USMSPermissionsBoundary; do
  arn=$(aws iam list-policies --scope Local \
          --query "Policies[?PolicyName=='$p'].Arn | [0]" --output text 2>/dev/null)
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then
    aws iam delete-policy --policy-arn "$arn" || true
  fi
done

say "restore the allow-all egress rule on three security groups"
for g in "$USMS_ALB_SG" "$USMS_ENROLMENT_SG" "$USMS_DB_SG"; do
  aws ec2 authorize-security-group-egress \
    --group-id "$g" \
    --ip-permissions file://policies/usms-egress-allow-all.json || true
done

say "restore the usms-app-sg SSH rule to 10.0.0.0/16"
aws ec2 authorize-security-group-ingress \
  --group-id "$USMS_APP_SG" --protocol tcp --port 22 --cidr 10.0.0.0/16 || true

say "delete usms-bastion-sg"
aws ec2 delete-security-group --group-id "$USMS_BASTION_SG" || true

echo
echo "Lab 09 reversed. Access key rotation and IMDSv2 were left in place deliberately."
