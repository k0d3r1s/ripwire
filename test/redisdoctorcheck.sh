#!/usr/bin/env bash
# RIPWIRE_TEST_DEPS: src/verbs_doctor.h,src/redis_client.cpp,src/cache_backend.cpp,src/cli.h,test/redis_stub.py
# Doctor must prove each cache capability with its own expiring canary and expose only categories.
set -euo pipefail
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${RIPWIRE_BIN:-$ROOT/build/ripwire}"
python3 - "$ROOT" "$BIN" <<'PY'
import importlib.util, os, pathlib, re, socket, subprocess, sys, tempfile, threading, time
import xml.etree.ElementTree as ET

root, binary = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).resolve()
spec = importlib.util.spec_from_file_location("redis_stub", root / "test/redis_stub.py")
stub = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(stub)
original = stub.execute_redis_command
mode = "healthy"
fault_command = b"PING"
sentinels = ["doctor_secret_password", "doctor_secret_username", "doctor_secret_namespace",
             "doctor_secret_project", "doctor_secret_checkout", "doctor_secret_socket", "doctor_secret_endpoint"]

def execute(state, command, selected, authenticated):
    name = command[0]
    if name == fault_command:
        if mode == "acl": return b"-NOPERM doctor_secret_endpoint doctor_secret_password\r\n", selected, authenticated
        if mode == "malformed": return b"!doctor_secret_endpoint\r\n", selected, authenticated
        if mode == "redirect": return b"-MOVED 12 doctor_secret_endpoint:6379\r\n", selected, authenticated
        if mode == "timeout": time.sleep(0.3)
        if mode == "wrong-value": return stub.bulk(b"doctor_secret_password"), selected, authenticated
        if mode == "wrong-array": return stub.array([b":1\r\n"]), selected, authenticated
        if mode == "zero": return b":0\r\n", selected, authenticated
        if mode == "collision": return stub.bulk(None), selected, authenticated
    return original(state, command, selected, authenticated)

stub.execute_redis_command = execute
with tempfile.TemporaryDirectory(prefix="redisdoctor-") as temporary:
    scratch = pathlib.Path(temporary)
    # Exercise the production category/finalisation helpers without sockets: a recovered live probe
    # must retain earlier process failures. This is source extraction, not a second implementation.
    doctor_source = (root / "src/verbs_doctor.h").read_text()
    helpers = doctor_source[doctor_source.index("inline const char* doctorRedisFailureName"):
                            doctor_source.index("inline DoctorIndexCache doctorCacheBackendRow")]
    health_source = '#include "redis_client.h"\n#include <cassert>\n#include <algorithm>\n#include <charconv>\n#include <cctype>\n#include <arpa/inet.h>\n'
    health_source += 'int doctorEntropyFailure( void*, std::size_t ) { return -1; }\n#define getentropy doctorEntropyFailure\n'
    health_source += 'struct DoctorIndexCache { std::string attrs; bool ok = true; };\n' + helpers
    health_source += r'''
unsigned commandsSent = 0;
rw::RedisClient::RedisClient( rw::RedisCacheConfig config ) : config_( std::move( config ) ) {}
rw::RedisResult rw::RedisClient::command( const std::vector<std::string_view>& args ) const
{
    ++commandsSent;
    assert( args.size() == 1 && args[0] == "PING" );
    RedisResult result;
    result.reply.type = RedisReplyType::Simple;
    result.reply.bytes = "PONG";
    return result;
}
int main()
{
    const unsigned earlier = ( 1u << static_cast<unsigned>( rw::RedisFailure::Auth ) )
                           | ( 1u << static_cast<unsigned>( rw::RedisFailure::Timeout ) );
    const auto recovered = doctorRedisFinalizeHealth( {}, nullptr, earlier );
    assert( !recovered.ok && recovered.attrs.find( "hint=\"previous_backend_failure\"" ) != std::string::npos );
    assert( recovered.attrs.find( "failures=\"timeout,auth\"" ) != std::string::npos );
    const auto partial = doctorRedisFinalizeHealth( {}, "protocol", earlier | ( 1u << static_cast<unsigned>( rw::RedisFailure::Protocol ) ) );
    assert( !partial.ok && partial.attrs.find( "hint=\"protocol\"" ) != std::string::npos );
    assert( partial.attrs.find( "failures=\"timeout,protocol,auth\"" ) != std::string::npos );
    const auto healthy = doctorRedisFinalizeHealth( {}, nullptr, 0 );
    assert( healthy.ok && healthy.attrs.find( " hint=" ) == std::string::npos && healthy.attrs.find( " failures=" ) == std::string::npos );
    assert( std::string_view( doctorRedisTransport( "redis://192.0.2.1:6379/2" ) ) == "remote_tcp" );
    assert( std::string_view( doctorRedisTransport( "redis://127.1.2.3:6379/2" ) ) == "loopback_tcp" );
    assert( std::string_view( doctorRedisTransport( "redis://[0:0:0:0:0:0:0:1]:6379/2" ) ) == "loopback_tcp" );
    assert( std::string_view( doctorRedisTransport( "redis://[2001:db8::1]:6379/2" ) ) == "remote_tcp" );
    assert( doctorRedisDatabase( "redis://localhost/02" ) == 2 );
    rw::CacheContext cache;
    cache.policy = std::make_shared<rw::CachePolicy>();
    unsigned failures = 0;
    assert( std::string_view( doctorRedisProbe( cache, "ripwire:test:", failures ) ) == "random_unavailable" );
    assert( commandsSent == 1 );
}
'''
    health_binary = scratch / "health-test"
    subprocess.run([os.environ.get("CXX", "c++"), "-std=c++23", "-I" + str(root / "src"), "-x", "c++", "-", str(root / "src/cache_backend.cpp"),
                    "-o", str(health_binary)], input=health_source, text=True, check=True)
    subprocess.run([str(health_binary)], check=True)
    print("  PASS  earlier failure classes, transport metadata, and entropy failure without any mutation")
    checkout = scratch / "doctor_secret_checkout"; checkout.mkdir()
    (scratch / "cache").mkdir()
    bindir = scratch / "bin"; bindir.mkdir(); (bindir / "ripwire").symlink_to(binary)
    state = stub.State("doctor_secret_username", "doctor_secret_password", None)
    tcp = stub.ThreadingTCPServer(("127.0.0.1", 0), stub.RedisHandler); tcp.state = state
    class IPv6Server(stub.ThreadingTCPServer):
        address_family = socket.AF_INET6
    tcp6 = IPv6Server(("::1", 0), stub.RedisHandler); tcp6.state = state
    # Unix path stays below the platform sockaddr_un limit, including Darwin's private temp prefix.
    unix_path = str(scratch / "doctor_secret_socket")
    unix = stub.ThreadingUnixServer(unix_path, stub.RedisHandler); unix.state = state
    servers = [tcp, tcp6, unix]
    for server in servers: threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {k: v for k, v in os.environ.items() if not k.startswith("RIPWIRE_REDIS_") and k != "RIPWIRE_CACHE_BACKEND"}
    env.update(RIPWIRE_REDIS_URL=f"redis://127.0.0.1:{tcp.server_address[1]}/2",
               RIPWIRE_REDIS_NAMESPACE=sentinels[2], RIPWIRE_REDIS_PROJECT=sentinels[3],
               RIPWIRE_REDIS_USERNAME=sentinels[1], RIPWIRE_REDIS_PASSWORD=sentinels[0],
               RIPWIRE_REDIS_TIMEOUT_MS="1000", XDG_CACHE_HOME=str(scratch / "cache"),
               TMPDIR=str(scratch / "cache"), PATH=str(bindir) + os.pathsep + os.environ["PATH"])

    def run(expected=True, overrides=None, flags=("--cache=redis",), hint=None):
        start = len(state.commands)
        current = dict(env, **(overrides or {}))
        result = subprocess.run([str(binary), str(checkout), "--doctor", *flags], env=current,
                                capture_output=True, text=True, timeout=10)
        combined = result.stdout + result.stderr
        for secret in sentinels + [env["RIPWIRE_REDIS_URL"], unix_path]:
            assert secret not in combined, ("leaked sentinel", secret)
        document = ET.fromstring(result.stdout)
        rows = document.findall("c")
        assert int(document.attrib["checks"]) == len(rows)
        assert int(document.attrib["passed"]) == sum(r.attrib["ok"] == "1" for r in rows)
        row = document.find("c[@n='cache_backend']")
        assert row is not None, "missing cache_backend row"
        assert row.attrib["ok"] == str(int(expected)), row.attrib
        assert result.returncode == (0 if expected else 1), (result.returncode, result.stdout, result.stderr)
        assert row.attrib["kind"] == "redis"
        assert row.attrib["db"] == "2"
        assert re.fullmatch("[0-9a-f]{16}", row.attrib["scope"]), row.attrib
        assert set(row.attrib) <= {"n", "ok", "kind", "transport", "db", "scope", "hint", "failures", "volatile"}
        if hint is not None: assert row.attrib["hint"] == hint, row.attrib
        if "hint" in row.attrib: assert re.fullmatch("[a-z_]+", row.attrib["hint"]), row.attrib
        assert document.find("c[@n='index-cache']").attrib["source"] == "redis"
        commands = []
        import struct
        for _, raw in state.commands[start:]:
            offset = 4; args = []
            for _ in range(struct.unpack("!I", raw[:4])[0]):
                size = struct.unpack("!I", raw[offset:offset + 4])[0]; offset += 4
                args.append(raw[offset:offset + size]); offset += size
            commands.append(args)
        assert all(c[0] in (b"AUTH", b"SELECT", b"PING", b"SET", b"GET", b"MGET", b"EXPIRE", b"DEL") for c in commands)
        return row.attrib, [c for c in commands if c[0] not in (b"AUTH", b"SELECT")]

    try:
        healthy, commands = run()
        assert healthy["transport"] == "loopback_tcp"
        assert [c[0] for c in commands] == [b"PING", b"SET", b"GET", b"MGET", b"EXPIRE", b"DEL"], commands
        key = commands[1][1]
        import hashlib
        prefix = b"ripwire:" + hashlib.sha256(sentinels[2].encode()).hexdigest().encode() + b":"
        prefix += hashlib.sha256(sentinels[3].encode()).hexdigest().encode() + b":"
        assert key.startswith(prefix) and re.fullmatch(rb"doctor:[0-9a-f]{32}", key[len(prefix):]), key
        assert commands[1][3:] == [b"NX", b"EX", b"5"], commands
        assert all(c[1] == key for c in commands[2:]), commands
        assert commands[4] == [b"EXPIRE", key, b"5"] and commands[5] == [b"DEL", key]
        assert stub.state_live(state, 2, key) is None
        for host in ("::1", "0:0:0:0:0:0:0:1", "0000:0000:0000:0000:0000:0000:0000:0001"):
            ipv6, _ = run(overrides={"RIPWIRE_REDIS_URL": f"redis://[{host}]:{tcp6.server_address[1]}/2"})
            assert ipv6["transport"] == "loopback_tcp" and ipv6["scope"] == healthy["scope"]
        print("  PASS  compressed and expanded IPv6 loopback probe without remote opt-in")
        same, again = run()
        assert same["scope"] == healthy["scope"] and again[1][1] != key
        changed, _ = run(overrides={"RIPWIRE_REDIS_NAMESPACE": "different_namespace"})
        assert changed["scope"] != healthy["scope"]
        changed, _ = run(overrides={"RIPWIRE_REDIS_PROJECT": "different_project"})
        assert changed["scope"] != healthy["scope"]
        unix_row, _ = run(overrides={"RIPWIRE_REDIS_URL": "redis+unix://" + unix_path + "?db=2"})
        assert unix_row["transport"] == "unix" and unix_row["scope"] == healthy["scope"]
        ambient, _ = run(overrides={"RIPWIRE_CACHE_BACKEND": "redis"}, flags=())
        assert ambient["scope"] == healthy["scope"]
        print("  PASS  command family, own random key, short TTL, cleanup, stable opaque scope and both transports")

        for command in (b"GET", b"MGET", b"SET", b"EXPIRE", b"DEL"):
            mode, fault_command = "acl", command
            row, commands = run(False, hint="server")
            assert command in [c[0] for c in commands], ("fault did not fire", command)
            sets = [c for c in commands if c[0] == b"SET"]
            assert sets
            canary = sets[0][1]
            if command != b"SET":
                assert b"DEL" in [c[0] for c in commands], "cleanup was not attempted"
            if command == b"DEL":
                assert stub.state_live(state, 2, canary)[1] <= state.clock + 5
                state.clock += 6
                assert stub.state_live(state, 2, canary) is None
            print("  PASS  denied", command.decode(), "is unhealthy; cleanup or 5-second TTL bounds residue")

        for mode, fault_command, hint in [("timeout", b"PING", "timeout"), ("malformed", b"PING", "protocol"),
                                         ("redirect", b"PING", "cluster_redirect"), ("wrong-value", b"GET", "protocol"),
                                         ("wrong-array", b"MGET", "protocol"), ("zero", b"EXPIRE", "protocol"),
                                         ("zero", b"DEL", "protocol")]:
            run(False, hint=hint, overrides={"RIPWIRE_REDIS_TIMEOUT_MS": "50"} if mode == "timeout" else None)
            # Drain the deliberately delayed handler before changing its fault mode for the next arm.
            with state.lock: pass
            print("  PASS ", mode, fault_command.decode(), "fails categorically without server text")
        mode, fault_command = "collision", b"SET"
        _, commands = run(False, hint="canary_collision")
        assert [c[0] for c in commands] == [b"PING", b"SET"], "NX collision must never delete an unowned key"
        mode = "healthy"
        run(False, overrides={"RIPWIRE_REDIS_PASSWORD": "incorrect_password"}, hint="auth")
        start = len(state.commands)
        result = subprocess.run([str(binary), str(checkout), "--doctor", "--cache=redis"],
                                env=dict(env, RIPWIRE_REDIS_URL="redis://doctor_secret_endpoint.invalid:6379/2"),
                                capture_output=True, text=True, timeout=10)
        assert result.returncode != 0 and "plaintext TCP outside loopback" in result.stderr
        assert len(state.commands) == start
        assert all(secret not in result.stdout + result.stderr for secret in sentinels)
        print("  PASS  NX collision, bad authentication and remote plaintext refusal")
        help_text = subprocess.run([str(binary), "--help=--cache"], env=env, capture_output=True, text=True, check=True).stdout
        assert "disposable shared cache" in help_text and "not a source of truth" in help_text
        assert "unreachable" in help_text and "without local persistence" in help_text
        print("redisdoctorcheck: ALL PASS")
    finally:
        for server in servers: server.shutdown(); server.server_close()
PY
