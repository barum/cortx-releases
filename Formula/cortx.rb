# Homebrew formula for the single `cortx` binary.
#
# This lives in a CUSTOM TAP (e.g. `barum/homebrew-cortxos`), NOT homebrew-core:
# CorTxOS is proprietary, and homebrew-core only accepts OSI-licensed, notable
# software. Install with:
#
#     brew tap barum/cortxos https://github.com/barum/homebrew-cortxos
#     brew install cortx
#
# The release workflow regenerates this file per tag, substituting the version
# and the four per-target SHA-256 sums (the __SHA256_*__ tokens below).
class Cortx < Formula
  desc "CorTxOS single-binary agentic skill runtime (run/dispatch/audit/memory/mcp/gateway)"
  homepage "https://cortxos.dev"
  version "6.14.0"
  license :cannot_represent # proprietary; see LICENSE in the release tarball

  on_macos do
    # Apple Silicon only. x86_64-apple-darwin (Intel Mac) is not published while
    # GitHub's macos-13 runners are deprecated; Intel-Mac users build from source.
    on_arm do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "790d0266ee052a934614f9d54d033539290fa5c95f62794f57ffd49e4e854e87"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "bc4ad39b0d11a809aae0aacdac8941466b05457bcebd5ffa47c3e9280765ddd4"
    end
    on_intel do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "53c559aca1d4f27b419408a5636fe9faba7c203b3a58d4bb4b9f695bc3c1a88d"
    end
  end

  def install
    bin.install "cortx"
  end

  # Durable long-term-memory daemon. `brew services start cortx` wires this to
  # launchd (macOS) or systemd --user (Linuxbrew). The graph persists at
  # ~/.cortx/memory/graph.grafeo across restarts.
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
