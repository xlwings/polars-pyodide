#!/usr/bin/env bash
# This script isn't used by the GitHub actions pipeline, but it makes developing easier for AI tools.
#
# Run this script on a fresh x86-64 Ubuntu 22.04/24.04 VPS, 8 GB RAM min, as root (or with sudo).
# It installs all dependencies and builds the polars 1.33.1 wasm32 wheel.
# The finished wheel is left in ~/wasm-dist/
#
# scp build-1.33.1-on-vps.sh root@your-vps:~
# ssh root@your-vps bash build-1.33.1-on-vps.sh
# scp root@your-vps:~/wasm-dist/*.whl ./wasm-dist/

# Does **not** work under QEMU (e.g. Docker `linux/amd64` on Apple Silicon) — 
# rustc segfaults under emulation.

# Build time: ~45–60 minutes on a 2-vCPU/8 GB VPS.

set -euo pipefail

POLARS_TAG="py-1.33.1"
PYODIDE_VERSION="0.29.3"
EMSCRIPTEN_VERSION="4.0.14"
RUST_TOOLCHAIN="nightly-2025-08-29"
OUT_DIR="$HOME/wasm-dist"

echo "==> Adding swap (15G) to avoid OOM during Rust link step"
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 15G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi
swapon --show

echo "==> Installing system packages"
apt-get update -qq
apt-get install -y --no-install-recommends \
  build-essential curl git wget xz-utils ca-certificates \
  lsb-release software-properties-common gnupg

echo "==> Installing uv"
if ! command -v uv &>/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
source "$HOME/.local/bin/env" 2>/dev/null || true
export PATH="$HOME/.local/bin:$PATH"

echo "==> Installing Python 3.13 via uv"
uv python install 3.13
UV_PYTHON=$(uv python find 3.13)
echo "Python 3.13: $UV_PYTHON"

echo "==> Installing maturin 1.7.4 via uv"
uv tool install --python 3.13 "maturin==1.7.4" || uv tool upgrade maturin

# Install pyodide-build + wheel<0.45 into a shared venv so `pyodide` CLI is on PATH
if [ ! -d /opt/pyodide-env ]; then
  uv venv --python 3.13 /opt/pyodide-env
  uv pip install --python /opt/pyodide-env/bin/python --prerelease=allow \
    "wheel<0.45" "pyodide-build==0.29.3"
fi
export PATH="/opt/pyodide-env/bin:$PATH"

echo "==> Installing LLVM 19"
if [ ! -f /usr/bin/clang-19 ]; then
  wget -qO /tmp/llvm.sh https://apt.llvm.org/llvm.sh
  chmod +x /tmp/llvm.sh
  /tmp/llvm.sh 19
  rm /tmp/llvm.sh
fi
export EM_LLVM_ROOT=/usr/lib/llvm-19/bin

echo "==> Installing Emscripten $EMSCRIPTEN_VERSION"
if [ ! -d /emsdk ]; then
  git clone --depth 1 https://github.com/emscripten-core/emsdk.git /emsdk
fi
/emsdk/emsdk install "$EMSCRIPTEN_VERSION"
/emsdk/emsdk activate "$EMSCRIPTEN_VERSION"
source /emsdk/emsdk_env.sh

echo "==> Patching Emscripten"
EMROOT=$(em-config EMSCRIPTEN_ROOT)
sed -i 's/assert.*c_ident.*export/# patched: skip C-ident check for export/' \
  "$EMROOT/tools/link.py" || true
sed -i 's/def check_export_name/def _disabled_check_export_name/' \
  "$EMROOT/tools/shared.py" || true
# emscripten.py also validates export names (mangled Rust symbols are not valid C idents)
sed -i "s/      exit_with_error(f'invalid export name: {n}')/      pass  # patched: skip invalid export name check/" \
  "$EMROOT/tools/emscripten.py" || true
grep -rl 'wasm-use-legacy-eh' "$EMROOT" | \
  xargs sed -i 's/.*wasm-use-legacy-eh.*/        pass  # patched/' || true
echo "Patched Emscripten at $EMROOT"

echo "==> Installing Rust $RUST_TOOLCHAIN"
if ! command -v rustup &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
fi
source "$HOME/.cargo/env"
rustup toolchain install "$RUST_TOOLCHAIN" --no-self-update
rustup target add wasm32-unknown-emscripten --toolchain "$RUST_TOOLCHAIN"
rustup default "$RUST_TOOLCHAIN"

echo "==> Installing Pyodide xbuildenv $PYODIDE_VERSION"
pyodide xbuildenv install "$PYODIDE_VERSION" || true
SYSCONFIG_FILE=$(find / -name "_sysconfigdata_*emscripten*.py" 2>/dev/null | head -1)
SYSCONFIG_DIR=$(dirname "$SYSCONFIG_FILE")
echo "sysconfig dir: $SYSCONFIG_DIR"

echo "==> Checking out Polars $POLARS_TAG"
if [ -d /polars-1.33.1 ]; then
  rm -rf /polars-1.33.1
fi
git clone --depth 1 --branch "$POLARS_TAG" https://github.com/pola-rs/polars.git /polars-1.33.1
cd /polars-1.33.1

echo "==> Removing rust-toolchain.toml (use our pinned nightly)"
rm -f rust-toolchain.toml

echo "==> Patching Cargo features"
# serde_json is optional in polars-python/Cargo.toml; make it non-optional and
# remove the feature entry (the "json" feature itself will be stripped below).
sed -i 's/serde_json = { workspace = true, optional = true }/serde_json = { workspace = true }/' \
  crates/polars-python/Cargo.toml || true
sed -i 's/  "serde_json", //' crates/polars-python/Cargo.toml || true

# In crates/polars/Cargo.toml, csv/ipc/json features include "new_streaming" which pulls
# in polars-stream, which hardcodes polars-io features ["async", "file_cache"] -> tokio -> mio.
# Remove "new_streaming" from those feature lines in the top-level polars crate.
sed -i 's/, "new_streaming"//' crates/polars/Cargo.toml || true

# Strip wasm-incompatible features from polars-python and py-polars Cargo.toml files.
# parquet: async I/O deps
# json: pulls in serde_json (already handled above for non-optionality)
# extract_jsonpath: json-path parsing deps
# catalog/cloud/polars_cloud: tokio + network deps
# clipboard: OS clipboard API unavailable in wasm
# decompress: not needed
# new_streaming: pulls in polars-stream which hardcodes async/file_cache deps
FEATURES='parquet|json|extract_jsonpath|catalog|cloud|polars_cloud|polars_cloud_client|polars_cloud_server|clipboard|decompress|new_streaming'
# Remove feature entries from the [dependencies.polars] features list (lines like `  "feature",`)
sed -E -i "/^  \"(${FEATURES})\",$/d" crates/polars-python/Cargo.toml py-polars/Cargo.toml
# Remove feature definitions in [features] section (lines like `feature = [...]`)
sed -E -i "/^(${FEATURES}) = \[/d" crates/polars-python/Cargo.toml py-polars/Cargo.toml

# Also remove "abi3-py39" from py-polars pyo3 features so the wheel is tagged cp313
# (the xbuildenv sysconfig only works with the exact Python version, not abi3)
sed -i 's/"abi3-py39", //' py-polars/Cargo.toml crates/polars-python/Cargo.toml || true

echo "==> Pre-fetching dependencies"
export PYO3_CROSS_LIB_DIR="$SYSCONFIG_DIR"
cargo fetch --manifest-path py-polars/Cargo.toml

echo "==> Installing rust-src (needed for -Z build-std)"
rustup component add rust-src --toolchain "$RUST_TOOLCHAIN"

echo "==> Writing .cargo/config.toml"
# build-std recompiles std+panic_unwind from source with native wasm EH,
# eliminating invoke_* trampolines that the Pyodide runtime doesn't export.
mkdir -p /polars-1.33.1/.cargo
cat > /polars-1.33.1/.cargo/config.toml << 'CARGO_CONFIG'
[unstable]
build-std = ["std", "panic_unwind"]
build-std-features = ["panic-unwind"]

[build]
rustflags = ["-C", "link-self-contained=no", "-Z", "emscripten-wasm-eh", "-C", "link-arg=-sSUPPORT_LONGJMP=wasm"]
CARGO_CONFIG

echo "==> Building wheel"
mkdir -p "$OUT_DIR"
# -fwasm-exceptions: compile C deps (lz4, zstd, mimalloc, psm) with native wasm EH
export CFLAGS="-fPIC -fwasm-exceptions"
export CXXFLAGS="-fPIC -fwasm-exceptions"
export PYO3_NO_PYTHON=1
export PYTHONPATH="$SYSCONFIG_DIR:${PYTHONPATH:-}"

# dist-release uses lto=fat which triggers SIGILL in this nightly codegen.
# Use --release with LTO disabled; the wheel is larger but works correctly.
CARGO_PROFILE_RELEASE_LTO=off \
maturin build \
  --release \
  --manifest-path py-polars/Cargo.toml \
  --target wasm32-unknown-emscripten \
  --interpreter "$UV_PYTHON" \
  --out "$OUT_DIR" \
  2>&1 | tee /tmp/maturin-1.33.1.log

if grep -q '💥 maturin failed' /tmp/maturin-1.33.1.log; then
  echo "==> BUILD FAILED"
  tail -50 /tmp/maturin-1.33.1.log
  exit 1
fi

echo "==> Retagging wheel to pyodide_2025_0_wasm32"
uv run --python 3.13 --with "wheel<0.45" \
  wheel tags --platform-tag pyodide_2025_0_wasm32 --remove "$OUT_DIR"/*.whl

echo ""
echo "==> Done! Wheel:"
ls "$OUT_DIR"
