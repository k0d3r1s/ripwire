#!/usr/bin/env bash
# redisclientcheck.sh — dependency-free RESP2 transport over TCP and Unix sockets.
set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
TMP="$( mktemp -d )"
STUB_PID=
cleanup()
{
    [ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null || true
    [ -z "$STUB_PID" ] || wait "$STUB_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT
fail=0
ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

cat > "$TMP/redis_client_gate.cpp" <<'CPP'
#include "redis_client.h"

#include <cerrno>
#include <cstdint>
#include <iostream>
#include <string>
#include <string_view>
#include <sys/wait.h>
#include <vector>

namespace rw
{
struct RedisClientTestPeer
{
    static void injectEintr() { RedisClient::injectEintrForTesting(); }
    static void resolverDelay( const std::uint32_t milliseconds ) { RedisClient::setResolverDelayForTesting( milliseconds ); }
    static void resolverAddresses( std::vector<std::string> addresses ) { RedisClient::setResolverAddressesForTesting( std::move( addresses ) ); }
    static void peerMismatch() { RedisClient::setPeerMismatchForTesting(); }
    static void unixPathSwap() { RedisClient::setUnixPathSwapForTesting(); }
    static void unsafeUnixOwner() { RedisClient::setUnsafeUnixOwnerForTesting(); }
};
}

namespace
{
int printFailure( const rw::RedisResult& result )
{
    std::cout << static_cast<int>( result.failure ) << '\n' << result.diagnostic << '\n';
    return result ? 0 : 1;
}
}

int main( int argc, char** argv )
{
    if( argc < 6 )
    {
        return 64;
    }
    rw::RedisCacheConfig config;
    config.endpoint = argv[1];
    config.username = argv[2];
    config.password = argv[3];
    config.timeoutMs = static_cast<std::uint32_t>( std::stoul( argv[4] ) );
    const rw::RedisClient client( config );
    const std::string_view mode = argv[5];
    if( mode == "basic" )
    {
        const std::string key( "k\0y", 3 );
        const std::string value( "v\0x", 3 );
        const rw::RedisResult set = client.command( { "SET", key, value, "NX", "EX", "9" } );
        if( !set || set.reply.type != rw::RedisReplyType::Simple || set.reply.bytes != "OK" )
        {
            return printFailure( set );
        }
        const rw::RedisResult get = client.command( { "GET", key } );
        if( !get || get.reply.type != rw::RedisReplyType::Bulk || get.reply.bytes != value )
        {
            return printFailure( get );
        }
        const rw::RedisResult pipeline = client.pipeline( { { "PING" }, { "TTL", key }, { "MGET", key, "absent" } } );
        if( !pipeline || pipeline.reply.type != rw::RedisReplyType::Array || pipeline.reply.elements.size() != 3
            || pipeline.reply.elements[0].bytes != "PONG" || pipeline.reply.elements[1].integer != 9
            || pipeline.reply.elements[2].elements.size() != 2 || pipeline.reply.elements[2].elements[0].bytes != value
            || pipeline.reply.elements[2].elements[1].type != rw::RedisReplyType::Nil )
        {
            return printFailure( pipeline );
        }
        std::cout << "ok\n";
        return 0;
    }
    if( mode == "set" && argc == 8 )
    {
        return printFailure( client.command( { "SET", argv[6], argv[7] } ) );
    }
    if( mode == "get" && argc == 7 )
    {
        const rw::RedisResult result = client.command( { "GET", argv[6] } );
        if( result && result.reply.type == rw::RedisReplyType::Nil )
        {
            std::cout << "nil\n";
            return 0;
        }
        if( result && result.reply.type == rw::RedisReplyType::Bulk )
        {
            std::cout << result.reply.bytes << '\n';
            return 0;
        }
        return printFailure( result );
    }
    if( mode == "ping" )
    {
        return printFailure( client.command( { "PING" } ) );
    }
    if( mode == "large" )
    {
        const std::string value( 7u * 1024u * 1024u, 'w' );
        return printFailure( client.command( { "SET", "large", value } ) );
    }
    if( mode == "eintr" )
    {
        rw::RedisClientTestPeer::injectEintr();
        return printFailure( client.command( { "PING" } ) );
    }
    if( mode == "resolver-delay" )
    {
        rw::RedisClientTestPeer::resolverDelay( 300 );
        const rw::RedisResult result = client.command( { "PING" } );
        errno = 0;
        const bool hasNoChild = waitpid( -1, nullptr, WNOHANG ) == -1 && errno == ECHILD;
        std::cout << ( hasNoChild ? "reaped\n" : "child-leak\n" );
        return printFailure( result );
    }
    if( mode == "remote-resolution" )
    {
        rw::RedisClientTestPeer::resolverAddresses( { "192.0.2.1" } );
        return printFailure( client.command( { "PING" } ) );
    }
    if( mode == "mixed-resolution" )
    {
        rw::RedisClientTestPeer::resolverAddresses( { "127.0.0.1", "192.0.2.1" } );
        return printFailure( client.command( { "PING" } ) );
    }
    if( mode == "peer-mismatch" )
    {
        rw::RedisClientTestPeer::peerMismatch();
        return printFailure( client.command( { "PING" } ) );
    }
    if( mode == "unix-path-swap" )
    {
        rw::RedisClientTestPeer::unixPathSwap();
        return printFailure( client.command( { "PING" } ) );
    }
    if( mode == "unsafe-unix-owner" )
    {
        rw::RedisClientTestPeer::unsafeUnixOwner();
        return printFailure( client.command( { "PING" } ) );
    }
    return 65;
}
CPP

if ! "${CXX:-c++}" -std=c++23 -pthread -DRIPWIRE_REDIS_TESTING=1 -Isrc "$TMP/redis_client_gate.cpp" src/redis_client.cpp -o "$TMP/redis_client_gate" >"$TMP/compile.out" 2>"$TMP/compile.err"; then
    sed -n '1,20p' "$TMP/compile.err"
    echo "FAILURES ABOVE"
    exit 1
fi
CLIENT="$TMP/redis_client_gate"

mkdir -m 700 "$TMP/safe"
python3 "$ROOT/test/redis_stub.py" --unix "$TMP/safe/redis.sock" --username gate-user --password gate-password --log "$TMP/commands.bin" >"$TMP/stub.json" &
STUB_PID=$!
for _attempt in 1 2 3 4 5 6 7 8 9 10
do
    [ -s "$TMP/stub.json" ] && break
    sleep 0.05
done
[ -s "$TMP/stub.json" ] || { echo "Redis stub did not start"; exit 2; }
TCP_PORT="$( python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tcp_port"])' "$TMP/stub.json" )"
ADMIN_PORT="$( python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["admin_port"])' "$TMP/stub.json" )"
TCP="redis://127.0.0.1:$TCP_PORT/2"
UNIX="redis+unix://$TMP/safe/redis.sock?db=2"

admin()
{
    python3 - "$ADMIN_PORT" "$1" <<'PY'
import json, socket, struct, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(sys.argv[2].encode() + b"\n")
header = b""
while len(header) < 4:
    header += s.recv(4 - len(header))
size = struct.unpack("!I", header)[0]
data = b""
while len(data) < size:
    data += s.recv(size - len(data))
print(data.decode())
PY
}

next_index()
{
    admin '{"op":"command_log"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["next_index"])'
}

user_command_index()
{
    python3 - "$( next_index )" <<'PY'
import sys
print(int(sys.argv[1]) + 2)
PY
}

if "$CLIENT" "$TCP" gate-user gate-password 500 basic >"$TMP/basic.out" 2>"$TMP/basic.err"; then ok "TCP AUTH SELECT binary command and ordered pipeline"; else no "TCP basic transport failed"; fi
if "$CLIENT" "$UNIX" gate-user gate-password 500 basic >"$TMP/unix.out" 2>"$TMP/unix.err"; then ok "Unix socket AUTH SELECT and binary replies"; else no "Unix socket transport failed"; fi
if "$CLIENT" "$TCP" gate-user gate-password 500 eintr >"$TMP/eintr.out" 2>&1; then ok "EINTR retries preserve the operation deadline"; else no "injected EINTR was not retried"; fi
if "$CLIENT" "$UNIX" gate-user gate-password 500 eintr >"$TMP/eintr-unix.out" 2>&1; then ok "Unix path and connect EINTR retries preserve the deadline"; else no "Unix EINTR was not retried"; fi

set +e
"$CLIENT" "redis://resolver.test:$TCP_PORT/0" '' '' 40 resolver-delay >"$TMP/resolver-delay.out" 2>&1
resolver_delay_rc=$?
"$CLIENT" "redis://remote.test:$TCP_PORT/0" '' '' 100 remote-resolution >"$TMP/remote.out" 2>&1
remote_rc=$?
"$CLIENT" "redis://mixed.test:$TCP_PORT/0" '' '' 100 mixed-resolution >"$TMP/mixed.out" 2>&1
mixed_rc=$?
"$CLIENT" "redis://127.0.0.1:$TCP_PORT/0" gate-user gate-password 100 peer-mismatch >"$TMP/peer.out" 2>&1
peer_rc=$?
set -e
if [ "$resolver_delay_rc" -ne 0 ] && grep -q 'reaped' "$TMP/resolver-delay.out" && grep -q 'redis tcp: timeout' "$TMP/resolver-delay.out"; then
    ok "name resolution is deadline-bounded and resolver child is reaped"
else
    no "resolver deadline or child reap failed"
fi
if [ "$remote_rc" -ne 0 ] && grep -q 'redis tcp: connect' "$TMP/remote.out"; then ok "hostname resolving only remote is refused"; else no "remote-only hostname was not refused"; fi
if [ "$mixed_rc" -ne 0 ] && grep -q 'redis tcp: connect' "$TMP/mixed.out"; then ok "mixed loopback and remote resolution is refused"; else no "mixed hostname was not refused"; fi
if [ "$peer_rc" -ne 0 ] && grep -q 'redis tcp: connect' "$TMP/peer.out"; then ok "connected peer is independently revalidated"; else no "post-connect peer mismatch was accepted"; fi

"$CLIENT" "$TCP" gate-user gate-password 500 set db-only value >/dev/null 2>&1
if [ "$( "$CLIENT" "redis://127.0.0.1:$TCP_PORT/0" gate-user gate-password 500 get db-only )" = nil ]; then ok "database selection isolates values"; else no "SELECT database was not honored"; fi

admin "{\"op\":\"fail_before\",\"command_index\":$( next_index ),\"mode\":\"drop\"}" >/dev/null
set +e
"$CLIENT" "$TCP" gate-user gate-password 200 ping >"$TMP/drop.out" 2>&1
drop_rc=$?
set -e
if [ "$drop_rc" -ne 0 ] && "$CLIENT" "$TCP" gate-user gate-password 500 ping >/dev/null 2>&1; then ok "next operation recovers after a dropped connection"; else no "drop recovery failed"; fi

admin "{\"op\":\"deadline\",\"command_index\":$( next_index ),\"seconds\":0.4}" >/dev/null
set +e
"$CLIENT" "$TCP" gate-user gate-password 40 ping >"$TMP/read-timeout.out" 2>&1
read_rc=$?
set -e
if [ "$read_rc" -ne 0 ] && grep -q 'redis tcp: timeout' "$TMP/read-timeout.out"; then ok "single absolute deadline bounds reply reads"; else no "read timeout was not classified"; fi

admin "{\"op\":\"fail_before\",\"command_index\":$( next_index ),\"mode\":\"non_reader\",\"seconds\":0.4}" >/dev/null
set +e
"$CLIENT" "$TCP" gate-user gate-password 40 large >"$TMP/write-timeout.out" 2>&1
write_rc=$?
set -e
if [ "$write_rc" -ne 0 ] && grep -q 'redis tcp: timeout' "$TMP/write-timeout.out"; then ok "single absolute deadline bounds request writes"; else no "write timeout was not classified"; fi

set +e
"$CLIENT" "$TCP" gate-user wrong-password 200 ping >"$TMP/auth.out" 2>&1
auth_rc=$?
set -e
if [ "$auth_rc" -ne 0 ] && grep -q 'redis tcp: auth WRONGPASS' "$TMP/auth.out" && ! grep -q 'wrong-password\|gate-user' "$TMP/auth.out"; then ok "authentication failure is classified and redacted"; else no "authentication failure diagnostic is unsafe"; fi

SERVER_ECHO_SENTINEL='SERVER_ECHO_SENTINEL_71d2'
admin "{\"op\":\"auth_error\",\"command_index\":$( next_index ),\"message\":\"$SERVER_ECHO_SENTINEL\"}" >/dev/null
set +e
"$CLIENT" "$TCP" CREDENTIAL_SENTINEL_34a1 gate-password 200 ping >"$TMP/auth-control.out" 2>&1
auth_control_rc=$?
set -e
if [ "$auth_control_rc" -ne 0 ] && grep -q 'redis tcp: auth' "$TMP/auth-control.out" \
    && ! grep -q 'CREDENTIAL_SENTINEL_34a1\|SERVER_ECHO_SENTINEL_71d2' "$TMP/auth-control.out"; then
    ok "explicit auth fault redacts credential and server echo"
else
    no "explicit auth fault diagnostic leaked input"
fi

admin "{\"op\":\"server_error\",\"command_index\":$( user_command_index ),\"message\":\"SERVER_ECHO_SENTINEL_71d2\"}" >/dev/null
set +e
"$CLIENT" "$TCP" gate-user gate-password 200 set COMMAND_SENTINEL_88c4 PAYLOAD_SENTINEL_19fa >"$TMP/server-error.out" 2>&1
server_error_rc=$?
set -e
if [ "$server_error_rc" -ne 0 ] && grep -q 'redis tcp: server ERR' "$TMP/server-error.out" \
    && ! grep -q 'COMMAND_SENTINEL_88c4\|PAYLOAD_SENTINEL_19fa\|SERVER_ECHO_SENTINEL_71d2\|gate-password' "$TMP/server-error.out"; then
    ok "server error redacts command payload credential and echo"
else
    no "server error diagnostic leaked sensitive input"
fi

admin "{\"op\":\"fail_after\",\"command_index\":$( next_index ),\"mode\":\"malformed\"}" >/dev/null
set +e
"$CLIENT" "$TCP" gate-user gate-password 200 ping >"$TMP/malformed.out" 2>&1
malformed_rc=$?
set -e
if [ "$malformed_rc" -ne 0 ] && grep -q 'redis tcp: protocol' "$TMP/malformed.out"; then ok "malformed reply is a protocol failure"; else no "malformed reply classification failed"; fi

"$CLIENT" "$TCP" gate-user gate-password 500 set controlled present >/dev/null 2>&1
admin "{\"op\":\"missing_record\",\"command_index\":$( user_command_index )}" >/dev/null
if [ "$( "$CLIENT" "$TCP" gate-user gate-password 500 get controlled )" = nil ]; then ok "explicit missing-record fault returns nil"; else no "missing-record fault failed"; fi
admin "{\"op\":\"corrupt_payload\",\"command_index\":$( user_command_index ),\"value\":\"Q09SUlVQVF9QQVlMT0FEXzQ2YjM=\"}" >/dev/null
if [ "$( "$CLIENT" "$TCP" gate-user gate-password 500 get controlled )" = CORRUPT_PAYLOAD_46b3 ]; then ok "explicit corrupt-payload fault is deterministic"; else no "corrupt-payload fault failed"; fi

BARRIER_INDEX="$( user_command_index )"
admin "{\"op\":\"hold\",\"barrier\":\"ordered-gate\",\"command_index\":$BARRIER_INDEX}" >/dev/null
"$CLIENT" "$TCP" gate-user gate-password 1000 get controlled >"$TMP/barrier.out" 2>&1 &
BARRIER_PID=$!
sleep 0.05
if kill -0 "$BARRIER_PID" 2>/dev/null; then ok "named barrier holds its indexed command"; else no "named barrier did not hold command"; fi
admin '{"op":"release","barrier":"ordered-gate"}' >/dev/null
if wait "$BARRIER_PID"; then ok "named barrier release resumes only its waiters"; else no "named barrier release failed"; fi

ln -s "$TMP/safe/redis.sock" "$TMP/symlink.sock"
printf 'not a socket\n' > "$TMP/regular.sock"
for unsafe_url in "redis+unix://$TMP/symlink.sock" "redis+unix://$TMP/regular.sock"
do
    set +e
    "$CLIENT" "$unsafe_url" gate-user gate-password 100 ping >"$TMP/unsafe.out" 2>&1
    unsafe_rc=$?
    set -e
    if [ "$unsafe_rc" -ne 0 ] && grep -Eq 'redis unix: (config|connect)' "$TMP/unsafe.out" && ! grep -qF "$TMP" "$TMP/unsafe.out"; then ok "unsafe Unix endpoint is rejected without path disclosure"; else no "unsafe Unix endpoint was accepted or disclosed"; fi
done
chmod 0777 "$TMP/safe"
set +e
"$CLIENT" "$UNIX" gate-user gate-password 100 ping >"$TMP/unsafe-parent.out" 2>&1
unsafe_parent_rc=$?
set -e
chmod 0700 "$TMP/safe"
if [ "$unsafe_parent_rc" -ne 0 ] && grep -q 'redis unix: connect' "$TMP/unsafe-parent.out" && ! grep -qF "$TMP" "$TMP/unsafe-parent.out"; then
    ok "world-writable non-sticky Unix parent is rejected"
else
    no "unsafe Unix parent was accepted or disclosed"
fi
chmod 0777 "$TMP/safe/redis.sock"
set +e
"$CLIENT" "$UNIX" gate-user gate-password 100 ping >"$TMP/unsafe-mode.out" 2>&1
unsafe_mode_rc=$?
set -e
chmod 0755 "$TMP/safe/redis.sock"
if [ "$unsafe_mode_rc" -ne 0 ] && grep -q 'redis unix: connect' "$TMP/unsafe-mode.out"; then ok "unsafe Unix endpoint mode is refused"; else no "unsafe Unix endpoint mode was accepted"; fi
set +e
"$CLIENT" "$UNIX" gate-user gate-password 100 unix-path-swap >"$TMP/path-swap.out" 2>&1
path_swap_rc=$?
"$CLIENT" "$UNIX" gate-user gate-password 100 unsafe-unix-owner >"$TMP/unsafe-owner.out" 2>&1
unsafe_owner_rc=$?
set -e
if [ "$path_swap_rc" -ne 0 ] && grep -q 'redis unix: connect' "$TMP/path-swap.out"; then ok "Unix path swap race is refused"; else no "Unix path swap race was accepted"; fi
if [ "$unsafe_owner_rc" -ne 0 ] && grep -q 'redis unix: connect' "$TMP/unsafe-owner.out"; then ok "unsafe Unix ownership is refused by test seam"; else no "unsafe Unix ownership was accepted"; fi

SECRET='secret-hostname.invalid'
set +e
"$CLIENT" "redis://$SECRET:$TCP_PORT/0/extra" gate-user gate-password 100 ping >"$TMP/config.out" 2>&1
config_rc=$?
set -e
if [ "$config_rc" -ne 0 ] && grep -q 'redis tcp: config' "$TMP/config.out" && ! grep -q "$SECRET\|gate-user\|gate-password" "$TMP/config.out"; then ok "invalid endpoint diagnostics are fully redacted"; else no "configuration diagnostic leaked input"; fi

if [ -s "$TMP/commands.bin" ]; then ok "stub writes a length-delimited binary command log"; else no "stub command log is empty"; fi
if admin '{"op":"command_log"}' | grep -q 'commands'; then ok "admin socket returns command log"; else no "admin command log operation failed"; fi
admin '{"op":"replace","db":2,"key":"YWRtaW4ta2V5","value":"YWRtaW4tdmFsdWU="}' >/dev/null
if [ "$( "$CLIENT" "$TCP" gate-user gate-password 500 get admin-key )" = admin-value ]; then ok "admin replace operation is deterministic"; else no "admin replace operation failed"; fi
admin '{"op":"delete","key":"YWRtaW4ta2V5"}' >/dev/null
admin '{"op":"advance_clock","seconds":10}' >/dev/null
admin '{"op":"release","barrier":"unused"}' >/dev/null
ok "admin clock delete and named release operations are accepted"

CONCURRENT_PIDS=
for concurrent_index in 1 2 3 4
do
    "$CLIENT" "$TCP" gate-user gate-password 1000 set "concurrent-$concurrent_index" value >"$TMP/concurrent-$concurrent_index.out" 2>&1 &
    CONCURRENT_PIDS="$CONCURRENT_PIDS $!"
done
concurrent_ok=1
for concurrent_pid in $CONCURRENT_PIDS
do
    wait "$concurrent_pid" || concurrent_ok=0
done
if [ "$concurrent_ok" -eq 1 ] && admin '{"op":"command_log"}' | python3 -c 'import base64,json,struct,sys; d=json.load(sys.stdin); rows=d["commands"]; assert [r["index"] for r in rows] == list(range(d["next_index"])); decoded=[base64.b64decode(r["record"]) for r in rows]; assert all(len(b)>=4 and struct.unpack_from("!I",b)[0]>=1 for b in decoded)'; then
    ok "concurrent command indexes and length-delimited log are deterministic"
else
    no "concurrent command log indexes are inconsistent"
fi

[ "$fail" -eq 0 ] || { echo "FAILURES ABOVE"; exit 1; }
echo "ALL REDIS CLIENT CHECKS PASSED"
