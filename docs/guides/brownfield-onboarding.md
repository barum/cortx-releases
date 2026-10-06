# CorTxOS v6.16.0 — Brownfield Onboarding

You already have a repository — code, existing documentation, or both — and you want the CorTxOS
pipeline to run on it from here forward. The `brownfield-onboarder` skill performs the one-time work
of mapping that existing reality into CorTxOS's artifact shapes so the normal pipeline (ideator →
epic → story → design → spec → implement) has the inputs it expects. It runs **once per product**, at
**Stage −1**, before `ideator`.

> **What it is — and is not.** The onboarder produces a *map* of what exists, at what altitude, with
> what confidence, against what the pipeline expects. It does **not** invent product vision (that's
> `ideator`) or design new systems (that's `principal-engineer`). Every artifact it emits is either
> recovered from a cited evidence source (code path, git commit, existing doc) or flagged as an
> explicit gap you close through the normal pipeline. Fabrication is the exact failure mode this skill
> exists to prevent.

## What you'll need

- An existing repository to onboard — referred to below as `$REPO` (use an absolute path).
- A built `cortx` binary on `PATH` (see [getting-started](../getting-started.md) to build it).
- `git` on `PATH` (for commit-history archaeology) and `grep`/`rg` (for inventory). Missing tools
  degrade gracefully — git archaeology and commit-message ADR proposals are skipped, and the report
  notes the limitation.
- A repo-root `CLAUDE.md`. If absent, the onboarder offers to generate a minimal one (product name +
  one-line description) and refuses to proceed without it.
- Cross-links: [getting-started](../getting-started.md) · [CLI reference](../cli/cortx.md) ·
  [knowledge-and-memory](../architecture/knowledge-and-memory.md) ·
  [scenarios: local-only](scenarios/local-only.md) ·
  [scenarios: mcp-persistence-brownfield](scenarios/mcp-persistence-brownfield.md).

## How it maps onto the pipeline

`brownfield-onboarder` sits at Stage −1. Its output is what every downstream skill expects to find in
`docs/products/<product>/`, as if the product had been built inside CorTxOS from the start — except
every recovered artifact carries `recovered: true` + `confidence: HIGH|MED|LOW` + `source_artifact:`
frontmatter so downstream skills know the content is inferred, not authoritative.

```text
Stage −1  ONBOARD   brownfield-onboarder   ← you are here (once per product)
Stage  0  IDEATE    ideator                ← fills vision-altitude gaps the onboarder surfaced
Stage  1+ …         product-manager → epic-developer → story-creator → principal-engineer → …
```

The brownfield report's `status:` gates downstream work: `status: draft` blocks `product-manager`
from generating new backlogs; only **you** set `status: accepted` after working the checklist.

## The 6-phase protocol

The onboarder runs phases conditionally on what the repo contains (`scope_classification` is one of
`code-only`, `code+docs`, `docs-only`, `empty`):

| Phase | Name | Runs when | Output |
|-------|------|-----------|--------|
| 0 | Inventory | always | `onboarding/inventory-<date>.md` — languages, build systems, service boundaries, wire/data schemas, test dirs, in-repo + ingested docs, git archaeology. |
| 1 | Classify by altitude | docs exist | `onboarding/classification-<date>.md` — each doc tagged with its pipeline altitude (vision / epic / story / design / spec / ADR / runbook / …) and HIGH/MED/LOW confidence. |
| 2 | Recover from code | code exists | Populates `architecture-cache.md`, `domain-model.md`, `operational-history.md`, and `specs/<NNN-feature>/` (via `spec-archaeologist`). Types and API contracts recover at HIGH confidence; ADRs mined from git log are LOW (proposals to ratify). |
| 3 | Map docs to CorTxOS shapes | docs exist | Recovered ideation/epic/story/design artifacts that **preserve the original content verbatim** in fenced blocks with `source_artifact:` citations; unmapped sections get explicit `[GAP]` markers. Originals are copied to `onboarding/sources/`. |
| 4 | Reconcile | code **and** docs exist | Cross-checks what the code says against what the docs say. Every disagreement becomes a `DRIFT-NNNN` entry in `.cortx/drift-monitor/drift-findings.yaml` with **two or more** resolution paths — never auto-resolved. |
| 5 | Gap surface + go-forward plan | always (last) | `onboarding/brownfield-report-<date>.md` — the master output (see below). |

Phase 0 runs `scripts/inventory.sh` (packaged with the skill) read-only against `$REPO`; it never
modifies the target repository.

## Step 1 — Install CorTxOS into the existing repo

Lay the skill catalog down under `$REPO/.claude/` so the onboarder (and later, MCP hosts) serves the
exact catalog the repo carries:

```bash
export REPO=/abs/path/to/your-existing-repo
bash install.sh --project "$REPO"
```

## Step 2 — Run the onboarder

Two equivalent entry points — pick one.

**A. Let `cortx start` classify and route.** The classifier inspects the target directory; an existing
codebase routes to `brownfield-onboarder` first, then a pipeline template. It prints the routing
decision and exits unless you pass `--dispatch`:

```bash
# Print the routing decision only (safe, no work performed)
cortx start "$REPO" --product yourproduct

# Actually run the onboarder + pipeline end-to-end
cortx start "$REPO" --product yourproduct \
  --request "onboard this repo to CorTxOS" --dispatch
```

**B. Dispatch the skill directly** (useful for debugging a single stage). Write the artifacts under
the `onboarding` subdir:

```bash
cortx dispatch yourproduct brownfield-onboarder \
  "onboard this repo to CorTxOS" --output-subdir onboarding
```

> **Preview first.** The skill honors a `--dry-run` prefix in its request: it emits the full plan plus
> the Phase 0 inventory to chat without writing any files. Use it to see the scope classification
> before committing to a full run.

Optional inputs the onboarder accepts (passed in the request / skill input):

- `--ingest <dir>` — a directory of existing docs (PDFs, Confluence/Notion exports, PRDs) to classify
  and map (Phases 1, 3).
- `--issues <file>` — an issue-tracker export (Jira CSV, Linear JSON, GitHub issues JSON) to recover
  epics and stories from. Allocated epic IDs are permanent and recorded in
  `onboarding/epic-id-map-<date>.md`.

## Step 3 — Read the brownfield report

The master output is `docs/products/<product>/onboarding/brownfield-report-<date>.md`. It ships with
`status: draft` and contains:

| Section | What it gives you |
|---------|-------------------|
| §1 Scope summary | Classification + inventory totals. |
| §2 Coverage matrix | One row per pipeline stage with HIGH/MED/LOW recovery counts and a plain-language Gaps column. |
| §3 Drift findings | `DRIFT-NNNN` rows where code and docs disagree, each naming ≥2 resolution paths (never auto-resolved). |
| §4 Invariants / posture conflicts | Each conflict between the recovered stack and the architectural-invariants / PQC posture, routed to `security-reviewer` with a migration-vs-override-ADR choice. |
| §5 Go-forward checklist | Ordered by pipeline stage; each item names the skill to invoke to close the gap. |
| §6 Estimated effort | 1-engineer and 2-engineer-parallelized ranges to clear the checklist. |
| §7 Steady-state transition | The 5-step acceptance process. |

Ancillary artifacts from the same run: `inventory-<date>.md`, `classification-<date>.md`,
`epic-id-map-<date>.md`, the verbatim `onboarding/sources/` copies, and the recovered artifacts across
`ideation/`, `epics/`, `specs/`, `architecture-cache.md`, `domain-model.md`, and
`operational-history.md` — all carrying `recovered: true` + `confidence:` + `source_artifact:`.

## Step 4 — Work the go-forward checklist, then accept

Close each §5 checklist item through the normal pipeline (typically: vision gaps via `ideator`, any
CRITICAL drift, any invariants/posture conflict routed to `security-reviewer`). Items you cannot
complete must be **formally waived via an ADR**, not silently skipped.

When the checklist is clear, set `status: accepted` in the report frontmatter yourself — the onboarder
never does this on your behalf. Acceptance flips the product into steady state, after which
`cortx-orchestrator` runs the normal templates (`feature`, `platform`, `hotfix`,
`incident-remediation`).

## Verify it worked

- `docs/products/<product>/onboarding/brownfield-report-<date>.md` exists with
  `status: draft` and `phases_completed:` matching the `scope_classification:` (Phases 3/4 are present
  only when docs exist, and explicitly marked skipped otherwise).
- Every recovered artifact carries `recovered: true` + `confidence: HIGH|MED|LOW` +
  `source_artifact:`. Grep for stragglers:

  ```bash
  grep -rL 'recovered:' docs/products/yourproduct/epics/ 2>/dev/null
  ```

- `onboarding/sources/` holds verbatim copies of any ingested docs.
- The §2 coverage matrix has one row per pipeline stage, and every §3 drift row names ≥2 resolution
  paths.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Onboarder refuses to start — "already a CorTxOS product" | `docs/products/<product>/epics/` has `epic-*.md` files lacking `recovered: true` frontmatter | This repo was already onboarded/authored in CorTxOS — use `cortx-orchestrator` in normal mode, not the onboarder. |
| Onboarder refuses to start — missing core references | `architectural-invariants.md` / `pqc-posture.md` not present | Install the core shared references first; Phase 4 needs them to surface posture conflicts. |
| Git archaeology section missing from inventory | `git` not on `PATH` | Install `git`; commit-message ADR proposals are also skipped without it. The report flags the limitation. |
| Existing report would be overwritten | A prior `brownfield-report-*.md` exists | The onboarder asks whether to resume from `phases_completed:` or start fresh — it never silently overwrites. Use `--restart-from 0` to archive the prior run and begin clean. |
| `product-manager` won't generate a backlog | Report is still `status: draft` | Work the §5 checklist, then set `status: accepted` yourself. |
| >70% of artifacts came back LOW confidence | Repo is too under-documented for archaeology to pay off | The onboarder's meta-cognition recommends a targeted rewrite-in-place with explicit greenfield CorTxOS adoption instead. |

## When NOT to use brownfield-onboarder

| Situation | Use instead |
|-----------|-------------|
| Greenfield repo — no code, no docs, just an idea | `ideator` → normal pipeline (see [local-only](scenarios/local-only.md)). |
| Already a CorTxOS product | `cortx-orchestrator` in normal mode. |
| Recover specs from a single module | `spec-archaeologist` directly. |
| A CorTxOS product that has accumulated drift | `drift-monitor` + `skill-improver`. |

## See also

- [getting-started](../getting-started.md) — install, build the runtime, first run.
- [scenarios: local-only](scenarios/local-only.md) — local greenfield **and** brownfield, no gateway.
- [scenarios: mcp-persistence-brownfield](scenarios/mcp-persistence-brownfield.md) — expose the
  onboarded repo's skills to an MCP host with durable memory.
- [architecture: knowledge & memory](../architecture/knowledge-and-memory.md) — the cortx-brain
  layers the onboarder populates.
