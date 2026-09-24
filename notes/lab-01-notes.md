# Lab 01 Notes: Identity and Access Management¶

## 1. Floci Configuration & Persistence

- **memory Mode Behavior:** Floci treats its state as disposable in this mode.
- **--persist Flag:** Only provides a mounted directory; it does not
enable durable storage.
- **Data & Storage Impact:** Floci writes minimal persistent data to the mounted directory and automatically cleans up its created Docker volumes upon environment teardown.

## 2. IAM Authorization Details

> **Key Distinction:** The AWS Policy Simulator differentiates between:
> * **Implicit Deny:** Default state when no policy explicitly grants permission.
> * **Explicit Deny:** Triggered when a `Deny` statement directly blocks the action (overrides any `Allow`).


## 3. Tool Issue: Floci Snapshot Limitation

* **Action Attempted:** `floci snapshot save lab-01-iam-complete`
* **Result:** Failed with an **HTTP 400 error**.
* **Root Cause:** Running `floci snapshot list` confirmed that the **Snapshot API is unavailable** on the active server version (`1.7.0`), even though the local Floci CLI is up to date.
* **Impact:** State for completed Lab 01 could not be saved via snapshot.