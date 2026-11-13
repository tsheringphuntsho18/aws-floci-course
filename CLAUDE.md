# DSO303 Lab Automation Rules

## Execution & Section Scope
- Environment: Floci 2.0.1 local AWS stack in `~/Desktop/DSO303/aws-floci-course` (consult `https://norbutlepcha25.github.io/dso303/Lab/known-issues.html` only if an API call fails).
- **ONLY process these lab sections:**
  - **Step-by-Step Implementation** & **Verification** (execute all AWS/Kubernetes/script commands sequentially)
  - **Independent Lab Exercises** (execute all tasks sequentially)
  - **Review Questions** (answer in `notes/lab-XX-notes.md`)
- **STRICTLY SKIP these sections, steps, and tasks (do not execute or document):**
  - Any **Git / "Commit" / "Commit your work"** steps or sections (if a step combines a non-git config repair with a git commit, apply only the config fix and skip all git actions)
  - **Checkpoints** (Section 9)
  - **Troubleshooting** (Section 10)
  - **Floci vs Real AWS** (Section 11)
  - **Lab Assessment Checklist** (Section 13)
  - **KEEP vs CLEAN UP** (Section 15)
  - **Preparation for the Next Lab** (Section 16)
- **No Git Commands:** NEVER run `git add`, `git commit`, `git push`, `git status`, `git diff`, or any other `git` CLI command in this workspace. Leave all version control actions to the user.
- Auto-fix any AWS/K8s/script errors immediately (up to 3 retries) and re-run cleanly before capturing screenshots.
- NEVER leave placeholders (`<id>`, `TODO`, `TBD`, `[screenshot]`, etc.) in any script, config, or markdown file—populate real ARNs, IDs, DNS names, IPs, and outputs.

## Terminal Screenshot Rules
- Capture all required terminal evidence using `python3 scripts/capture.py <path> "<command>"` (generates `.png` files only; do not create `.txt` files).
- Main implementation & verification steps: `screenshots/<lab-folder>/s1.png`, `s2.png`, `s3.png`, ...
- Independent Lab Exercises steps: `screenshots/<lab-folder>/e1.png`, `e2.png`, `e3.png`, ...
- Embed images using valid relative paths from each markdown file (e.g., `/screenshots/<lab-folder>/s1.png`).

## Three-File Documentation Structure (Direct Disk Writes)
Use your file-editing tools to create and write these three files directly on disk (matching the formatting and style of existing Labs 01–05):
1. `labs/<lab-dir>/README.md`: Complete 10-section DSO303 report (1. Aim / Objective, 2. Introduction, 3. Use Case, 4. System Architecture / Design, 5. Implementation Procedure, 6. Results and Evidence with embedded `s*.png`, 7. Analysis and Discussion, 8. Reflection, 9. Conclusion, 10. Appendix).
2. `labs/<lab-dir>/exercises.md`: Complete solutions, executed CLI outputs, explanations, and embedded `e*.png` screenshots for every task in **Independent Lab Exercises**.
3. `notes/lab-XX-notes.md`: All **Review Questions** from the lab with complete, accurate technical answers and key notes/takeaways.

## Token & Quota Conservation
- Write all files directly to disk—**never** paste or echo full report/script contents into chat replies.
- Keep chat responses concise: report only created resources, screenshot counts, and the 3 written file paths.