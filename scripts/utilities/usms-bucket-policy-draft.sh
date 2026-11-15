#!/usr/bin/env bash
# Draft the bucket policy the (still unwritten) S3 configuration lab will apply
# to usms-student-data once Lab 10 creates it. An identity policy is never
# consulted for another account's principal; a resource policy on the bucket
# always is - this is that resource policy, drafted, not applied.
#
# Read-only against AWS: it reads the identity inventory and the three
# transcripts policies, and only WRITES a local draft file. Applying it is
# the S3 configuration lab's job, not this script's.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true

INVENTORY="${1:-outputs/lab-09-identity-inventory.json}"
if [ ! -f "$INVENTORY" ]; then
  echo "no inventory at $INVENTORY - run Lab 09 Step 4 part 2 first" >&2
  exit 2
fi

# Derive the bucket name from a policy document, not by typing it: Lab 1's
# USMSStudentDataReadWrite names the bucket in its Resource ARNs, and that ARN
# is the one source of truth this script is willing to trust.
RW_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)
RW_VER=$(aws iam get-policy --policy-arn "$RW_ARN" --query 'Policy.DefaultVersionId' --output text)
RW_DOC=$(aws iam get-policy-version --policy-arn "$RW_ARN" --version-id "$RW_VER" \
  --query 'PolicyVersion.Document' --output json)

# A shell parameter expansion, not python, for this one extraction: the bucket
# name is the only thing this script needs before it can even call AWS again
# for the other two policies, and `${VAR#prefix}`/`${VAR%suffix}` trims the
# fixed "arn:aws:s3:::" prefix and the "/*" suffix without invoking an
# interpreter just to strip two literal substrings.
BUCKET_ARN=$(echo "$RW_DOC" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['Statement'][0]['Resource'])")
BUCKET_NAME="${BUCKET_ARN#arn:aws:s3:::}"
BUCKET_NAME="${BUCKET_NAME%/*}"
echo "bucket name, derived from USMSStudentDataReadWrite: $BUCKET_NAME"

python3 - "$INVENTORY" "$BUCKET_NAME" "$USMS_ACCOUNT_ID" outputs/lab-09-bucket-policy-draft.json << 'PY'
import json, sys

inventory_path, bucket, account_id, out_path = sys.argv[1:5]

def as_list(x):
    if x is None:
        return []
    return x if isinstance(x, list) else [x]

roles = json.load(open(inventory_path))

# Every role ARN granted any s3: action on the bucket, with exactly the
# actions it already has - never a wider grant than the identity policy gives.
principals = {}
for r in roles:
    docs = [p.get("document") for p in r.get("attachedPolicies", [])]
    docs += [p.get("document") for p in r.get("inlinePolicies", [])]
    actions = set()
    for doc in docs:
        if not doc:
            continue
        for st in as_list(doc.get("Statement")):
            if st.get("Effect") != "Allow":
                continue
            res = as_list(st.get("Resource"))
            if not any(bucket in x for x in res if isinstance(x, str)):
                continue
            for a in as_list(st.get("Action")):
                if a.startswith("s3:"):
                    actions.add(a)
    if actions:
        principals[r["arn"]] = sorted(actions)

bucket_arn = f"arn:aws:s3:::{bucket}"
bucket_arn_objects = f"arn:aws:s3:::{bucket}/*"
root_arn = f"arn:aws:iam::{account_id}:root"
allowed_principals = sorted(principals) + [root_arn]

statements = []

for arn, actions in sorted(principals.items()):
    statements.append({
        "Sid": f"AllowExactlyWhatThisRoleAlreadyHas-{arn.split('/')[-1]}",
        "Effect": "Allow",
        "Principal": {"AWS": arn},
        "Action": actions,
        "Resource": [bucket_arn, bucket_arn_objects],
    })

statements.append({
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [bucket_arn, bucket_arn_objects],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}},
})

statements.append({
    "Sid": "DenyEveryPrincipalNotOnTheList",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [bucket_arn, bucket_arn_objects],
    "Condition": {"StringNotLike": {"aws:PrincipalArn": allowed_principals}},
})

doc = {"Version": "2012-10-17", "Statement": statements}
with open(out_path, "w") as f:
    json.dump(doc, f, indent=2)

print(f"{len(principals)} principal(s) granted bucket access, {len(statements)} statements written")
for arn, actions in sorted(principals.items()):
    print(f"  {arn}  ->  {','.join(actions)}")
PY

python3 -m json.tool outputs/lab-09-bucket-policy-draft.json > /dev/null && echo "valid JSON"

echo
echo "== mechanical checks =="
python3 - << 'PY'
import json
d = json.load(open("outputs/lab-09-bucket-policy-draft.json"))
sts = d["Statement"]
ok = True
for s in sts:
    princ = s.get("Principal")
    if s["Sid"] == "DenyInsecureTransport":
        if princ != "*":
            print("FAIL: DenyInsecureTransport must use Principal \"*\""); ok = False
        continue
    if s["Sid"] == "DenyEveryPrincipalNotOnTheList":
        if princ != "*":
            print("FAIL: DenyEveryPrincipalNotOnTheList must use Principal \"*\""); ok = False
        continue
    if isinstance(princ, dict) and princ.get("AWS") == "*":
        print(f"FAIL: {s['Sid']} uses Principal \"*\" where an ARN was required"); ok = False
    elif not (isinstance(princ, dict) and isinstance(princ.get("AWS"), str) and princ["AWS"].startswith("arn:")):
        print(f"FAIL: {s['Sid']} does not carry a Principal.AWS ARN"); ok = False

has_both = any(
    any(r.endswith("/*") for r in (s["Resource"] if isinstance(s["Resource"], list) else [s["Resource"]]))
    and any(not r.endswith("/*") for r in (s["Resource"] if isinstance(s["Resource"], list) else [s["Resource"]]))
    for s in sts
)
print("every Allow Principal is an ARN (except the two Deny-all-by-condition statements):", ok)
print("the bucket ARN appears WITH and WITHOUT /*:", has_both)
PY
