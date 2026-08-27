# AWS & Cloud Infrastructure Course

This repository contains my laboratory work and practical reports for the **AWS & Cloud Infrastructure course**.

All laboratories are part of one continuous project: the **University Student Management System (USMS)**. Throughout the course, I will progressively build the cloud infrastructure for USMS using different **AWS services**, with all practical work performed locally on my own laptop using the **AWS CLI**.

## Project Scenario

USMS is a web application designed to:

* Manage student records
* Upload and store transcripts
* Send enrollment notifications
* Generate student reports

Each laboratory focuses on a specific AWS service or cloud infrastructure concept and contributes to the overall USMS project.

## Repository Structure

```text
aws-floci-course/
├── README.md                  
├── .gitignore                 
├── docker-compose.yml         
├── .env                       
│
├── labs/                      # one folder per laboratory
│   └── lab-01-iam/
│       └── README.md           # your notes + evidence for this lab
|       ├── lab-02/ 
|       ├── lab-03/ 
|       ├── ...        
│
├── policies/                  
│   ├── usms-developer-base-policy.json
│   ├── usms-student-data-rw-policy.json
│   ├── usms-assume-app-roles-policy.json
│   ├── usms-self-manage-credentials.json
│   ├── usms-lambda-basic-policy.json
│   ├── trust-ec2.json
│   ├── trust-lambda.json
│   └── trust-account-developers.json
│
├── configs/                   # non-secret configuration (committed)
│   ├── course.env             
│   └── lab-01.env             
│
├── scripts/
│   ├── setup/                 # bring the environment up and down
│   │   ├── floci-up.sh
│   │   └── floci-down.sh
│   ├── utilities/             # small helpers reused all course
│   │   ├── whoami.sh
│   │   ├── floci-storage-check.sh
│   │   └── verify-lab-01.sh
│   └── cleanup/               # careful, controlled teardown
│       ├── floci-prune-volumes.sh
│       └── lab-01-cleanup.sh
│
├── templates/                 # CLI skeletons, CloudFormation (later labs)
├── outputs/                   # command output + SECRETS (never committed)
│   └── .gitkeep
├── screenshots/               # evidence for your lab report
└── notes/                     # your own learning notes
    └── lab-01-notes.md
```

> **Note:** This repository is created for academic and learning purposes as part of the AWS & Cloud Infrastructure course.
