# Independent Lab Exercises

## Exercise 1 – Basic: a maintenance instance

```bash
ADMIN_ID=$(aws ec2 run-instances \
  --image-id "$USMS_BASE_AMI" \
  --instance-type t3.micro \
  --key-name usms-app-key \
  --subnet-id "$USMS_PUBLIC_SUBNET_B" \
  --security-group-ids "$USMS_APP_SG" \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=usms-admin-01-host},{Key=Project,Value=USMS},{Key=Tier,Value=admin},{Key=Lab,Value=03},{Key=Ephemeral,Value=true}]' \
    'ResourceType=volume,Tags=[{Key=Name,Value=usms-admin-01-root},{Key=Project,Value=USMS}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids "$ADMIN_ID"

aws ec2 describe-instances --filters "Name=tag:Tier,Values=admin" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,AZ:Placement.AvailabilityZone,Profile:IamInstanceProfile.Arn}' \
  --output table
```

Expected: exactly one running instance in `us-east-1b`, with no instance profile. Do not add it to `configs/lab-03.env`; Exercise 4 removes it. (`$USMS_BASE_AMI` is saved in `lab-03.env`; use `$AMI_ID` if you have not sourced it.)

## Exercise 2 – Intermediate: a self-describing bootstrap

`labs/lab-03-ec2/user-data-db.sh`:

```bash
cat > labs/lab-03-ec2/user-data-db.sh << 'EOF'
#!/bin/bash
# USMS data tier bootstrap. Runs as root via cloud-init. Idempotent: exits if already done.
MARKER=/var/log/usms-db-bootstrap.done
[ -f "$MARKER" ] && { echo "already bootstrapped"; exit 0; }
exec > /var/log/usms-db-bootstrap.log 2>&1
set -x

PKG=$(command -v dnf || command -v yum)
$PKG -y install postgresql-server

postgresql-setup --initdb || /usr/bin/postgresql-setup initdb
systemctl enable --now postgresql
sudo -u postgres createdb usms

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
echo "$IID $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
EOF
bash -n labs/lab-03-ec2/user-data-db.sh && wc -c labs/lab-03-ec2/user-data-db.sh
```

Launch `usms-db-02` and prove the stored copy matches:

```bash
DB02_ID=$(aws ec2 run-instances --image-id "$USMS_BASE_AMI" --instance-type t3.micro \
  --key-name usms-app-key --subnet-id "$USMS_PRIVATE_SUBNET_B" --security-group-ids "$USMS_DB_SG" \
  --user-data file://labs/lab-03-ec2/user-data-db.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-db-02},{Key=Project,Value=USMS},{Key=Tier,Value=data},{Key=Lab,Value=03}]' \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "$DB02_ID"

aws ec2 describe-instance-attribute --instance-id "$DB02_ID" --attribute userData \
  --query 'UserData.Value' --output text > outputs/lab-03-userdata-db.b64
openssl base64 -d -A -in outputs/lab-03-userdata-db.b64 -out outputs/lab-03-userdata-db.sh
diff labs/lab-03-ec2/user-data-db.sh outputs/lab-03-userdata-db.sh && echo "USER DATA PROVEN"
```

**Why the outer heredoc is quoted:** the `$(date ...)`, `$MARKER` and `$IID` expressions must be evaluated on the instance at boot, not by my laptop's shell when the file is written; an unquoted heredoc would bake my laptop's values into the script (or empty strings).

**When can a re-run actually happen?** User data runs once per instance, so a normal reboot will not re-run it. It can run again when a new instance is launched from an AMI captured from an already-bootstrapped instance, because cloud-init sees a new instance ID. Here the marker file in the AMI makes the script exit early instead of re-initialising a database. It can also re-run if someone runs `cloud-init clean`, or if the script is placed in a per-boot hook.

## Exercise 3 – Problem solving: a reachability report

`scripts/utilities/lab-03-reachability.sh`:

```bash
cat > scripts/utilities/lab-03-reachability.sh << 'EOF'
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
EOF
chmod +x scripts/utilities/lab-03-reachability.sh
bash -n scripts/utilities/lab-03-reachability.sh && echo "syntax OK"

# Prove it runs from any directory
(cd ~ && ~/aws-floci-course/scripts/utilities/lab-03-reachability.sh)
(cd ~/aws-floci-course/labs/lab-03-ec2 && ../../scripts/utilities/lab-03-reachability.sh)
```

Expected: identical output from both directories, with `usms-web-01` REACHABLE, `usms-db-01` UNREACHABLE, and any instance in a public subnet without an address NO-ADDRESS. A subnet with no explicit route table association uses the main route table, which has no `0.0.0.0/0` route, so it is correctly classified UNREACHABLE. The verdict uses only the route table, public address and security group, never names or tags.

## Exercise 4 – Challenge: right-size and clean up

**Analysis (adapt with your own numbers).**

*Scale up or out.* The load is mostly reads, with a midday peak and idle nights, and it currently runs on one `t3.micro` at 85% CPU. Scaling up (a larger single instance) is simple but leaves a single point of failure and still pays for the larger size overnight. Scaling out (two or more small instances behind a load balancer, later in an Auto Scaling group) handles read-heavy traffic, survives the loss of one instance or AZ, and allows scale-in overnight, which is the only option that reduces the idle cost. I would scale out, and use the golden AMI as the launch template image.

*Burstable credits.* A `t3.micro` has 2 vCPUs and a baseline of 20% CPU per vCPU. It earns CPU credits below the baseline and spends them above it. Sustained 85% will drain the credit balance. In `standard` mode the instance is then throttled to the baseline, so users get slow responses; in `unlimited` mode (the default for `t3`) it keeps running at full speed but accrues surplus-credit charges. Check which mode applies with:

```bash
aws ec2 describe-instance-credit-specifications --instance-ids "$USMS_WEB_INSTANCE"
```

*Cost comparison (us-east-1, Linux on-demand; verify against the AWS EC2 On-Demand Pricing page and cite the date you checked):*

| Option | Monthly (≈730 h) | Notes |
|---|---|---|
| 1 × t3.micro (today) | ≈ $7.60 | Overheated at peak; surplus credits extra if unlimited |
| 1 × t3.small | ≈ $15.20 | Higher baseline; still one instance, always on |
| 2 × t3.micro + ALB | ≈ $15 + load balancer (≈ $16+) | Resilient; scale in overnight to cut instance cost |
| t3.small, stopped 12 h/day | ≈ $7.60 | Cheap, but the portal is down while stopped |

Prices above are from my recollection of the AWS pricing page (t3.micro $0.0104/h, t3.small $0.0208/h) and must be re-checked; the lab itself quotes ≈ $7.50/month for a `t3.micro`, $0.64 per 8 GiB gp3 volume and $3.60 for an unassociated Elastic IP.

**What I would delete today.** The Exercise 1 admin host and any orphaned volumes or unassociated Elastic IPs. Do not touch anything in the KEEP column of Section 15, and do not release `usms-nat-eip` from Lab 2 even if Floci shows it without an association.

> **Danger – terminate `usms-admin-01-host`**
> **What will be deleted:** the admin instance and its root volume.
> **What depends on it:** nothing; it was created for Exercise 1 only.
> **Reversible?** No, termination is permanent.
> **Effect on later labs:** none.

```bash
ADMIN_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=usms-admin-01-host" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
echo "$ADMIN_ID"          # confirm it starts with i- and is the admin host before continuing
aws ec2 terminate-instances --instance-ids "$ADMIN_ID"
aws ec2 wait instance-terminated --instance-ids "$ADMIN_ID" || sleep 10
```

> **Danger – delete orphaned volumes**
> **What will be deleted:** EBS volumes with status `available` (attached to nothing).
> **What depends on it:** nothing, provided `usms-web-data-vol` is attached (it is not `available`).
> **Reversible?** No, unless a snapshot exists.
> **Effect on later labs:** none, but list first and never delete `usms-web-data-vol`.

```bash
aws ec2 describe-volumes --filters "Name=status,Values=available" \
  --query 'Volumes[].{Id:VolumeId,Name:Tags[?Key==`Name`]|[0].Value,Size:Size}' --output table
# delete only the ones you recognise as test leftovers:
# aws ec2 delete-volume --volume-id <vol-id>
```

> **Danger – release unassociated Elastic IPs**
> **What will be deleted:** the listed Elastic IP allocation.
> **What depends on it:** anything pointing at that address.
> **Reversible?** No, you cannot get the same address back.
> **Effect on later labs:** none for the web EIP and NAT EIP, which must stay.

```bash
aws ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].{Name:Tags[?Key==`Name`]|[0].Value,Alloc:AllocationId,IP:PublicIp}' --output table
# release only a leftover test address, never usms-web-eip or usms-nat-eip:
# aws ec2 release-address --allocation-id <eipalloc-id>
```

Afterwards run `./scripts/utilities/verify-lab-03.sh` and confirm `FAIL=0`.

## Exercise 5 – Integration: prepare the S3 hand-off for Lab 4

**1. `labs/lab-03-ec2/transcript-upload.sh`** (runs on `usms-web-01`; no credentials):

```bash
cat > labs/lab-03-ec2/transcript-upload.sh << 'EOF'
#!/usr/bin/env bash
# Upload a student's transcript to S3. Uses the instance profile; no keys are read or stored.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <student-id> <file-path>" >&2
  exit 2
fi
STUDENT_ID=$1
FILE=$2
[ -f "$FILE" ] || { echo "error: file not found: $FILE" >&2; exit 1; }

aws s3 cp "$FILE" "s3://usms-student-data/transcripts/${STUDENT_ID}/$(basename "$FILE")"
EOF
chmod +x labs/lab-03-ec2/transcript-upload.sh
bash -n labs/lab-03-ec2/transcript-upload.sh && grep -Ei 'AKIA|secret|access_key' labs/lab-03-ec2/transcript-upload.sh || echo "no credentials referenced"
```

**2. No TCP 443 inbound rule is needed.** The S3 call is an outbound connection from the instance, and security groups are stateful, so the replies are allowed automatically. The only rule that matters is the default allow-all outbound rule that every security group gets at creation, which I never wrote, and it is what permits the instance to reach S3 on 443. Confirm:

```bash
aws ec2 describe-security-groups --group-ids "$USMS_APP_SG" \
  --query 'SecurityGroups[0].IpPermissionsEgress[].{Proto:IpProtocol,CIDR:IpRanges[0].CidrIp}' --output table
```

**3. `outputs/lab-03-s3-readiness.txt`:**

```bash
ROLE=$(aws iam get-instance-profile --instance-profile-name "$USMS_INSTANCE_PROFILE" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)

# Capture the real exit code right after the command ("|| true" would hide it).
aws s3api head-bucket --bucket usms-student-data > outputs/lab-03-headbucket.txt 2>&1
HB_EXIT=$?

{
  echo "instance:        $USMS_WEB_INSTANCE"
  echo "profile arn:     $(aws ec2 describe-instances --instance-ids "$USMS_WEB_INSTANCE" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)"
  echo "role:            $ROLE"
  echo "policy:          USMSStudentDataReadWrite"
  echo "bucket ARNs:     $(jq -r '.Statement[].Resource | if type=="array" then .[] else . end' outputs/lab-03-instance-policy.json | grep s3 | sort -u | tr '\n' ' ')"
  echo "head-bucket exit code: $HB_EXIT"
  echo "head-bucket output:"
  cat outputs/lab-03-headbucket.txt
} | tee outputs/lab-03-s3-readiness.txt
```

Expected: a 404 / `NoSuchBucket` style error and a non-zero exit code. That failure is the evidence: after Lab 4 creates the bucket the same command succeeds and the same policy takes effect.

**4. Bucket name:**

```bash
grep USMS_BUCKET_NAME configs/lab-01.env || echo 'export USMS_BUCKET_NAME=usms-student-data' >> configs/lab-03.env
```