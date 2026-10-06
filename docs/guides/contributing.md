# CorTxOS v6.16.0 — Contributor Guide

This guide covers the mechanics of contributing to CorTxOS v6.16.0: repo layout, adding a skill,
building and testing the Rust runtime, the local CI gates, and the conventions CI enforces. It is
derived from `CONTRIBUTING.md`, the repo's `CLAUDE.md`, `runtime/Cargo.toml`, and the `scripts/check-*`
gates.

Cross-link:

- [Skills overview](../skills/overview.md)
- [CLI tooling](../cli/tooling.md)

> **External / third-party authors:** the open surface you may build on is the `SKILL.md` v2 format and
> frontmatter schema; the Rust runtime/dispatch is closed. See the portability posture in
> [`GOVERNANCE.md`](../../GOVERNANCE.md) §8.1 for the open-vs-closed boundary. `CONTRIBUTING.md` is the
> internal mechanics reference.

## Repo layout

| Directory | Contents |
|-----------|----------|
| `skills/` | The skill corpus — `cortx-core/` (stable), `cortx-core/experimental/`, `cortx-meta/` |
| `runtime/` | The Rust workspace — `crates/` (libraries) + `cmd/` (binaries: gateway, runtime, mcp, lint, registry, …) and `migrations/` |
| `shared/references/` | Shared reference docs consumed by 20+ skills (`shared_refs:`) |
| `deploy/` | Deployment surfaces — `helm/`, `registry/`, `observability/`, `dist/` |
| `packages/` | Public SDKs (e.g. `cortx-sdk-python/`) |
| `evals/` | Per-skill eval fixtures (`prompts.md`, `golden.md`, `scoring.md`) |
| `docs/` | ADRs, release notes, guides, capabilities registry, analysis |

The CorTxOS suite version is single-sourced in `VERSION` (`CORTXOS_VERSION=6.16.0`); the Rust workspace
pins the same in `runtime/Cargo.toml` (`workspace.package.version = "6.16.0"`, MSRV `rust-version =
"1.91"`).

## Adding a skill

1. **Scaffold** the skill (defaults to the stable tier):

   ```bash
   bash scripts/new-skill.sh my-new-skill                  # stable
   bash scripts/new-skill.sh my-new-skill --experimental   # skills/cortx-core/experimental/
   bash scripts/new-skill.sh my-new-skill --meta           # skills/cortx-meta/
   ```

   This creates `skills/cortx-core/my-new-skill/SKILL.md` and `evals/my-new-skill/` with canonical
   frontmatter + required sections.

2. **SKILL.md frontmatter** (CI-enforced): `name`, `description`, `version`, `format: v2`, `created`,
   `updated`, `product_agnostic`, `consumes_from`, `produces_for`, `may_invoke`, `uses_tools`, `tools`
   (Claude Code canonical allowlist — subset of `[Read, Write, Edit, Bash, Grep, Glob, WebSearch,
   WebFetch, TodoWrite]`), `model` (always `opus`), `shared_refs`, `estimated_tokens`, `max_artifacts`.
   `uses_tools:` documents design intent; `tools:` is what the runtime enforces — both required, do not
   conflate.

3. **Required body sections** (CI-enforced): "you are" persona, numbered protocol/workflow, output
   template, a **Rationalization Defense** table, and a **CorTxOS Integration** section
   (consumes-from / produces-for / invokes).

4. **Eval fixture** under `evals/my-new-skill/`: `prompts.md` (test prompt), `golden.md` (expected
   shape), `scoring.md` (rubric).

5. **Reciprocity** — `consumes_from` is the source of truth; `produces_for` is derived. Run the
   reciprocity check so the skill graph stays a DAG (a `consumes_from` edge that creates a cycle is
   rejected):

   ```bash
   cortx lint reciprocity --check
   # normalize produces_for, then enforce the tier rule as a hard failure:
   cortx lint reciprocity --write --strict-tiers
   ```

   Tier rule: product-pipeline skills (stable / experimental) must **never** `consumes_from` a meta
   skill — a hard error.

## Build and test

The runtime is a Rust workspace. Build and test from `runtime/`:

```bash
cd runtime
cargo build --release          # release binaries (gateway, runtime, mcp, lint, …)
cargo test --workspace         # workspace test suite
```

The release profile uses `opt-level = 3`, thin LTO, and symbol stripping. `unsafe_code` is `forbid`
workspace-wide.

## Local CI gates

`.github/workflows/cortx-linux-ci.yml` is the authoritative CI gate. It is **manual-only**
(`workflow_dispatch`) and runs the workspace **build + test** on Linux — not `clippy -D warnings`. Run
the same gates locally before pushing.

```bash
cortx validate                 # structural + semantic validation
bash scripts/cortx health      # health checks
bash scripts/pre-commit.sh     # shellcheck + frontmatter validation (install as a git hook)
```

Install the pre-commit hook once so commits fail fast on the same issues CI flags:

```bash
ln -sf ../../scripts/pre-commit.sh .git/hooks/pre-commit
chmod +x scripts/pre-commit.sh
# or: bash install.sh --project /path/to/repo --with-hooks
```

Key `scripts/check-*.sh` gates:

| Script | Enforces |
|--------|----------|
| `check-doc-sync.sh` | Single-source version: every version-consumer file must match `VERSION` (no drift); skill counts derived dynamically by tier |
| `check-no-python.sh` | Locks in the Python→Rust eradication — fails on any tracked `*.py` outside the allowlist (`packages/cortx-sdk-python/`, `scripts/train_trajectory_scorer.py`) |
| `check-skill-structure.sh` | Required frontmatter fields + body sections |
| `check-skill-versions.sh` | Per-skill version discipline |
| `check-shared-refs.sh` | `shared_refs:` path resolution |
| `check-skill-registry-parity.sh` | Skill index vs. on-disk corpus |
| `check-manifest-sync.sh` | Manifest consistency |
| `check-mcp-docs.sh` | MCP docs vs. served tools |

Other gates include `check-crate-version.sh`, `check-description-integrity.sh`, `check-eval-fixtures.sh`,
`check-gate-negatives.sh`, `check-installed-refs.sh`, `check-lean-dag-coverage.sh`,
`check-lean-kernel.sh`, `check-port-parity.sh`, `check-replay-corpus-lock.sh`,
`check-tracked-artifacts.sh`, `check-brain-updates.sh`. A green CI is the minimum bar — not a substitute
for careful review.

## Conventions

- **One logical change per PR.** Mixed refactor + feature is hard to review and revert.
- **No stale dates.** Update the `updated:` frontmatter on any file you touch; never change `created`.
- **No hardcoded secrets**, and **no version numbers in skill prose** — use "latest stable" and let
  lockfiles pin.
- **Skill graph stays a DAG.** Cycles in `consumes_from` are rejected.
- **Capabilities ledger.** Any add/change to runtime, skills, CI, or security must update
  `docs/capabilities/capabilities_ledger.db` (SQLite source of truth) in the same PR — update the
  affected rows, refresh `last_verified`, and regenerate `docs/capabilities/capabilities_ledger.md`
  from it (maintenance protocol at the bottom of that file).

### Branch and PR naming

- Branch from `main`: `<type>/<short-description>` where `<type>` is `feat|fix|docs|refactor|chore`.
- Commit: `<type>(<PROJECT_ABBR-NNNNN>) - <short description>` (e.g. `feat(CORTX-00142) - add
  progressive disclosure to spec-developer`). For CorTxOS itself `PROJECT_ABBR` is `CORTX`.
- PR title: `<type>(<PROJECT_ABBR-PR-NNNNN>) - <short description>`. PRs are squash-merged; one logical
  change each.

### Release notes (required)

Every PR or shipped feature lands a release-notes entry under `docs/release-notes/` covering everything
an operator needs to roll the change forward and back: summary, code/schema/migration/seed/env/infra
deltas, feature flags, runbook, test plan, rollback, and linked PRs/tickets. Add the entry to the
rolling `docs/release-notes/CHANGELOG.md` index. A pure internal refactor may use a one-line entry that
says exactly that.

### Version drift guard

`VERSION` is the single source of truth (`CORTXOS_VERSION`). `check-doc-sync.sh` fails the build on any
consumer file (`plugin.json`, `package.json`, manifests, runtime crate version) that drifts from it. Do
not hand-edit a consumer version in isolation — the guard + release tooling own those literals.

## Questions

Open an issue. The skill system has subtle invariants (`shared_refs:` path resolution, hook-protocol
inheritance, tier rules) that are not obvious from reading one file.
