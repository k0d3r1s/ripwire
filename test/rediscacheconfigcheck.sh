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
        std::cout << rw::redisKeyHash( "" ) << '\n' << rw::redisKeyHash( "abc" ) << '\n' << rw::redisKeyHash( binary ) << '\n'
                  << rw::redisKeyHash( std::string( 55, 'a' ) ) << '\n' << rw::redisKeyHash( std::string( 56, 'a' ) ) << '\n'
                  << rw::redisKeyHash( std::string( 64, 'a' ) ) << '\n' << rw::redisKeyHash( std::string( 128, 'a' ) ) << '\n';
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
if [ "$( "$UNIT" policy 0 0 '' '' )" = 'file' ]; then ok "default policy is filesystem"; else no "default policy is not filesystem"; fi
if [ "$( "$UNIT" policy 1 1 redis redis )" = 'disabled' ]; then ok "--no-cache wins over explicit and environment Redis"; else no "--no-cache precedence is wrong"; fi
if [ "$( "$UNIT" policy 0 1 ./redis redis )" = $'file\n./redis' ]; then ok "./redis remains a file path"; else no "./redis did not resolve as a file"; fi

export RIPWIRE_REDIS_URL='redis://127.0.0.1:6379/0' RIPWIRE_REDIS_NAMESPACE='unit-space' RIPWIRE_REDIS_PROJECT='unit-project'
if [ "$( "$UNIT" policy 0 1 redis '' )" = 'redis' ]; then ok "explicit Redis activation resolves"; else no "explicit Redis activation did not resolve"; fi
if [ "$( "$UNIT" policy 0 0 '' redis )" = 'redis' ]; then ok "environment Redis activation resolves"; else no "environment Redis activation did not resolve"; fi
if [ "$( "$UNIT" policy 0 1 "$TMP/explicit.bin" redis )" = $'file\n'"$TMP/explicit.bin" ]; then ok "explicit file wins over environment Redis"; else no "explicit file precedence is wrong"; fi

# Numerically equivalent loopback literals must not require the remote-plaintext opt-in.
for host in localhost LOCALHOST 127.1.2.3 '[::1]' '[0:0:0:0:0:0:0:1]' '[0000:0000:0000:0000:0000:0000:0000:0001]' \
            '[::ffff:127.0.0.0]' '[::ffff:127.0.0.1]' '[::ffff:127.255.255.255]' '[0:0:0:0:0:ffff:7f01:0203]'; do
    if [ "$( RIPWIRE_REDIS_URL="redis://$host:6379/2" "$UNIT" policy 0 1 redis '' 2>"$TMP/loopback.err" )" = 'redis' ]; then
        ok "numeric loopback accepted without remote opt-in: $host"
    else
        no "loopback required remote opt-in: $host"
    fi
done
for host in '[::2]' '[2001:db8::1]' '[::]' '[not-an-ipv6-address]' cache.example.invalid \
            '[::ffff:126.255.255.255]' '[::ffff:128.0.0.0]' '[::ffff:192.0.2.1]' '[::127.0.0.1]'; do
    if RIPWIRE_REDIS_URL="redis://$host:6379/2" "$UNIT" policy 0 1 redis '' >"$TMP/remote.out" 2>"$TMP/remote.err"; then
        no "non-loopback accepted without remote opt-in: $host"
    elif [ ! -s "$TMP/remote.out" ] && ! grep -qF "$host" "$TMP/remote.err"; then
        ok "non-loopback still refused with categorical diagnostics: $host"
    else
        no "non-loopback refusal leaked endpoint: $host"
    fi
done

HASHES="$( "$UNIT" hash-vectors )"
EXPECTED=$'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\nba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n59b271ae1bbcb1d31d41929817f4b16fb439eb4f31520b5ad1d5ce98920a7138\n9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318\nb35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a\nffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb\n6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e'
if [ "$HASHES" = "$EXPECTED" ]; then ok "SHA-256 vectors cover padding and multi-block boundaries with full lowercase output"; else no "SHA-256 vectors differ"; fi

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
if [ "$IDA" = "$( "$UNIT" identity "$TMP/repo-b/src" '' )" ]; then ok "HTTPS and SCP-style remotes normalize identically"; else no "supported remote forms normalize differently"; fi
git -C "$TMP/repo-b" remote set-url origin 'ssh://git@EXAMPLE.com/Owner/Repo.git'
if [ "$IDA" = "$( "$UNIT" identity "$TMP/repo-b/src" '' )" ]; then ok "HTTPS and ssh:// remotes normalize identically"; else no "HTTPS and ssh:// remotes normalize differently"; fi

cp -R "$TMP/repo-a" "$TMP/repo-case"
git -C "$TMP/repo-case" config --rename-section remote.origin remote.saved
git -C "$TMP/repo-case" config --add remote.Origin.url 'https://example.com/Wrong/Repo.git'
git -C "$TMP/repo-case" config --add remote.origin.url 'https://Example.COM/Owner/Repo.git'
CASE_UPPER_FIRST="$( "$UNIT" identity "$TMP/repo-case/src" '' )"
git -C "$TMP/repo-case" config --remove-section remote.Origin
git -C "$TMP/repo-case" config --remove-section remote.origin
git -C "$TMP/repo-case" config --add remote.origin.url 'https://Example.COM/Owner/Repo.git'
git -C "$TMP/repo-case" config --add remote.Origin.url 'https://example.com/Wrong/Repo.git'
CASE_LOWER_FIRST="$( "$UNIT" identity "$TMP/repo-case/src" '' )"
if [ "$CASE_UPPER_FIRST" = "$IDA" ] && [ "$CASE_LOWER_FIRST" = "$IDA" ]; then
    ok "Git origin subsection selection is case-sensitive and order-independent"
else
    no "Git origin subsection selection depends on case or order"
fi

git -C "$TMP/repo-b" remote set-url origin 'https://Example.COM:8443/Owner/Repo.git'
PORT_ID="$( "$UNIT" identity "$TMP/repo-b/src" '' )"
if printf '%s\n' "$PORT_ID" | grep -qF 'example.com:8443/Owner/Repo'; then ok "non-default Git remote port is preserved"; else no "non-default Git remote port was lost"; fi
git -C "$TMP/repo-b" remote set-url origin 'https://Example.COM:0443/Owner/Repo.git'
if [ "$IDA" = "$( "$UNIT" identity "$TMP/repo-b/src" '' )" ]; then ok "zero-padded HTTPS default port normalizes away"; else no "zero-padded HTTPS default port changes identity"; fi
git -C "$TMP/repo-b" remote set-url origin 'ssh://git@Example.COM:0022/Owner/Repo.git'
if [ "$IDA" = "$( "$UNIT" identity "$TMP/repo-b/src" '' )" ]; then ok "zero-padded SSH default port normalizes away"; else no "zero-padded SSH default port changes identity"; fi
git -C "$TMP/repo-b" remote set-url origin 'https://Example.COM:08443/Owner/Repo.git'
PADDED_PORT_ID="$( "$UNIT" identity "$TMP/repo-b/src" '' )"
if [ "$PADDED_PORT_ID" = "$PORT_ID" ] && printf '%s\n' "$PADDED_PORT_ID" | grep -qF 'example.com:8443/Owner/Repo' \
    && ! printf '%s\n' "$PADDED_PORT_ID" | grep -qF ':08443'; then
    ok "non-default Git remote port uses canonical decimal spelling"
else
    no "non-default Git remote port retained a non-canonical spelling"
fi
git -C "$TMP/repo-b" remote set-url origin 'https://Example.COM:8444/Owner/Repo.git'
DIFFERENT_PORT_ID="$( "$UNIT" identity "$TMP/repo-b/src" '' )"
if [ "$DIFFERENT_PORT_ID" != "$PORT_ID" ]; then ok "meaningful Git remote ports remain distinct"; else no "distinct Git remote ports collided"; fi
git -C "$TMP/repo-b" remote set-url origin 'ssh://git@[2001:DB8::1]/Owner/Repo.git'
IPV6_ID="$( "$UNIT" identity "$TMP/repo-b/src" '' )"
if printf '%s\n' "$IPV6_ID" | grep -qF '[2001:db8::1]/Owner/Repo'; then ok "bracketed IPv6 Git host identity is preserved"; else no "bracketed IPv6 Git host identity was lost"; fi
git -C "$TMP/repo-b" remote set-url origin 'ssh://git@[2001:DB8::1]:0022/Owner/Repo.git'
if [ "$( "$UNIT" identity "$TMP/repo-b/src" '' )" = "$IPV6_ID" ]; then ok "padded IPv6 SSH default port normalizes away"; else no "padded IPv6 SSH default port changes identity"; fi
git -C "$TMP/repo-b" remote set-url origin 'ssh://git@[2001:DB8::1]:0222/Owner/Repo.git'
IPV6_PORT_ID="$( "$UNIT" identity "$TMP/repo-b/src" '' )"
if printf '%s\n' "$IPV6_PORT_ID" | grep -qF '[2001:db8::1]:222/Owner/Repo' && ! printf '%s\n' "$IPV6_PORT_ID" | grep -qF ':0222'; then
    ok "non-default IPv6 Git port uses canonical decimal spelling"
else
    no "non-default IPv6 Git port retained a non-canonical spelling"
fi

expect_bad_remote()
{
    label="$1"; remote="$2"; credential_sentinel="${3:-}"
    git -C "$TMP/repo-b" config remote.origin.url "$remote"
    if "$UNIT" identity "$TMP/repo-b/src" '' >"$TMP/remote.out" 2>"$TMP/remote.err"; then
        no "$label Git remote was accepted"
    elif [ -n "$credential_sentinel" ] && grep -Fq "$credential_sentinel" "$TMP/remote.out" "$TMP/remote.err"; then
        no "$label Git remote leaked a credential substring"
    elif grep -Fq "$remote" "$TMP/remote.out" "$TMP/remote.err"; then
        no "$label Git remote was echoed in diagnostics"
    else
        ok "$label Git remote is rejected without echoing it"
    fi
}

expect_bad_remote "credential userinfo" 'https://user:CREDENTIAL_SENTINEL_9f31@example.com/Owner/Repo.git' 'CREDENTIAL_SENTINEL_9f31'
expect_bad_remote "userless SSH" 'ssh://example.com/Owner/Repo.git'
expect_bad_remote "uppercase SSH username" 'ssh://GIT@example.com/Owner/Repo.git'
expect_bad_remote "uppercase SCP username" 'GIT@example.com:Owner/Repo.git'
expect_bad_remote "query" 'https://example.com/Owner/Repo.git?branch=main'
expect_bad_remote "fragment" 'https://example.com/Owner/Repo.git#main'
expect_bad_remote "percent escape" 'https://example.com/Owner%2FRepo.git'
expect_bad_remote "ambiguous percent escape" 'https://example.com/Owner%zzRepo.git'
expect_bad_remote "control character" $'https://example.com/Owner/Repo\t.git'
expect_bad_remote "unsupported transport" 'git://example.com/Owner/Repo.git'
expect_bad_remote "empty port" 'https://example.com:/Owner/Repo.git'
expect_bad_remote "zero port" 'https://example.com:0/Owner/Repo.git'
expect_bad_remote "oversized port" 'https://example.com:65536/Owner/Repo.git'
expect_bad_remote "non-decimal port" 'https://example.com:nope/Owner/Repo.git'
expect_bad_remote "unbracketed IPv6 authority" 'ssh://git@2001:db8::1/Owner/Repo.git'
expect_bad_remote "unclosed IPv6 authority" 'ssh://git@[2001:db8::1/Owner/Repo.git'
expect_bad_remote "malformed IPv6 authority suffix" 'ssh://git@[2001:db8::1]oops/Owner/Repo.git'
expect_bad_remote "empty IPv6 port" 'ssh://git@[2001:db8::1]:/Owner/Repo.git'
expect_bad_remote "non-decimal IPv6 port" 'ssh://git@[2001:db8::1]:notaport/Owner/Repo.git'
expect_bad_remote "zero IPv6 port" 'ssh://git@[2001:db8::1]:0/Owner/Repo.git'
expect_bad_remote "oversized IPv6 port" 'ssh://git@[2001:db8::1]:65536/Owner/Repo.git'

git -C "$TMP/repo-b" remote set-url origin 'https://Example.COM/Owner/Repo.git'

unset RIPWIRE_REDIS_PROJECT
CONTEXT_A="$( "$UNIT" context "$TMP/repo-a/src" )"
if printf '%s\n' "$CONTEXT_A" | grep -qx 'redis' && printf '%s\n' "$CONTEXT_A" | grep -qF "$IDA"; then
    ok "Redis context derives the Git project without an override"
else
    no "Redis context did not derive its Git project"
fi

mkdir "$TMP/non-git"
if "$UNIT" identity "$TMP/non-git" '' >"$TMP/non-git.out" 2>"$TMP/non-git.err"; then no "non-Git root did not require project override"; else ok "non-Git root requires project override"; fi
if [ "$( "$UNIT" identity "$TMP/non-git" explicit-project )" = 'explicit-project' ]; then ok "project override supports non-Git roots"; else no "project override was not used"; fi
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
if [ "$( RIPWIRE_REDIS_URL='redis://192.0.2.1:6379' RIPWIRE_REDIS_ALLOW_PLAINTEXT_REMOTE=1 "$UNIT" policy 0 1 redis '' )" = 'redis' ]; then
    ok "explicit opt-in permits remote plaintext configuration"
else
    no "remote plaintext opt-in was ignored"
fi
if [ "$( RIPWIRE_REDIS_URL='redis+unix:///tmp/redis.sock?db=2' "$UNIT" policy 0 1 redis '' )" = 'redis' ]; then
    ok "redis+unix configuration is accepted"
else
    no "redis+unix configuration was rejected"
fi
if "$UNIT" invalid-nul >"$TMP/nul.out" 2>"$TMP/nul.err" && ! grep -q 'PASSWORD_SENTINEL_9f31' "$TMP/nul.out" "$TMP/nul.err"; then ok "embedded NUL is rejected without secret disclosure"; else no "embedded NUL validation failed"; fi
for credential_arg in '--redis-password' '--redis-password=PASSWORD_SENTINEL_9f31' '--redis-username' '--redis-username=PASSWORD_SENTINEL_9f31'
do
    set +e
    "$BIN" "$TMP/fixture" "$credential_arg" >"$TMP/cli-secret.out" 2>"$TMP/cli-secret.err"
    credential_rc=$?
    set -e
    if [ "$credential_rc" -eq 1 ] && [ ! -s "$TMP/cli-secret.out" ] \
       && ! grep -q 'PASSWORD_SENTINEL_9f31' "$TMP/cli-secret.err"; then
        ok "credential-shaped CLI option rejects without echoing its value"
    else
        no "credential-shaped CLI option leaked or was accepted: ${credential_arg%%=*}"
    fi
done
if "$BIN" --help=all 2>&1 | grep -Eq -- '--redis-(password|username)'; then no "Redis credential CLI flags are advertised"; else ok "Redis credentials remain environment-only"; fi

unset_redis
TMPDIR="$TMP/default-cache" "$BIN" "$TMP/fixture" --no-stable >/dev/null 2>"$TMP/default.err"
if find "$TMP/default-cache" -type f -size +0c | grep -q .; then ok "default execution still creates a local cache"; else no "default local cache was not created"; fi
if RIPWIRE_CACHE_BACKEND=redis "$BIN" "$TMP/fixture" --no-cache --no-stable >"$TMP/nocache.out" 2>"$TMP/nocache.err"; then
    ok "--no-cache wins over invalid environment Redis"
else
    no "--no-cache did not win over environment Redis"
fi
RIPWIRE_CACHE_BACKEND=redis "$BIN" "$TMP/fixture" --cache="$TMP/explicit.bin" --no-stable >/dev/null 2>"$TMP/file.err"
if [ -s "$TMP/explicit.bin" ]; then ok "explicit file path wins over environment Redis"; else no "explicit file path did not retain file behavior"; fi

export RIPWIRE_REDIS_URL='redis://127.0.0.1:6379/0' RIPWIRE_REDIS_NAMESPACE='unit-space' RIPWIRE_REDIS_PROJECT='unit-project'
( cd "$TMP/run" && "$BIN" "$TMP/fixture" --cache=redis --no-stable >redis.out 2>redis.err )
if [ ! -e "$TMP/run/redis" ]; then ok "--cache=redis selects Redis without creating a same-named file"; else no "--cache=redis created a file"; fi
if RIPWIRE_CACHE_BACKEND=redis "$BIN" "$TMP/fixture" --no-stable >/dev/null 2>"$TMP/envredis.err"; then ok "RIPWIRE_CACHE_BACKEND=redis activates Redis"; else no "environment Redis activation failed"; fi

unset RIPWIRE_REDIS_PROJECT
set +e
RIPWIRE_CACHE_BACKEND=redis "$BIN" "$TMP/non-git" --mcp </dev/null >"$TMP/mcp-known.out" 2>"$TMP/mcp-known.err"
mcp_known_rc=$?
RIPWIRE_CACHE_BACKEND=redis "$BIN" --mcp </dev/null >"$TMP/mcp-rootless.out" 2>"$TMP/mcp-rootless.err"
mcp_rootless_rc=$?
set -e
if [ "$mcp_known_rc" -eq 1 ] && grep -q 'RIPWIRE_REDIS_PROJECT' "$TMP/mcp-known.err" && [ ! -s "$TMP/mcp-known.out" ]; then
    ok "known MCP root derives and validates its Redis cache context"
else
    no "known MCP root skipped Redis cache context validation"
fi
if [ "$mcp_rootless_rc" -eq 0 ] && ! grep -q 'RIPWIRE_REDIS_PROJECT' "$TMP/mcp-rootless.err"; then
    ok "rootless MCP startup defers project identity until a root is known"
else
    no "rootless MCP startup did not defer project identity"
fi

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
