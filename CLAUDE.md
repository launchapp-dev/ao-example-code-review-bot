# Code Review Bot — Agent Context

This is an automated GitHub pull request review pipeline. It runs on AO and posts
structured code reviews to GitHub PRs across one or more repositories.

## What This Project Does

Every 15 minutes, the `review-prs` workflow:
1. Calls `gh pr list` across configured repos to find unreviewed open PRs
2. Fetches raw unified diffs and PR metadata via `gh pr diff`
3. Runs diff-analyzer (Haiku) to extract structure: files, functions, complexity
4. Runs security-scanner (Sonnet + sequential-thinking) to find vulnerabilities
5. Runs style-checker (Haiku) to check code quality and conventions
6. Runs review-composer (Sonnet) to synthesize findings and post the review to GitHub

## Data Flow

All data lives in the `data/` directory:
- `data/pending-reviews.json` — PRs to process this run (overwritten each cycle)
- `data/diffs/{repo}--{pr}.json` — raw diff + metadata from gh CLI
- `data/analysis/{repo}--{pr}.json` — diff-analyzer output
- `data/security/{repo}--{pr}.json` — security-scanner findings
- `data/style/{repo}--{pr}.json` — style-checker findings
- `data/composed/{repo}--{pr}.json` — final composed review (before posting)
- `data/review-log.json` — append-only history of all posted reviews

File naming: slashes in repo names are replaced with double-underscores.
Example: `launchapp-dev/api` becomes `launchapp-dev__api--42.json`

## Configuration

- `config/review-config.yaml` — repos to monitor, filtering options
- `config/security-rules.yaml` — regex patterns for security scanning
- `config/style-rules.yaml` — complexity thresholds and check toggles
- `config/review-templates.yaml` — Markdown templates for review formatting

## GitHub Integration

Uses `gh-cli-mcp` MCP server for posting reviews. The `review-composer` agent
uses this to call `gh pr review` with the appropriate --approve, --request-changes,
or --comment flag and the formatted review body.

The `GH_TOKEN` env var must have `repo` scope and `pull_requests:write`.

## Deduplication

A PR is only reviewed once per head SHA. The `discover-prs` phase checks
`data/review-log.json` and skips PRs that already have a review entry matching
the current head SHA. If a developer force-pushes (changing the SHA), the bot
will re-review the updated PR.

## On-Demand Reviews

To review a specific PR immediately:
```bash
ao queue enqueue \
  --title "Review owner/repo#42" \
  --description "owner/repo#42" \
  --workflow-ref review-single
```

The description field is parsed as `owner/repo#number` by `scripts/fetch-single-pr.sh`.

## Extending This Example

- Add more security patterns to `config/security-rules.yaml`
- Add language-specific style rules to `config/style-rules.yaml`
- Add a Slack notification phase after `post-reviews` using `@modelcontextprotocol/server-slack`
- Add a Linear ticket creation phase for critical findings using `@tacticlaunch/mcp-linear`
- Connect to a PostgreSQL database to store metrics long-term
