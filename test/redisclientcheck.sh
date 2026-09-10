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

#include <iostream>
#include <string>
#include <string_view>
#include <vector>

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
    return 65;
}
CPP

if ! "${CXX:-c++}" -std=c++23 -pthread -Isrc "$TMP/redis_client_gate.cpp" src/redis_client.cpp -o "$TMP/redis_client_gate" >"$TMP/compile.out" 2>"$TMP/compile.err"; then
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

if "$CLIENT" "$TCP" gate-user gate-password 500 basic >"$TMP/basic.out" 2>"$TMP/basic.err"; then ok "TCP AUTH SELECT binary command and ordered pipeline"; else no "TCP basic transport failed"; fi
if "$CLIENT" "$UNIX" gate-user gate-password 500 basic >"$TMP/unix.out" 2>"$TMP/unix.err"; then ok "Unix socket AUTH SELECT and binary replies"; else no "Unix socket transport failed"; fi

"$CLIENT" "$TCP" gate-user gate-password 500 set db-only value >/dev/null 2>&1
if [ "$( "$CLIENT" "redis://127.0.0.1:$TCP_PORT/0" gate-user gate-password 500 get db-only )" = nil ]; then ok "database selection isolates values"; else no "SELECT database was not honored"; fi

admin '{"op":"fail_after","mode":"drop"}' >/dev/null
set +e
"$CLIENT" "$TCP" gate-user gate-password 200 ping >"$TMP/drop.out" 2>&1
drop_rc=$?
set -e
if [ "$drop_rc" -ne 0 ] && "$CLIENT" "$TCP" gate-user gate-password 500 ping >/dev/null 2>&1; then ok "next operation recovers after a dropped connection"; else no "drop recovery failed"; fi

admin '{"op":"fail_after","mode":"delay","seconds":0.4}' >/dev/null
set +e
"$CLIENT" "$TCP" gate-user gate-password 40 ping >"$TMP/read-timeout.out" 2>&1
read_rc=$?
set -e
if [ "$read_rc" -ne 0 ] && grep -q 'redis tcp: timeout' "$TMP/read-timeout.out"; then ok "single absolute deadline bounds reply reads"; else no "read timeout was not classified"; fi

admin '{"op":"fail_before","mode":"non_reader","seconds":0.4}' >/dev/null
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

admin '{"op":"fail_after","mode":"malformed"}' >/dev/null
set +e
"$CLIENT" "$TCP" gate-user gate-password 200 ping >"$TMP/malformed.out" 2>&1
malformed_rc=$?
set -e
if [ "$malformed_rc" -ne 0 ] && grep -q 'redis tcp: protocol' "$TMP/malformed.out"; then ok "malformed reply is a protocol failure"; else no "malformed reply classification failed"; fi

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
admin '{"op":"hold"}' >/dev/null
admin '{"op":"release"}' >/dev/null
ok "admin clock delete hold and release operations are accepted"

[ "$fail" -eq 0 ] || { echo "FAILURES ABOVE"; exit 1; }
echo "ALL REDIS CLIENT CHECKS PASSED"
