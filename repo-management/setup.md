# Repository Setup — azurelocal-ztp

> How this repository is configured. Use this as the reference when replicating
> the setup or auditing the repo against [organization standards](https://azurelocal.cloud/standards/).

---

## Branch Protection — main

| Setting | Value |
|---------|-------|
| Require pull request before merging | Yes |
| Required approving reviews | 0 (small team — review encouraged, not enforced) |
| Dismiss stale reviews on new push | No |
| Require status checks to pass | Yes |
| Required status checks | `validate-repo-structure` (once enabled) |
| Require branches to be up to date | No |
| Allow force pushes | No |
| Allow deletions | No |
| Administrator bypass | Yes — allows org admins to push directly for controlled maintenance |

---

## Labels

Labels are defined in and synced from:
[`azurelocal.github.io/.github/labels.yml`](https://github.com/AzureLocal/azurelocal.github.io/blob/main/.github/labels.yml)

The `sync-labels` workflow on `azurelocal.github.io` propagates labels to all repos in the organisation.

Label prefixes used:
- `type/` — feature, bug, docs, infra, refactor, security
- `priority/` — critical, high, medium, low
- `solution/` — which AzureLocal solution the issue belongs to (this repo uses `solution/ztp`)
- `status/` — work state tracking

---

## Secrets

| Secret | Required by | How to create |
|--------|-------------|---------------|
| `ADD_TO_PROJECT_PAT` | `add-to-project.yml` | GitHub PAT with `project` scope, owned by a user with org project write access. Set at: Settings → Secrets and variables → Actions → New repository secret |
| `GITHUB_TOKEN` | All other workflows | Automatic — provided by GitHub Actions, no setup needed |

---

## CODEOWNERS

File: `.github/CODEOWNERS`

```
* @kristopherjturner
```

Adjust to the actual maintainers as the team grows.

---

## Issue Templates

Location: `.github/ISSUE_TEMPLATE/`

| Template | Purpose |
|----------|---------|
| `bug_report.md` | Bug report |
| `feature_request.md` | Feature request |
| `docs_issue.md` | Documentation problem |
| `config.yml` | Disables blank issues; surfaces canonical reference links |

---

## PR Template

File: `.github/pull_request_template.md`

Covers: summary, type of change, related issues, testing notes (with hardware platform), checklist.

---

## Release Automation

Release-please is configured but the workflow is currently a **placeholder stub** (see `automation.md`). When the placeholder is replaced with the real implementation, release-please will:

1. Read conventional commit messages on `main`.
2. Maintain an open release PR that updates `CHANGELOG.md` and bumps the version in `.release-please-manifest.json`.
3. On merge, create a GitHub release and tag.

Configuration files:

- `release-please-config.json`
- `.release-please-manifest.json`

---

## GitHub Pages (Documentation)

The `docs/` folder is built with **MkDocs** (`mkdocs.yml` at the repo root) and is intended to publish to GitHub Pages once the docs deployment workflow is implemented.

Until the workflow is wired up, run locally:

```bash
pip install mkdocs mkdocs-material
mkdocs serve
```

---

## Replication Checklist

When auditing or recreating this repo:

- [ ] `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `LICENSE`, `STANDARDS.md` exist at root
- [ ] `.github/CODEOWNERS`, `.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/` populated
- [ ] `release-please-config.json` and `.release-please-manifest.json` present
- [ ] `.azurelocal-platform.yml` self-descriptor present
- [ ] `repo-management/{README,setup,automation}.md` present
- [ ] `mkdocs.yml` builds locally without warnings
- [ ] Branch protection on `main` configured per the table above
- [ ] `ADD_TO_PROJECT_PAT` secret set
- [ ] Repository topics applied (see below)

## Repository Topics

```
azure-local
azure-stack-hci
azurelocal
azure-arc
powershell
infrastructure-as-code
zero-touch-provisioning
ztp
redfish
idrac
fdo
simplified-provisioning
```
