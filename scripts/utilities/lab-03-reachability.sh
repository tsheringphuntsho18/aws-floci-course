#!/usr/bin/env bash
# Classify every running USMS instance by COMPUTED reachability from the internet.
# set -e is deliberately omitted: one failed lookup must not abort the report for the others.
set -uo pipefail
[ -n "${COURSE_ROOT:-}" ] && [ -f "$COURSE_ROOT/configs/course.env" ] && source "$COURSE_ROOT/configs/course.env"

rows=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,SubnetId,PrivateIpAddress,PublicIpAddress,SecurityGroups[0].GroupId]' \
  --output text)

printf '%-16s %-12s %-16s %-14s %s\n' NAME PRIVATE PUBLIC VERDICT REASON
while read -r id name subnet priv pub sg; do
  [ -z "${id:-}" ] && continue
  [ "${pub:-None}" = "None" ] && pubshow="-" || pubshow="$pub"

  igw=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnet" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
        --output text 2>/dev/null || echo None)
  case "$igw" in igw-*) has_igw=1 ;; *) has_igw=0 ;; esac

  open80=$(aws ec2 describe-security-groups --group-ids "$sg" \
        --query 'length(SecurityGroups[0].IpPermissions[?FromPort<=`80` && ToPort>=`80` && IpRanges[?CidrIp==`0.0.0.0/0`]])' \
        --output text 2>/dev/null || echo 0)
  [ "$open80" = "None" ] && open80=0

  if   [ "$has_igw" -eq 0 ];                       then v=UNREACHABLE; r="no igw route on subnet"
  elif [ "$pubshow" = "-" ];                       then v=NO-ADDRESS;  r="igw route present but no public address"
  elif [ "$open80" -gt 0 ] 2>/dev/null;            then v=REACHABLE;   r="igw route + sg allows 80/tcp from 0.0.0.0/0"
  else                                                  v=BLOCKED;     r="igw route + address, but sg does not allow 80/tcp from 0.0.0.0/0"
  fi
  printf '%-16s %-12s %-16s %-14s %s\n' "$name" "$priv" "$pubshow" "$v" "$r"
done <<< "$rows"
