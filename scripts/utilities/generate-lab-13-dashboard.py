#!/usr/bin/env python3
"""Lab 13 Exercise 2: generate templates/lab-13-dashboard.json from
USMS_ACCOUNT_ID (configs/lab-01.env) and AWS_REGION_COURSE (configs/course.env)
instead of literals, and add a sixth widget (CentralErrorCount, last 3h).
Re-runnable: run it, it overwrites the file with the same account/region
substituted in, every time.
"""
import json
import os

ACCOUNT_ID = os.environ["USMS_ACCOUNT_ID"]
REGION = os.environ["AWS_REGION_COURSE"]


def alarm_arn(name):
    return f"arn:aws:cloudwatch:{REGION}:{ACCOUNT_ID}:alarm:{name}"


dashboard = {
    "widgets": [
        {
            "type": "text",
            "x": 0, "y": 0, "width": 24, "height": 2,
            "properties": {
                "markdown": "# USMS - transcript delivery\nOwner: platform team · Runbook: notes/lab-13-runbook.md · Alarms page the composite alarm only."
            },
        },
        {
            "type": "metric",
            "x": 0, "y": 2, "width": 12, "height": 6,
            "properties": {
                "title": "Transcripts processed, by faculty",
                "region": REGION,
                "stat": "Sum",
                "period": 300,
                "view": "timeSeries",
                "stacked": False,
                "metrics": [
                    ["USMS/Application", "TranscriptsProcessed", "Faculty", "science", "Stage", "notify"],
                    ["USMS/Application", "TranscriptsProcessed", "Faculty", "engineering", "Stage", "notify"],
                ],
            },
        },
        {
            "type": "metric",
            "x": 12, "y": 2, "width": 12, "height": 6,
            "properties": {
                "title": "Notification latency - max and average",
                "region": REGION,
                "period": 60,
                "view": "timeSeries",
                "metrics": [
                    ["USMS/Application", "TranscriptLagSeconds", "Stage", "notify", {"stat": "Maximum", "label": "max"}],
                    ["USMS/Application", "TranscriptLagSeconds", "Stage", "notify", {"stat": "Average", "label": "avg"}],
                ],
                "annotations": {"horizontal": [{"label": "alarm threshold", "value": 2}]},
            },
        },
        {
            "type": "metric",
            "x": 0, "y": 8, "width": 8, "height": 4,
            "properties": {
                "title": "Notifications in the last 5 minutes",
                "region": REGION,
                "stat": "Sum",
                "period": 300,
                "view": "singleValue",
                "metrics": [
                    ["USMS/Application", "NotifyCount"],
                    ["USMS/Application", "CentralErrorCount"],
                ],
            },
        },
        {
            "type": "alarm",
            "x": 8, "y": 8, "width": 16, "height": 4,
            "properties": {
                "title": "Pipeline alarms",
                "alarms": [
                    alarm_arn("usms-transcript-pipeline-down"),
                    alarm_arn("usms-transcript-lag-high"),
                    alarm_arn("usms-notify-silence"),
                ],
            },
        },
        {
            "type": "metric",
            "x": 0, "y": 12, "width": 24, "height": 6,
            "properties": {
                "title": "Central error count - last 3 hours",
                "region": REGION,
                "stat": "Sum",
                "period": 300,
                "view": "timeSeries",
                "metrics": [["USMS/Application", "CentralErrorCount"]],
                "annotations": {"horizontal": [{"label": "investigate", "value": 1}]},
            },
        },
    ]
}

with open("templates/lab-13-dashboard.json", "w") as fh:
    json.dump(dashboard, fh, indent=2)
    fh.write("\n")

print("generated templates/lab-13-dashboard.json for account %s, region %s" % (ACCOUNT_ID, REGION))
