# CorTxOS — Operating a Disconnected (Air-Gapped) Site End to End

GAP-AIR005: the two runbooks that existed before this one each cover half the problem —
[deployment.md](deployment.md) covers standing up the **gateway control plane** air-gapped, and
[auditor-reproducibility-proof.md](scenarios/auditor-reproducibility-proof.md) covers **consuming**
a signed proof with no network. Neither covers **producing work** — running the agent loop itself —
on a disconnected host. This guide composes all three, plus the local-model runbook
([local-model.md](scenarios/local-model.md)) and the egress-lockdown switch
(**GAP-AIR003**), into one lifecycle: what crosses the boundary, how you install it, how you run
the loop, how you update, and how you verify you are actually offline.

**Read this first — what this guide can and cannot promise today.** See
[Known limits](#known-limits) before you plan a cutover. In short: the transfer manifest and the
install/run/verify phases below are real and usable today, and the runtime-enforced egress-lockdown
switch (**GAP-AIR003**, `CORTX_OFFLINE=1`) **has landed** and is a single flag you set — but it is
not a blanket "zero egress" guarantee for every subsystem in the tree. It closes provider selection,
the shared HTTP chokepoint, self-update, the MCP browser tool, skill-source registration, and CLI
startup/marketplace verbs; it does **not yet** close the Forge/GitHub client, Anchor, OTLP
export, the remote (E2B) sandbox, gateway posts, the per-token stream tee, `cortx_http_fetch`, or
the marketplace MCP tools — those still rely on the per-subsystem controls this guide already
documented. The egress-accounting table below is generated directly from a scan of the source
(`scripts/gen-egress-table.sh`; enforced by `scripts/check-doc-sync.sh`) so this list cannot drift
out of sync with the code the way the earlier "not landed" claim did.

## The five phases

1. [Prepare — the transfer manifest](#1-prepare--the-transfer-manifest)
2. [Install — bring the control plane up disconnected](#2-install--bring-the-control-plane-up-disconnected)
3. [Run — the agent loop with no egress](#3-run--the-agent-loop-with-no-egress)
4. [Update — moving a new version across the boundary](#4-update--moving-a-new-version-across-the-boundary)
5. [Verify — proving the site is honest](#5-verify--proving-the-site-is-honest)

---

## 1. Prepare — the transfer manifest

Everything below is produced on a **connected** build host and carried across the boundary on
removable media (or a one-way transfer diode). Each row names the exact command that produces the
artifact on the connected side and the command that verifies it on the disconnected side.

| Artifact | Produce (connected host) | Verify (disconnected host) |
|---|---|---|
| `cortx` binary + `.sha256` | `cargo build --manifest-path runtime/Cargo.toml -p cortx-runtime --release` (or download from `barum/cortx-releases`) | `sha256sum -c cortx-runtime-<triple>.sha256` |
| Helm chart | `helm package deploy/helm/cortx-cloud -d dist/` (or the `helm-package` job in `.github/workflows/onprem-artifacts.yml`) | `helm lint dist/cortx-cloud-*.tgz` then `helm template dist/cortx-cloud-*.tgz` |
| Container images (`cortx-gateway`, `postgres-cortx`) | `scripts/build-images.sh --sign --key cosign.key --sbom` (**GAP-ENT015** — the image and its Dockerfile now exist; see [Known limits](#known-limits) for the residual mirroring gap) | `cosign verify --key cosign.pub <image>` then `docker load < cortx-gateway-<ver>.tar` |
| SBOM (CycloneDX) | produced alongside the image by the same `build-images.sh --sbom` run | `jq '.components \| length' cortx-gateway-sbom.cdx.json` (non-zero) |
| Offline licence file | issued by CorTxOS licensing (out of band — see [deployment.md](deployment.md), "Licensing") | `cortx license verify --file ./cortx.license` |
| Model weights (for the local LLM provider) | `ollama pull <model>` on a connected host, then transfer `$OLLAMA_MODELS`'s `manifests/`+`blobs/` and a digest manifest — see [air-gapped-models.md](air-gapped-models.md) (**GAP-AIR017**) for the verified, end-to-end procedure and `scripts/airgap-model-verify.sh` | `scripts/airgap-model-verify.sh --verify weights.manifest` exits 0; `ollama list` on the disconnected host shows the model; `curl -fsS http://127.0.0.1:11434/api/tags` |
| Skill corpus (embedded in `cortx`, ADR-0152) | already inside the `cortx` binary — no separate transfer step | `cortx doctor` (or `cortx mcp` startup log) reports 88 skills discovered |
| Reproducibility proof(s) you want an auditor to check later | `cortx-runtime certify ...` per [auditor-reproducibility-proof.md](scenarios/auditor-reproducibility-proof.md) | `cortx-runtime verify --bundle *.cortxproof.json` |

Run `scripts/airgap-preflight.sh` on the disconnected host **before** starting the install phase —
it fails fast, listing exactly which of the above the host is missing or misconfigured (see
[Verify](#5-verify--proving-the-site-is-honest)).

## 2. Install — bring the control plane up disconnected

This phase is [deployment.md](deployment.md)'s Helm/Compose install, unchanged — this guide does not
restate it. Load the images and chart carried across the boundary, point the Helm values at the
mirrored image references (never `ghcr.io/cortxos/...:latest` — `deploy/registry/docker-compose.yml`
already pins a version tag), and mount the offline licence Secret:

```bash
# On the disconnected host, after `docker load`-ing the mirrored images:
kubectl create secret generic cortx-license --from-file=license.json=./cortx.license
helm install cortx-cloud ./cortx-cloud-<ver>.tgz \
  --set gateway.image.repository=<your-internal-mirror>/cortx-gateway \
  --set gateway.image.tag=<ver>
kubectl port-forward svc/cortx-cloud-cortx-cloud-gateway 8080:8080 &
curl http://localhost:8080/v1/health
```

Full detail — secrets, migrations, licensing enforcement, HA tiers — lives in
[deployment.md](deployment.md), section "Helm — Cloud control plane".

## 3. Run — the agent loop with no egress

This is the phase the two prior runbooks did not cover. Running `cortx dispatch` / `cortx agent`
disconnected means every subsystem below either refuses non-loopback egress or is not exercised at
all. `CORTX_OFFLINE=1` (**GAP-AIR003**) is the single switch: it is checked at provider selection
(so an explicit `claude`/cloud pin is overridden to Ollama rather than silently honored), at the
shared HTTP chokepoint every cloud-LLM provider routes through (any non-loopback host is refused
regardless of scheme), and at each of the additional enforcement points listed in the
[egress accounting table](#egress-accounting-table) below.

```bash
# The single switch (GAP-AIR003) — set this on every disconnected run.
CORTX_OFFLINE=1 CORTX_LLM_PROVIDER=ollama OLLAMA_HOST=http://127.0.0.1:11434 \
  cortx dispatch --spec ./spec.md --execute --product my-product
```

`CORTX_LLM_PROVIDER=ollama`/`OLLAMA_HOST` above are not strictly required for the egress guarantee
— `CORTX_OFFLINE=1` alone already forces provider selection to `Ollama` — but set them anyway so
the run fails fast with a clear "Ollama unreachable" error if the local server is not actually up,
rather than a less obvious downstream failure. `CORTX_UPDATE_CHECK=0` is already the default (see
the egress table's Self-update row) and does not need to be set explicitly, but setting it is
harmless and documents intent. **`CORTX_OFFLINE=1` does not cover every subsystem** — see the table
below for exactly which ones still need their own per-subsystem control, and set those too if your
workload touches them.

### Egress accounting table

One row per subsystem in **GAP-AIR003**'s inventory (`docs/epics/X-EXTENSIBILITY/stories/GAP-AIR003.md`,
"Current state" table), plus two enforcement points GAP-AIR003 added beyond that original inventory
(skill-source registration, CLI startup/marketplace verbs). The "Covered by `CORTX_OFFLINE`" column
is **not hand-maintained prose** — it is generated by scanning each subsystem's real source file(s)
for a genuine, non-test, non-comment reference to `CORTX_OFFLINE`:

```bash
scripts/gen-egress-table.sh            # regenerate the table below from a fresh scan
scripts/gen-egress-table.sh --check    # fail if the table below has drifted from the code
```

`scripts/check-doc-sync.sh` runs the `--check` form on every invocation, so a subsystem gaining or
losing `CORTX_OFFLINE` coverage without this table being regenerated fails the doc-sync gate — the
table cannot silently go stale the way the old hand-typed "No for every row" version did.

<!-- BEGIN GENERATED EGRESS TABLE (scripts/gen-egress-table.sh) — do not hand-edit the table below; edit this script instead. -->
<!-- Regenerate with `scripts/gen-egress-table.sh`; `scripts/check-doc-sync.sh` fails if this block drifts from a fresh scan (GAP-OFF0030). -->

| Subsystem | file:line | Covered by `CORTX_OFFLINE` | Residual mitigation today |
|---|---|---|---|
| LLM providers (cortx-llm, incl. `claude_cli.rs`) | `cortx-llm/src/resolve.rs:412-439`, `http.rs:108-122` | Yes | Selection (`resolve_selection`) and the fallback chain resolve to Ollama under `CORTX_OFFLINE=1` even when a skill/env pin names `claude` or a cloud provider explicitly (logged at `warn`, never silent); the HTTP chokepoint (`require_secure_url`) additionally refuses any non-loopback host regardless of scheme for every HTTP-based provider at once |
| Self-update (`cortx-update`) | `cortx-update/src/lib.rs:422-457` | Yes | `require_online_or_loopback` gates every network call in the crate (asset download, Sigstore bundle, sidecar fetch) via the shared `http_get_bytes` chokepoint |
| Forge/GitHub client (`cortx-forge`) | `cortx-forge/src/lib.rs:564,583,658,679,761,786,797,821` | Yes | Do not invoke `cortx forge`/`cortx pr` verbs on a disconnected site; no env gate exists — block `api.github.com` at the firewall if the binary is ever invoked accidentally |
| Browse (`cortx-browse`) | `cortx-browse/src/lib.rs:232` | N/A — already fail-closed | `CORTX_BROWSE_ENABLE` is unset by default (off); leave unset. Note: the MCP `cortx_browser` tool the agent loop actually calls is a separate implementation (`cortx-innovation::browser`, see its own row below), not this crate |
| MCP `cortx_browser` tool (`cortx-innovation::browser`) | `cortx-innovation/src/browser.rs:62-69` | Yes | `navigate_and_screenshot` routes through `cortx_llm::http::require_secure_url` (GAP-AEX0080); a `CORTX_OFFLINE` refusal degrades to an explicitly-labeled synthesized result instead of attempting the fetch |
| Anchor (`cortx-anchor`) | `cortx-anchor/src/lib.rs:90-124` | No | Leave `CORTX_ANCHOR_ENABLED` unset (off by default) |
| OTLP metrics/traces (`cortx-pipeline` `metrics.rs`) | `cortx-pipeline/src/metrics.rs:626,693` | No | Leave `CORTX_OTLP_ENDPOINT` unset (no-op when unset), or point it at an in-cluster collector (loopback/cluster-local, not external) |
| Remote sandbox (`cortx-pipeline` `sandbox.rs`) | `cortx-pipeline/src/sandbox.rs:196` (`https://api.e2b.dev`) | No | Do not select the E2B sandbox kind on a disconnected site; use the local sandbox |
| Gateway posts (`cortx-pipeline` `pipeline.rs`/`adversary.rs`) | `cortx-pipeline/src/adversary.rs:148,154`, `pipeline.rs:2079,2085` | No | Point `CORTX_GATEWAY_URL` at the in-cluster gateway only (loopback/cluster-local); it is a no-op when unset |
| Per-token stream tee (`gateway_stream`) | `cortx-llm/src/gateway_stream.rs:9` | No | Same as above — governed by `CORTX_GATEWAY_URL`, no-op when unset |
| MCP `cortx_http_fetch` | `cortx-mcp/src/lib.rs:1960` (renamed from `cortx_browser_fetch`) | No | Allowlist-only when a skill passes one; do not run skills that call this tool against non-loopback hosts (see GAP-SBX007) |
| Marketplace MCP tools | `cortx-mcp/src/marketplace.rs:100,126,148` | No | Governed by the gateway URL, same as gateway posts above |
| Skill source registration (`cortx sources add`, `cortx-core::sources`) | `cortx-core/src/sources.rs:253-270` | Yes | Fully enforced — `add()` refuses any non-loopback source URL under `CORTX_OFFLINE=1` (AC-8, GAP-AIR003) |
| CLI startup / `cortx marketplace` verbs | `cortx-runtime/src/main.rs` (`validate_offline_gateway_startup`, `marketplace_offline_guard`) | Yes | Fully enforced — `CORTX_OFFLINE=1` with a non-loopback `CORTX_GATEWAY_URL` is a startup error (AC-5), and `cortx marketplace` verbs refuse a non-loopback gateway outright (AC-6, GAP-EXT005) |
<!-- END GENERATED EGRESS TABLE -->

**`CORTX_OFFLINE` is a cooperative in-process refusal, not an OS
boundary.** A skill that shells out to its own `curl` is unaffected by any of the above. The only
hard guarantee is network-layer blocking (firewall / namespace policy / air-gap by construction) —
that is the operator's responsibility, not something this guide or GAP-AIR003 can enforce from
inside the process. The OS-level boundary is tracked separately as **GAP-SBX014**
(epic **S-SANDBOX**).

## 4. Update — moving a new version across the boundary

`cortx self-update` defaults to the public `barum/cortx-releases` repo, which is unreachable from a
disconnected host — but **GAP-AIR016** landed a mirrored/offline update channel, so a live
`cortx self-update` invocation is now the supported path instead of a manual re-run of Phase 1 + 2:

```bash
# On a connected machine, carry exactly two files across the air gap:
curl -LO https://github.com/barum/cortx-releases/releases/latest/download/cortx-runtime-<triple>
curl -LO https://github.com/barum/cortx-releases/releases/latest/download/cortx-runtime-<triple>.sha256

# On the disconnected host:
mv cortx-runtime-<triple> cortx-new && mv cortx-runtime-<triple>.sha256 cortx-new.sha256
CORTX_OFFLINE=1 cortx self-update --from-file ./cortx-new --apply
```

If the site instead maintains an internal static mirror (an HTTP-served directory of `latest.json` +
assets + sidecars — see [`deployment.md`'s "Offline / mirrored update channels"
section](deployment.md#offline--mirrored-update-channels-gap-air016) for the exact layout), point at
it with `--base-url <mirror-url> --mirror` instead of carrying files by hand. Both paths keep the
SHA-256 integrity check (`--from-file` cannot also verify the Sigstore/cosign authenticity gate — no
network to reach the trust root — a mirror can, if it carries the `.sigstore.json` bundles along).
The Helm control-plane image still needs its own mirror (see "Known limits" below) — this section is
about the CLI binary.

## 5. Verify — proving the site is honest

```bash
# Preflight: run BEFORE install/run, fails listing exactly what is misconfigured.
scripts/airgap-preflight.sh

# After install: control plane reachable only on cluster-local/loopback addresses.
curl -fsS http://127.0.0.1:8080/v1/health   # or the in-cluster service DNS name

# After a run: no unexpected outbound connections were made (requires an operator-supplied
# network capture tool; CorTxOS does not ship one — see the egress accounting table above for
# why this is currently a network-layer check, not a `cortx`-reported one).
ss -tnp | grep cortx    # or the site's own network monitoring — anything non-loopback here that
                         # isn't explained by the egress accounting table is a real finding.

# The auditor-facing proof path (fully offline already, no changes needed here):
cortx-runtime verify --bundle ./my-run.cortxproof.json
```

## Known limits

Per **GAP-AIR005** AC-5, this section states plainly what is not yet shippable, rather than
describing a path an operator cannot actually walk:

- **The egress-lockdown switch (`CORTX_OFFLINE`) has landed — GAP-AIR003 — but does not cover every
  subsystem yet.** Phase 3's single-switch command is real: provider selection, the shared HTTP
  chokepoint, self-update, the MCP browser tool, skill-source registration, and CLI
  startup/marketplace verbs all refuse non-loopback egress under `CORTX_OFFLINE=1`. The
  [egress accounting table](#egress-accounting-table) — generated from a code scan, not hand-typed
  — names exactly which subsystems still need their own per-subsystem control (Forge/GitHub client,
  Anchor, OTLP export, the remote/E2B sandbox, gateway posts, the per-token stream tee,
  `cortx_http_fetch`, and the marketplace MCP tools as of this writing) and network-layer blocking
  remains the only hard guarantee regardless of how many subsystems the switch eventually covers —
  see the "cooperative in-process refusal, not an OS boundary" note above.
- **The mirrored update channel now exists — GAP-AIR016 (landed).** `cortx self-update
  --from-file`/`--mirror` is usable on a disconnected site; see Phase 4 above.
- **The container images now exist and are buildable — GAP-ENT015 (landed).** Prior versions of
  this guide would have had to say the control-plane half of Phase 1 was not walkable at all,
  because no Dockerfile for the CorTxOS product image existed anywhere in the tree. That is fixed:
  `packaging/docker/cortx-gateway.Dockerfile` and `scripts/build-images.sh` produce a signed, SBOM'd
  image today. What remains open is **mirroring** that image into an internal registry the
  disconnected site can pull from — the produce/verify commands in Phase 1 assume the operator has
  set up such a mirror; this guide does not prescribe one, since mirror tooling varies by site.
- **Model weight distribution now has a verified, first-class procedure — GAP-AIR017 (landed).**
  [air-gapped-models.md](air-gapped-models.md) documents the connected/disconnected transfer
  procedure end to end, verified against a real Ollama installation, plus
  `scripts/airgap-model-verify.sh` for digest verification. It does not add a CorTxOS-controlled
  weight-distribution system — see that guide's "What CorTxOS does not do" — and
  [local-model.md](scenarios/local-model.md) remains the reference for running the agent loop
  against the served model once it has arrived.
