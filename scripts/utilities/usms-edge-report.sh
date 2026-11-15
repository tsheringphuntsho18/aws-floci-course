#!/usr/bin/env bash
# Emit one JSON document listing every usms- Lambda function's edge
# readiness. Valid JSON on stdout ONLY; every diagnostic goes to stderr.
# Read-only, re-runnable, and hard-codes no function name.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env" 1>&2

NAMES=$(aws lambda list-functions \
  --query "Functions[?starts_with(FunctionName, 'usms-')].FunctionName" \
  --output text)

if [ -z "$NAMES" ]; then
  echo "usms-edge-report.sh: no usms- functions found" >&2
  echo "[]"
  exit 0
fi

python3 - "$NAMES" << 'PY'
import json
import subprocess
import sys

names = sys.argv[1].split()

def aws(*args):
    out = subprocess.run(["aws"] + list(args), capture_output=True, text=True, check=True)
    return out.stdout

report = []
for name in names:
    cfg = json.loads(aws("lambda", "get-function-configuration", "--function-name", name, "--output", "json"))
    versions = json.loads(aws("lambda", "list-versions-by-function", "--function-name", name,
                               "--query", "length(Versions[?Version!='$LATEST'])", "--output", "json"))
    aliases = json.loads(aws("lambda", "list-aliases", "--function-name", name,
                              "--query", "length(Aliases)", "--output", "json"))

    runtime = cfg.get("Runtime", "")
    memory = cfg.get("MemorySize", 0)
    timeout = cfg.get("Timeout", 0)
    # .get("Environment") can be absent entirely, or present with no Variables key -
    # both must resolve to {} rather than raising under a stricter caller.
    env_vars = bool((cfg.get("Environment") or {}).get("Variables") or {})
    vpc_subnets = len((cfg.get("VpcConfig") or {}).get("SubnetIds") or [])

    is_node_or_python = runtime.startswith("nodejs") or runtime.startswith("python")
    cap_mem, cap_timeout = (128, 5) if "viewer" in name else (10240, 30)

    edge_eligible = (
        is_node_or_python
        and not env_vars
        and vpc_subnets == 0
        and versions >= 1
        and memory <= cap_mem
        and timeout <= cap_timeout
    )

    report.append({
        "name": name,
        "runtime": runtime,
        "memory": memory,
        "timeout": timeout,
        "versions": versions,
        "aliases": aliases,
        "env_vars": env_vars,
        "edge_eligible": edge_eligible,
    })
    print(f"checked {name}: edge_eligible={edge_eligible}", file=sys.stderr)

print(json.dumps(report, indent=2))
PY
