#!/usr/bin/env bash
# fetch-diffs.sh — Fetch diffs and metadata for all pending PRs
# Reads data/pending-reviews.json, writes to data/diffs/

set -euo pipefail

PENDING="data/pending-reviews.json"
DIFFS_DIR="data/diffs"

mkdir -p "$DIFFS_DIR"

if [ ! -f "$PENDING" ]; then
  echo "No pending-reviews.json found. Nothing to fetch."
  exit 0
fi

COUNT=$(python3 -c "import json; print(len(json.load(open('$PENDING'))))" 2>/dev/null || echo 0)

if [ "$COUNT" -eq 0 ]; then
  echo "No pending PRs to fetch diffs for."
  exit 0
fi

echo "Fetching diffs for $COUNT pending PRs..."

python3 << 'EOF'
import json
import subprocess
import os
import sys
import re

pending = json.load(open("data/pending-reviews.json"))

for pr in pending:
    repo = pr["repo"]
    num = pr["pr_number"]
    # File-safe key: replace / with __ for filenames
    file_key = repo.replace("/", "__") + "--" + str(num)
    out_path = f"data/diffs/{file_key}.json"

    print(f"  Fetching {repo}#{num}...", flush=True)

    result = {
        "repo": repo,
        "pr_number": num,
        "head_sha": pr.get("head_sha", ""),
        "title": pr.get("title", ""),
        "author": pr.get("author", ""),
        "created_at": pr.get("created_at", ""),
        "base_branch": pr.get("base_branch", "main"),
    }

    # Fetch unified diff
    try:
        diff_output = subprocess.run(
            ["gh", "pr", "diff", str(num), "-R", repo],
            capture_output=True, text=True, timeout=30
        )
        result["diff"] = diff_output.stdout[:100000]  # Cap at 100KB
        result["diff_truncated"] = len(diff_output.stdout) > 100000
    except Exception as e:
        result["diff"] = ""
        result["diff_error"] = str(e)

    # Fetch file summary and metadata
    try:
        view_output = subprocess.run(
            ["gh", "pr", "view", str(num), "-R", repo,
             "--json", "files,additions,deletions,changedFiles,body,labels,milestone,headRefOid"],
            capture_output=True, text=True, timeout=30
        )
        if view_output.returncode == 0:
            meta = json.loads(view_output.stdout)
            result["files"] = meta.get("files", [])
            result["additions"] = meta.get("additions", 0)
            result["deletions"] = meta.get("deletions", 0)
            result["changed_files"] = meta.get("changedFiles", 0)
            result["body"] = meta.get("body", "")
            result["labels"] = [l["name"] for l in meta.get("labels", [])]
        else:
            result["metadata_error"] = view_output.stderr
    except Exception as e:
        result["metadata_error"] = str(e)

    with open(out_path, "w") as f:
        json.dump(result, f, indent=2)

    print(f"    Saved to {out_path}", flush=True)

print(f"\nDone. Fetched {len(pending)} PR diffs.")
EOF
