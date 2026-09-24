# Lab 01 — IAM — Report

    Student Name: Tshering Phuntsho
    Student ID: 02230310
    Module: DSO303 Cloud Native Solution Design
    Date: 22/08/2026
    

## 1. Aim / Objective

The main objective of this lab was to learn and implement AWS Identity and Access Management (IAM) using the AWS CLI in a local Floci environment.

The specific objectives were to:

- Understand IAM users, groups, roles and policies.
- Create and manage IAM users and groups using the AWS CLI.
- Attach AWS-managed and customer-managed policies to groups.
- Create and manage inline policies.
- Create IAM roles and instance profiles for AWS services.
- Generate temporary credentials using AWS Security Token Service (STS).
- Use the IAM policy simulator to evaluate permissions.
- Understand explicit deny and implicit deny.
- Manage IAM policy versions.
- Configure persistent Floci storage so that IAM resources remain available across restarts.
- Maintain Git hygiene and prevent credentials or sensitive files from being committed.

## 2. Introduction

AWS Identity and Access Management (IAM) is an AWS service used to securely control access to AWS resources and services. IAM allows administrators to create users, groups, roles and policies that determine what actions identities are permitted or denied to perform. In this practical, IAM was explored through the AWS CLI while running AWS services locally using Floci. The practical covered important IAM concepts such as customer-managed policies, inline policies, trust policies, roles, instance profiles, temporary STS credentials, policy versions, ARNs, tagging and least privilege. IAM is an important component of cloud security because it ensures that users and applications receive only the permissions they require. The lab also highlighted that Floci stores and validates IAM policies but, by default, does not fully enforce them in the same way as real AWS

## 3. Use Case

IAM is commonly used in cloud environments to manage identities and control access to resources.

For the University Student Management System (USMS), IAM can be used for:

- Managing permissions for developers working on the USMS application.
- Providing auditors with read-only access to resources.
- Giving applications access to AWS services through IAM roles instead of storing long term credentials.
- Controlling access to student transcript files stored in Amazon S3.
- Providing temporary access to external or partner organizations.
- Restricting sensitive operations such as creating or deleting IAM users.
- Applying least-privilege permissions to different USMS components.
- Managing permissions for future AWS services used by the USMS project.

The lab specifically uses IAM roles for services such as the USMS application server and notification functions, demonstrating why applications should use roles instead of storing permanent access keys.


## 4. Implementation Procedure

**4.1 Configuring the Floci Environment**

The practical was performed locally using Floci as an AWS-compatible environment. The AWS CLI was configured to communicate with the local Floci endpoint instead of real AWS.

![floci](/screenshots/lab-1-iam/floci-ui.png)

**4.2 Storage diagnostics and completion of PART A**

![part A](/screenshots/lab-1-iam/part-A.png)

Six sections, all [ok], with section 5 reporting no dangling volumes.

**4.3 Creating IAM Groups**

Three IAM groups were created to act as permission containers for different types of USMS users.

![iam group](/screenshots/lab-1-iam/IAM-groups.png)

**4.4 Creating IAM Users**

IAM users were created for different USMS roles.

The practical demonstrated capturing resource ARNs directly into shell variables instead of manually copying them from command output. For example, the ARN of the audit user was captured into a variable.

![iam users](/screenshots/lab-1-iam/IAM-users.png)

A fourth user, usms-intern-01, was also created and tagged with the Intern role. The AWS CLI --query option was used to retrieve only the required UserId. 

![intern user](/screenshots/lab-1-iam/step19-youturn.png)

**4.5 Adding Users to Groups**

The created users were added to their corresponding IAM groups.

This demonstrated how identity and permission containers are connected. Group membership allows users to inherit the policies attached to the group.

![adding-users-to-group](/screenshots/lab-1-iam/step20-addUsertoGroup.png)

User(usms-intern-01) is added to the group usms-auditors.

![intern-to-group](/screenshots/lab-1-iam/step20-yourturn.png)

**4.6 Attaching AWS-Managed Policies**

An AWS-managed policy was attached to the appropriate group to provide broad read-only permissions for auditing purposes.

The practical also highlighted that Floci only provides a subset of AWS-managed policies. If a particular AWS-managed policy is unavailable, the lab provides a workaround using an equivalent customer-managed policy.

First explore what is available.

![explore](/screenshots/lab-1-iam/step21-explore.png)

Then attach:

![attach](/screenshots/lab-1-iam/step21-attach.png)

**4.7 Creating Customer-Managed Policies**

Customer-managed policies were created for USMS-specific requirements.

The developer policy was designed using the principle of least privilege. It provided the required infrastructure permissions while avoiding unrestricted write permissions. The policy also included explicit deny statements for sensitive identity operations.

The practical demonstrated why policies should be stored as separate JSON files. This makes them easier to review, version-control, reuse, and modify safely.

Verified after creating the policies.

![policies](/screenshots/lab-1-iam/step22.png)

**4.8 Creating an S3 Transcript Policy**

An S3 policy was created for student transcript storage.

The policy distinguished between:

- The bucket ARN, used for bucket-level operations.
- The object ARN, used for operations on objects stored in the bucket.

![s3](/screenshots/lab-1-iam/step23.png)

**4.9 Creating an Inline Policy**

![inline](/screenshots/lab-1-iam/step25.png)

**4.10 Working with Policy Versions**

Customer-managed policies were modified by creating new policy versions instead of directly replacing the existing version.

![policy version](/screenshots/lab-1-iam/step27-verify.png)

**4.11 Creating an EC2 IAM Role and Instance Profile**

An IAM role was created for the USMS application server.

The role used an EC2 trust policy to specify that the EC2 service could assume the role. An instance profile was then created to allow the role to be associated with an EC2 instance.

![command](/screenshots/lab-1-iam/step28-command.png)

Verify

![verify](/screenshots/lab-1-iam/step28-verify.png)

Instance

![instance](/screenshots/lab-1-iam/step28-instance.png)

**4.12 Creating the Lambda Execution Role**

Another IAM role was created for a USMS notification function.

![lambda](/screenshots/lab-1-iam/step29.png)

**4.13 Temporary credentials with STS**

Temporary credentials were obtained by assuming an IAM role. These credentials contain an access key, secret access key and session token and they expire after the configured duration.

![sts](/screenshots/lab-1-iam/step30-assumethrole.png)

![sts](/screenshots/lab-1-iam/step30-givePermission.png)

![sts](/screenshots/lab-1-iam/step30-identity.png)

![sts](/screenshots/lab-1-iam/step30-role.png)

**4.14 Access keys, handled safely**

Programmatic credentials were created for the required IAM user and store them without ever risking a commit.

![access](/screenshots/lab-1-iam/step31.png)


**4.15 Testing Permissions with the Policy Simulator**

The IAM policy simulator was used to test whether particular actions were allowed without actually performing those actions.

![simulaotr](/screenshots/lab-1-iam/step32.png)


**4.16 IAM State Snapshot**   
The completed IAM environment was intended to be saved as a Floci snapshot so that the environment could be restored later.

![save](/screenshots/lab-1-iam/step33.png)

**Verification**
![verification](/screenshots/lab-1-iam/Verification.png)



## 5. Results and Evidence  
### 5.1 CLI / SDK Output

**Evidence 1 — Inspect the IAM account**

Command:
```bash
aws iam list-users
```

### 5.2 AWS Management Console Verification

![aws console](/screenshots/lab-1-iam/aws-iam-console.png)

The screenshot demonstrates the creation of IAM users in aws console.

## 6. Analysis and Discussion

The practical successfully demonstrated the fundamental concepts of AWS IAM using the AWS CLI and a local Floci environment. IAM users, groups, policies, roles, instance profiles and temporary credentials were created and managed as part of the USMS cloud infrastructure.

One of the most important concepts learned was least privilege. Instead of granting unrestricted administrative access, policies were designed to provide only the permissions required for a particular role. The developer policy, for example, provided the infrastructure permissions required for future USMS development while explicitly preventing dangerous identity management operations. The lab emphasizes that explicit Deny statements take precedence over Allow statements.

The practical also demonstrated several differences between Floci and real AWS. Floci is useful for local learning because it provides AWS compatible APIs without requiring a real AWS account or incurring cloud costs. However, some AWS features are not fully implemented or enforced. In particular, IAM policies are generally stored and validated but are not enforced by default in the same way as real AWS. Another challenge involved persistence and snapshots. 

## 7. Reflection

**1. What did you learn about this AWS service?**

I learned that IAM is responsible for controlling identities and permissions in AWS. I learned how users, groups, roles and policies are related and how permissions can be managed using both managed and inline policies. I also learned about IAM roles, trust policies, instance profiles, STS temporary credentials, policy versions, ARNs and the principle of least privilege.

**2. What challenges did you encounter?**

One of the main challenges was understanding the difference between IAM policy types and the relationship between permissions policies and trust policies. I also encountered issues related to Floci persistence, unsupported AWS operations and snapshot functionality. 

**3. How would you apply this service in a real-world cloud environment?**

In a real USMS deployment, IAM would be used to provide different levels of access to developers, auditors, administrators and application services. Applications would use IAM roles instead of storing permanent access keys. Least-privilege policies would be applied to restrict access to student information and other sensitive resources.

**4. What additional concepts or features would you like to explore?**

I would like to explore IAM permission boundaries, AWS Organizations and Service Control Policies, IAM Access Analyzer, identity federation, MFA enforcement and more advanced IAM policy conditions.

## 8. Conclusion

This practical successfully introduced and demonstrated the core concepts of AWS Identity and Access Management (IAM) through the AWS CLI and a local Floci environment. IAM users, groups, policies, roles, instance profiles, policy versions and temporary credentials were created and managed as part of the USMS cloud infrastructure. The practical also demonstrated how policies can be tested using the IAM policy simulator and how explicit and implicit denies are interpreted.

The practical provided important hands-on experience with cloud identity and access management, least-privilege security, role-based access, temporary credentials, policy management and secure Git practices. These skills are directly applicable to the remaining USMS laboratories because IAM provides the security foundation for the AWS services that will be introduced in future labs. The completed lab therefore establishes the identity and permission foundation required for the next stage of the project, Lab 02 — VPC. 



