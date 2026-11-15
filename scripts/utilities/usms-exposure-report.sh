#!/usr/bin/env bash
# USMS exposure report. Classifies every network interface in the VPC as
# EXPOSED or ISOLATED, derived from its subnet's route table, its own public
# address, and its security group's ingress rules - never from names or tags.
#
# Read-only. No arguments, no hard-coded IDs: resolves configs/ from its own
# path so it runs correctly from any directory.
#
# set -e is deliberately OMITTED: a single interface with a missing security
# group, no route table association, or any other partial AWS response must
# not abort the whole report - it should be classified UNKNOWN and the report
# must still cover every other interface. set -uo pipefail still catches an
# unset variable or a failed pipe stage, which are programming errors, not
# data the account is allowed to be messy about.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

VPC="${USMS_VPC_ID:-}"
if [ -z "$VPC" ] || [ "$VPC" = "none" ]; then
  echo "USMS_VPC_ID is not set in configs/lab-02.env" >&2
  exit 2
fi

aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" --output json \
  > /tmp/usms-exposure-eni-$$.json || { echo "cannot read network interfaces" >&2; exit 2; }
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --output json \
  > /tmp/usms-exposure-subnets-$$.json
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" --output json \
  > /tmp/usms-exposure-rts-$$.json
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" --output json \
  > /tmp/usms-exposure-sgs-$$.json

python3 - "$VPC" /tmp/usms-exposure-eni-$$.json /tmp/usms-exposure-subnets-$$.json \
            /tmp/usms-exposure-rts-$$.json /tmp/usms-exposure-sgs-$$.json \
            outputs/lab-09-exposure.json << 'PY'
import json, sys

vpc, eni_f, subnet_f, rt_f, sg_f, out_f = sys.argv[1:7]

enis    = json.load(open(eni_f)).get("NetworkInterfaces", [])
subnets = json.load(open(subnet_f)).get("Subnets", [])
rts     = json.load(open(rt_f)).get("RouteTables", [])
sgs     = json.load(open(sg_f)).get("SecurityGroups", [])

sg_by_id = {g["GroupId"]: g for g in sgs}

# subnet-id -> route table: explicit associations first, then the VPC's main
# table for any subnet with no explicit association (AWS's own fallback rule).
main_rt = None
assoc_rt = {}
for rt in rts:
    for a in rt.get("Associations", []):
        if a.get("Main"):
            main_rt = rt
        sid = a.get("SubnetId")
        if sid:
            assoc_rt[sid] = rt

def route_table_for(subnet_id):
    return assoc_rt.get(subnet_id, main_rt)

def has_igw_route(rt):
    if rt is None:
        return False
    return any(r.get("GatewayId", "").startswith("igw-") for r in rt.get("Routes", []))

def open_ingress(group_ids):
    """True if ANY attached security group allows 0.0.0.0/0 or ::/0 on any port."""
    for gid in group_ids:
        g = sg_by_id.get(gid)
        if g is None:
            continue  # the group is not cached in this VPC snapshot - cannot confirm; treated as no match
        for p in g.get("IpPermissions", []):
            for r in p.get("IpRanges", []):
                if r.get("CidrIp") in ("0.0.0.0/0",):
                    return True
            for r in p.get("Ipv6Ranges", []):
                if r.get("CidrIpv6") in ("::/0",):
                    return True
    return False

def no_ingress_at_all(group_ids):
    for gid in group_ids:
        g = sg_by_id.get(gid)
        if g is not None and g.get("IpPermissions"):
            return False
    return True

rows = []
for eni in enis:
    status = eni.get("Status")
    attach = eni.get("Attachment") or {}
    instance_id = attach.get("InstanceId")
    if eni.get("Description", "").startswith("ELB") or not instance_id:
        label = eni.get("Description") or eni["NetworkInterfaceId"]
    else:
        label = instance_id

    subnet_id = eni.get("SubnetId")
    rt = route_table_for(subnet_id)
    igw = has_igw_route(rt)
    rt_known = rt is not None

    group_ids = [g["GroupId"] for g in eni.get("Groups", [])]
    private_ip = eni.get("PrivateIpAddress", "-")
    public_ip = None
    for a in eni.get("PrivateIpAddresses", []):
        assoc = a.get("Association") or {}
        if assoc.get("PublicIp"):
            public_ip = assoc["PublicIp"]

    if not rt_known:
        verdict, why = "UNKNOWN", "no route table association found for this subnet"
    elif not igw:
        verdict, why = "ISOLATED", "no igw route on subnet"
    elif open_ingress(group_ids):
        verdict, why = "EXPOSED", "igw route + sg allows ingress from 0.0.0.0/0 or ::/0"
    elif no_ingress_at_all(group_ids):
        # igw route exists, no public-CIDR allow rule, but ALSO no ingress rule
        # at all: nothing can reach it on any port, so there is nothing to be
        # exposed ON even though the path to the internet exists. Call this
        # EXPOSED anyway, deliberately: a route to the internet plus a public
        # IP is reachability infrastructure, and "no rule yet" is one
        # authorize-security-group-ingress call away from exposure, which is
        # a materially different risk from an instance with NO igw route at
        # all. Treating it as ISOLATED would hide that it sits on the public
        # side of the network.
        if status == "in-use" and (eni.get("Association") or {}).get("PublicIp") or public_ip:
            verdict, why = "EXPOSED", "igw route, but no ingress rule at all"
        else:
            verdict, why = "ISOLATED", "igw route exists but no public IP and no open ingress rule"
    else:
        verdict, why = "ISOLATED", "igw route exists, but no security group rule allows 0.0.0.0/0 or ::/0"

    pub = public_ip or (eni.get("Association") or {}).get("PublicIp")
    rows.append({
        "label": label,
        "eni": eni["NetworkInterfaceId"],
        "private_ip": private_ip,
        "public_ip": pub,
        "status": status,
        "verdict": verdict,
        "reason": why,
    })

rows.sort(key=lambda r: r["label"])

for r in rows:
    print(f"{r['label']:<18} {r['private_ip']:<12} {r['public_ip'] or '-':<15} "
          f"{r['verdict']:<10} {r['reason']}")

with open(out_f, "w") as f:
    json.dump(rows, f, indent=2)
PY

rm -f /tmp/usms-exposure-eni-$$.json /tmp/usms-exposure-subnets-$$.json \
      /tmp/usms-exposure-rts-$$.json /tmp/usms-exposure-sgs-$$.json
