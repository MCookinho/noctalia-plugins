#!/usr/bin/env bash
# Builds and installs the goanime-stream helper.
#
# goanime-stream reuses GoAnime's own internals (internal packages), so it must
# be compiled inside the GoAnime module. This script clones the pinned GoAnime
# source (v1.8.7 — same as the released binary), drops cmd/goanime-stream into
# it and runs `go build`.
#
# Requirements: git, go (>= 1.27.1 as required by GoAnime's go.mod), network.
# The first build downloads the module dependencies and takes a few minutes.
#
# Usage:
#   ./build.sh [INSTALL_DIR]
#   INSTALL_DIR defaults to ~/.local/bin — make sure it is in your PATH, or the
#   Noctalia panel will fall back to the temporary-cache streaming mode.
set -euo pipefail

GOANIME_TAG="${GOANIME_TAG:-v1.8.7}"
INSTALL_DIR="${1:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(mktemp -d)"

trap 'rm -rf "$SRC_DIR"' EXIT

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required" >&2
  exit 1
fi
if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required (https://go.dev/dl/)" >&2
  exit 1
fi

echo "==> Cloning GoAnime ${GOANIME_TAG}:"
git clone --depth 1 --branch "$GOANIME_TAG" https://github.com/alvarorichard/GoAnime.git "$SRC_DIR"

echo "==> Adding cmd/goanime-stream:"
mkdir -p "$SRC_DIR/cmd/goanime-stream"
cp "$SCRIPT_DIR/main.go" "$SRC_DIR/cmd/goanime-stream/main.go"

echo "==> Building (first build downloads dependencies, be patient):"
(
  cd "$SRC_DIR"
  go build -trimpath -ldflags "-s -w" -o goanime-stream ./cmd/goanime-stream
)

mkdir -p "$INSTALL_DIR"
install -m 0755 "$SRC_DIR/goanime-stream" "$INSTALL_DIR/goanime-stream"

echo
echo "Installed goanime-stream -> ${INSTALL_DIR}/goanime-stream"
echo "Ensure ${INSTALL_DIR} is in your PATH so the Noctalia panel finds it:"
echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
echo "Then click Assistir again — the panel will stream (no temp cache)."