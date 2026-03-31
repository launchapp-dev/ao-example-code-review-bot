# Code Review Bot

Automated PR review pipeline — polls GitHub for open pull requests, runs multi-agent analysis (diff triage, security scanning, style checking), and posts structured approve/request-changes reviews with severity-badged inline comments.

## Workflow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    review-prs  (every 15 min)                       │
│                                                                     │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────────────────┐ │
│  │ discover-prs │──▶│ fetch-diffs  │──▶│     analyze-diff        │ │
│  │  (command)   │   │  (command)   │   │  (diff-analyzer/haiku)  │ │
│  └──────────────┘   └──────────────┘   └───────────┬─────────────┘ │
│                                                     │               │
│                           ┌─────────────────────────▼─────────────┐│
│                           │         scan-security                  ││
│                           │   (security-scanner/sonnet +          ││
│                           │    sequential-thinking MCP)           ││
│                           └─────────────────────────┬─────────────┘│
│                                                     │               │
│                           ┌─────────────────────────▼─────────────┐│
│                           │          check-style                   ││
│                           │    (style-checker/haiku)              ││
│                           └─────────────────────────┬─────────────┘│
│                                                     │               │
│   ┌──────────────┐   ┌─────────────────────────────▼─────────────┐ │
│   │ post-reviews │◀──│         compose-review                    │ │
│   │   (github    │   │  (review-composer/sonnet)                 │ │
│   │    MCP)      │   │  verdict: approve / request-changes /     │ │
│   └──────────────┘   │           comment-only                    │ │
│         │            │  ┌──── rework ────▶ scan-security         │ │
│         │            └──┘                                        │ │
│         ▼                                                         │ │
│   data/review-log.json + output/dashboard.md                     │ │
└─────────────────────────────────────────────────────────────────────┘

On-demand:
  ao queue enqueue --title "owner/repo#42" \
                   --description "owner/repo#42" \
                   --workflow-ref review-single
    └──▶ fetch-single (command) ──▶ full-review (review-composer/sonnet)
```

## Quick Start

```bash
cd examples/code-review-bot

# 1. Set your GitHub token
export GH_TOKEN=ghp_...

# 2. Configure repos to monitor
vim config/review-config.yaml   # add repos: or org:

# 3. Start the daemon (auto-runs every 15 min)
ao daemon start --autonomous

# Watch live
ao daemon stream --pretty

# Review a specific PR right now
ao queue enqueue \
  --title "Review owner/repo#42" \
  --description "owner/repo#42" \
  --workflow-ref review-single
```

## Agents

| Agent | Model | Role |
|---|---|---|
| **diff-analyzer** | `claude-haiku-4-5` | Fast triage — reads PR diffs, extracts changed files/functions, estimates complexity and review priority |
| **security-scanner** | `claude-sonnet-4-6` | Deep security analysis — secrets, injection vulnerabilities, auth issues, data exposure |
| **style-checker** | `claude-haiku-4-5` | Code quality — naming conventions, complexity thresholds, code smells, test coverage expectations |
| **review-composer** | `claude-sonnet-4-6` | Synthesizes all findings, writes GitHub review comments, posts approve/request-changes via gh-cli-mcp |

## AO Features Demonstrated

- **Scheduled workflows** — `review-prs` polls every 15 minutes via `schedules.yaml`
- **Command phases** — `discover-prs` and `fetch-diffs` use `gh` CLI directly
- **Multi-agent pipeline** — 4 specialized agents in sequence, each with a focused role
- **Decision contracts** — `compose-review` outputs structured `{verdict, reasoning, comment_count, ...}`
- **Rework loops** — on `rework` verdict, re-runs `scan-security` before recomposing
- **Mixed models** — Haiku for fast triage/style, Sonnet for security depth and synthesis
- **MCP integration** — `gh-cli-mcp` for GitHub operations, `sequential-thinking` for vulnerability chains
- **On-demand workflow** — `review-single` for instant single-PR reviews via queue

## Requirements

| Requirement | Details |
|---|---|
| **GitHub Token** | `GH_TOKEN` env var — needs `repo` and `pull_requests:write` scope |
| **gh CLI** | `brew install gh` — must be authenticated (`gh auth login`) |
| **Node.js** | v18+ for `npx` to run MCP servers |
| **Python 3** | Used in command phases for JSON processing |

## Directory Structure

```
config/
├── review-config.yaml      # Repos to monitor, filtering options
├── security-rules.yaml     # Security scanning patterns (regex)
├── style-rules.yaml        # Style thresholds and checks
└── review-templates.yaml   # Review comment formatting templates

scripts/
├── fetch-diffs.sh          # Batch fetch diffs for all pending PRs
└── fetch-single-pr.sh      # Fetch diff for a single PR

data/
├── pending-reviews.json    # PRs queued this cycle
├── diffs/                  # Raw diff + metadata per PR (owner__repo--N.json)
├── analysis/               # Diff analysis output per PR
├── security/               # Security findings per PR
├── style/                  # Style findings per PR
├── review-log.json         # All posted reviews (deduplication)
└── metrics.json            # Running totals

output/
├── reviews/                # Formatted review per PR (owner__repo--N.md)
└── dashboard.md            # Metrics and recent activity
```

## Review Verdict Logic

| Condition | Verdict |
|---|---|
| Any `critical` security finding | `request-changes` |
| Warnings but no criticals | `comment-only` |
| Only info/suggestions or clean | `approve` |

## Severity Badges

- 🔴 **Critical** — Blockers that must be fixed before merge (hardcoded secrets, RCE vectors)
- 🟡 **Warning** — Should be addressed; may allow merge at reviewer discretion
- 🟢 **Info** — Informational notes, no action required
- 💡 **Suggestion** — Optional improvements
