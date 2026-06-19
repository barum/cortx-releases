# cortx-releases

Public distribution host for **CorTxOS** — the single-binary agentic skill runtime.
The source lives in a private repo; this repo hosts the downloadable binaries, the
Homebrew formula (`Formula/`), and the Scoop manifest (`bucket/`).

## Install

### macOS / Linux — Homebrew
```sh
brew tap barum/cortx-releases https://github.com/barum/cortx-releases
brew install barum/cortx-releases/cortx
brew services start cortx     # optional: durable long-term-memory daemon
```

### macOS / Linux — curl | sh
```sh
curl -fsSL https://raw.githubusercontent.com/barum/cortx-releases/main/scripts/install-cortx.sh | bash
```

### Windows — Scoop or PowerShell
```powershell
scoop bucket add cortx-releases https://github.com/barum/cortx-releases
scoop install cortx
# or:
irm https://raw.githubusercontent.com/barum/cortx-releases/main/scripts/install-cortx.ps1 | iex
```

Every download is verified against its `.sha256` sidecar. Update in place with
`cortx self-update --apply`.

## Platform availability

| Platform | Status |
|----------|--------|
| macOS arm64 (Apple Silicon) | ✅ published |
| macOS x86_64, Linux x86_64/arm64, Windows x86_64 | ⏳ published by CI on the next tagged release |

## One binary

`cortx` is a single executable with every subcommand compiled in — `run`,
`dispatch`, `audit`, `certify`, `memory`, `mcp`, `graph-server`, `gateway`,
`brain`, `lint`, `registry`, `llm`, `attest`. Skills + references are embedded, so
it runs with no checked-out tree.
