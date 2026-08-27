# AWS CLI + Floci — USMS Course Project

Infrastructure for the **University Student Management System (USMS)**, built lab by lab
with the AWS CLI against [Floci](https://floci.io), a local AWS emulator.

This repository contains my laboratory work and practical reports for the AWS & Cloud Infrastructure course.

All laboratories are part of one continuous project: the University Student Management System (USMS). Throughout the course, I will progressively build the cloud infrastructure for USMS using different AWS services, with all practical work performed locally on my own laptop using the AWS CLI.

## Project Scenario

USMS is a web application designed to:

- Manage student records
- Upload and store transcripts
- Send enrollment notifications
- Generate student reports

Each laboratory focuses on a specific AWS service or cloud infrastructure concept and contributes to the overall USMS project.

## Quick start

```bash
source configs/course.env
./scripts/setup/floci-up.sh
./scripts/utilities/whoami.sh
```

## Daily workflow

```bash
./scripts/setup/floci-up.sh      # start or resume (idempotent)
# ... lab work ...
./scripts/setup/floci-down.sh    # pause; state is kept
```

## Never run these

| Command | Why |
|---|---|
| `docker compose down -v` | `-v` deletes volumes |
| `docker volume prune` | Unfiltered; use scripts/cleanup/floci-prune-volumes.sh |
| `floci start ...` | Bypasses Compose; disables persistence |
| `rm -rf ~/floci-data` | That directory is the IAM state |

## Labs

| Lab | Topic | Status |
|-----|-------|--------|
| 01  | IAM   | [x] complete |
| 02  | VPC   | [ ] not started |

## Conventions

- All resources are prefixed `usms-`
- Region: `us-east-1`  ·  Floci account: `000000000000`
- Storage mode: `hybrid`, bind-mounted to `~/floci-data`
- Secrets live in `outputs/` and are **never** committed

> **Note:** This repository is created for academic and learning purposes as part of the AWS & Cloud Infrastructure course.
