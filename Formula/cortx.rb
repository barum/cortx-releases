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
      sha256 "b5d613a9c81165273ced0cfe42aa94dd22279f99837aee9b502114326bfba115"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "0771ff269282454b16d69b2feca9121797fd0218d8a3fbd885243da761cffe27"
    end
    on_intel do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "a8c3975813dff888e8371bcd38b4fd8092554bbb78dd85239fb0ef3868acdeab"
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
