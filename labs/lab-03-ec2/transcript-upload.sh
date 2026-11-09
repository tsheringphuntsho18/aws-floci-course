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
