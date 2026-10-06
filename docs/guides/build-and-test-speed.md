# Build and test speed

Measured on this workspace, 2026-07-26, `aarch64-apple-darwin`, 50-member Cargo workspace,
70 integration test binaries (40 of them in `cortx-gateway`), ~2,400 tests. The cross-worktree
cache section below was measured separately on 2026-07-29 against a 55-member workspace (the
member count grew between the two measurement dates; re-run `ls -d runtime/crates/*/
runtime/cmd/*/ | wc -l` rather than trusting either number going forward).

Every number below is a measurement, not an estimate. Two commonly-recommended optimisations were
measured and found **not** to help here; they are documented as such rather than quietly adopted.

## The short version

```sh
cargo t-lib cortx-gateway      # one crate's unit tests            ~7s
cargo t-one <test_name>        # one test, workspace-wide
cargo t-quick                  # full suite, fail-fast, no doctests
cargo t                        # full suite, no doctests
cargo t-doc                    # doctests only — see below, they test nothing today
```

Aliases live in [`.cargo/config.toml`](../../.cargo/config.toml).

## What actually helps

### 1. Scope the build — 8.5× measured

The dominant cost is **linking integration test binaries**, not compiling.

| Command (incremental, after a one-line change to `cortx-gateway/src/lib.rs`) | real | sys |
|---|---:|---:|
| `cargo test -p cortx-gateway --no-run` (all targets, 40 binaries) | 61.7s | 2m24s |
| `cargo test -p cortx-gateway --lib --no-run` (unit tests only) | **7.3s** | 2.5s |

`sys` time collapsing from 2m24s to 2.5s is the tell: the machine was doing link I/O, not
compilation. If you are iterating on library code, `--lib` skips all 40 binaries.

### 2. Skip doctests — 9m22s for zero tests

```
cargo test --workspace --doc   →   9m 22s
```

All **47 doctest suites report `0 passed; 0 failed; 0 ignored` in `0.00s`.** There are no doctests
in this workspace — the ~10 files with ``` fences in doc comments use non-Rust fences
(```text, ```sh, ```json), which rustdoc does not collect. The entire 9m22s is spent compiling and
linking a doctest harness for 47 crates that contains nothing.

Plain `cargo test --workspace` pays this on every run. `cargo nextest run` cannot run doctests at
all, so **using nextest as the default runner drops those 9m22s automatically, with zero coverage
loss** — there is no coverage to lose.

Run `cargo t-doc` on the day someone adds a real Rust ``` fence to a doc comment.

### 3. Give rust-analyzer its own target directory

**Measured incident:** an rust-analyzer `cargo check --workspace --all-targets` held the shared
`target/` lock for **24 minutes**, blocking a terminal `cargo test` for the entire time
(`Blocking waiting for file lock on build directory`). RA and CLI cargo share one target dir and
serialise on its lock.

`.vscode/` is gitignored in this repo, so this is not committed. Apply it locally —
`.vscode/settings.json`:

```json
{
  "rust-analyzer.cargo.targetDir": true,
  "rust-analyzer.check.allTargets": false,
  "files.watcherExclude": { "**/target/**": true }
}
```

`targetDir` costs a second set of artifacts on disk. Related: `runtime/target` was measured at
**242 GB** — run `cargo clean --manifest-path runtime/Cargo.toml` before adding a second tree.

### 4. nextest for full runs

`cargo test` runs each test *binary* sequentially, parallelising only within a binary. With 70
binaries the tail of a full run is mostly idle cores. nextest puts every test into one global
queue, gives per-test timing, and surfaces slow tests.

Install: `cargo install cargo-nextest --locked`. Config: [`runtime/.config/nextest.toml`](../../runtime/.config/nextest.toml).

### 5. Cross-worktree build cache: sccache (GAP-FVR001) — measured, and it does not win here

Every `Agent(isolation: "worktree")` / `cortx worktree` copy of this repo has its own
`runtime/target/`, so today N concurrent worktrees each cold-compile all 55 crates from scratch.
[`sccache`](https://github.com/mozilla/sccache) is the standard fix — it caches individual
*compilation units* keyed on a hash of the source and compiler flags, outside any single
worktree's target dir. **Measured here, it does not deliver that win for Rust.** This section
documents the honest result, following this workspace's own convention (§"What does NOT help")
of recording a measured negative rather than quietly shipping an unproven claim.

**Read `47deed9` first if you are touching this** — it independently measured that
rust-analyzer's `cargo check --workspace --all-targets` held the shared `target/` lock for 24
minutes, blocking a terminal `cargo test` the whole time (§3 above). That finding is corroborated
below by a dedicated concurrent-build measurement, and together they are why a shared
`CARGO_TARGET_DIR` is rejected as this story's mechanism.

MEASURED, `aarch64-apple-darwin`, 55-member workspace, 14 cores, rustc 1.91.1, sccache 0.17.0,
2026-07-29:

| Scenario | `cargo build --manifest-path runtime/Cargo.toml --workspace` |
|---|---:|
| Baseline: cold, empty target dir, no cache, no wrapper | **59s** |
| sccache, `CARGO_TARGET_DIR=A`, cold sccache cache, `CARGO_INCREMENTAL=0` (priming) | 109s |
| sccache, `CARGO_TARGET_DIR=B` (different dir, same source, warm shared cache) | **134s** |

`sccache --show-stats` on the `CARGO_TARGET_DIR=B` build: **0.00% Rust cache-hit rate** (528/528
Rust compile requests missed) against a **100.00%** hit rate for the C/C++ build-script compiles
(`aws-lc-sys`, `zstd-sys`, compiled via the `cc` crate; 351 hits). The second, supposedly
cache-assisted build was **slower** than the no-cache baseline, not 50%+ faster — **AC1 is not
met by sccache as configured**, and this is reported honestly rather than adjusted.

**Diagnosing why, so the negative is not mistaken for "sccache is broken":**

1. **First hypothesis, refuted as incomplete:** leaving `CARGO_INCREMENTAL` at Cargo's dev-profile
   default (`1`) gives a **0.00% Rust hit rate even with a warm cache**, because sccache cannot
   cache incremental `rustc` invocations at all — the build still succeeds, so this is exactly the
   "wrapper silently falls through, green measurement" risk this story's own notes warn about,
   caught here only by reading `--show-stats`'s per-language breakdown rather than the exit code.
   Setting `CARGO_INCREMENTAL=0` is necessary but, as the table above shows, **not sufficient**.
2. **Controlled follow-up, isolating the real cause:** rebuilding a single crate
   (`cargo clean -p cortx-assets && cargo build -p cortx-assets`, same target dir) still measured
   0.00% Rust hits — but that comparison mixed a `--workspace` build against a `-p <crate>` build,
   which changes Cargo's feature-unification/metadata hash on its own. Repeating it correctly —
   `cargo clean -p cortx-assets` then `cargo build --workspace` (same invocation shape, same
   `CARGO_TARGET_DIR`) — gave **100.00% Rust cache hits (14/14)**. Rust caching *does* work on
   this toolchain when the target directory is reused.
3. **Conclusion:** the 0% result across `CARGO_TARGET_DIR=A` vs `=B` is a genuine, reproducible
   property of *different target directories*, not a methodology mistake and not an invocation-
   shape artifact. Something Cargo derives from the target directory's identity (candidates not
   root-caused further in this pass: `--extern name=<target-dir>/debug/deps/libname-HASH.rlib`
   dependency-path arguments, or a `-C metadata` component) changes what sccache hashes for every
   Rust compile unit, busting the cache on every single crate the moment the target directory
   differs — even with byte-identical source and an identical `cargo build --workspace` command.

**Where this leaves the mechanism:** real Rust cache reuse was only demonstrated when reusing the
*same* `CARGO_TARGET_DIR` — which is precisely the shared-target-dir scenario rejected below for
lock contention, not the independent-worktree scenario this story needs. The only genuine,
reproducible cross-worktree win measured is for C/C++ build-script dependencies (a small minority
of total compile units here). **Not re-attempted in this pass, flagged as the next thing to try**:
a newer sccache release, or forcing byte-identical relative `CARGO_TARGET_DIR` paths across
worktrees (e.g. a fixed absolute path per host rather than per-worktree), which — if the
`--extern` path-argument hypothesis above is correct — should restore cross-worktree Rust hits
without reintroducing the shared-directory lock.

**Shipped anyway, commented out, because it is a safe, real, non-breaking primitive:**
`.cargo/config.toml` carries a commented-out `[build] rustc-wrapper = "sccache"` block (AC5: a
`rustc-wrapper` naming a binary absent from `PATH` is a hard build failure, not a graceful
fallback, so it must never be on by default). Enable with:

```sh
brew install sccache                        # macOS
cargo install sccache --locked              # Linux (or your distro's package)
winget install sccache                       # Windows (or: cargo install sccache --locked)
```

then uncomment the block and export `CARGO_INCREMENTAL=0` (required, not optional — see above).
**Disable** by re-commenting and `unset RUSTC_WRAPPER CARGO_INCREMENTAL` — cargo falls back to
invoking `rustc` directly with no other change, and sccache's cache directory can be deleted at
any time with no correctness impact.

**Correctness (AC2), unaffected either way:** `cargo test --manifest-path runtime/Cargo.toml
--workspace` produces the same pass count with the cache present, absent, warm, or cold — sccache
only changes where compiled object code is sourced from, never what is compiled (same source,
same `Cargo.lock`).

**Cross-platform (AC4):** `rustc-wrapper = "sccache"` resolves via `PATH` lookup identically on
macOS, Linux, and Windows (`CreateProcess`/`PATHEXT` resolves the bare name to `sccache.exe` the
same way Unix `exec` resolves it to the native binary) — no OS-specific wrapper script is needed.
sccache ships official Windows binaries (winget, or `cargo install`). **Caveat:** this was not
run on an actual Windows host in this measurement pass; the mechanism is documented, standard
Cargo behavior rather than empirically re-verified on Windows here.

### Shared `CARGO_TARGET_DIR` — evaluated and rejected

A shared `CARGO_TARGET_DIR` across worktrees is simpler than sccache and, for a single builder,
often faster. It was rejected as this story's mechanism because **Cargo takes an exclusive lock
on the target directory**, and two concurrent `cargo build --manifest-path runtime/Cargo.toml
--workspace` invocations against one shared, empty `CARGO_TARGET_DIR` (launched ~5s apart) were
measured contending on that lock rather than compiling independently in parallel: build A took
85s (from its own start), build B — started 5s later — took 80s, and both finished at the same
wall-clock instant, both markedly slower than the 59s single-builder baseline. Build B's log
contains the literal line `Blocking waiting for file lock on build directory` — direct textual
proof of the contention, not an inference from timing alone. This corroborates §3 above's
independent rust-analyzer/cargo lock-contention measurement (24 minutes) with a second, dedicated
measurement of the exact concurrent-build scenario, and is the opposite of the fleet-concurrency
purpose GAP-FVR001 exists to serve.

## What does NOT help here (measured)

### mold / lld — not applicable on macOS

- **mold has no macOS support.** The macOS port (`sold`) is a separate commercial product.
- This machine has Apple `ld-1267` — the rewritten linker from Xcode 15+ (`ld_prime`), which is
  generally faster than LLVM lld for arm64 Mach-O. Forcing `-fuse-ld=lld` would be a regression.

The mechanism *does* apply to the Linux CI target, so
[`.cargo/config.toml`](../../.cargo/config.toml) carries target-gated mold blocks — **commented
out**, because a missing linker is a hard build failure, not a graceful fallback, and enabling it
by default would break every machine without mold installed.

### Reducing debug info — 3%, i.e. nothing (on macOS)

`[profile.dev] debug = "line-tables-only"` plus `debug = false` for dependencies:

| | real | sys |
|---|---:|---:|
| full debug info | 63.5s | 2m24s |
| line-tables-only + no dep debug | 61.7s | 2m24s |

Within noise. **Reason:** macOS defaults to `split-debuginfo = "unpacked"`, so DWARF stays in the
`.o` files and never passes through the linker — there is no debug-info link cost here to remove.

The setting is kept in [`runtime/Cargo.toml`](../../runtime/Cargo.toml) because the mechanism does
apply to Linux, where debug info is packed into the binary and the linker must copy it. **That
benefit is expected but unmeasured** — no Linux machine was available.

### "Keep unit tests inside source files" — already done

202 source files already carry an inline `#[cfg(test)] mod tests`. This is not the problem. The
problem is the 70 *integration* binaries, 40 of them in `cortx-gateway`, each linking the full
axum/sqlx/reqwest graph.

## The structural fix, not yet done

Consolidating `cmd/cortx-gateway/tests/` (40 files → a handful of binaries, e.g. one per subsystem
with modules inside) would cut link work proportionally, because **each `tests/*.rs` file is a
separate binary that links the whole crate graph**. That is a real refactor of test code and has
not been attempted here — the `--lib` scoping above gets most of the inner-loop benefit for none
of the risk.
