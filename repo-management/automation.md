# GitHub Actions — azurelocal-ztp

> This document describes every GitHub Actions workflow in this repository:
> what it does, why it exists, what it requires, and what must be replicated
> when setting up a new repository in this organisation.
>
> **Status:** All workflows in this repo are currently **placeholder stubs**. They expose the intended workflow surface and a `workflow_dispatch` no-op job, but no real CI/CD logic has been wired up yet. Each entry below documents the *intended* behavior so the stubs can be filled in incrementally.

---

## Workflow Index

| File | Name | Trigger (intended) | Status |
|------|------|--------------------|--------|
| `release-please.yml` | Release Please | push to `main` | Stub |
| `add-to-project.yml` | Add to Project | issue / PR opened or labeled | Stub |
| `validate-repo-structure.yml` | Validate Repo Structure | PR to `main` | Stub |
| `deploy-docs.yml` | Deploy Docs | push to `main` touching `docs/**` or `mkdocs.yml` | Stub |
| `lint-scripts.yml` | Lint Scripts | push / PR touching `scripts/**` | Stub |
| `ztp-runner-setup.yml` | ZTP Runner Setup | manual `workflow_dispatch` | Stub |
| `ztp-config-bootstrap.yml` | ZTP Config Bootstrap | manual `workflow_dispatch` | Stub |
| `ztp-deployment.yml` | ZTP Deployment | manual `workflow_dispatch` | Stub |

---

## release-please.yml

### Intended behavior

Slim caller for the org-wide reusable workflow:

```yaml
uses: AzureLocal/.github/.github/workflows/reusable-release-please.yml@main
```

On every push to `main`, release-please reads conventional commit messages and maintains an open release PR that updates `CHANGELOG.md` and bumps the version in `.release-please-manifest.json`. When the release PR is merged, it creates a GitHub release and tag.

### Secrets required

`GITHUB_TOKEN` (automatic).

---

## add-to-project.yml

### Intended behavior

Slim caller for `AzureLocal/.github/.github/workflows/reusable-add-to-project.yml@main`. Adds new issues and PRs to the [shared org project board](https://github.com/orgs/AzureLocal/projects/3) and sets the `Solution`, `Priority`, and `Category` fields based on labels.

### Configuration needed before enabling

- `id-prefix`: assign a short repo prefix (proposed: `ZTP`)
- `solution-option-id`: look up `solution/ztp` option ID in the project board

### Secrets required

`ADD_TO_PROJECT_PAT` — classic PAT with `project` scope.

---

## validate-repo-structure.yml

### Intended behavior

Slim caller for `AzureLocal/.github/.github/workflows/reusable-validate-structure.yml@main`. Checks that required root files (`README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `LICENSE`, `STANDARDS.md`, `.azurelocal-platform.yml`) and directories (`.github/`, `docs/`, `repo-management/`) exist on every PR to `main`.

### Secrets required

None.

---

## deploy-docs.yml

### Intended behavior

Build the MkDocs site from `docs/` and publish to GitHub Pages on every push to `main` that touches documentation. Pattern follows the docs deployment workflow used in `azurelocal-toolkit`.

### Secrets required

None — uses the built-in `GITHUB_TOKEN` with Pages write permission.

---

## lint-scripts.yml

### Intended behavior

Run PSScriptAnalyzer against every `.ps1` file under `scripts/` on every push or PR that touches `scripts/**`. Fail the build on any rule with severity `Error`.

### Secrets required

None.

---

## ztp-runner-setup.yml

### Intended behavior (carried over from private-preview design)

Manual `workflow_dispatch` workflow that prepares a self-hosted GitHub runner with the prerequisites needed to drive iDRAC/Redfish operations against an on-premises management network. Was the entry point for the private-preview pipeline-driven flow.

**Open question:** the public-preview design may not require a self-hosted runner if all BMC operations can be driven from a workstation. Decide whether this stub should be implemented or removed before the v1.0.0 release.

---

## ztp-config-bootstrap.yml

### Intended behavior (carried over from private-preview design)

Manual `workflow_dispatch` workflow that bootstraps the cluster configuration files (`config/cluster/cluster-config.md` → `config/environment.{json,yaml}`) from a runtime template and validates the result.

---

## ztp-deployment.yml

### Intended behavior (carried over from private-preview design)

Manual `workflow_dispatch` workflow that runs the end-to-end automation against a target cluster: discover BMCs, mount the maintenance environment ISO via Redfish, set boot order, restart, collect vouchers, and (optionally) drive Azure portal provisioning steps.

This is the primary differentiator vs the official Microsoft documentation, which requires manual USB media creation and per-machine boot.

---

## Replication Notes

When replicating this repo's workflow set to a new AzureLocal repo:

1. Copy the three baseline workflows (`release-please.yml`, `add-to-project.yml`, `validate-repo-structure.yml`) and update `id-prefix` and `solution-option-id` for the new repo.
2. Copy the docs and lint workflows if the repo has a `docs/` or `scripts/` directory.
3. Do **not** copy the three `ztp-*` workflows — those are specific to this repo's automation surface.
