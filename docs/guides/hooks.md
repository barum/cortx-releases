# Hooks (GAP-EXT006)

CorTxOS has shipped two fixed, CorTxOS-authored lifecycle scripts since early versions —
`scripts/cortx-pre-invoke.sh` and `scripts/cortx-post-invoke.sh` — run around every skill dispatch.
Their contract is exit-code-only: a non-zero exit halts the stage, a zero exit lets it proceed. This
page documents the layer on top of that: **registerable manifest hooks** that return a structured
decision.

## What did not change

The two shipped scripts are untouched. With no manifest present, dispatch behaves exactly as it did
before this feature — same argv, same exit-code semantics, same timeout. Registering hooks is
strictly additive.

## The manifest

Two layered locations, read in this precedence order — **both fire**, project entries before user
entries (this is not an override chain):

1. `<repo>/.cortx/hooks.yaml` — project-scoped.
2. `~/.cortx/hooks.yaml` — user-scoped, applies across every repo on the machine.

```yaml
hooks:
  - event: pre-skill          # "pre-skill" | "post-skill"
    matcher: "^epic-.*"       # optional; regex over the skill name. Absent = every skill.
    command: |
      ./scripts/my-policy-check.sh
```

## Events

| Event | Fires | Analogous to |
|---|---|---|
| `pre-skill` | After the shipped `cortx-pre-invoke.sh` hook, before the skill's LLM call | `run_pre_invoke` |
| `post-skill` | After the shipped `cortx-post-invoke.sh` hook, once the artifact is written | `run_post_invoke` |

Per-tool-call events (a `PreToolUse`-style hook) do not exist yet — CorTxOS has no tool-calling loop
today (that is the A-EXECUTION epic's territory). Adding such an event now would ship one that never
fires.

## The decision protocol

A registered hook's **stdout** (not exit code) carries its decision, as one JSON object:

```jsonc
{"decision": "allow"}
{"decision": "deny", "reason": "human-readable reason"}
{"decision": "ask",  "reason": "human-readable reason"}
```

| stdout | Effect |
|---|---|
| `{"decision":"allow"}` | Dispatch proceeds. |
| `{"decision":"deny","reason":"..."}` | Dispatch halts; the error contains the reason. |
| `{"decision":"ask","reason":"..."}` | **Fails closed today** — see below. |
| anything unparseable, or exit non-zero | Treated as a hard failure / deny, never as `allow`. |

A hook that cannot state its decision has not made one — unparseable stdout is `deny`, not a
warning that lets dispatch through. This will break a naive hook that prints debug output to
stdout; write diagnostics to stderr instead.

### `ask` fails closed

There is no interactive approval channel on the dispatch path today (that is the
M-ORCHESTRATION epic's territory). An `ask` decision is therefore treated exactly like `deny` — it
halts dispatch — but the error names `ask` explicitly, so an operator reading logs can tell "a
policy denied this" apart from "a hook wanted human approval and none was available." Do not build
automation that assumes `ask` will ever proceed unattended; it will not, until an approval channel
exists.

### Two decision protocols coexist, by design

The shipped `cortx-pre-invoke.sh`'s stdout contract — its first non-empty line is a *context file
path* — is unrelated to and untouched by this feature. Registered hooks use the JSON-on-stdout
contract above. The two are deliberately kept separate rather than unified into one stdout format.

## Isolation

A registered hook runs with the **same** environment allowlist and timeout as the shipped scripts:

- Env: only `PATH`, `HOME`, `LANG`, `LC_ALL`, `TZ`, `TMPDIR` (plus `CORTX_RUN_ID`, `CORTX_PRODUCT`,
  `CORTX_SKILL`, `CORTX_HOOK_EVENT` for correlation) — everything else from the invoking process's
  environment (API keys, tokens, …) is stripped.
- Timeout: 30 s by default, overridable via `CORTX_HOOK_TIMEOUT_MS` (milliseconds) — a hook that
  exceeds it is killed and dispatch fails with a timeout error, not left running.
- A registered hook runs a user-chosen command with the dispatching process's own OS authority —
  the same posture the two shipped scripts have always had. There is no additional sandboxing here;
  that OS-level boundary is tracked separately (`GAP-SBX014`, S-SANDBOX epic).

## Source

`runtime/crates/cortx-pipeline/src/hooks.rs` (manifest loading, matching, decision parsing) and
`runtime/crates/cortx-pipeline/src/dispatch.rs::run_registered_hooks` (subprocess execution, wired
into the same two call sites as the shipped scripts).
