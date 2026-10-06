# CorTxOS — Mirroring Ollama Model Weights to an Air-Gapped Site

**GAP-AIR017.** This guide is one narrow thing: a verified procedure for moving a model's
*weights* from a connected host to a disconnected one, plus a small tool
(`scripts/airgap-model-verify.sh`) that catches transfer corruption. It is **not** a CorTxOS
weight-distribution system — see [What CorTxOS does not do](#what-cortxos-does-not-do) below,
which is not a caveat added after the fact but the reason this guide is scoped the way it is.

This is a section of the broader disconnected-site lifecycle in
[air-gapped-site.md](air-gapped-site.md) (Phase 1, "Model weights" row) — read that guide first if
you haven't stood up a disconnected control plane yet. This guide only covers the model-weight
artifact class, in depth.

## Why Ollama, specifically

CorTxOS has exactly one local-inference path: HTTP to an Ollama daemon
(`runtime/crates/cortx-llm/src/providers/ollama.rs`, `http://127.0.0.1:11434` by default). CorTxOS
never loads a weight file itself — it talks to a server that does. In-process inference
(llama.cpp / candle / a GGUF loader / ONNX / burn) is `wont-fix`
(`GAP-MDL007`, `docs/gaps/_DISPOSITION.md`), so "mirroring weights" here means exactly one thing:
getting Ollama's own on-disk model store from a connected host to a disconnected one intact.

## What was actually verified, and how

Every command and finding below was run against a real Ollama installation (**Ollama 0.31.2**,
Linux) as part of writing this guide — not inferred from Ollama's documentation. Two things came
out of that which the guide below reflects directly:

1. **Whole-directory transfer of `$OLLAMA_MODELS` is the verified, working path.** Copying
   `manifests/` and `blobs/` for a model to a second host (in the test, a second Ollama daemon
   given its own `OLLAMA_MODELS`, isolated from the first) and pointing Ollama at that directory
   was sufficient — `ollama list` showed the model immediately and `POST /api/generate` returned a
   real completion, with **no `ollama create` step at all**.
2. **`ollama create -f Modelfile` against a bare local `.gguf` file failed in this environment**,
   for both a BERT-family embedding model (`all-minilm`) and a Llama-family chat model
   (`smollm2:135m`): `Error: failed to validate GGUF with llama-quantize without compatibility
   patches: llama-quantize failed: signal: aborted (core dumped)`. This is recorded here because a
   guide that silently drops a failing path and only shows the one that worked is exactly the kind
   of unverified documentation this story exists to avoid (see
   [Risks / notes](../epics/X-EXTENSIBILITY/stories/GAP-AIR017.md) in the source story). If a future
   Ollama release fixes this, the `ollama create` path becomes a second valid option for the
   "single file, not the whole store" case; until then, this guide recommends whole-directory
   transfer as the primary method.

## Prerequisites

| Requirement | Needed for |
|---|---|
| Ollama installed identically on both hosts (same version — see [Compatibility list](#compatibility-list-models-actually-run-against-cortxos)) | Serving the transferred store |
| `sha256sum` (Linux) or `shasum` (macOS) on both hosts | `scripts/airgap-model-verify.sh`'s digest checks |
| Removable media or a one-way transfer mechanism | Carrying the model store across the boundary |

## Procedure

### 1. Connected host — pull and locate

```bash
ollama pull <model>          # e.g. ollama pull smollm2:135m
ollama list                  # confirms it landed
```

Ollama stores every model under `$OLLAMA_MODELS` (default `~/.ollama/models`) as two directories:

- `manifests/registry.ollama.ai/library/<model>/<tag>` — a small JSON file (Docker-distribution
  manifest format) listing the model's component blobs by digest (the GGUF weight layer, a
  license text layer, a template layer, a params layer, …).
- `blobs/sha256-<digest>` — the actual content-addressed files. **Ollama already names each blob
  after its own SHA-256 digest**, which is what makes verification below straightforward: a
  blob's filename is a claim about its content, and re-hashing the file checks that claim.

### 2. Connected host — compute and record digests

```bash
scripts/airgap-model-verify.sh --emit-manifest --model <model> > weights.manifest
# omit --model to cover every model currently in $OLLAMA_MODELS
```

This walks the model's manifest JSON, resolves every blob it references, and emits a JSON digest
manifest (model name, Ollama version, each blob's digest and size). Carry `weights.manifest`
across the boundary alongside the model store itself — it is the connected side's attestation of
what the weights were supposed to be.

### 3. Transfer

Copy the two directories (`manifests/<...>/<model>/` and every blob they reference under
`blobs/`) plus `weights.manifest` to the disconnected host's `$OLLAMA_MODELS`, by whatever
removable-media or one-way-transfer mechanism the site uses. This is a plain file copy — no
`ollama` command runs during this step.

### 4. Disconnected host — verify before serving

```bash
scripts/airgap-model-verify.sh --verify weights.manifest --models-dir "$OLLAMA_MODELS"
echo "exit=$?"     # 0 = every blob's digest matches; non-zero = see the corrupted/missing files below
```

On mismatch, the script names every offending blob on stderr, prefixed `MISMATCH:` (digest
doesn't match — corruption) or `MISSING:` (blob absent — an incomplete copy), and exits non-zero.
Do not proceed to serving until this exits 0.

### 5. Disconnected host — serve and point CorTxOS at it

```bash
export OLLAMA_MODELS=/path/to/the/transferred/store   # if not Ollama's default location
ollama serve &
ollama list                          # the transferred model should already be listed — no import step
curl -fsS http://127.0.0.1:11434/api/tags | grep '<model>'

export CORTX_LLM_PROVIDER=ollama
export OLLAMA_HOST=http://127.0.0.1:11434
export CORTX_OFFLINE=1               # GAP-AIR003 — refuses any non-loopback egress in-process
cortx llm complete --provider ollama "reply with the word ready"
```

`ollama list` picking up the model with no `ollama create`/`ollama pull` step is the verified
behavior from this guide's own testing (see [above](#what-was-actually-verified-and-how)) — Ollama
discovers models by walking `$OLLAMA_MODELS/manifests` at startup, so a directory that already has
the right shape is enough.

### 6. Corruption drill (do this once, so the failure mode is not a surprise on a real transfer)

```bash
# Corrupt one byte of any transferred blob:
printf 'x' >> "$OLLAMA_MODELS/blobs/$(ls "$OLLAMA_MODELS/blobs" | head -1)"
scripts/airgap-model-verify.sh --verify weights.manifest --models-dir "$OLLAMA_MODELS"
echo "exit=$?"
# expected: non-zero, with a line "MISMATCH: <path> (expected sha256:<a>, got sha256:<b>)"
# naming the exact corrupted file.
```

This is not hypothetical — it is the exact test this story's own acceptance criteria required
(AC-3), and it was run for real while writing this guide: a corrupted 45 MB blob was correctly
flagged, alongside a deliberately deleted blob correctly reported as `MISSING:`.

## Compatibility list (models actually run against CorTxOS)

Every row below cites a run that happened; nothing here is aspirational. All three runs were on
**Ollama 0.31.2**, Linux, CorTxOS **6.16.0**, 2026-07-30.

| Model | Size | Date | CorTxOS version | Ollama version | Notes on output quality |
|---|---|---|---|---|---|
| `all-minilm:latest` | 45 MB | 2026-07-30 | 6.16.0 | 0.31.2 | Embedding model, not a chat model — no completion output to assess. Served correctly via `/api/tags`; digest-verified via `airgap-model-verify.sh`. `ollama create` from its raw `.gguf` blob **fails** (`llama-quantize` crash, see above); directory transfer works. |
| `nomic-embed-text:latest` | 274 MB | 2026-07-30 | 6.16.0 | 0.31.2 | Embedding model. Served correctly via `/api/tags`; digest-verified. Not exercised through `ollama create` (not attempted — no reason to expect a different result than `all-minilm`'s). |
| `smollm2:135m` | 270 MB | 2026-07-30 | 6.16.0 | 0.31.2 | Chat-capable. Directory-transferred to a second, fully isolated Ollama daemon (separate `$OLLAMA_MODELS`, separate port) and produced a real completion via `POST /api/generate` with no `ollama create` step. Output quality: coherent but did not follow the literal "reply with one word" instruction precisely (`"I'm ready. Let's go over your text..."`) — consistent with [local-model.md](scenarios/local-model.md)'s existing caveat that small local models are weaker at precise instruction-following than the cloud-default providers. `ollama create` from its raw `.gguf` blob **fails** the same way `all-minilm`'s does. |

Larger, general-purpose chat models (`llama3.1`, `llama3.2`, etc., referenced in
[local-model.md](scenarios/local-model.md)) were not pulled for this guide — multi-gigabyte
downloads were out of scope for verifying the *mirroring procedure*, which is size-independent
(the same manifest/blob mechanism applies regardless of model size). Add a row here, following the
same "date + CorTxOS VERSION + Ollama version + honest quality note" format, the next time one is
actually run against CorTxOS.

## What CorTxOS does not do

Stated plainly, per this story's acceptance criteria:

- **CorTxOS does not host model weights.** There is no CorTxOS-operated download source for any
  model; every weight file traces back to whatever registry (`ollama.com` or a private one) the
  operator pulled it from.
- **CorTxOS does not bundle weights in its embedded asset pack.** The asset pack embedded in the
  `cortx` binary (ADR-0152, `runtime/crates/cortx-assets-embedded/src/lib.rs`) is skills and
  references only, with a 1 MiB per-file cap in the builder
  (`runtime/crates/cortx-assetpack/src/lib.rs`) — weights (tens of MB to tens of GB) do not fit
  that model and were never intended to.
- **CorTxOS does not load weights in-process.** It has no GGUF loader, no llama.cpp/candle/ONNX/burn
  dependency, and no plan to add one (`GAP-MDL007`, `wont-fix`). Every inference call is HTTP to a
  daemon CorTxOS does not control.
- **CorTxOS does not vendor a licence for any model.** The operator who pulls a model owns that
  model's licensing; this guide (and CorTxOS generally) takes no position on it.

## Known limits

- **`ollama create -f Modelfile` from a bare local `.gguf` file is currently broken in this
  environment's Ollama 0.31.2** (see [above](#what-was-actually-verified-and-how)). If your site
  needs to construct a model from a raw weight file rather than transferring an already-`ollama
  pull`-ed store, test that path against your own Ollama version before relying on it — do not
  assume it works because Ollama's own docs describe it.
- **Ollama's on-disk layout is Ollama's, not CorTxOS's, and it can change between versions.** The
  [Compatibility list](#compatibility-list-models-actually-run-against-cortxos) records the exact
  Ollama version each row was verified against for this reason. If a transfer fails against a newer
  Ollama with the same shape assumptions, check the installed Ollama version on both hosts first.
- **This guide assumes the digest manifest itself (`weights.manifest`) crosses the boundary
  intact.** `scripts/airgap-model-verify.sh` verifies the *weights* against the manifest; it does
  not itself detect a tampered manifest. Sites with a stronger integrity requirement should sign
  `weights.manifest` the same way [air-gapped-site.md](air-gapped-site.md) signs its other transfer
  artifacts (e.g. `cosign` or an HMAC, per that guide's SBOM/image rows) — that step is left to the
  operator's existing signing tooling rather than duplicated here.
