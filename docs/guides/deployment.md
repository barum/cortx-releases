# CorTxOS v6.16.0 — Operator Deployment Guide

This guide is the operator-facing reference for standing up CorTxOS v6.16.0. It is derived from the
live deploy trees (`deploy/helm/`, `deploy/registry/`, `deploy/observability/`, `deploy/dist/`), the
SQL migrations under `runtime/migrations/`, and `install.sh`.

For gateway-level knobs and request flow, cross-link:

- [Gateway configuration](../gateway/configuration.md)
- [Gateway overview](../gateway/overview.md)

## Deployment targets

CorTxOS ships four distinct deployment surfaces. Pick the one(s) that match your operating model.

| Target | Path | Status | What it deploys |
|--------|------|--------|-----------------|
| Helm (Cloud control plane) | `deploy/helm/cortx-cloud` | Shipping | `cortx-gateway` + Postgres 16 + optional MinIO/Vault |
| Registry | `deploy/registry` | Deployment-pending | Public/private skill registry over `cortx-gateway` `/v1/registry` |
| Observability | `deploy/observability` | Shipping | Grafana + Prometheus + Tempo + OTel Collector (Compose) |
| Binary channels | `packaging/` (+ legacy `deploy/dist` templates) | Shipping (manual release) | Homebrew, Scoop, winget, .deb/.rpm — published to `barum/cortx-releases` with SHA-256 checksums |

### 1. Helm — Cloud control plane (`deploy/helm/cortx-cloud`)

On-prem / air-gapped deployment of the CorTxOS Cloud control plane. The chart installs:

- `cortx-gateway` — Axum HTTP gateway (audit ingestion, skill registry, billing).
- `postgres` (custom `postgres:16-cortx` image) — Postgres 16 with **AGE + pg_jsonschema + pgvector +
  pg_trgm + pgcrypto** preinstalled.
- `minio` (optional) — S3-compatible artifact storage for skill tarballs and audit reports.
- `vault` (optional, external) — tenant signing keys.

The gateway runs the container **read-only, non-root, capabilities dropped**, with NetworkPolicy on.

```bash
# Create the secrets the chart expects
kubectl create secret generic cortx-postgres-credentials \
    --from-literal=password=$(openssl rand -hex 16)
kubectl create secret generic cortx-minio-credentials \
    --from-literal=rootUser=cortx \
    --from-literal=rootPassword=$(openssl rand -hex 24)

# Air-gapped: provide a signed license file
kubectl create secret generic cortx-license \
    --from-file=license.json=./cortx.license

# Install
helm install cortx-cloud ./deploy/helm/cortx-cloud

# Probe
kubectl port-forward svc/cortx-cloud-cortx-cloud-gateway 8080:8080 &
curl http://localhost:8080/v1/health
```

**Migrations auto-run.** Postgres migrations under `runtime/migrations/` apply automatically on gateway
startup via `sqlx migrate run` (0001–0012). See the [migrations table](#the-twelve-migrations).

**Licensing (GAP-RMD016 / GAP-ENT009).** Set `CORTX_LICENSE_PATH` to the mounted license file
(`/etc/cortx/license.json` in the chart above) to enforce a license at all. The verifying key is
**compiled into the `cortx-gateway` binary** (`cortx_license::env::OPERATOR_PUBKEY_HEX`) — there is no
`CORTX_LICENSE_PUBKEY_HEX` / `security.operatorPublicKeyHex` to set in a stock build, and no env var lets
a licensee substitute their own key. Two distinct states:

- **`CORTX_LICENSE_PATH` unset entirely.** Legitimate Free-tier deployment: the gateway starts and serves
  `Tier::Free` (Private Registry, Cloud Replay, MCP Gateway, SSO, Audit History, Emergent Capability
  Detector, Knowledge GC, and ML-DSA signing all disabled).
- **`CORTX_LICENSE_PATH` set but the file is missing, unreadable, malformed, has a bad signature, or is
  expired.** The gateway **refuses to start** (breaking change as of GAP-ENT009 — previously this
  silently downgraded to `Tier::Free` with only an `eprintln!`, so a corrupted license in a monitored
  production deployment could go unnoticed indefinitely). The startup error names the specific cause
  (`BadSignature`, `Expired(<timestamp>)`, `Malformed(...)`, or an I/O error) so an operator's deploy
  pipeline fails loudly instead of quietly serving Free-tier traffic under what looks like a licensed
  deployment.

`CORTX_GATEWAY_DEV_AUTH=1` is refused at startup whenever any production signal is present — a
configured `CORTX_LICENSE_PATH`, a non-loopback `--listen` bind address, or a configured
`CORTX_GATEWAY_SHARED_SECRET`. When dev auth legitimately runs (loopback, no secret, no license), every
request it bypasses logs a `WARN` naming the request path, not only once at startup.

> **Upgrade caution.** Never downgrade Postgres between minor versions without a tested migration path —
> AGE graph rows are not downgrade-safe.

> **Decision record — Enterprise SSO: SAML is not a supported entitlement, use OIDC (GAP-ENT002).**
> *Decider: GAP-ENT002 implementation pass (automated remediation agent, following the story's own
> Option B recommendation and rationale). Date: 2026-07-30.*
>
> `POST /v1/auth/saml/acs` (`routes/saml.rs`) has rejected every SAML assertion unconditionally
> since REG-0218 — there is no vetted pure-Rust XML-DSig implementation that avoids an OpenSSL/C
> dependency, and this repo is rustls-only, cross-platform, no-native-C by standing directive
> (`CLAUDE.md`). That left SAML SSO fail-closed but still *sold*: `Features::SSO_SAML` was granted
> by the Business and Enterprise tiers for a capability that always returns 401. **Decision: stop
> selling SAML SSO as a functioning capability (Option B) rather than build real XML-DSig
> verification (Option A, realistically L/XL effort).** OIDC (`SSO_OIDC`, below) already covers the
> same enterprise SSO need with real JWKS-backed `id_token` signature verification and is the
> supported path going forward.
>
> **Operator impact:** the tier-3 marketing/demo surface (`cortx-innovation/src/tier3.rs`) no
> longer lists `/v1/auth/saml/acs` as part of the SSO offering. `Business`/`Enterprise` licences do
> **not** change in what they grant in this pass — `Features::SSO_SAML` is marked
> deprecated/pending-retirement in `cortx-license/src/lib.rs` but is still technically present in
> `default_features()` for both tiers, because removing it cleanly also requires updating an
> incidental round-trip assertion in `cortx-license/src/issuer.rs` and the SP-metadata assertions in
> `cortx-gateway/tests/gw_admin_fed.rs` + `tests/phase7.rs`, none of which were in this change's
> scope. `GET /v1/auth/saml/metadata` and `POST /v1/auth/saml/acs` remain registered and behave as
> before (metadata still serves a descriptor; ACS still 401s, now with a message naming the OIDC
> path). A follow-up should finish retiring the licence bit and the metadata endpoint together with
> those three files. Restoring real SAML SSO (Option A) remains possible as separate future work,
> starting from a parsed-XML implementation.

**OIDC single sign-on.** The gateway ships an OIDC Authorization Code + PKCE login flow (feature
`SSO_OIDC`, Business tier, inherited by Enterprise). SAML SSO (`SSO_SAML`) is **not** a supported
enterprise SSO path — see the decision record above; use OIDC. Routes served by
`runtime/cmd/cortx-gateway/src/routes/oidc.rs` (public, no gateway JWT required):

| Route | Purpose |
|-------|---------|
| `GET /v1/auth/oidc/login` | Begin Authorization Code + PKCE (S256): resolve the IdP discovery doc, generate `state` (CSRF) + `nonce` (replay defense) + PKCE verifier/challenge, store the one-time transaction server-side (TTL), then 303-redirect to the IdP. `?mode=json` returns `{authorize_url, state}` instead of redirecting. |
| `GET /v1/auth/oidc/callback` | Consume the one-time `state`, exchange the code with the PKCE verifier at the `token_endpoint`, verify the `id_token` signature against the IdP JWKS (RS256/384/512) plus `iss/aud/exp/iat/nbf/nonce`, map IdP group claims to gateway roles, and mint an 8h HS256 gateway JWT. Returns `{token, expires_at, user_id}`, or 303-redirects to `CORTX_OIDC_POST_LOGIN_REDIRECT` with the token in the URL fragment when set. |
| `POST /v1/auth/oidc` | **Deprecated** in favour of the `login` + `callback` flow. Hardened: a returned `id_token` is now signature-verified against the discovery JWKS (RS256/384/512) with `iss/aud/exp` before any identity is trusted (a forged token → HTTP 401); providers that return no `id_token` keep the OAuth2 userinfo fallback, so existing callers are unaffected. |

`SSO_OIDC` (feature bit 14) is enforced on these routes **only** when license enforcement is configured
(`CORTX_LICENSE_PATH` set — see [Licensing](#1-helm--cloud-control-plane-deployhelmcortx-cloud) above);
without a license the routes are open.

Configure the flow with these variables (defaults shown):

| Variable | Required | Default |
|----------|----------|---------|
| `CORTX_OIDC_ISSUER` | yes | — (IdP issuer base URL) |
| `CORTX_OIDC_CLIENT_ID` | yes | — (OAuth client id; also the `id_token` aud) |
| `CORTX_OIDC_CLIENT_SECRET` | no | unset (omit for public + PKCE clients) |
| `CORTX_OIDC_REDIRECT_URI` | no | `http://127.0.0.1:8080/v1/auth/oidc/callback` |
| `CORTX_OIDC_SCOPES` | no | `openid profile email` |
| `CORTX_OIDC_POST_LOGIN_REDIRECT` | no | unset (if set, callback 303-redirects here with `#token=…&expires_at=…`) |
| `CORTX_OIDC_DISCOVERY_URL` | no | `{issuer}/.well-known/openid-configuration` |
| `CORTX_OIDC_CLOCK_SKEW_SECS` | no | `60` |
| `CORTX_OIDC_STATE_TTL_SECS` | no | `600` |
| `CORTX_OIDC_JWKS_TTL_SECS` | no | `3600` |
| `CORTX_OIDC_GROUPS_CLAIM` | no | `groups` (shared with the github/google/microsoft OAuth handlers) |
| `CORTX_OIDC_GROUP_MAP` | no | unset — `"group=role,group2=role2"`; only `org_admin`/`admin`/`editor`/`author`/`dev`/`viewer` are accepted as the role side of an entry |
| `CORTX_GATEWAY_REPLICAS` | no | `1` — set to the actual replica count in a multi-replica deployment; gateway startup fails fast if `>1` without a Postgres-backed pending-auth store (`DATABASE_URL` + `postgres` feature) |

> **Multi-replica (GAP-ENT010): Postgres-backed by default, sticky sessions only as a fallback.** The
> `state`/`nonce`/PKCE transaction store is injectable (`AppState::pending_auth_store`) and mirrors the
> rate limiter: an in-memory default for Tier 0 / single-replica, and a Postgres-backed store
> (`gateway_oidc_pending` table, migration `0012_gateway_oidc_pending.sql`) selected automatically when
> the gateway is built with the `postgres` feature (the default) and `DATABASE_URL` is set — exactly the
> same condition that already makes the rate limiter, kill switch, and SSE run channels HA-safe. With
> that store, `/login` and `/callback` can land on **different** replicas with no sticky sessions; the
> `consume` step is a single atomic `DELETE … RETURNING` so a replayed/racing `state` is still rejected
> exactly once (never a double-win). Sticky sessions / session affinity are only needed as a fallback
> when running multi-replica **without** `DATABASE_URL` — set `CORTX_GATEWAY_REPLICAS` to the replica
> count and the gateway **fails fast at startup** (naming both `CORTX_GATEWAY_REPLICAS` and
> `DATABASE_URL`) rather than silently breaking the first login whose callback lands on a different
> replica than its `/login` did.

**Group-to-role mapping is fail-CLOSED (GAP-ENT008).** `map_roles_from_claims` in
`routes/auth_route.rs` (shared by the OIDC callback, the legacy `POST /v1/auth/oidc` exchange, and the
GitHub/Google/Microsoft OAuth handlers) turns the IdP's `groups` claim (or whatever claim
`CORTX_OIDC_GROUPS_CLAIM` names) into gateway roles:

| IdP group value (case-insensitive) | Gateway role |
|---|---|
| `org_admin`, `admin`, `cortx_admin` | `org_admin` |
| `viewer`, `read_only` | `viewer` |
| `editor`, `author`, `dev` | same name (pass-through) |
| any group present in `CORTX_OIDC_GROUP_MAP` | the mapped role, if it is one of the six known roles above |
| **anything else — unrecognised group, typo, or the `groups` claim missing/empty entirely** | **`viewer`** (least-privileged; no write access) |

Before this fix, every unrecognised group **and** a missing `groups` claim fell through to the
write-capable `editor` role — an IdP misconfiguration, a renamed or typo'd group, or simply forgetting
to assert a `groups` claim silently granted editor access instead of being denied. That fail-open
default is gone: the only way an IdP-driven login now reaches `editor`/`author`/`dev`/`org_admin` is an
exact (case-insensitive) match on the built-in names above, or an explicit operator-declared override
via `CORTX_OIDC_GROUP_MAP`.

**Operator action required.** If your IdP's group names don't already match the built-in set (e.g. your
groups are named `engineering` or `platform-admins` rather than `editor`/`org_admin`), you must map them
explicitly or every login from that group will land as `viewer` (read-only):

```sh
export CORTX_OIDC_GROUP_MAP="engineering=editor,platform-admins=org_admin,qa=viewer"
```

- Entries are `group=role`, comma-separated; group names are matched case-insensitively.
- The role side must be one of `org_admin`, `admin`, `editor`, `author`, `dev`, `viewer` — anything else
  in an entry is silently ignored (fails closed on operator typos too, rather than minting an arbitrary
  role string).
- **Operators who relied on the old fail-open default** (any unmapped group, or no `groups` claim at
  all, silently getting `editor`) must add an explicit mapping (or accept the new `viewer` default) —
  otherwise previously-editor users will see reduced (read-only) access after upgrading.

### 2. Registry (`deploy/registry`) — deployment-pending

Ships deploy-ready config and an `install.sh` resolution path for the already-implemented
`cortx-gateway` `/v1/registry` service. **No public endpoint is live until an operator runs one of the
procedures below.** The local/git install path in `install.sh` works with no registry at all.

Routes already served by the gateway (`runtime/cmd/cortx-gateway/src/routes/registry.rs`):

| Route | Purpose |
|-------|---------|
| `GET  /v1/registry/:org/skills` | search / list (relevance, trust, semantic, published sorts) |
| `POST /v1/registry/:org/skills` | publish (RBAC + scan + Lean semver proof + 402 tier gate) |
| `GET  /v1/registry/:org/skills/:name/versions/:version/bundle` | signed `SKILL.md` bundle (402 Free tier) |
| `GET  /v1/registry/:org/skills/quarantine` | quarantined-tier listing |
| `DELETE /v1/registry/:org/skills/:name/versions/:version` | admin delete |

**Option A — Docker Compose (single-node / staging / air-gapped):**

```bash
docker compose -f deploy/registry/docker-compose.yml up -d
curl -fsS http://127.0.0.1:8080/v1/health

# Point the installer at it (graceful fallback if down)
CORTX_REGISTRY_URL=http://127.0.0.1:8080 bash install.sh --project "$PWD"
#   or: bash install.sh --project "$PWD" --registry http://127.0.0.1:8080
```

`CORTX_GATEWAY_DEV_AUTH=0` (default) keeps RBAC + 402 tier enforcement live. Set it to `1` only for a
local smoke test with no auth.

**Option B — Kubernetes (Helm overlay on `cortx-cloud`):**

```bash
helm upgrade --install cortx-registry deploy/helm/cortx-cloud \
  -f deploy/helm/cortx-cloud/values.yaml \
  -f deploy/registry/values-registry.yaml \
  --set gateway.config.publicUrl=https://registry.cortxos.dev \
  --set gateway.ingress.host=registry.cortxos.dev
```

The overlay sets 3 replicas, an nginx ingress with TLS via `letsencrypt-prod`, a PodDisruptionBudget
(`minAvailable: 2`), and keeps NetworkPolicy on.

**install.sh resolution semantics:** with `--registry <url>` (or `CORTX_REGISTRY_URL`), the installer
`curl`s `<url>/v1/health` (5s timeout). Reachable → records the registry as resolved source and *still*
seeds the local on-disk layout (offline source of truth); unreachable → graceful fallback to local/git
install with no error. `CORTX_REGISTRY_ORG` (default `cortxos`) selects the discovery namespace.

**Operator go-live checklist:**

- [ ] Build + push the `cortx-gateway` image (`scripts/build-images.sh`, or the manual
      `.github/workflows/onprem-artifacts.yml` run) to a reachable registry, then **verify it before
      install** — see [Verifying the gateway image](#verifying-the-gateway-image-signature-and-sbom)
      below.
- [ ] Provision Postgres (the `postgres-cortx` image with AGE/pgvector/pg_trgm).
- [ ] Provision DNS (`registry.<domain>`) + TLS (cert-manager ClusterIssuer or pre-provisioned Secret).
- [ ] Set `CORTX_LICENSE_PATH` to the mounted license file if enforcing entitlements (the verifying key
      is compiled into the binary — no separate pubkey to configure). A missing/invalid file at that
      path is now a **startup failure**, not a silent Free-tier downgrade (GAP-ENT009).
- [ ] Confirm `CORTX_GATEWAY_DEV_AUTH` is unset / `0` (production auth). If set, the gateway itself
      refuses to start once a license, a non-loopback bind, or a shared secret is also configured.
- [ ] Verify `GET /v1/health` and `GET /v1/registry/cortxos/skills` over TLS.
- [ ] Seed the registry (publish skills) so discovery returns non-empty.

**Rollback:** `helm uninstall cortx-registry` or `docker compose -f deploy/registry/docker-compose.yml
down`. Removing the registry never breaks an existing install — clients revert to the on-disk source of
truth.

#### Verifying the gateway image signature and SBOM

GAP-ENT015: an on-prem or air-gapped install trusts an image it did not build itself, so **verify
before you run it** — a signed image nobody is told to verify is provenance theatre, not security.

```bash
# 1. Pull the tag you're about to deploy (never `latest` — see
#    deploy/registry/docker-compose.yml, which pins CORTX_GATEWAY_TAG to the
#    suite VERSION by default).
IMAGE="ghcr.io/cortxos/cortx-gateway:$(grep -m1 CORTXOS_VERSION VERSION | cut -d= -f2)"
docker pull "$IMAGE"

# 2. Verify the cosign signature against the published public key.
cosign verify --key cosign.pub "$IMAGE"
#    exit 0 == the image is exactly what onprem-artifacts.yml built and signed.
#    Any non-zero exit means DO NOT deploy — the image is unverified.

# 3. Fetch and inspect the attached SBOM before install.
cosign download sbom "$IMAGE" > cortx-gateway-sbom.cdx.json
jq '.components | length' cortx-gateway-sbom.cdx.json   # sanity: non-zero component count
```

Locally, without a registry or CI, `scripts/build-images.sh --sign --key cosign.key --sbom` produces
the same signature and SBOM against a freshly built image — the exact steps
`.github/workflows/onprem-artifacts.yml` runs, runnable while GitHub Actions billing is blocked
(CLAUDE.md, "Gotchas"). Air-gapped sites that mirror images per **GAP-AIR005**'s transfer manifest
carry the signature and SBOM alongside the image so this verification works with no network egress.

### 3. Observability (`deploy/observability`)

Ten-minute path to Grafana panels after one pipeline dispatch. Requires Docker + Docker Compose and a
CorTxOS gateway/runtime with OTLP enabled.

```bash
cd deploy/observability
docker compose up -d
```

| Service | URL | Purpose |
|---------|-----|---------|
| Grafana | http://localhost:3000 | Dashboards (admin / admin) |
| Prometheus | http://localhost:9090 | Metrics scrape |
| Tempo | http://localhost:3200 | Trace backend |
| OTel Collector | http://localhost:4318 | OTLP HTTP ingest |

Point CorTxOS at the collector (set the same vars for the gateway process and every dispatch worker):

```bash
export CORTX_OTLP_ENDPOINT=http://localhost:4318/v1/traces
export CORTX_OTLP_HEADERS=
```

Import `grafana-dashboard-cortx.json` (Grafana → Dashboards → Import, select the Prometheus
datasource). After one dispatch you should see the Run-throughput panel increment, Tempo traces
searchable by `CORTX_RUN_ID`, and healthy Prometheus targets. Tear down with `docker compose down`. See
[gateway configuration](../gateway/configuration.md) for production OTLP settings.

### 4. Binary channels (`packaging/`)

Because the source repo is private, all binary distribution publishes to the separate **public** repo
**`barum/cortx-releases`**. The release workflow `.github/workflows/release.yml` is **manual-only**
(`workflow_dispatch`; run it with `gh workflow run release.yml -f version=<x.y.z>`). It cross-builds the
five targets, emits tarballs/zip plus the raw `cortx-runtime-<triple>` binary and its `.sha256`
(the assets `cortx self-update` resolves), builds `.deb`/`.rpm` via nfpm (`packaging/nfpm.yaml`), and
regenerates the Homebrew/Scoop/winget manifests from the `packaging/` sources with real checksums —
then commits them to `barum/cortx-releases` `main` and uploads the binaries to an orphan-tagged release.
Integrity is anchored by the published **SHA-256** sidecars, and authenticity by a **Sigstore/cosign**
keyless signature over every shipped asset (GAP-RMD012: `cosign sign-blob --bundle` in the workflow's
`Sign every shipped release asset` step, verified on install against the exact `release.yml`
workflow-identity — see `runtime/crates/cortx-update/src/lib.rs`'s module doc for the full chain). SBOM /
SLSA provenance attestation is not yet wired into this workflow. The stubs under `deploy/dist/` are older
templates — the live manifest sources are under `packaging/`.

| Channel | Manifest source | Audience |
|---------|-----------------|----------|
| Homebrew | `packaging/homebrew/cortx.rb` → `barum/cortx-releases` `Formula/` | macOS (Intel + Apple Silicon), Linuxbrew |
| Scoop | `packaging/scoop/cortx.json` → `barum/cortx-releases` `bucket/` | Windows |
| winget | `packaging/winget/*.yaml` → `barum/cortx-releases` `winget/` | Windows |
| Debian/RPM | `packaging/nfpm.yaml` (`.deb` + `.rpm`) | apt-/rpm-based distros |

```bash
brew install barum/cortx-releases/cortx       # tap-installs from the public release repo
cortx self-update --apply                      # downloads + verifies (Sigstore + .sha256) + replaces the binary

scoop bucket add cortx https://github.com/barum/cortx-releases
scoop install cortx                            # validates SHA-256 from the manifest
```

The release workflow regenerates and commits the channel manifests (version + matching SHA-256s) on
every run; there is no separate manual mirror step. Not yet covered: Nixpkgs, Chocolatey, standalone
CLI Docker images.

#### Offline / mirrored update channels (GAP-AIR016)

The public GitHub Releases host is unreachable from a disconnected or air-gapped site. `cortx
self-update` has three ways to reach a binary without it:

1. **A GitHub Enterprise (or GitHub-API-compatible) host** — `--base-url <url>` (or
   `CORTX_UPDATE_BASE_URL`) overrides `https://api.github.com`, e.g.
   `--base-url https://ghe.example.internal/api/v3`. Everything else (SHA-256 sidecar resolution,
   Sigstore bundle verification) is unchanged.
2. **A static mirror** — any HTTP-served directory, no GitHub API semantics required. Combine
   `--base-url <mirror-url> --mirror`. The directory must contain:
   - `latest.json` — a `{"version": "...", "assets": [{"name", "url", "sha256_url"?, "sha256"?,
     "bundle_url"?}, ...]}` document (the same shape `cortx-update::ReleaseInfo` serializes to).
   - The named assets, their `<asset>.sha256` sidecars (SHA-256 integrity — refused if absent,
     unchanged from the GitHub-sourced path), and, to keep the Sigstore authenticity gate intact,
     the `<asset>.sigstore.json` bundles carried over unmodified from the original release. A
     mirror that drops the bundles makes every install through it fail closed with
     `AuthenticityFailure`, by design — mirror the whole asset set, not just the binaries.
   Build one by rsync-ing/`curl`-ing a real release's assets plus a hand-written or scripted
   `latest.json` to internal HTTP storage.
3. **A fully offline, no-network install** — `cortx self-update --from-file <path> --apply` verifies
   `<path>` against a sidecar at `<path>.sha256` (SHA-256 only — a disconnected site cannot reach
   the Sigstore trust root either) and installs it. Carry exactly two files across the air gap:

   ```bash
   # On a connected machine:
   curl -LO https://github.com/barum/cortx-releases/releases/latest/download/cortx-runtime-<triple>
   curl -LO https://github.com/barum/cortx-releases/releases/latest/download/cortx-runtime-<triple>.sha256
   # Carry both files across the air gap, then on the disconnected host:
   mv cortx-runtime-<triple> cortx-new && mv cortx-runtime-<triple>.sha256 cortx-new.sha256
   CORTX_OFFLINE=1 cortx self-update --from-file ./cortx-new --apply
   ```

`CORTX_OFFLINE=1` (GAP-AIR003) refuses every update path except a loopback `--base-url`/`--mirror`
target; `--from-file` is unaffected since it never touches the network. See
[`air-gapped-site.md`](air-gapped-site.md) for the full disconnected-deployment walkthrough.

## Machine-scope policy for installed CLI clients (GAP-ENT011)

Everything above this section deploys the **gateway** — a server an administrator already controls.
This section is about the opposite problem: **installed `cortx` CLIs on end-user machines**, where
every prior configuration knob (`CORTX_GATEWAY_URL`, `CORTX_LICENSE_PATH`,
`CORTX_GATEWAY_DEV_AUTH`, `CORTX_OFFLINE`, the trusted-signer allowlist, which MCP hosts get
installed) was a user dotfile or a process environment variable — writable by exactly the person an
administrator would want to constrain. MDM / configuration-management tools (Jamf, Intune, Ansible,
Puppet, `systemd-firstboot` drop-ins, ...) can now place one file that those installed CLIs read and,
optionally, cannot be overridden by a forgotten env var.

**This is not a remote policy-push protocol.** CorTxOS does not become a policy distribution service;
the supported mechanism is a file your existing MDM or configuration-management tool places on the
machine, in the platform-correct, admin-writable location:

| Platform | Path |
|----------|------|
| Linux | `/etc/cortx/policy.yaml` |
| macOS | `/Library/Application Support/CorTxOS/policy.yaml` |
| Windows | `%ProgramData%\CorTxOS\policy.yaml` |

The file is read **once, at process startup** — there is no hot-reload / file-watcher (a live-reloaded
policy is a plausible source of half-applied state; restart the process to pick up a change). A missing
file is not an error: every key falls through to today's behavior exactly (env var, then a built-in
default).

### Precedence

```text
machine policy (highest, if enforced) -> CLI flag -> env var -> project config -> user config
  -> machine policy (if NOT enforced) -> built-in default
```

A key marked `enforced: true` always wins and **cannot** be overridden by a flag or env var — an
attempted override is refused and a warning names the policy file. An unenforced entry behaves as an
elevated default (still above project/user config) that a flag or env var can still override, with no
warning — the normal case of "the administrator suggested a starting point" rather than a hard lock.

### Schema and the six policy-controllable keys

```yaml
# /etc/cortx/policy.yaml — must be owned by root/an admin account and NOT group- or world-writable
# (checked; a permissive file is refused rather than silently honoured — see below).
gateway_url:
  value: "https://cortx.internal.example.com"
  enforced: false            # optional, default false
license_path:
  value: "/etc/cortx/license.json"
allow_dev_auth:               # the single most valuable key — see the callout below
  value: false
  enforced: true
offline:
  value: true
trusted_signers:              # list — UNIONED with the repo-committed `.cortx/trusted-signers`,
  - "3fa8e1…"                  # never replaces it
allowed_mcp_hosts:             # list — empty/absent means "unrestricted" (today's behavior)
  - "claude-code"
  - "vscode"
```

`allow_dev_auth: { value: false, enforced: true }` is the highest-value entry in this file: it is the
setting a forgotten `CORTX_GATEWAY_DEV_AUTH=1` turns into a full org-admin authentication bypass (see
GAP-ENT009). With it enforced, that env var becomes a no-op instead of an incident.

### The permission check

A "machine policy" a non-administrator can edit is not a control — it is the same problem
`.cortx/trusted-signers` has when it lives inside a repo anyone can push to. The policy file is
**refused** (not silently ignored) if it is writable by anyone other than its owner: on Linux/macOS,
any group- or other-write bit set (e.g. `chmod 664`/`666`) is rejected with a message naming the file's
permissions; on Windows, the file must have its read-only attribute set. Deploy it with your MDM /
configuration-management tool set to `0644` (Unix) or read-only (Windows), owned by root / an
Administrator account.

### Inspecting the effective configuration

```sh
cortx policy show            # value + resolution layer (machine-policy/cli-flag/env/project/user/default) per key
cortx policy show --json     # same, machine-readable
```

### Out of scope

- **Remote policy push / a CorTxOS-hosted MDM protocol.** Use your existing MDM or configuration
  management tool to place the file.
- **Live reload.** The file is read once at startup; restart the process to pick up a change.
- **A full `std::env::var` replacement.** Exactly six keys route through this resolver — see
  `runtime/crates/cortx-config/src/lib.rs`'s module doc for the list and the rationale for stopping
  there.
- **Signing the policy file.** The owner/permission check is the trust anchor; a signed policy is a
  stronger model and a separate decision.

## Optional enterprise HA (opt-in)

CorTxOS is single-host / single-writer by default (Tier 0, solo) — zero external services. **That
default is unchanged.** HA is strictly opt-in, selected with
`CORTX_DEPLOYMENT_PROFILE = solo | regional-ha | geo-multimaster`.

See [`../architecture/ha-deployment.md`](../architecture/ha-deployment.md) for the full tier model and
[`scenarios/enterprise-ha.md`](scenarios/enterprise-ha.md) for an end-to-end walkthrough. HA deployment
values live in the `values-enterprise-ha.yaml` overlay on `deploy/helm/cortx-cloud`.

### Tier 1 — Regional HA (shippable today)

N stateless `cortx` compute pods against **one** HA Postgres + AGE. Postgres MVCC is the write arbiter;
JWT auth is stateless; singletons are leader-elected (`cortx-cluster` `LeaderGuard` via
`pg_advisory_lock`). The audit chain, rate limiter, kill switch, and SSE are all Postgres-backed — **no
Redis/Valkey**. Delivers no-SPOF + horizontal scale within a region.

```bash
export CORTX_DEPLOYMENT_PROFILE=regional-ha
export DATABASE_URL=postgres://…
export CORTX_GRAPH_BACKEND=postgres-age
```

### Tier 2 — Geo multi-master (runs; behind the `geo` feature)

Federated regions that each accept writes and reconcile via CRDTs (HLC + OR-Set + LWW), a federated
checkpoint Merkle-DAG, a multi-signer trust registry, and a federation transport (with a real
HTTP/3/QUIC option). It **runs**: under `CORTX_DEPLOYMENT_PROFILE=geo-multimaster` the gateway runs a
background anti-entropy loop that pulls each `CORTX_FEDERATION_PEERS` region's signed bundle and merges
it (convergence-under-partition is proven by an automated test; endpoints are authenticated via
`CORTX_FEDERATION_SECRET`). Ships behind the `geo` Cargo feature (`cargo build -p cortx-runtime
--features geo`), off in the default binary to keep the solo build clean; deploy one Helm release per
region (`geo.{enabled,region,peers,federationSecret}`). The remaining acceptance step is **operational**
— a live multi-region soak on real infra. See the
[enterprise-HA scenario](scenarios/enterprise-ha.md) for the full walkthrough.

## Production checklist

Run through this before promoting any gateway deployment to production. The gateway **fails closed** on
these — missing values reject requests rather than silently degrading.

| Item | Setting | Behavior if unset |
|------|---------|-------------------|
| Production mode | `CORTX_GATEWAY_PRODUCTION=1` | Dev defaults; non-durable store |
| Shared secret | `CORTX_GATEWAY_SHARED_SECRET=<random>` | Mutating routes rejected unless `CORTX_GATEWAY_DEV_AUTH=1` |
| Database | `DATABASE_URL=postgres://…` | `CORTX_GATEWAY_PRODUCTION=1` errors without a migrated schema + `postgres` feature |
| Dev-auth bypass | `CORTX_GATEWAY_DEV_AUTH` unset / `0` | RBAC + 402 tier enforcement stay live. If set `1` under a license, non-loopback bind, or shared secret, **the gateway refuses to start** (GAP-ENT009). |
| Secrets | Postgres / MinIO / license via K8s Secrets | Chart install fails |
| TLS | Ingress TLS (cert-manager / pre-provisioned Secret) | Plaintext — do not expose publicly |
| License | `CORTX_LICENSE_PATH=/etc/cortx/license.json` | Unset → `Tier::Free` (paid features disabled). **Set but invalid/expired/unreadable → the gateway refuses to start** (GAP-ENT009; previously a silent Free-tier downgrade). |

> `CORTX_GATEWAY_PRODUCTION=1` requires `DATABASE_URL` with a migrated schema and the `postgres`
> feature — the gateway refuses to boot otherwise (`runtime/cmd/cortx-gateway/src/store.rs`).

## The twelve migrations

Migrations apply automatically on gateway startup via `sqlx migrate run` against `runtime/migrations/`.
They are forward-only; apply in order.

| File | Adds |
|------|------|
| `0001_extensions.sql` | Enables `pgcrypto`, `pg_trgm`, `age`, `pg_jsonschema`, `vector`; creates the `cortx_graph` AGE graph under a dedicated schema |
| `0002_identity.sql` | `organizations`, `users` (RLS-enabled, tenant-scoped via `app.tenant_id`); tier check `free/team/business/enterprise` |
| `0003_registry.sql` | `skill_registries` + skill versions; per-version Ed25519 (→ ML-DSA) signature for pull/install provenance; dependency edges mirrored into AGE |
| `0004_audits.sql` | `audit_runs`, `audit_findings`, and the **tamper-evident** `audit_log_events` — append-only, SHA-256 Merkle hash chain enforced by a `BEFORE INSERT` trigger |
| `0005_cortx_graph_vectors.sql` | `cortx_graph_vectors` (`vector(384)` embeddings) + IVFFlat cosine index for the AGE backend |
| `0006_billing.sql` | `usage_events`, `org_tiers`, `billing_periods` — durable billing usage + per-org tier overrides |
| `0007_gateway_jobs.sql` | `gateway_jobs` — durable async gateway jobs that survive pod restart when `DATABASE_URL` is set |
| `0008_gateway_durable_state.sql` | `gateway_registry_skills` + `gateway_royalty_ledger` — JSONB control-plane durability mirroring in-memory models |
| `0009_audit_chain.sql` | Multi-writer audit chain — appends serialized under `pg_advisory_xact_lock` so concurrent replicas keep the Merkle hash chain intact |
| `0010_rate_limit.sql` | Cross-replica rate-limiter token buckets — shared limiter state so N pods enforce one budget |
| `0011_kill_switch.sql` | Postgres kill switch — durable per-capability halt state visible to every replica |
| `0012_gateway_oidc_pending.sql` | `gateway_oidc_pending` — shared OIDC login `state`/`nonce`/PKCE transaction store so N replicas serve `/login` and `/callback` for the same `state` interchangeably (GAP-ENT010) |

**How they apply:** the gateway connects as the `cortx_app` role and sets `app.tenant_id` per request
via `SET LOCAL` for RLS. The relational schema is the source of truth; a background worker mirrors
dependency edges into AGE so graph queries (blast-radius) stay cheap.
