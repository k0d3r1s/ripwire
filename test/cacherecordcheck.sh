#!/usr/bin/env bash
# cacherecordcheck.sh — CMake-backed v18 per-file record compatibility gate.
#
# Regenerate/check the independent baseline only from the exact pre-refactor source commit:
#   git worktree add /tmp/ripwire-cache-v18-baseline 4fa7a75e7d767aeff1e666f04eda16f4bf4084c1
#   CACHE_RECORD_SOURCE_ROOT=/tmp/ripwire-cache-v18-baseline CACHE_RECORD_BASELINE=1 \
#     bash test/cacherecordcheck.sh

set -euo pipefail

SCRIPT_ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
SOURCE_ROOT="${CACHE_RECORD_SOURCE_ROOT:-$SCRIPT_ROOT}"
BASELINE_COMMIT=4fa7a75e7d767aeff1e666f04eda16f4bf4084c1
BASELINE_MODE="${CACHE_RECORD_BASELINE:-0}"
if [ "$BASELINE_MODE" = 1 ]; then
    SOURCE_HEAD="$( git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null )" || {
        echo "FAIL: CACHE_RECORD_SOURCE_ROOT is not a Git checkout: $SOURCE_ROOT"; exit 2;
    }
    if [ "$SOURCE_HEAD" != "$BASELINE_COMMIT" ]; then
        echo "FAIL: CACHE_RECORD_SOURCE_ROOT must be exactly $BASELINE_COMMIT (got $SOURCE_HEAD)"; exit 2
    fi
fi

BUILD_DIR="${RIPWIRE_TEST_BUILD_DIR:-$SCRIPT_ROOT/build-tests}"
if [ "$BASELINE_MODE" = 1 ]; then
    BUILD_DIR="${RIPWIRE_TEST_BUILD_DIR:-$SCRIPT_ROOT/build-tests-cache-baseline}"
fi

cmake -S "$SCRIPT_ROOT" -B "$BUILD_DIR" -DRIPWIRE_TESTS=ON \
    -DRIPWIRE_CACHE_RECORD_SOURCE_ROOT="$SOURCE_ROOT" \
    -DRIPWIRE_CACHE_RECORD_BASELINE="$BASELINE_MODE" >/dev/null
cmake --build "$BUILD_DIR" --target ripwire_test_cache_record -j2

if [ "$BASELINE_MODE" != 1 ]; then
    ctest --test-dir "$BUILD_DIR" --output-on-failure -R '^ripwire\.cache_record$'

    SAVE_BODY="$( sed -n '/^inline void saveCache/,/quality::sweepStaleCacheBlobsOnce/p' "$SCRIPT_ROOT/src/ingest_cache.h" )"
    grep -q 'appendCacheRecord( w,' <<<"$SAVE_BODY" || {
        echo "FAIL: saveCache does not use the direct record append seam"; exit 1;
    }
    if grep -q 'encodeCacheRecord(' <<<"$SAVE_BODY"; then
        echo "FAIL: saveCache still creates an owned cache record before appending"; exit 1
    fi
    echo "  PASS  saveCache uses direct append with caller-owned scratch"
fi

TMP="$( mktemp -d )"
trap 'rm -rf "$TMP"' EXIT
"$BUILD_DIR/ripwire_test_cache_record" --write-records "$TMP/lean.bin" "$TMP/rich.bin"

if command -v shasum >/dev/null 2>&1; then
    sha256_of(){ shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
    sha256_of(){ sha256sum "$1" | awk '{print $1}'; }
else
    echo "FAIL: shasum or sha256sum is required"; exit 2
fi

ENDIAN="$( python3 - <<'PYEOF'
import sys
print(sys.byteorder)
PYEOF
)"
if [ "$ENDIAN" != little ]; then
    echo "SKIP: no committed native-endian v18 record baseline for $ENDIAN-endian hosts"
    exit 0
fi

LEAN_SIZE=447
LEAN_SHA=4dd495877c02be912f0424eda2ef441e9f31bf0b37f35e9602f3f860aed4bfc5
RICH_SIZE=499
RICH_SHA=47f8105e4861ce9b0e08adf5450e6b8e884991d1aaefa34da8c7802c88d01fb1
ACTUAL_LEAN_SIZE="$( wc -c <"$TMP/lean.bin" | tr -d ' ' )"
ACTUAL_LEAN_SHA="$( sha256_of "$TMP/lean.bin" )"
ACTUAL_RICH_SIZE="$( wc -c <"$TMP/rich.bin" | tr -d ' ' )"
ACTUAL_RICH_SHA="$( sha256_of "$TMP/rich.bin" )"

if [ "$ACTUAL_LEAN_SIZE" != "$LEAN_SIZE" ] || [ "$ACTUAL_LEAN_SHA" != "$LEAN_SHA" ]; then
    echo "FAIL: lean v18 drift: got $ACTUAL_LEAN_SIZE B $ACTUAL_LEAN_SHA, expected $LEAN_SIZE B $LEAN_SHA"; exit 1
fi
if [ "$ACTUAL_RICH_SIZE" != "$RICH_SIZE" ] || [ "$ACTUAL_RICH_SHA" != "$RICH_SHA" ]; then
    echo "FAIL: rich v18 drift: got $ACTUAL_RICH_SIZE B $ACTUAL_RICH_SHA, expected $RICH_SIZE B $RICH_SHA"; exit 1
fi

echo "  PASS  lean v18 record matches independent little-endian baseline ($LEAN_SIZE B, $LEAN_SHA)"
echo "  PASS  rich v18 record matches independent little-endian baseline ($RICH_SIZE B, $RICH_SHA)"
echo "ALL PASS"
