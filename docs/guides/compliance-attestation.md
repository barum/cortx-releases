# CorTxOS v6.16.0 — Compliance Attestation Packages

`cortx attest` generates auditor-facing compliance packages — **SSP, SOC 2, FedRAMP, CMMC, and an ATO
readiness memo** — by mapping a curated, real control catalog to *located* CorTxOS evidence and
rendering Markdown + machine-readable JSON. It is backed by the
[`cortx-compliance`](../../runtime/crates/cortx-compliance) crate.

See also: [security](security.md) · [architecture: proof & trust](../architecture/proof-and-trust.md)
· [CLI reference](../cli/cortx.md).

> **Honest scope — read first.** This produces the audit **package**, not an attestation. CorTxOS
> cannot self-certify: a SOC 2 report requires a licensed CPA firm, a FedRAMP ATO requires a 3PAO
> assessment and an Authorizing Official's signature, and CMMC requires a C3PAO. What you get is the
> *evidence-of-record* an assessor consumes — every control gets a row, every row points at a concrete
> artifact (a file, a ledger record, or a posture with a source pointer), and every row carries an
> unambiguous status: **pass / mitigated / gap**. An empty evidence set is a gap, never a pass. The
> catalogs are **curated baselines** (the high-signal controls CorTxOS has evidence for), not the
> complete frameworks; each package states its control count.

## Usage

```bash
# Generate all five packages (Markdown + JSON) into docs/cortx/compliance/
cortx attest all

# A single framework
cortx attest ssp
cortx attest soc2 --format md
cortx attest fedramp --out ./audit-2026Q3
cortx attest cmmc
cortx attest ato            # synthesizes across SSP/800-53 + SOC 2 + CMMC
```

Flags: `--out <DIR>` (default `docs/cortx/compliance`), `--evidence <DIR>` (where `trust-report.json`
lives, default `docs/cortx`), `--format both|md|json` (default `both`), `--system <NAME>` (default
`CorTxOS`). The report kind is `ssp` | `soc2` | `fedramp` | `cmmc` | `ato` | `all`.

> `attest` is a `cortx-runtime` subcommand proxied by the `cortx` wrapper. From a source checkout you
> can also call `./runtime/target/release/cortx-runtime attest …` directly.

## What each report is

| Report | Standard basis | Contents |
|---|---|---|
| **SSP** | NIST SP 800-53 Rev 5 | Control-implementation summary, grouped by family, with located evidence per control + POA&M. |
| **SOC 2** | AICPA Trust Services Criteria (2017) | CC-series + Availability/Confidentiality/Processing-Integrity criteria mapped to evidence. |
| **FedRAMP** | NIST SP 800-53 Rev 5 (High) | Same 800-53 basis as the SSP, framed as a baseline package with a POA&M for every open item. |
| **CMMC** | NIST SP 800-171 Rev 2 (CMMC mapping) | Practices by domain (AC/AU/CM/IA/RA/CA/SC/SI/IR). |
| **ATO** | — (synthesis) | Executive readiness memo: combined readiness, per-framework rollup, residual risks, POA&M, and a recommendation (Authorize / Authorize-with-conditions / Not-recommended). |

## How status is decided

Each control carries one or more **located-evidence probes**:

- `FileExists` — a concrete artifact on disk (e.g. `docs/cortx/.run-report-mldsa-key`).
- `JsonlNonEmpty` — a ledger with records (e.g. `docs/cortx/audit-chain.jsonl`).
- `TrustFloor` — a numeric field in `trust-report.json` clears a floor (e.g. eval-fixture coverage).
- `Posture` — a build-level architectural invariant with a source pointer (e.g. ML-DSA-87 signing).

A control is **Pass** only when *every* probe is satisfied; some-but-not-all is **Mitigated**; none is
a **Gap**. The package summary reports `readiness = (pass + 0.5·mitigated) / total`.

## Example output

Running `cortx attest ato` against this repo produces (abridged):

```text
✓ Authority to Operate (readiness memo) → docs/cortx/compliance/ato.md
  ato — readiness 99.1% (pass 52, mitigated 1, gap 0)
```

The ATO memo's recommendation downgrades from full *Authorize to Operate* to *…with conditions*
whenever any control is less than fully met, and lists the mitigated/gap controls as residual risks +
POA&M rows — so the memo never overstates readiness.

## Where the evidence comes from

The probes read the live repository and the runtime state under `docs/cortx/`
(`trust-report.json`, `audit-chain.jsonl`, `metrics.jsonl`, signing keys), the gateway migrations
(`runtime/migrations/0002_identity.sql` for identity/RBAC), CI config, and architectural postures
(PQC signing, replay-certified proofs, RBAC + tier ceilings, sandboxing). Because the probes evaluate
against real files at run time, the same command on a stripped-down checkout will honestly report
gaps — the generator never fabricates a pass.

## CI use

`cortx attest` exits `0` on successful generation (gaps are normal output, not a failure), so it fits
a scheduled "refresh the audit binder" job. To gate on readiness, parse the JSON `summary.readiness_pct`
/ `summary.gap` from the emitted `<kind>.json`. Pair with
[`cortx-runtime verify`](../architecture/proof-and-trust.md) to bind the package to signed, replayable
run evidence.
