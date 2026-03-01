# polars-pyodide

Builds [Polars](https://github.com/pola-rs/polars) 1.33.1 as a [Pyodide](https://pyodide.org) compatible wheel.

**Official test suite** (`test-official.html`) — **~23066 pass, ~281 fail, 9 skipped** (2 tests deselected as they intentionally exhaust the call stack; hypothesis-based tests are non-deterministic so counts vary slightly between runs):

Failures group into known categories:

| Category | Root cause |
|----------|-----------|
| `serialize_json` / `str_json_decode` / `str_json_path_match` / `struct_json_encode` missing | `json` + `extract_jsonpath` features stripped |
| `new_from_parquet` / `sink_parquet` missing | `parquet` feature stripped |
| `activate 'new_streaming'` / `invalid build. Missing feature new-streaming` panic | `new_streaming` feature stripped |
| `collect_concurrently` / `to_dot_streaming_phys` missing | `new_streaming` feature stripped |
| SQL tests using `scan_ipc` (`test_group_by`, `test_joins`, `test_regex`, …) | `scan_ipc(...).collect()` routes through `new_streaming` internally |
| `test_merge_sorted_unbalanced` / `test_merge_sorted_chain_streaming_*` | `merge_sorted` with `engine="streaming"` requires `new_streaming` |
| `test_join_where` / `test_boolean_min_max_agg` / `test_cat_order_flag_csv_read_23823` | Non-deterministic ordering on wasm32 |
| `test_reproducible_hash_with_seeds` / `test_hash_struct` / `test_list_sample` / `test_sample_n_expr` / `test_shuffle_series` / `test_rank_random_series` | Hash/RNG values differ — wasm32 is 32-bit, host is 64-bit |
| `Could not convert 86400000000 to usize` | 32-bit `usize` overflow on large temporal values (date/time ranges, group_by_dynamic, join_asof) |
| `capacity overflow` panic / `test_sort_row_fmt` | 32-bit `usize` overflow in Arrow record batch serialization or row encoding |
| `OSError: emscripten does not support processes` | No subprocess support in Pyodide |
| `cloudpickle` missing | Not available in Pyodide; affects UDF pickling in `test_serde` |
| Rolling window wrong values (`test_rolling_negative_offset`, `test_rolling_extrema`, …) | wasm32 behavioral difference in rolling aggregation implementation |
| `test_object_estimated_size` | Object size estimate assumes 8-byte pointers; wasm32 uses 4-byte pointers |
| `test_no_panic_pandas_nat` / `test_parse_apply_raw_functions` | Behaviour differs on wasm32: `pd.NaT` accepted without raising; `json_decode` warning not emitted (feature stripped) |
| `test_from_pandas_nan_to_null_16453` | Monkeypatches multithreading threshold; wasm32 has no threads, path behaves differently |

## Version ceiling

**1.33.1 is the highest Polars version buildable for wasm32.** Polars 1.18.0 was the last version shipped with Pyodide (through 0.27.7) before it was dropped from Pyodide 0.28+ due Pyodide having upgraded its build toolchain from (Python 3.12, Emscripten 3.1.58) to (Python 3.13, Emscripten 4.0.9).

From **1.34.0** onwards, `polars-stream` became a standalone crate with unconditional `tokio`, `rayon`, and `crossbeam-*` dependencies. These do not support `wasm32-unknown-emscripten`, and removing them would require architectural changes to the streaming engine. The Polars core team dropped the Pyodide build in [#24630](https://github.com/pola-rs/polars/pull/24630) citing recurring `mio` incompatibilities with no intention to make it optional, see [#26484](https://github.com/pola-rs/polars/pull/26484); the tracking issue is [#22231](https://github.com/pola-rs/polars/issues/22231). As a result, 1.34.0+ cannot be built for Pyodide without upstream changes. A previous attempt in building polars against Pyodide 0.29 was made in [#24058](https://github.com/pola-rs/polars/pull/24058).

## Testing

### Smoke tests

Four basic correctness tests (DataFrame creation, operations, dtypes, CSV). Must pass for the build to succeed.

**Interactive** — serve the repo root and open in a browser:
```bash
uv run -m http.server
# open http://localhost:8000/test-smoke.html
```

**Headless** (CI / command line):
```bash
npm install playwright
npx playwright install chromium --with-deps
node test-runner.mjs --strict test-smoke.html wasm-dist
```

### Official test suite

303 test files from `py-polars/tests/unit/` (streaming, cloud, IO, and ML directories excluded). Results are informational — a few known failures are expected (see table above). The `tests/unit/` directory must be present (copy `py-polars/tests/unit/` from the Polars 1.33.1 source).

**Interactive:**
```bash
uv run -m http.server
# open http://localhost:8000/test-official.html
```

**Headless:**
```bash
node test-runner.mjs test-official.html wasm-dist
```

`wasm-dist/` must contain the built wheel. The headless runner starts a local HTTP server, launches Chromium via Playwright, and prints results to stdout. `--strict` makes it exit 1 on any failure.

## Build

**GitHub Actions** (~20 minutes):

1. Push `.github/workflows/build-1.33.1.yml` to your repo
2. Go to Actions → "Build Polars 1.33.1 for Pyodide 0.29.3" → Run workflow
3. Download the wheel artifact when the run completes

The GH Actions runner has 16 GB RAM; only 6 GB swap is needed for the Rust link step.

## Fixes

### 1. SIGILL during link (`lto=fat`)

The `dist-release` Cargo profile enables `lto = "fat"`, which triggers an illegal instruction crash during the wasm32 link step with `nightly-2025-08-29`.

**Fix:** Use `--release` instead and override LTO:
```bash
CARGO_PROFILE_RELEASE_LTO=off maturin build --release ...
```

### 2. Emscripten export name validation

Emscripten 4.0.14 validates that all exported symbols are valid C identifiers. Rust-mangled symbols are not, so the link fails. The check exists in **three places**:

| File | Patch |
|------|-------|
| `tools/link.py` | `assert.*c_ident.*export` → `# patched` |
| `tools/shared.py` | `def check_export_name` → `def _disabled_check_export_name` |
| `tools/emscripten.py` | `exit_with_error(f'invalid export name: {n}')` → `pass` |

### 3. `-wasm-use-legacy-eh` injection

Emscripten injects `-wasm-use-legacy-eh` into some link commands, but LLVM 19 does not recognise this flag. Lines containing it are patched to `pass`.

### 4. `invoke_*` not resolved at runtime

Pyodide 0.29.3 was built with native wasm exceptions and exports zero `invoke_*` functions. The pre-built Rust sysroot uses legacy Emscripten EH, which generates `invoke_*` trampolines — causing a dynamic linking error at load time.

**Fix:** Recompile `std` and `panic_unwind` from source with native wasm EH using `-Z build-std`. This requires the `rust-src` component and a `.cargo/config.toml`:

```toml
[unstable]
build-std = ["std", "panic_unwind"]
build-std-features = ["panic-unwind"]   # hyphen (not underscore) in nightly-2025-08-29+

[build]
rustflags = [
  "-C", "link-self-contained=no",
  "-Z", "emscripten-wasm-eh",
  "-C", "link-arg=-sSUPPORT_LONGJMP=wasm",
  "-C", "link-arg=-sSTACK_SIZE=4194304",
]
```

C dependencies must also be compiled with native wasm EH:
```bash
export CFLAGS="-fPIC -fwasm-exceptions"
export CXXFLAGS="-fPIC -fwasm-exceptions"
```

### 5. Stripped Cargo features

These features are removed from `crates/polars-python/Cargo.toml` and `py-polars/Cargo.toml`:

| Feature | Reason |
|---------|--------|
| `parquet` | async I/O deps |
| `json`, `extract_jsonpath` | `serde_json` is `optional = true`; made non-optional first, then feature entry removed |
| `catalog`, `cloud`, `polars_cloud`, `polars_cloud_client`, `polars_cloud_server` | tokio + network deps |
| `clipboard` | OS clipboard API unavailable in wasm |
| `decompress` | not needed |
| `new_streaming` | pulls in `polars-stream` → `polars-io[async,file_cache]` → tokio → mio |

An additional patch to `crates/polars/Cargo.toml` removes `"new_streaming"` from the `csv`/`ipc`/`json` feature lines, which breaks the transitive tokio dependency chain.

`serde_json` must be made non-optional before removing the `json` feature definition — otherwise cargo errors with "feature includes serde_json but it is not an optional dependency".

The `"abi3-py39"` pyo3 feature is also removed so maturin produces a non-abi3 wheel tagged `cp313`.

### 6. `rust-toolchain.toml` must be deleted

Polars ships a `rust-toolchain.toml` pinning its own nightly. Delete it before building so the explicitly-installed toolchain is used instead.

### 7. `rustup default` vs `rustup override set`

`rustup override set` only applies to the current directory. If the build changes into a subdirectory, the override doesn't apply. Use `rustup default` to set the system-wide default.

### 8. `wheel<0.45` installation order

`pyodide-build==0.29.3` depends on `auditwheel-emscripten`, which imports `wheel.cli`. In `wheel>=0.45` this module was removed. Install `wheel<0.45` **before** `pyodide-build`.

### 9. pyodide-build has no console_scripts entry point

`uv tool install pyodide-build` fails because pyodide-build doesn't register a console_scripts entry point. Install into a plain venv instead:
```bash
uv venv /opt/pyodide-env
uv pip install --python /opt/pyodide-env/bin/python "wheel<0.45" "pyodide-build==0.29.3"
```

## Credits

This repo was developed with [Claude Code](https://claude.ai/claude-code) (claude-sonnet-4-6).
