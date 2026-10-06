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
# and the three published bottle digests (Apple Silicon + Linux arm64/x86_64).
# Placeholders below use the release.yml token form SHA256_<TRIPLE> with
# double-underscore delimiters; do not put that token form in comments — the
# post-rewrite gate greps the whole file.
class Cortx < Formula
  desc "CorTxOS single-binary agentic skill runtime (run/dispatch/audit/memory/mcp/gateway)"
  homepage "https://cortxos.dev"
  version "6.16.0"
  license :cannot_represent # proprietary; see LICENSE in the release tarball

  on_macos do
    # Apple Silicon only. x86_64-apple-darwin (Intel Mac) is not published while
    # GitHub's macos-13 runners are deprecated; Intel-Mac users build from source.
    on_arm do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "def5923590bffbe418938a7b8df97601fd8f727a79cdb3d9b0ff1f6570b6e6ef"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "b20304fc425085823ba9e7b56cd8dd50de68e95096406b2142ff3300eee00796"
    end
    on_intel do
      url "https://github.com/barum/cortx-releases/releases/download/v#{version}/cortx-#{version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "584b34436e8a3f634c4bc597d4bf86416b788fe6f93715447de933c52e0ba23a"
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
