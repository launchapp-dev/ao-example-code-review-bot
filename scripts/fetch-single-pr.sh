#!/usr/bin/env bash
# fetch-single-pr.sh — Fetch diff and metadata for one specific PR
# Usage: fetch-single-pr.sh "owner/repo#123"
# Writes to data/diffs/owner__repo--123.json

set -euo pipefail

PR_REF="${1:-}"

if [ -z "$PR_REF" ]; then
  echo "Error: PR reference required (format: owner/repo#123)"
  exit 1
fi

# Parse owner/repo#number
REPO=$(echo "$PR_REF" | sed 's/#[0-9]*//')
NUMBER=$(echo "$PR_REF" | grep -oE '[0-9]+$')

if [ -z "$REPO" ] || [ -z "$NUMBER" ]; then
  echo "Error: Could not parse PR reference: $PR_REF"
  echo "Expected format: owner/repo#123"
  exit 1
fi

FILE_KEY=$(echo "$REPO" | tr '/' '_')
FILE_KEY="${FILE_KEY}--${NUMBER}"
OUT="data/diffs/${FILE_KEY}.json"

mkdir -p data/diffs

echo "Fetching $REPO#$NUMBER..."

python3 << EOF
import json, subprocess, sys

repo = "$REPO"
num = $NUMBER
out_path = "$OUT"

result = {"repo": repo, "pr_number": num}

# Diff
try:
    r = subprocess.run(["gh", "pr", "diff", str(num), "-R", repo],
                       capture_output=True, text=True, timeout=30)
    result["diff"] = r.stdout[:100000]
    result["diff_truncated"] = len(r.stdout) > 100000
except Exception as e:
    result["diff"] = ""
    result["diff_error"] = str(e)

# Metadata
try:
    r = subprocess.run(["gh", "pr", "view", str(num), "-R", repo,
                        "--json", "title,author,files,additions,deletions,changedFiles,body,labels,headRefOid,baseRefName"],
                       capture_output=True, text=True, timeout=30)
    if r.returncode == 0:
        meta = json.loads(r.stdout)
        result.update({
            "title": meta.get("title", ""),
            "author": meta.get("author", {}).get("login", "unknown"),
            "files": meta.get("files", []),
            "additions": meta.get("additions", 0),
            "deletions": meta.get("deletions", 0),
            "changed_files": meta.get("changedFiles", 0),
            "body": meta.get("body", ""),
            "labels": [l["name"] for l in meta.get("labels", [])],
            "head_sha": meta.get("headRefOid", ""),
            "base_branch": meta.get("baseRefName", "main"),
        })
    else:
        result["metadata_error"] = r.stderr
except Exception as e:
    result["metadata_error"] = str(e)

with open(out_path, "w") as f:
    json.dump(result, f, indent=2)

print(f"Saved to {out_path}")
print(f"  Files changed: {result.get('changed_files', '?')}")
print(f"  +{result.get('additions', '?')} / -{result.get('deletions', '?')}")
EOF

echo "Done."
