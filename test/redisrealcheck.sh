#!/usr/bin/env bash
# Ordinary regression is fixture-only. External Redis must be explicitly selected.
# RIPWIRE_TEST_DEPS: test/redis_real_admin.py,test/redis_stub.py,test/redis_protocol_unit.cpp,src/redis_client.cpp,src/cache_backend.cpp
set -euo pipefail
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${RIPWIRE_BIN:-$ROOT/build/ripwire}"
case "${1:---fixture-only}" in
    --fixture-only)
        BUILD_DIR="${RIPWIRE_REDIS_PROTOCOL_BUILD_DIR:-$ROOT/build-tests-redisprotocol}"
        cmake -Wno-deprecated -S "$ROOT" -B "$BUILD_DIR" -DRIPWIRE_TESTS=ON >/dev/null
        cmake --build "$BUILD_DIR" --target ripwire_test_redis_protocol -j2 >/dev/null
        "$BUILD_DIR/ripwire_test_redis_protocol"
        python3 "$ROOT/test/redis_real_admin.py" --fixture "$BIN"
        ;;
    --real|--ci-acl)
        if [ -z "${RIPWIRE_REDIS_TEST_URL:-}" ]; then
            if [ "${CI:-}" = true ]; then
                echo 'FAIL: CI real Redis gate requires RIPWIRE_REDIS_TEST_URL' >&2
                exit 1
            fi
            echo '  SKIP  real Redis: set RIPWIRE_REDIS_TEST_URL and select --real explicitly'
            exit 0
        fi
        python3 "$ROOT/test/redis_real_admin.py" "$1" "$BIN"
        ;;
    *) echo 'usage: redisrealcheck.sh --fixture-only|--real|--ci-acl' >&2; exit 2 ;;
esac
