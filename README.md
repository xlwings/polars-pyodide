# Polars + Pyodide notes

## Compatibility matrix

| Pyodide | Python | Emscripten | Polars |
|---------|--------|------------|--------|
| 0.27.x  | 3.12   | 3.1.x      | 1.18.0 (known working) |
| 0.28.x+ | 3.13   | 4.0.9      | needs rebuild |
| 0.29.x  | 3.13   | 4.0.9      | needs rebuild |

Pyodide 0.27.5 ships Polars 1.18.0 and it works. Pyodide 0.28.0 upgraded both Python (3.12 → 3.13) and Emscripten (3.1.x → 4.0.9), breaking ABI compatibility with the 0.27.x wheels.

## Rebuilding Polars 1.18.0 for Pyodide 0.29.x

Rebuilding 1.18.0 against the new toolchain is the recommended path. Newer Polars versions have deep Rust/tokio async dependencies that don't compile cleanly for WASM (`tokio` lacks `wasm32` support without significant shims). 1.18.0 is likely the last version before that complexity.

## What needs to happen

- Build Polars 1.18.0 from source using `pyodide build` with:
  - Pyodide 0.29.3 xbuildenv (Python 3.13, Emscripten 4.0.9)
  - Rust toolchain with `wasm32-unknown-emscripten` target
- Check if any patches are needed (similar to the `--export-dynamic-symbol` issue with DuckDB)
- The existing pyodide package recipe for Polars in the pyodide repo may be a useful reference:
  https://github.com/pyodide/pyodide/tree/main/packages/polars

## Build pipeline plan

The old workflow (targeting Pyodide 0.27 / Emscripten 3.1.58) needs these changes for 0.29.3:

| Item | Old (Pyodide 0.27) | New (Pyodide 0.29.3) |
|------|-------------------|----------------------|
| Emscripten | 3.1.58 | **4.0.9** |
| LLVM | 19 | 19 (same) |
| Python | 3.10 | **3.13** |
| maturin `--interpreter` | `python3.10` | **`python3.13`** |
| ABI tag | `cp310-pyodide_2024_0` | **`cp313-pyodide_2025_0`** |

Additional work required beyond version bumps:

- **Emscripten 4.0.9 export name validation**: Emscripten 4.0.9 rejects Rust-mangled symbol names that don't look like valid C identifiers. A patch to bypass this check is required (surfaced in draft PR [pola-rs/polars#24058](https://github.com/pola-rs/polars/pull/24058)).
- **Features to strip**: `parquet`, `async`, `json`, `extract_jsonpath`, `cloud`, `polars_cloud`, `tokio`, `clipboard`, `decompress`, `new_streaming` — same as before; `tokio` in particular has no `wasm32` support.
- **Polars status in Pyodide**: Polars was present in Pyodide 0.27 (as 1.18.0), removed in 0.28 due to build failures, and remains absent in 0.29. The goal of this pipeline is to produce a standalone `.whl` that can be loaded manually via `micropip`.

The pipeline will:
1. Check out `polars` at tag `py-1.18.0`
2. Set up swap space (10 GB) to avoid OOM during Rust compilation
3. Install Emscripten 4.0.9 and LLVM 19
4. Patch Emscripten's export name validator to accept Rust-mangled symbols
5. Strip the incompatible Cargo features
6. Build with maturin targeting `wasm32-unknown-emscripten` / `python3.13`
7. Upload the resulting `.whl` as a GitHub Actions artifact


Previous pipeline from https://github.com/pola-rs/polars/blob/93ceaccdac6f05c9b07a5117f3a4a90c238dbd29/.github/workflows/release-python.yml

```yaml
  build-wheel-pyodide:
    name: build-wheels (polars, pyodide, wasm32)
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ inputs.sha }}

      # Avoid potential out-of-memory errors
      - name: Set swap space for Linux
        uses: pierotofy/set-swap-space@master
        with:
          swap-size-gb: 10

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: ${{ env.PYTHON_VERSION }}

      - name: Disable incompatible features
        env:
            FEATURES: parquet|async|json|extract_jsonpath|cloud|polars_cloud|tokio|clipboard|decompress|new_streaming
        run: |
          sed -i 's/^  "json",$/  "serde_json",/' crates/polars-python/Cargo.toml
          sed -E -i "/^  \"(${FEATURES})\",$/d" crates/polars-python/Cargo.toml py-polars/Cargo.toml

      - name: Setup emsdk
        uses: mymindstorm/setup-emsdk@v14
        with:
          # This should match the exact version of Emscripten used by Pyodide
          version: 3.1.58

      - name: Install LLVM
        # This should match the major version of LLVM expected by Emscripten
        run: |
          wget https://apt.llvm.org/llvm.sh
          chmod +x llvm.sh
          sudo ./llvm.sh 19
          echo "EM_LLVM_ROOT=/usr/lib/llvm-19/bin" >> $GITHUB_ENV

      - name: Set CFLAGS and RUSTFLAGS for wasm32
        run: |
            echo "CFLAGS=-fPIC" >> $GITHUB_ENV
            echo "RUSTFLAGS=-C link-self-contained=no" >> $GITHUB_ENV

      - name: Build wheel
        uses: PyO3/maturin-action@v1
        with:
          command: build
          target: wasm32-unknown-emscripten
          args: >
            --profile dist-release
            --manifest-path py-polars/Cargo.toml
            --interpreter python3.10
            --out wasm-dist
          maturin-version: 1.7.4

      - name: Upload wheel
        uses: actions/upload-artifact@v4
        with:
          name: wheel-polars-emscripten-wasm32
          path: wasm-dist/*.whl
```