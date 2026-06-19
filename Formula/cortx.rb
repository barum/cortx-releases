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
      sha256 "c02a2773beebb88127d5bef312f686240d3f03ba8cc1f4703e6308a1ceac5739"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "acdac59eadb4159dcfb079ee57505cc60cc352fd39faf888392cbc7d89376cf3"
    end
    on_intel do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "26d9d857be98faf0a68d06b011a91acdac62b3a361c88cac9a9433353513120c"
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
