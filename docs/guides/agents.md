# CorTxOS v6.16.0 — Agents, Sub-agents, and Loops

Goal-directed **agents** that run a plan→act→evaluate **loop**, spawn **sub-agents** for parallel
sub-goals, and stop on goal-satisfaction, budget, iteration cap, or no-progress. The engine is
`cortx-agent`; the surface is `cortx agent`.

## The model

- **Blackboard** — the agent's growing set of `key → value` facts.
- **Goal** — a set of `Requirement`s (fact keys, optionally with values); satisfied when all hold.
- **Executor** — pluggable "run one step" (a skill in the runtime; a deterministic mock in tests). A
  step emits facts and may **spawn sub-goals**.
- **Loop** — each iteration: satisfied? / budget spent? / iteration cap? / stalled? → `step` → merge
  facts → fan out any spawned sub-goals as **sub-agents** (parallel `std::thread::scope`) whose results
  merge back and whose cost shares the budget. The plan executor schedules **topologically**: each round
  it resolves every fact whose dependencies are met, running independent ones in parallel — and each
  fact's skill runs **exactly once**, so a shared dependency (a "diamond") is never executed twice.
- **Tier (T0→T4)** — the autonomy ceiling. Sub-agents inherit a tier **no higher** than their parent —
  delegation only narrows autonomy, never widens it.
- **LoopPolicy** — `max_iters`, `budget`, `stall_limit`, `max_depth` (sub-agent recursion cap, default
  64 — bounds recursion so a cyclic/deep plan can't overflow the stack); presets `until_dry(rounds)`
  (tail-catcher for unknown-size work) and `bounded(max_iters, budget)`.
- **Spec validation** — a plan with a **dependency cycle** (`a` requires `b`, `b` requires `a`) is
  rejected up front with the cycle path, rather than recursing to the depth cap.

## `cortx agent`

```sh
cortx agent --spec plan.json            # human summary: trace + nested sub-agent tree + stop reason
cortx agent --spec plan.json --json     # the full AgentReport as JSON
cortx agent --spec plan.json --out report.json --sign   # persist + Ed25519-sign the report
cortx agent --spec plan.json --lint     # validate the spec and exit (runs nothing)
```

`--lint` checks the spec without running it: a **dependency cycle** is an error (non-zero exit);
warnings flag a required/depended fact with **no plan step** (assumed at runtime) and a **plan step
nothing needs** (dead). Use it as a CI gate on your specs.

The spec is a declarative plan — a goal, a tier, a loop policy, and a `plan` mapping each fact to the
skill that produces it plus its dependency facts:

```json
{
  "goal": { "desc": "ship the auth feature", "require": ["released"] },
  "tier": "T2",
  "policy": { "max_iters": 20, "budget": 100, "stall_limit": 3 },
  "plan": {
    "designed":    { "skill": "spec-synthesizer",     "cost": 5 },
    "implemented": { "skill": "epic-developer",        "cost": 20, "requires": ["designed"] },
    "reviewed":    { "skill": "security-reviewer",     "cost": 8,  "requires": ["implemented"] },
    "released":    { "skill": "release-notes-curator", "cost": 3,  "requires": ["reviewed"] }
  }
}
```

Running it resolves `released` by recursively spawning sub-agents for each dependency
(`released → reviewed → implemented → designed`), then completes — the human summary prints the nested
sub-agent tree, the trace, the cost, and the stop reason.

By **default** this is a deterministic **planner/preview**: it runs the real loop engine and records
each skill as run (no external calls), showing exactly how the agent decomposes and sequences the work.

## Real execution (`--execute`)

To actually run each skill, pass `--execute` with **either** a real product **or** your own executor:

```sh
cortx agent --spec plan.json --execute --product shipr                      # real dispatch via the runtime
cortx agent --spec plan.json --execute --executor ./docs/guides/examples/agent-executor.sh   # custom
```

- **`--product <name>`** (no `--executor`): each skill is dispatched **for real** via the runtime's own
  `cortx dispatch --product <name> --skill <skill> --stage-input <goal> --output-subdir agent` — i.e. the
  actual CorTxOS skill runs through `claude -p`. Requires the `claude` binary + API.
- **`--executor <path>`**: the agent invokes `<executor> <skill-name>` — a script/binary you provide
  (an [example](examples/agent-executor.sh) ships in the repo).

Either way the skill name is a single argv element, **never through a shell**, and validated as a slug
(`[a-z0-9_-]`) first, so a spec cannot inject a command. Exit `0` means the
skill succeeded and the agent establishes that step's fact; a non-zero exit (or a spawn error) means the
skill failed — the agent makes no progress on that fact and the loop eventually **stalls**. `--execute`
is strictly opt-in; without it (and without `--executor`/`--product`) nothing external runs.

Each skill runs with **stdin closed** and a hard **`--exec-timeout`** (default 300s): a skill that
exceeds it is killed and treated as failed, so a hung executor can never wedge the loop (the loop policy
bounds iterations, not a single in-flight call). A failed fact is not recorded, so a failing skill is
**re-invoked each round until the stall limit** — keep `--execute` skills **idempotent** so a retry is
safe.

## From an MCP host

The agent is also a built-in MCP tool. `cortx mcp` exposes `cortx_agent` in `tools/list`; a host
(Claude Code, Cursor, …) calls it with the spec inline as the arguments (`goal`, `tier`, `policy`,
`plan`) and gets the `AgentReport` back. **Default (`execute` absent/false) is preview** — pure
compute, no capability gate beyond the tool's own (empty) manifest entry, no LLM calls, each skill
just recorded as run.

**Real dispatch (GAP-AEX005).** Set `execute: true` plus `product: "<slug>"` to reach the same real
dispatch the CLI's `cortx agent --execute --product` has: each plan step runs as a `cortx dispatch
--product <product> --skill <step>` child process (the actual CorTxOS skill via `claude -p`), exit
0 establishes the fact, non-zero/spawn-failure/timeout fails it. `product` without `execute: true`
is a caller error (mirrors `--executor`/`--product` only being meaningful with `--execute` on the
CLI); `execute: true` without `product` is a named error, not a silent preview. The `cortx_agent`
tool itself still does no direct filesystem/network/exec work — real per-skill capability, tier
ceiling, and sandbox enforcement all happen inside the spawned `cortx dispatch` child, exactly as
for a plain `cortx dispatch` call or the CLI's own `--execute` path (unlike `cortx_pipeline_<name>`
tools, which use the identical delegation pattern, `cortx_agent`'s real-dispatch reach is new as of
this story — an MCP host can now trigger real subprocess dispatch through it, which is unsandboxed
beyond what `cortx dispatch` itself does; see `S-SANDBOX` GAP-SBX014).

### LLM plan authoring — `cortx_swarm` (REG-0736, feature-gated)

Built with `--features mcp-llm`, `cortx mcp` also exposes **`cortx_swarm`**: pass one
natural-language `sentence` (and optional `tier`, default **T1**) and it authors a validated
`plan::Spec` via the LLM — the MCP counterpart of `cortx swarm`. It is **authoring only** (it never
dispatches skills): the returned `{spec, warnings, unknown_skills}` has its autonomy tier *forced* and
the plan `validate`+`lint`-checked, so untrusted model output can't yield a cyclic or out-of-ceiling
plan. Hand the `spec` to `cortx_agent` to run it. The base (default) build omits the tool entirely, so
the stock MCP server stays deterministic and LLM-free.

## Auditable runs

`--out` writes the `AgentReport` (goal, tier, iters, cost, stop reason, satisfied, board, trace, and the
full nested sub-agent reports). `--sign` adds a detached Ed25519 sidecar (`<out>.sig`, the same
`public_hex`/`signature` shape run reports use) so an agent run is verifiable with
`cortx-core::signing` — agent decisions join the proof spine.

## Multi-agent: handoff pipelines

Chain several agents so each **hands its facts to the next** — agent-to-agent coordination via forwarded
state (distinct from the parallel sub-agents *within* one agent):

```sh
cortx agent --handoff pipeline.json     # run ordered stages; each seeded by the last
```

The file is `{ stages: [{ name, goal, tier?, policy?, plan }] }`. Stage 2 starts from stage 1's final
blackboard, so a fact produced upstream (e.g. `spec_ready`) is already met downstream and its skill is
not re-run. See [an example](examples/agent-handoff.json) (research → build → ship).

## Persistent daemon

Run a long-lived agent processor fed by dropping specs into a directory:

```sh
cortx agent --daemon [--queue <dir>] [--daemon-interval <secs>]
```

Each `*.json` spec in the queue (default `docs/cortx/agent-queue/`) is run (preview) and appended to the
run ledger, then moved into `<queue>/done/`. The daemon polls forever — drop a spec, it runs; check
`--history` for results.

## Event-triggered (`cortx watch`)

Run an agent automatically whenever the repo changes:

```sh
cortx watch <product> --agent plan.json      # on every commit: preview the plan + append to the ledger
```

On each new commit `cortx watch` previews the agent plan (never `--execute` — a commit doesn't auto-run
real skills) and appends the result to the run ledger, building a history of how the agent evaluates the
repo over time. It composes with watch's normal file-routed skill dispatch.

## Run history

`--record` appends a one-line summary of the run to an append-only ledger
(`docs/cortx/agent-runs.jsonl`, the same convention as `metrics.jsonl`): `{ts, goal, tier, iters, cost,
stop, satisfied, skills}`. `--history` reads it back and prints the aggregate (run count, success rate,
total cost) plus the most recent runs — a queryable record of what agents ran and how they fared. The
ledger is JSONL, so `jq` works too.

```sh
cortx agent --spec plan.json --record    # run + append to the ledger
cortx agent --history                    # summary + recent runs (no spec needed)
```

## Tournaments

Generate several candidate plans for the same goal and let the agent pick the best:

```sh
cortx agent --tournament plan-tournament.json   # run every candidate, rank them
```

The file is `{ goal, candidates: [{ name, tier?, policy?, plan }] }`. Each candidate runs against the
shared goal; they are ranked **satisfied first, then lowest cost, then fewest iterations**, and the
winner is printed at the top of the table. See [an example](examples/agent-tournament.json).

## Loop strategies

`cortx_agent::strategies` provides reusable building blocks: `FnExecutor` (closure → executor),
`Sequential` (a linear pipeline-as-agent), and the `fact`/`fan_out` step helpers. Compose these — or
implement `Executor` directly — for retry/verify, judge-panel, or loop-until-dry shapes on the same
engine.

## See also

- [Architecture: crates](../architecture/crates.md) — `cortx-agent`
- [Autonomy tiers](../../shared/references/core/autonomy-boundaries.md) — the T0→T4 model agents bound to
- [CLI reference](../cli/cortx.md)
