# Code Review Bot — Build Plan

## Overview

Automated PR review pipeline — polls for new PRs in a GitHub org/repo, fetches diffs
and changed files, runs multi-agent analysis (code quality, security scanning, style
checking), composes structured review comments with severity levels, and posts
approve/request-changes verdicts back to GitHub.

All operations use `gh` CLI commands (command phases) and the GitHub MCP server
(gh-cli-mcp). No custom MCP servers needed.

---

## Agents (4)

| Agent | Model | Role |
|---|---|---|
| **diff-analyzer** | claude-haiku-4-5 | Fast triage — reads PR diffs, extracts changed functions/files, identifies scope and complexity |
| **security-scanner** | claude-sonnet-4-6 | Deep security analysis — checks for hardcoded secrets, injection vulnerabilities, auth issues |
| **style-checker** | claude-haiku-4-5 | Code style and quality — naming conventions, complexity, patterns, test coverage expectations |
| **review-composer** | claude-sonnet-4-6 | Synthesizes all findings into a coherent review with severity levels, posts to GitHub |

### MCP Servers Used by Agents

- **filesystem** — all agents read/write JSON data files
- **github** (gh-cli-mcp) — review-composer uses for posting review comments
- **sequential-thinking** — security-scanner uses for reasoning through complex vulnerability chains

---

## Workflows (2)

### 1. `review-prs` (primary — scheduled every 15 minutes)

Main pipeline: poll for PRs → analyze → review → post.

**Phases:**

1. **discover-prs** (command)
   - Command: `gh pr list` across configured repos with `--json` fields
   - Reads repo list from `config/review-config.yaml`
   - Filters to PRs not already reviewed (checks `data/review-log.json`)
   - Writes unreviewed PR list to `data/pending-reviews.json`
   - Each entry: `{repo, pr_number, title, author, created_at, head_sha, base_branch}`

2. **fetch-diffs** (command)
   - Script: `scripts/fetch-diffs.sh`
   - For each PR in `data/pending-reviews.json`:
     - `gh pr diff {number} -R {repo}` — full unified diff
     - `gh pr view {number} -R {repo} --json files,additions,deletions,changedFiles` — file summary
     - `gh pr view {number} -R {repo} --json body,labels,milestone` — PR metadata
   - Writes per-PR data to `data/diffs/{repo}--{pr_number}.json`
   - Exit 0 always (individual failures logged but don't block)

3. **analyze-diff** (agent: diff-analyzer)
   - Reads each PR from `data/diffs/`
   - Produces structured analysis per PR:
     - `files_changed[]` with: path, language, change_type (added/modified/deleted), lines_added, lines_deleted
     - `functions_modified[]` with: name, file, change_summary
     - `complexity_estimate`: low/medium/high (based on file count, line count, cross-cutting changes)
     - `scope_summary`: one-sentence description of what the PR does
     - `review_priority`: critical/normal/low (large PRs or sensitive files = critical)
   - Writes `data/analysis/{repo}--{pr_number}.json` per PR

4. **scan-security** (agent: security-scanner)
   - Reads diffs from `data/diffs/` and analysis from `data/analysis/`
   - For each PR, checks for:
     - **Secrets**: hardcoded API keys, tokens, passwords, private keys in diff
     - **Injection**: SQL injection, command injection, XSS patterns in new/changed code
     - **Auth issues**: missing auth checks, privilege escalation patterns
     - **Dependency risks**: new dependencies added, known vulnerable patterns
     - **Data exposure**: logging sensitive data, error messages leaking internals
   - Each finding: `{type, severity (critical/warning/info), file, line, description, recommendation}`
   - Writes `data/security/{repo}--{pr_number}.json` per PR
   - Uses sequential-thinking for complex multi-file vulnerability chain analysis

5. **check-style** (agent: style-checker)
   - Reads diffs from `data/diffs/` and analysis from `data/analysis/`
   - For each PR, checks:
     - **Naming**: inconsistent variable/function naming conventions
     - **Complexity**: functions too long (>50 lines), deep nesting (>4 levels), high cyclomatic complexity
     - **Patterns**: anti-patterns, code smells, DRY violations within the PR
     - **Tests**: are tests added/updated for new functionality? Test coverage expectations
     - **Documentation**: public API changes without doc updates
   - Each finding: `{type, severity (warning/info/suggestion), file, line, description, suggestion}`
   - Writes `data/style/{repo}--{pr_number}.json` per PR

6. **compose-review** (agent: review-composer)
   - Reads all findings from `data/security/`, `data/style/`, and `data/analysis/`
   - Per PR, synthesizes a single structured review:
     - **Verdict**: approve / request-changes / comment-only
       - `request-changes` if ANY critical security finding
       - `comment-only` if warnings exist but no blockers
       - `approve` if clean or only info/suggestions
     - **Summary comment**: overall assessment paragraph
     - **Inline comments**: mapped to specific file:line from findings
     - **Severity badges**: 🔴 Critical | 🟡 Warning | 🟢 Info | 💡 Suggestion
   - Decision contract: `{verdict, reasoning, comment_count, critical_count}`

7. **post-reviews** (agent: review-composer)
   - Uses gh-cli-mcp to post reviews to GitHub
   - For each PR:
     - `gh pr review {number} -R {repo} --approve/--request-changes/--comment --body "..."`
     - Posts inline comments on specific files/lines
   - Records posted reviews in `data/review-log.json` with timestamp and verdict
   - Updates `data/metrics.json` with running totals

### 2. `review-single` (on-demand — review a specific PR)

Quick single-PR review, triggered via queue with PR URL or repo#number.

**Phases:**

1. **fetch-single** (command)
   - Reads PR reference from `{{subject_title}}` (format: `owner/repo#123`)
   - Fetches diff, files, metadata via gh CLI
   - Writes to `data/diffs/{repo}--{pr_number}.json`

2. **full-review** (agent: review-composer)
   - Performs all analysis inline (no separate scanner/style phases)
   - Analyzes diff for security, style, and quality issues
   - Composes and posts review in one step
   - Updates review log

---

## Decision Contracts

### compose-review verdict
```json
{
  "verdict": "approve | request-changes | comment-only",
  "reasoning": "why this verdict was chosen",
  "comment_count": 5,
  "critical_count": 0,
  "warning_count": 2,
  "info_count": 3
}
```

---

## Directory Layout

```
config/
├── review-config.yaml      # Repos to monitor, polling interval, exclusion patterns
├── security-rules.yaml     # Security scanning rules and patterns
├── style-rules.yaml        # Style checking rules and thresholds
└── review-templates.yaml   # Review comment templates and formatting

scripts/
├── fetch-diffs.sh          # Batch fetch diffs for all pending PRs
└── fetch-single-pr.sh      # Fetch diff for a single PR

data/
├── pending-reviews.json    # PRs awaiting review this cycle
├── diffs/{repo}--{pr}.json # Raw diff and metadata per PR
├── analysis/{repo}--{pr}.json  # Diff analysis output
├── security/{repo}--{pr}.json  # Security scan findings
├── style/{repo}--{pr}.json     # Style check findings
├── review-log.json         # History of all posted reviews (prevents duplicates)
└── metrics.json            # Running review metrics (counts, verdicts, trends)

output/
├── reviews/{repo}--{pr}.md     # Formatted review for reference
└── dashboard.md                # Review activity dashboard
```

---

## Config Files

### config/review-config.yaml
```yaml
repos:
  - owner/repo-name
# Or monitor entire org:
org: launchapp-dev
# Filter options:
exclude_repos: []
exclude_authors: ["dependabot[bot]", "renovate[bot]"]
min_files_changed: 1
max_files_changed: 100  # Skip mega-PRs
pr_states: ["open"]
skip_draft: true
skip_already_reviewed: true
```

### config/security-rules.yaml
```yaml
patterns:
  secrets:
    - pattern: "(api[_-]?key|apikey|secret|token|password|passwd|credential)\\s*[:=]\\s*['\"][^'\"]{8,}"
      severity: critical
      description: "Possible hardcoded secret"
    - pattern: "(AKIA[0-9A-Z]{16})"
      severity: critical
      description: "AWS Access Key ID"
    - pattern: "-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----"
      severity: critical
      description: "Private key in source code"
  injection:
    - pattern: "\\$\\{.*\\}.*sql|query.*\\+.*req\\."
      severity: warning
      description: "Potential SQL injection"
    - pattern: "innerHTML\\s*=|dangerouslySetInnerHTML|v-html="
      severity: warning
      description: "Potential XSS via raw HTML insertion"
  auth:
    - pattern: "TODO.*auth|FIXME.*permission|skip.*auth.*check"
      severity: warning
      description: "Authentication/authorization TODO or skip"
```

### config/style-rules.yaml
```yaml
thresholds:
  max_function_lines: 50
  max_nesting_depth: 4
  max_parameters: 5
  max_file_lines: 500
checks:
  require_tests_for_new_files: true
  require_docs_for_public_api: true
  flag_console_log: true
  flag_commented_code: true
```

---

## Schedule

```yaml
schedules:
  - id: review-poll
    cron: "*/15 * * * *"
    workflow_ref: review-prs
    enabled: true
```

Polls every 15 minutes for new PRs across configured repos.

---

## Key Design Decisions

1. **Haiku for fast triage, Sonnet for deep analysis** — diff-analyzer and style-checker use Haiku
   for speed since they're doing pattern matching. Security scanner uses Sonnet for deeper reasoning
   about vulnerability chains. Review composer uses Sonnet for synthesis.

2. **Parallel analysis phases** — security scanning and style checking read the same inputs
   independently. In a future AO version with parallel phases, these could run concurrently.
   For now, they run sequentially but are designed to be independent.

3. **Deduplication via review-log.json** — the discover-prs phase checks this log to avoid
   re-reviewing PRs. A PR is only re-reviewed if its head SHA has changed (force-push).

4. **Graceful degradation** — if a repo is inaccessible or a diff is too large, the pipeline
   logs the issue and skips that PR rather than failing the entire run.

5. **No custom MCP servers needed** — everything uses gh CLI (command phases) and gh-cli-mcp
   (for review posting). This makes the example immediately runnable.
