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
      sha256 "47ae433d76c269e4a18b1e9c2957002e97c9d72beec3e8036b43b3d2574508bc"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "689022094b42e28249f9e2077e6adc653104b0ca8a395b9cfa6e3e54aaa5ecc5"
    end
    on_intel do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "225abd91551e7fe5f236701d0b3ca77e87901b12f000dc318610850b515ede05"
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
