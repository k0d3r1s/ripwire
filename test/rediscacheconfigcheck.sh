#!/usr/bin/env bash
# rediscacheconfigcheck.sh — immutable Redis cache selection, validation, and project/key identity.
set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${RIPWIRE_BIN:-$ROOT/build/ripwire}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }
[ -x "$BIN" ] || { echo "no ripwire binary at $BIN"; exit 2; }

mkdir -p "$TMP/fixture" "$TMP/run" "$TMP/default-cache"
printf 'int redis_config_fixture() { return 7; }\n' > "$TMP/fixture/a.cpp"

# RED-FIRST: before this slice, --cache=redis is interpreted as a file path and therefore does not
# reject the missing Redis endpoint before ingest.
set +e
( cd "$TMP/run" && "$BIN" "$TMP/fixture" --cache=redis --no-stable >missing.out 2>missing.err )
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'RIPWIRE_REDIS_URL' "$TMP/run/missing.err" && [ ! -s "$TMP/run/missing.out" ]; then
    ok "--cache=redis requires configuration before ingest"
else
    no "--cache=redis was not resolved as Redis before ingest (exit=$rc)"
fi

cat > "$TMP/cache_backend_unit.cpp" <<'CPP'
#include "cache_backend.h"
#include <iostream>
#include <memory>
#include <string>
#include <string_view>

namespace
{
const char* kindName( const rw::CacheBackendKind kind )
{
    switch( kind )
    {
        case rw::CacheBackendKind::Disabled: return "disabled";
        case rw::CacheBackendKind::File: return "file";
        case rw::CacheBackendKind::Redis: return "redis";
    }
    return "invalid";
}
}

int main( int argc, char** argv )
{
    if( argc == 2 && std::string_view( argv[1] ) == "hash-vectors" )
    {
        const std::string binary( "a\0b", 3 );
        std::cout << rw::redisKeyHash( "" ) << '\n' << rw::redisKeyHash( "abc" ) << '\n' << rw::redisKeyHash( binary ) << '\n';
        return 0;
    }
    if( argc == 4 && std::string_view( argv[1] ) == "identity" )
    {
        std::string error;
        const std::string identity = rw::redisProjectIdentity( argv[2], argv[3], error );
        if( !error.empty() ) { std::cerr << error << '\n'; return 1; }
        std::cout << identity << '\n';
        return 0;
    }
    if( argc == 2 && std::string_view( argv[1] ) == "invalid-nul" )
    {
        std::string value( "bad\0project", 11 );
        std::string error;
        if( !rw::redisProjectIdentity( ".", value, error ).empty() ) { return 2; }
        std::cout << error << '\n';
        return error.empty() ? 3 : 0;
    }
    if( argc == 6 && std::string_view( argv[1] ) == "policy" )
    {
        rw::CacheSelectionInput input;
        input.noCache = std::string_view( argv[2] ) == "1";
        input.cacheWasExplicit = std::string_view( argv[3] ) == "1";
        input.explicitCache = argv[4];
        input.environmentBackend = argv[5];
        std::shared_ptr<const rw::CachePolicy> policy;
        std::string error;
        if( !rw::resolveCachePolicy( input, policy, error ) ) { std::cerr << error << '\n'; return 1; }
        std::cout << kindName( policy->kind ) << '\n' << policy->explicitFilePath << '\n';
        return 0;
    }
    if( argc == 3 && std::string_view( argv[1] ) == "context" )
    {
        rw::CacheSelectionInput input;
        input.cacheWasExplicit = true;
        input.explicitCache = "redis";
        std::shared_ptr<const rw::CachePolicy> policy;
        std::string error;
        if( !rw::resolveCachePolicy( input, policy, error ) ) { std::cerr << error << '\n'; return 1; }
        rw::CacheContext context;
        if( !rw::cacheContextForRoot( policy, argv[2], true, context, error ) ) { std::cerr << error << '\n'; return 1; }
        std::cout << kindName( context.policy->kind ) << '\n' << context.project << '\n'
                  << context.filePath << '\n' << ( context.captureValueUses ? "rich" : "lean" ) << '\n';
        return 0;
    }
    return 64;
}
CPP

if "${CXX:-c++}" -std=c++23 -Isrc "$TMP/cache_backend_unit.cpp" src/cache_backend.cpp -o "$TMP/cache_backend_unit" >"$TMP/compile.out" 2>"$TMP/compile.err"; then
    ok "cache backend contract harness compiles"
else
    no "cache backend contract harness did not compile"
    sed -n '1,12p' "$TMP/compile.err"
    echo "FAILURES ABOVE"
    exit 1
fi
UNIT="$TMP/cache_backend_unit"

unset_redis()
{
    unset RIPWIRE_CACHE_BACKEND RIPWIRE_REDIS_URL RIPWIRE_REDIS_NAMESPACE RIPWIRE_REDIS_USERNAME \
          RIPWIRE_REDIS_PASSWORD RIPWIRE_REDIS_PROJECT RIPWIRE_REDIS_TTL_DAYS RIPWIRE_REDIS_TIMEOUT_MS \
          RIPWIRE_REDIS_ALLOW_PLAINTEXT_REMOTE
}

unset_redis
[ "$( "$UNIT" policy 0 0 '' '' )" = 'file' ] && ok "default policy is filesystem" || no "default policy is not filesystem"
[ "$( "$UNIT" policy 1 1 redis redis )" = 'disabled' ] && ok "--no-cache wins over explicit and environment Redis" || no "--no-cache precedence is wrong"
[ "$( "$UNIT" policy 0 1 ./redis redis )" = $'file\n./redis' ] && ok "./redis remains a file path" || no "./redis did not resolve as a file"

export RIPWIRE_REDIS_URL='redis://127.0.0.1:6379/0' RIPWIRE_REDIS_NAMESPACE='unit-space' RIPWIRE_REDIS_PROJECT='unit-project'
[ "$( "$UNIT" policy 0 1 redis '' )" = 'redis' ] && ok "explicit Redis activation resolves" || no "explicit Redis activation did not resolve"
[ "$( "$UNIT" policy 0 0 '' redis )" = 'redis' ] && ok "environment Redis activation resolves" || no "environment Redis activation did not resolve"
[ "$( "$UNIT" policy 0 1 "$TMP/explicit.bin" redis )" = $'file\n'"$TMP/explicit.bin" ] && ok "explicit file wins over environment Redis" || no "explicit file precedence is wrong"

HASHES="$( "$UNIT" hash-vectors )"
EXPECTED=$'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\nba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n59b271ae1bbcb1d31d41929817f4b16fb439eb4f31520b5ad1d5ce98920a7138'
[ "$HASHES" = "$EXPECTED" ] && ok "SHA-256 vectors include binary input and full lowercase output" || no "SHA-256 vectors differ"

mkdir -p "$TMP/repo-a/src"
printf 'int x;\n' > "$TMP/repo-a/src/x.cpp"
git -C "$TMP/repo-a" init -q
git -C "$TMP/repo-a" config user.email fixture@example.invalid
git -C "$TMP/repo-a" config user.name fixture
git -C "$TMP/repo-a" remote add origin 'https://Example.COM/Owner/Repo.git'
git -C "$TMP/repo-a" add src/x.cpp
git -C "$TMP/repo-a" commit -qm fixture
cp -R "$TMP/repo-a" "$TMP/repo-b"
IDA="$( "$UNIT" identity "$TMP/repo-a/src" '' )"
IDB="$( "$UNIT" identity "$TMP/repo-b/src" '' )"
if [ -n "$IDA" ] && [ "$IDA" = "$IDB" ] && ! printf '%s' "$IDA" | grep -q "$TMP"; then
    ok "project identity is stable across absolute checkout paths"
else
    no "project identity contains checkout-specific state"
fi
git -C "$TMP/repo-b" remote set-url origin 'git@example.com:Owner/Repo.git'
[ "$IDA" = "$( "$UNIT" identity "$TMP/repo-b/src" '' )" ] && ok "HTTPS and SCP-style remotes normalize identically" || no "supported remote forms normalize differently"

unset RIPWIRE_REDIS_PROJECT
CONTEXT_A="$( "$UNIT" context "$TMP/repo-a/src" )"
printf '%s\n' "$CONTEXT_A" | grep -qx 'redis' && printf '%s\n' "$CONTEXT_A" | grep -qF "$IDA" \
    && ok "Redis context derives the Git project without an override" || no "Redis context did not derive its Git project"

mkdir "$TMP/non-git"
if "$UNIT" identity "$TMP/non-git" '' >"$TMP/non-git.out" 2>"$TMP/non-git.err"; then no "non-Git root did not require project override"; else ok "non-Git root requires project override"; fi
[ "$( "$UNIT" identity "$TMP/non-git" explicit-project )" = 'explicit-project' ] && ok "project override supports non-Git roots" || no "project override was not used"
if "$UNIT" context "$TMP/non-git" >"$TMP/context.out" 2>"$TMP/context.err"; then no "Redis context accepted a non-Git root without an override"; else ok "Redis context requires Git identity or a project override"; fi

expect_bad()
{
    label="$1"; shift
    if "$@" >"$TMP/bad.out" 2>"$TMP/bad.err"; then
        no "$label was accepted"
    elif grep -q 'PASSWORD_SENTINEL_9f31' "$TMP/bad.out" "$TMP/bad.err"; then
        no "$label leaked the password sentinel"
    else
        ok "$label is rejected with redacted diagnostics"
    fi
}

export RIPWIRE_REDIS_PASSWORD='PASSWORD_SENTINEL_9f31'
for endpoint in 'redis://user@127.0.0.1:6379' 'redis://user%40host@127.0.0.1:6379' 'rediss://127.0.0.1:6379' \
    'redis://192.0.2.1:6379' 'redis://127.0.0.1:6379/not-a-db' 'redis://127.0.0.1:6379/999999999999999999999' \
    'redis://127.0.0.1:6379/0?unknown=1' 'redis://127.0.0.1:6379/0#fragment' 'redis://127.0.0.1:6379/%30' \
    'redis+unix:///tmp/redis.sock?unknown=1'
do
    RIPWIRE_REDIS_URL="$endpoint" expect_bad "invalid endpoint" "$UNIT" policy 0 1 redis ''
done
RIPWIRE_REDIS_URL=$'redis://127.0.0.1:6379\n' expect_bad "endpoint control character" "$UNIT" policy 0 1 redis ''
RIPWIRE_REDIS_URL='redis://127.0.0.1:6379/0' RIPWIRE_REDIS_NAMESPACE='' expect_bad "missing namespace" "$UNIT" policy 0 1 redis ''
RIPWIRE_REDIS_URL='redis://127.0.0.1:6379/0' RIPWIRE_REDIS_TTL_DAYS=0 expect_bad "zero TTL" "$UNIT" policy 0 1 redis ''
RIPWIRE_REDIS_URL='redis://127.0.0.1:6379/0' RIPWIRE_REDIS_TTL_DAYS=50000 expect_bad "overflowing TTL" "$UNIT" policy 0 1 redis ''
RIPWIRE_REDIS_URL='redis://127.0.0.1:6379/0' RIPWIRE_REDIS_TIMEOUT_MS=0 expect_bad "zero timeout" "$UNIT" policy 0 1 redis ''
RIPWIRE_REDIS_URL='redis://127.0.0.1:6379/0' RIPWIRE_REDIS_TIMEOUT_MS=999999999999 expect_bad "overflowing timeout" "$UNIT" policy 0 1 redis ''
expect_bad "unknown backend" "$UNIT" policy 0 0 '' mystery
[ "$( RIPWIRE_REDIS_URL='redis://192.0.2.1:6379' RIPWIRE_REDIS_ALLOW_PLAINTEXT_REMOTE=1 "$UNIT" policy 0 1 redis '' )" = 'redis' ] \
    && ok "explicit opt-in permits remote plaintext configuration" || no "remote plaintext opt-in was ignored"
[ "$( RIPWIRE_REDIS_URL='redis+unix:///tmp/redis.sock?db=2' "$UNIT" policy 0 1 redis '' )" = 'redis' ] \
    && ok "redis+unix configuration is accepted" || no "redis+unix configuration was rejected"
if "$UNIT" invalid-nul >"$TMP/nul.out" 2>"$TMP/nul.err" && ! grep -q 'PASSWORD_SENTINEL_9f31' "$TMP/nul.out" "$TMP/nul.err"; then ok "embedded NUL is rejected without secret disclosure"; else no "embedded NUL validation failed"; fi
if "$BIN" "$TMP/fixture" --redis-password=PASSWORD_SENTINEL_9f31 >"$TMP/cli-secret.out" 2>"$TMP/cli-secret.err"; then
    no "a Redis password CLI flag was accepted"
elif "$BIN" --help=all 2>&1 | grep -q -- '--redis-password'; then
    no "a Redis password CLI flag is advertised"
else
    ok "Redis credentials remain environment-only"
fi

unset_redis
TMPDIR="$TMP/default-cache" "$BIN" "$TMP/fixture" --no-stable >/dev/null 2>"$TMP/default.err"
find "$TMP/default-cache" -type f -size +0c | grep -q . && ok "default execution still creates a local cache" || no "default local cache was not created"
RIPWIRE_CACHE_BACKEND=redis "$BIN" "$TMP/fixture" --no-cache --no-stable >"$TMP/nocache.out" 2>"$TMP/nocache.err" \
    && ok "--no-cache wins over invalid environment Redis" || no "--no-cache did not win over environment Redis"
RIPWIRE_CACHE_BACKEND=redis "$BIN" "$TMP/fixture" --cache="$TMP/explicit.bin" --no-stable >/dev/null 2>"$TMP/file.err"
[ -s "$TMP/explicit.bin" ] && ok "explicit file path wins over environment Redis" || no "explicit file path did not retain file behavior"

export RIPWIRE_REDIS_URL='redis://127.0.0.1:6379/0' RIPWIRE_REDIS_NAMESPACE='unit-space' RIPWIRE_REDIS_PROJECT='unit-project'
( cd "$TMP/run" && "$BIN" "$TMP/fixture" --cache=redis --no-stable >redis.out 2>redis.err )
[ ! -e "$TMP/run/redis" ] && ok "--cache=redis selects Redis without creating a same-named file" || no "--cache=redis created a file"
RIPWIRE_CACHE_BACKEND=redis "$BIN" "$TMP/fixture" --no-stable >/dev/null 2>"$TMP/envredis.err" && ok "RIPWIRE_CACHE_BACKEND=redis activates Redis" || no "environment Redis activation failed"

unset_redis
set +e
RIPWIRE_CACHE_BACKEND=redis RIPWIRE_REDIS_PASSWORD='PASSWORD_SENTINEL_9f31' "$BIN" "$TMP/definitely-missing-root" >"$TMP/pre.out" 2>"$TMP/pre.err"
pre_rc=$?
set -e
if [ "$pre_rc" -eq 1 ] && grep -q 'RIPWIRE_REDIS_URL' "$TMP/pre.err" && ! grep -q 'root path does not exist' "$TMP/pre.err" \
   && ! grep -q 'PASSWORD_SENTINEL_9f31' "$TMP/pre.out" "$TMP/pre.err"; then
    ok "invalid Redis settings fail before root ingest with redacted errors"
else
    no "invalid Redis settings were not rejected before ingest"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES ABOVE"
exit $fail
