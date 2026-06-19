#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  CorTxOS — single-binary installer (macOS + Linux).
#
#  Downloads the `cortx` binary for this host's OS/arch from the GitHub
#  release, verifies its SHA-256 against the published sidecar, and installs
#  it to a directory on PATH. Distinct from install.sh (which lays out the
#  skills tree for Claude-Code-native discovery); this one is JUST the binary.
#
#  One-liner:
#    curl -fsSL https://raw.githubusercontent.com/barum/cortx-releases/main/scripts/install-cortx.sh | bash
#
#  Options (env):
#    CORTX_VERSION   release to install (default: latest)
#    CORTX_REPO      owner/repo (default: barum/cortx-releases)
#    CORTX_BIN_DIR   install dir (default: /usr/local/bin if writable, else ~/.local/bin)
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

REPO="${CORTX_REPO:-barum/cortx-releases}"
VERSION="${CORTX_VERSION:-latest}"

err() { printf 'cortx-install: %s\n' "$1" >&2; exit 1; }

# ── Resolve target triple ──────────────────────────────────────────
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Darwin) os_part="apple-darwin" ;;
  Linux)  os_part="unknown-linux-gnu" ;;
  *) err "unsupported OS: $os (macOS and Linux only)" ;;
esac
case "$arch" in
  x86_64|amd64) arch_part="x86_64" ;;
  arm64|aarch64) arch_part="aarch64" ;;
  *) err "unsupported architecture: $arch" ;;
esac
triple="${arch_part}-${os_part}"

# ── Resolve version ────────────────────────────────────────────────
if [ "$VERSION" = "latest" ]; then
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/')"
  [ -n "$VERSION" ] || err "could not resolve latest version"
fi
printf '→ Installing cortx %s (%s)…\n' "$VERSION" "$triple"

base="https://github.com/${REPO}/releases/download/v${VERSION}"
tarball="cortx-${VERSION}-${triple}.tar.gz"
url="${base}/${tarball}"

# ── Download + verify ──────────────────────────────────────────────
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "${tmp}/${tarball}" || err "download failed: $url"
curl -fsSL "${url}.sha256" -o "${tmp}/${tarball}.sha256" || err "checksum download failed"

expected="$(awk '{print $1}' "${tmp}/${tarball}.sha256" | tr '[:upper:]' '[:lower:]')"
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${tmp}/${tarball}" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "${tmp}/${tarball}" | awk '{print $1}')"
fi
actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
[ "$actual" = "$expected" ] || err "SHA-256 mismatch (expected $expected, got $actual). Refusing to install."
printf '✓ SHA-256 verified.\n'

tar -xzf "${tmp}/${tarball}" -C "$tmp"
[ -f "${tmp}/cortx" ] || err "archive did not contain a 'cortx' binary"
chmod +x "${tmp}/cortx"

# ── Choose install dir ─────────────────────────────────────────────
if [ -n "${CORTX_BIN_DIR:-}" ]; then
  bindir="$CORTX_BIN_DIR"
elif [ -w /usr/local/bin ] 2>/dev/null; then
  bindir="/usr/local/bin"
else
  bindir="${HOME}/.local/bin"
fi
mkdir -p "$bindir"
mv -f "${tmp}/cortx" "${bindir}/cortx"
printf '✓ cortx installed at %s/cortx\n' "$bindir"

case ":${PATH}:" in
  *":${bindir}:"*) : ;;
  # shellcheck disable=SC2016  # literal $PATH is intentional — it's instructional text.
  *) printf '  NOTE: %s is not on your PATH. Add it:\n    export PATH="%s:$PATH"\n' "$bindir" "$bindir" ;;
esac

# shellcheck disable=SC2016  # literal backticks/commands are intentional help text.
printf '  Durable memory: run `cortx graph-server` (keep running). Verify: `cortx memory health`.\n'
printf '  Update later:   cortx self-update --apply\n'
