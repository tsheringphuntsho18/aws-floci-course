# Notes

In `memory` mode, Floci treats its state as disposable, so `--persist` only provides a mounted directory without enabling durable storage. As a result, Floci writes very little persistent data there and cleans up the Docker volumes it creates when the environment is torn down.

# Lab 01 Prediction: IAM Authorization Details
### Step 32 — Policy Simulator Prediction

For `usms-audit-01`, I predict that `ec2:CreateVpc` will result in **implicitDeny** because the audit user does not have a policy statement allowing VPC creation.

I also predict that `ec2:DescribeVpcs` will be **allowed** if the audit policy contains an Allow statement for this action; otherwise, it will result in **implicitDeny**. The policy simulator distinguishes between an explicit deny, where a Deny statement directly blocks an action, and an implicit deny, where no policy grants permission.

### Floci Snapshot Limitation

I attempted to save the completed Lab 01 state using:

`floci snapshot save lab-01-iam-complete`

However, Floci returned an HTTP 400 error. The `floci snapshot list` command also reports that the Snapshot API is not available on the current server version (1.7.0). Therefore, the snapshot could not be created even though the Floci CLI is up to date.