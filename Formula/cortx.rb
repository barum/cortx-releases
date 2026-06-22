# Homebrew formula for the single `cortx` binary (custom tap — CorTxOS is
# proprietary, so not homebrew-core). Regenerated per release by CI; this seed
# ships macOS arm64. Other targets are added when CI publishes them.
class Cortx < Formula
  desc "CorTxOS single-binary agentic skill runtime (run/dispatch/audit/memory/mcp/gateway)"
  homepage "https://cortxos.dev"
  version "6.13.0"
  license :cannot_represent # proprietary; see LICENSE in the release tarball

  on_macos do
    on_arm do
      url "https://github.com/barum/cortx-releases/releases/download/v6.13.0/cortx-6.13.0-aarch64-apple-darwin.tar.gz"
      sha256 "4bdb89e604916d3fc675eebf647a72c50b69881d17a8eb1bf67594892b4dd038"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "d461b0c3ab081d2d201eeb6d2a904958bae571d54144c3709e5f6a4d93946a05"
    end
    on_intel do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "ef59d1d65fff6c58eabba2626e511174b0e1e983689f24281e849343db4564a5"
    end
  end

  def install
    bin.install "cortx"
  end

  # Durable long-term-memory daemon. `brew services start cortx` wires this to
  # launchd; the graph persists at ~/.cortx/memory/graph.grafeo across restarts.
  service do
    run [opt_bin/"cortx", "graph-server"]
    keep_alive true
    log_path var/"log/cortx-graph-server.log"
    error_log_path var/"log/cortx-graph-server.log"
  end

  test do
    assert_match "cortx", shell_output("#{bin}/cortx --help 2>&1", 2)
  end
end
