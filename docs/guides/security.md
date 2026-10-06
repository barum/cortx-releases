# CorTxOS v6.16.0 — Security Posture

This guide describes the CorTxOS v6.16.0 security model: cryptographic signing, the proof/trust model,
the sandbox and capability model, policy-as-code, authentication/authorization, and the compliance
posture. It is derived from the live runtime, `SECURITY.md`, and the shared posture references.

For vulnerability reporting, see [SECURITY.md](../../SECURITY.md). For the proof model in depth, see
[proof and trust](../architecture/proof-and-trust.md).

> **Read the operational caveat first.** Per `SECURITY.md`, governance gates (tier-ceiling, HITL
> approval, observability breaker, kill-switch) are wired into dispatch but **default to Advisory
> mode** — production enforcement requires `CORTX_SECURITY_PROFILE=production`. The run-report signing
> default is currently `Ed25519Demo`: the crate-level `SignatureAlgorithm::default()` is already
> ML-DSA-87, but the live run-report path has not been flipped to PQC yet (tracked under audit H3-2).
> No product pipeline has yet run end-to-end under the production profile. The skill corpus under
> `skills/`, `shared/`, and `scripts/` is treated as **curated, trusted content**; filesystem/process
> isolation around skill execution is **defense-in-depth only**. wasmtime/container sandboxing for
> untrusted skills is scoped to the v7.0 line.

## Post-quantum signing

CorTxOS signs its work products with **ML-DSA-87 (FIPS 204)** as the target default, with **Ed25519**
retained for back-compatibility. The signing crate (`runtime/crates/cortx-core/src/signing.rs`) carries
both algorithms; the workspace pins `pqcrypto-mldsa` and `ed25519-dalek` (`runtime/Cargo.toml`).

Signed surfaces:

- **Run reports** — every pipeline run report carries a signature.
- **Skill bundles** — registry bundle pulls return a signed `SKILL.md` bundle verified client-side.
- **Asset-pack manifests** — embedded asset packs are signed.
- **`plugin.json`** — the plugin descriptor is signed.

> The Ed25519 run-report signing key (`docs/cortx/.run-report-signing-key`) must remain `chmod 0600`
> and per-machine. Never commit it, never share it.

## Proof and trust model

See [proof and trust](../architecture/proof-and-trust.md) for the full design. In summary:

- **Replay-certified bundles** — `cortx certify` / `cortx verify` produce and check
  Replay-Certified Proof-of-Work-Product bundles; the merkle root is the anchor of the certified set.
- **Tamper-evident audit log** — `audit_log_events` (migration `0004_audits.sql`) is append-only and
  hash-chained: each row carries the SHA-256 of the prior row's full payload, enforced by a
  `BEFORE INSERT` trigger. Breaking the chain is detectable on read.
- **Merkle anchors** — certified bundles and the audit chain anchor to Merkle roots, giving
  cryptographic evidence of integrity over time.

## Sandbox model

| Surface | Control | Behavior |
|---------|---------|----------|
| Skill execution sandbox | `CORTX_SANDBOX` | Selects the sandbox backend (`landlock` on Linux; delegates to a WSL2 guest on Windows per GAP-SBX002, attested as `wsl2`; `none` on macOS, GAP-SBX001); reflected by `GET /v1/config/sandbox` |
| Container resource caps | `CORTX_SANDBOX_CPUS` / `CORTX_SANDBOX_MEMORY` / `CORTX_SANDBOX_PIDS` | GAP-SBX010: CPU/memory/pid ceilings on the `container` backend only; default 2 cpus / 4g / 256 pids |
| Browser fetch | `CORTX_BROWSE_ENABLE` | `cortx browse` is **default-deny / fail-closed** — it refuses unless `CORTX_BROWSE_ENABLE=1`, then enforces an allowlist |
| MCP | Capability scoping | Per-tool capability scoping + network egress allowlists |

- **`CORTX_SANDBOX`** selects the OS-level isolation backend. On Linux, **landlock** confines skill
  process filesystem access. On Windows (GAP-SBX002), a `landlock` request transparently delegates
  to a **WSL2** guest (`wsl.exe`) when one is reachable — a genuinely separate kernel/namespace
  boundary from the Windows host process, not filesystem-path-scoped confinement like Linux
  Landlock — and the run report attests the real applied kind, `sandbox:wsl2`, never a fabricated
  `sandbox:landlock`; with no WSL2 guest reachable it falls back to `sandbox:none`, same as macOS
  (GAP-SBX001, still unconfined). See
  [the GAP-SBX002 decision record](../architecture/decisions/GAP-SBX002-windows-sandbox-wsl2-delegation.md)
  for the full candidate comparison (AppContainer / Windows Sandbox / low-integrity tokens / WSL2).
- **The default is now product-wide, not MCP-only (GAP-SBX004).** When `CORTX_SANDBOX` is unset,
  every dispatch entry point — `cortx dispatch`/`cortx run` (CLI), the `cortx-gateway` job worker
  (which spawns `cortx dispatch` as a child and passes it the resolved kind), and `cortx mcp` —
  defaults it to `landlock` on Linux (or the WSL2 delegation above on Windows) when a working
  backend is actually available, and truthfully leaves it `none` when it isn't (macOS, or
  Windows/Linux with no reachable backend). This default logic previously lived only in
  `cortx-mcp`; it now lives in `cortx-pipeline::sandbox::ensure_default_sandbox_env` and is called
  from every surface. Set **`CORTX_SANDBOX=none`** explicitly to opt back out on any surface — an
  unrecognised value (e.g. a typo) is refused with an error rather than silently downgraded to
  `none`.
- **Resource caps on the container backend (GAP-SBX010).** When `CORTX_SANDBOX=container` resolves,
  every dispatch is wrapped with `--cpus`, `--memory` and `--pids-limit` — CPU, memory and process-
  count ceilings enforced by podman/docker, not merely `--network none` filesystem/network
  isolation. Defaults are deliberately generous (a too-tight cap turns into dispatch failures that
  look like model/network flakiness, not a security signal): **2 cpus**, **4g** memory, **256**
  pids. Override per-field with **`CORTX_SANDBOX_CPUS`**, **`CORTX_SANDBOX_MEMORY`**,
  **`CORTX_SANDBOX_PIDS`**; an empty or unparseable override falls back to the default rather than
  reaching the container runtime as an invalid value. The applied caps (never the caps that *would*
  apply for a different backend) are recorded in the run report manifest alongside `sandbox:<kind>`
  — nothing is recorded when no cap was applied, matching the same resolve()-not-requested
  attestation discipline as `sandbox:<kind>` itself. **Scope note:** today only the container
  backend applies these caps; the non-container Landlock/WSL2 paths do not yet enforce a
  process-level `RLIMIT_AS`/cgroup memory ceiling on Linux (tracked separately) — do not read this
  section as claiming an OS-level memory/CPU cap on every `CORTX_SANDBOX` kind, only on `container`.
- **`cortx-browse`** (`runtime/crates/cortx-browse`) is an allowlisted, fail-closed HTTP fetch: it
  refuses all fetches unless `CORTX_BROWSE_ENABLE=1` and the target matches the allowlist.
- **MCP** capabilities are scoped per-tool with network egress allowlists. Per `SECURITY.md`, the MCP
  server has no per-tool authn today — do not connect `cortx-mcp` to untrusted MCP clients.
- **Seccomp-BPF syscall filter (GAP-SBX003).** On Linux, whenever `landlock` applies, a
  seccomp-BPF filter installs on the SAME confined child, inside the same `pre_exec` closure
  immediately after Landlock's own restriction — closing a gap Landlock cannot reach by design
  (it is scoped to filesystem paths and cannot filter syscalls generally, at any ABI level).
  It is a **denylist**, not a full allowlist: `ptrace`, `process_vm_readv`/`process_vm_writev`,
  `mount`/`umount2`/`pivot_root`/`open_by_handle_at`/`name_to_handle_at`, `unshare`/`setns`/`bpf`/
  the kernel-module and `kexec` family, the `keyctl` family, and misc privileged surface
  (`reboot`, `swapon`/`swapoff`, `acct`, `quotactl`, `perf_event_open`) are refused with
  `SCMP_ACT_ERRNO(EPERM)`. Covers x86_64 and aarch64; the run report's `seccomp:applied` /
  `seccomp:unavailable` entry reflects a real functional check, never a fabricated claim on a
  kernel built without `CONFIG_SECCOMP_FILTER` or an uncovered CPU architecture. This is
  defense-in-depth against a compromised confined process pivoting off Landlock's filesystem
  scope — it is **not** a claim that the remaining syscall surface is bounded; a full positive
  allowlist is future work.
- **OS-level TCP egress boundary (GAP-SBX006).** On Linux, whenever `landlock` applies, the same
  Landlock ruleset also handles `AccessNet` (TCP bind + connect), at the same ABI ceiling as the
  filesystem rules. **Default posture is deny-all-TCP** — the confined skill subprocess (not just
  the pre/post-invoke hooks) cannot open any outbound TCP connection unless explicitly
  allowlisted. Set **`CORTX_EGRESS_ALLOW_TCP_PORTS`** to a comma-separated list of local TCP
  ports (e.g. `443,8080`) to open exactly those ports; unset, empty, or containing even one
  malformed entry all fail closed to the empty (deny-all) list — a typo never silently widens
  access. **This is a PORT allowlist, not a host allowlist**: `AccessNet` has no concept of
  remote host/domain, and covers neither UDP nor DNS resolution — do not confuse it with
  `cortx-browse`'s or `enforce_egress_allowlist`'s per-host application-layer controls above,
  which remain the only host-scoped egress control CorTxOS has. The run report's
  `egress:deny-all-tcp` / `egress:allow-tcp-ports:<ports>` / `egress:unavailable` entry reflects
  a real functional probe (a disposable child's actual connect attempt), not merely "was
  `AccessNet` requested" — an older kernel/ABI can silently accept the request without enforcing
  it, and the manifest says `unavailable` in that case rather than overclaiming. A netns +
  filtering-proxy route (the `anthropic/claude-code` pattern) would close the host-allowlist gap
  but is substantially more work — out of scope for this pass.
- **Per-destination-host egress allowlist (GAP-SBX0044).** `AccessNet` above is PORT-granular
  only. Set **`CORTX_EGRESS_ALLOW_HOSTS`** (comma-separated `host`, `host:port`, or
  `[ipv6]:port` entries; port defaults to 443) to additionally restrict a Landlock-confined
  child's TCP egress to specific destination HOSTS, resolved to concrete IPv4 addresses at
  dispatch time. Enforcement is a `connect()`-intercepting shim injected via `LD_PRELOAD` that
  checks the REAL destination `sockaddr` the kernel is about to dial — never a Host header or
  TLS SNI — so a connection dressed up with an allowlisted-sounding Host header while dialing a
  different, non-allowlisted address is refused exactly like any other non-allowlisted
  destination (domain-fronting is ineffective against it). `build_ruleset` unions the
  host-derived ports into the same `NetPort` allowlist `CORTX_EGRESS_ALLOW_TCP_PORTS` populates,
  so the kernel layer doesn't block the syscall before the shim's userspace check runs. A
  configured-but-unresolvable allowlist REFUSES the dispatch outright (fail-closed) rather than
  spawn a child the operator believes is host-restricted but isn't. The run report records
  `egress:allow-hosts:<sorted csv>` as its own manifest entry alongside the existing
  `egress:<ports posture>` one. **Linux (Landlock) only**: `sandbox-exec` (macOS Seatbelt)
  strips `DYLD_INSERT_LIBRARIES` from the child's environment before it starts — verified
  empirically — and SBPL's own `(remote ip ...)` predicate accepts only the literal host values
  `*`/`localhost`, so `SeatbeltBackend::spawn` refuses a dispatch that sets
  `CORTX_EGRESS_ALLOW_HOSTS` rather than silently spawn an unrestricted (or falsely-attested)
  child. See `runtime/crates/cortx-pipeline/src/sandbox.rs`'s "GAP-SBX0044" module doc comment
  and `runtime/crates/cortx-pipeline/src/egress_shim/shim.c` for the full mechanism and its
  stated limits.

### Container sandbox image pin (GAP-SBX012)

The `container` sandbox backend (`runtime/crates/cortx-pipeline/src/sandbox.rs::container_backend`)
wraps the pre/post-invoke bash hooks in a `podman`/`docker run`. Its base image reference must be
**digest-pinned** — `<repo>@sha256:<64 lowercase hex>` — never a mutable tag: a tag's content can
change on every upstream rebuild, which would make the isolation boundary itself supply-chain
untrusted (an attacker who can influence the upstream tag, or a registry compromise, changes what
runs inside "the sandbox" without any change on this side).

- **Default.** `CORTX_SANDBOX_IMAGE` unset resolves to a digest-pinned default,
  `docker.io/library/debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818`
  (resolved 2026-07-30; see the dated comment above `DEFAULT_SANDBOX_IMAGE` in `sandbox.rs` for the
  exact resolution command and history).
- **Refused by default.** An operator-supplied `CORTX_SANDBOX_IMAGE` without an `@sha256:` digest is
  refused (`SandboxError::UnpinnedImage`, naming the offending reference) before the container
  runtime is even invoked — it is not silently accepted and not silently downgraded.
- **Escape hatch.** Set `CORTX_SANDBOX_IMAGE_ALLOW_UNPINNED=1` to opt back into an unpinned tag. This
  is off by default and logs a `tracing::warn!` naming the image every time it is used — treat any
  occurrence of that warning in production logs as worth investigating.
- **Rotation procedure.** To move the pin forward (e.g. to pick up upstream CVE fixes to the base
  layer, or to point at a different base image):
  1. Resolve the new digest against the target tag, e.g.:
     ```sh
     TOKEN=$(curl -s 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/debian:pull' | jq -r .token)
     curl -sI -H "Authorization: Bearer $TOKEN" \
       -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.index.v1+json' \
       https://registry-1.docker.io/v2/library/debian/manifests/bookworm-slim | grep -i docker-content-digest
     ```
     (equivalently, `podman image inspect --format '{{.Digest}}'` or `docker buildx imagetools
     inspect` against a locally pulled image).
  2. Update `DEFAULT_SANDBOX_IMAGE` in `sandbox.rs`, replacing the resolution-date comment above it.
  3. Re-run `cargo test --manifest-path runtime/Cargo.toml -p cortx-pipeline --lib sandbox`; the
     `default_sandbox_image_is_digest_pinned` test enforces the new value's shape.
  4. Record the rotation in the release notes: a pinned base image is a maintenance obligation — it
     stops receiving upstream rebuilds (including CVE fixes) until a rotator repeats this procedure,
     so an un-rotated pin drifts into staleness exactly like any other frozen dependency. Pair pin
     rotation with `dependency-updater` / `vulnerability-and-cve-coordinator` coverage rather than
     letting it go stale indefinitely.
- **Out of scope for this pin:** signature verification (cosign/notation) of the image content. A
  digest pin makes the image immutable and auditable; verifying *what was pushed* against a trust
  root is a separate follow-on that needs its own key-distribution story.

## Policy-as-code, capabilities, and the kill switch

- **`cortx-policy`** (`runtime/crates/cortx-policy`) expresses governance as code rather than prose.
- **Capability declarations** — each skill declares its capabilities/tools; the runtime enforces the
  `tools:` allowlist (subset of `[Read, Write, Edit, Bash, Grep, Glob, WebSearch, WebFetch,
  TodoWrite]`) to scope prompt-injection blast radius.
- **`requires-predecessor` gates** — skills can require an upstream predecessor before they run,
  enforcing pipeline ordering.
- **Agent kill switch** — `POST /v1/admin/agent/halt` (`runtime/cmd/cortx-gateway/src/routes/admin.rs`,
  REG-0560) halts cost-incurring / high-impact agents. The kill switch **fails closed** (REG-0610): a
  present-but-corrupt or unreadable `agent-halt.json` is treated as halted, not as "safe to proceed".
  Operator recovery is to delete the flag (`halt::release`). The halt route requires the
  `PRIVATE_REGISTRY` feature — Free tier is denied.

## Authentication and authorization

- **JWT** — the gateway authenticates every route except `/v1/health` on an **HS256** JWT validated
  against `CORTX_GATEWAY_SHARED_SECRET` (`runtime/cmd/cortx-gateway/src/auth.rs`). With no secret and no
  dev bypass, mutating routes are rejected.
- **SSO** — OAuth / SAML / OIDC for enterprise identity (SSO is a paid-tier feature).
- **OIDC single sign-on** — the gateway ships a full OpenID Connect Authorization Code + PKCE (S256)
  flow via two public (no-JWT) endpoints (`runtime/cmd/cortx-gateway/src/routes/oidc.rs`):

  | Endpoint | Handler | Behavior |
  |----------|---------|----------|
  | `GET /v1/auth/oidc/login` | `routes::oidc::login` | Resolves the IdP discovery document; generates a CSRF `state`, a replay-defeating `nonce`, and a PKCE `code_verifier`/`code_challenge`; stores the one-time transaction server-side (TTL); 303-redirects to the IdP `authorization_endpoint`. `?mode=json` returns `{authorize_url, state}` instead of redirecting. |
  | `GET /v1/auth/oidc/callback` | `routes::oidc::callback` | Consumes the one-time `state`, exchanges the code (with the PKCE `code_verifier`) at the `token_endpoint`, **verifies the `id_token` signature** against the IdP JWKS (RS256/RS384/RS512) plus `iss`/`aud`/`exp`/`iat`/`nbf`/`nonce`, maps IdP group claims to gateway roles, and mints an 8h gateway HS256 JWT. Returns `{token, expires_at, user_id}`, or 303-redirects to `CORTX_OIDC_POST_LOGIN_REDIRECT` with the token in the URL fragment when set. |
  | `POST /v1/auth/oidc` | `auth_route::oidc_exchange` | **Deprecated** in favour of the login+callback flow. **Hardened**: a returned `id_token` is now signature-verified against the discovery JWKS (RS256/384/512) with `iss`/`aud`/`exp` validated before any identity is trusted — a forged `id_token` yields `401`. Providers that return no `id_token` keep the OAuth2 userinfo fallback, so existing callers are unaffected. |

  The OIDC endpoints are gated by the **`SSO_OIDC`** feature (Business tier, inherited by Enterprise;
  ships alongside `SSO_SAML`), enforced **only** when license enforcement is configured
  (`CORTX_LICENSE_PATH` + `CORTX_LICENSE_PUBKEY_HEX` set). Configuration is env-driven:

  | Variable | Required | Default |
  |----------|----------|---------|
  | `CORTX_OIDC_ISSUER` | yes | — (IdP issuer base URL) |
  | `CORTX_OIDC_CLIENT_ID` | yes | — (OAuth client id; also the `id_token` aud) |
  | `CORTX_OIDC_CLIENT_SECRET` | no | unset (omit for public + PKCE clients) |
  | `CORTX_OIDC_REDIRECT_URI` | no | `http://127.0.0.1:8080/v1/auth/oidc/callback` |
  | `CORTX_OIDC_SCOPES` | no | `openid profile email` |
  | `CORTX_OIDC_POST_LOGIN_REDIRECT` | no | unset (if set, callback 303-redirects here with `#token=...&expires_at=...`) |
  | `CORTX_OIDC_DISCOVERY_URL` | no | `{issuer}/.well-known/openid-configuration` |
  | `CORTX_OIDC_CLOCK_SKEW_SECS` | no | `60` |
  | `CORTX_OIDC_STATE_TTL_SECS` | no | `600` |
  | `CORTX_OIDC_JWKS_TTL_SECS` | no | `3600` |
  | `CORTX_OIDC_GROUPS_CLAIM` | no | `groups` (shared with the github/google/microsoft OAuth handlers) |

  > **HA note.** The `state` transaction is held in-process (like the rate limiter and SSE run
  > channels), so a multi-replica deployment must enable session affinity / sticky sessions so
  > `/login` and `/callback` land on the same replica.
- **RBAC + tiers** — roles (`owner` / `admin` / `member`) and plan tiers
  (`free` / `team` / `business` / `enterprise`) gate access; paid features return `402` to Free tier.
- **Production fail-closed checks** — `CORTX_GATEWAY_PRODUCTION=1` requires `DATABASE_URL` with a
  migrated schema and the `postgres` feature; `CORTX_GATEWAY_DEV_AUTH` must be unset / `0` so RBAC and
  402 tier enforcement stay live. Missing `CORTX_GATEWAY_SHARED_SECRET` rejects mutating routes.

## Compliance posture

CorTxOS targets the following frameworks. Several are **aspirational** at v6.16.0 (notably FedRAMP
High); the SECURITY.md operational posture is authoritative on what is actually enforced today.

| Framework | Posture |
|-----------|---------|
| FedRAMP High | Aspirational; tamper-evident audit log + signed offline licenses are the supporting controls |
| CMMC L3 | Aspirational |
| SOC 2 | Aspirational |
| GDPR | Right-to-erasure supported via `cortx memory erase` |
| ITAR | Aspirational |

Supporting controls:

- **Row-Level Security (RLS)** in Postgres — every tenant-scoped table carries `tenant_id` as its first
  column with RLS enabled; the gateway connects as `cortx_app` and sets `app.tenant_id` per request via
  `SET LOCAL`.
- **Tamper-evident audit** — `audit_log_events` hash chain (see [proof and trust](#proof-and-trust-model)).
- **Signed offline licenses** — `runtime/crates/cortx-license/src/issuer.rs`.
- **GDPR erase** — `cortx memory erase` removes durable memory for a subject.

## Reporting a vulnerability

Do **not** open public GitHub issues for security reports. Send to **security@cortxos.dev**, encrypt
sensitive details with the maintainer PGP key, and include a minimal reproduction, the repo HEAD SHA,
and your impact assessment. Maintainers acknowledge within 3 business days, triage within 10, and
default to a 90-day coordinated-disclosure timeline. Full policy, in-scope/out-of-scope lists, and the
supported-version matrix are in [SECURITY.md](../../SECURITY.md).
