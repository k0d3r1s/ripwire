#!/usr/bin/env bash
# RIPWIRE_TEST_DEPS: src/mcpindex.h,src/mcp.h,src/mcpserver.h,src/main.cpp
# Foreground MCP Redis reuse, per-root identity, failure framing and prefetch suppression.
set -euo pipefail
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${RIPWIRE_BIN:-$ROOT/build/ripwire}"
python3 - "$ROOT" "$BIN" <<'PY'
import base64, http.client, json, os, pathlib, re, select, socket, struct, subprocess, sys, tempfile, time

root, binary = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).resolve()
with tempfile.TemporaryDirectory(prefix="redismcp-") as temporary:
    scratch = pathlib.Path(temporary)
    stub = subprocess.Popen([sys.executable, str(root / "test/redis_stub.py")], stdout=subprocess.PIPE, text=True)
    processes = []
    try:
        ports = json.loads(stub.stdout.readline())
        env = {k: v for k, v in os.environ.items() if not k.startswith("RIPWIRE_REDIS_") and k != "RIPWIRE_CACHE_BACKEND"}
        env.update(RIPWIRE_CACHE_STATS="1", RIPWIRE_MCP_TIMINGS="1", RIPWIRE_QSNAP_PREFETCH_MIN_FILES="1",
                   RIPWIRE_REDIS_URL=f'redis://127.0.0.1:{ports["tcp_port"]}',
                   RIPWIRE_REDIS_NAMESPACE="mcp-private-namespace", RIPWIRE_REDIS_TIMEOUT_MS="100")
        def admin(op, **args):
            with socket.create_connection(("127.0.0.1", ports["admin_port"]), timeout=5) as sock:
                sock.sendall(json.dumps(dict(op=op, **args)).encode() + b"\n")
                stream = sock.makefile("rb")
                return json.loads(stream.read(struct.unpack("!I", stream.read(4))[0]))
        def commands(start):
            result = []
            for entry in admin("command_log")["commands"]:
                if entry["index"] < start: continue
                raw = base64.b64decode(entry["record"])
                offset = 4; args = []
                for _ in range(struct.unpack("!I", raw[:4])[0]):
                    size = struct.unpack("!I", raw[offset:offset + 4])[0]; offset += 4
                    args.append(raw[offset:offset + size]); offset += size
                result.append(args)
            return result
        def git(path, *args):
            subprocess.run(["git", "-C", str(path), *args], check=True, capture_output=True)
        def fixture(name, project="shared"):
            path = scratch / name; path.mkdir()
            git(path, "init", "-q")
            git(path, "config", "user.name", "Gate")
            git(path, "config", "user.email", "gate@example.invalid")
            git(path, "remote", "add", "origin", f"https://example.invalid/team/{project}.git")
            for i in range(3): (path / f"file{i}.cpp").write_text(f"int target{i}() {{ return {i}; }}\n")
            git(path, "add", "."); git(path, "commit", "-qm", "fixture")
            return path
        def start(name, checkout, *flags):
            private = scratch / name; private.mkdir()
            for d in ("tmp", "xdg", "home"): (private / d).mkdir()
            stderr = (private / "stderr").open("w+")
            process = subprocess.Popen([str(binary), "--mcp", "--cache=redis", *flags], cwd=checkout,
                                       env=dict(env, TMPDIR=str(private / "tmp"), XDG_CACHE_HOME=str(private / "xdg"), HOME=str(private / "home")),
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True)
            processes.append(process)
            return process, private, stderr
        def request(process, path, request_id, method="tools/call", expected_error=None, symbol="target1"):
            frame = dict(jsonrpc="2.0", id=request_id, method=method)
            if method == "tools/call":
                arguments = dict(symbol=symbol)
                if path is not None: arguments["path"] = str(path)
                frame["params"] = dict(name="find_symbol", arguments=arguments)
            process.stdin.write(json.dumps(frame) + "\n"); process.stdin.flush()
            assert select.select([process.stdout], [], [], 15)[0], "MCP response timed out"
            line = process.stdout.readline()
            response = json.loads(line)
            assert response.get("id") == request_id, response
            if expected_error:
                assert expected_error in response.get("error", {}).get("message", ""), response
                return response
            assert "error" not in response, response
            assert not response.get("result", {}).get("isError"), response
            return response
        def finish(process, private, stderr):
            process.stdin.close(); process.wait(timeout=15)
            assert process.returncode == 0, process.returncode
            stderr.seek(0); diagnostic = stderr.read()
            assert "ripwire-prefetch spawn" not in diagnostic, diagnostic
            assert not re.search(r"runtime error:|Sanitizer", diagnostic), diagnostic
            files = [str(p.relative_to(private)) for p in private.rglob("*") if p.is_file() and p.relative_to(private) != pathlib.Path("stderr")]
            assert not files, ("unexpected persistent local files", files)
            return diagnostic
        a, b, other = fixture("a"), fixture("b"), fixture("other", "other")
        p, private, err = start("cold", a)
        request(p, a, 1)
        cold = finish(p, private, err)
        assert re.findall(r"cache-stats reparsed=(\d+)", cold) == ["3"], cold
        first_commands = commands(0)
        assert any(c[0] == b"SET" for c in first_commands), "foreground MCP did not publish Redis records"
        offset = admin("command_log")["next_index"]
        p, private, err = start("warm", b)
        request(p, b, 1)
        warm_commands = commands(offset)
        assert any(c[0] == b"MGET" for c in warm_commands), warm_commands
        assert not any(c[0] == b"SET" for c in warm_commands), "warm process replaced cached records"
        # Rootless stdio switches projects: identical source bytes must not alias distinct origins.
        request(p, other, 2); request(p, b, 3)
        # A real HEAD move would trigger prefetch at the forced threshold in filesystem mode.
        git(b, "commit", "--allow-empty", "-qm", "move HEAD")
        request(p, b, 4)
        warm = finish(p, private, err)
        assert re.findall(r"cache-stats reparsed=(\d+)", warm) == ["0", "3", "0"], warm
        print("  PASS  independent checkouts reuse Redis with no SET, per-request projects isolate, no local prefetch/cache")
        offset = admin("command_log")["next_index"]
        p, private, err = start("workspace", a, str(a), str(other))
        request(p, None, 1)
        diagnostic = finish(p, private, err)
        assert re.findall(r"cache-stats reparsed=(\d+)", diagnostic) == ["0", "0"], diagnostic
        assert not any(c[0] == b"SET" for c in commands(offset))
        print("  PASS  multi-root workspace derives and reuses an independent context for each root")
        nongit = scratch / "non-git"; nongit.mkdir()
        (nongit / "a.cpp").write_text("int target1() { return 1; }\n")
        p, private, err = start("root-refusal", a)
        request(p, nongit, 1, expected_error="RIPWIRE_REDIS_PROJECT")
        request(p, a, 2)
        diagnostic = finish(p, private, err)
        assert re.findall(r"cache-stats reparsed=(\d+)", diagnostic) == ["0"], diagnostic
        print("  PASS  rootless request rejects missing project identity before ingest and accepts the next root")
        # Each injected command is reached in this ONE long-lived MCP process. Rebuild on each edit,
        # then prove normal JSON-RPC ping and the next rebuild still work after every failure class.
        p, private, err = start("faults", b)
        request(p, b, 1)
        for request_id, mode in enumerate(("drop", "delay", "malformed", "auth_error", "server_error"), 2):
            (b / "file0.cpp").write_text(f"int target_changed_{request_id}() {{ return {request_id}; }}\n")
            offset = admin("command_log")["next_index"]
            if mode in ("auth_error", "server_error"):
                admin(mode, command_index=offset, message="private-server-payload redis://secret@host mcp-private-namespace")
            else:
                admin("fail_before", command_index=offset, mode=mode, seconds=0.3)
            reply = request(p, b, request_id, symbol=f"target_changed_{request_id}")
            payload = json.loads(reply["result"]["content"][0]["text"])
            assert payload["symbol"]["name"] == f"target_changed_{request_id}", payload
            reached = commands(offset)
            assert reached and reached[0][0] == b"MGET", (mode, reached)
            request(p, b, 100 + request_id, "ping")
        diagnostic = finish(p, private, err)
        assert re.findall(r"cache-stats reparsed=(\d+)", diagnostic) == ["0"] + ["3"] * 5, diagnostic
        assert diagnostic.count("Redis cache unavailable or invalid") == 1, diagnostic
        for secret in ("private-server-payload", "secret@host", "mcp-private-namespace", env["RIPWIRE_REDIS_URL"]):
            assert secret not in diagnostic, diagnostic
        print("  PASS  drop, timeout, malformed, auth and server failures recover with exactly one redacted warning")
        # HTTP pinned startup must use the same policy before its eager foreground build.
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0)); http_port = listener.getsockname()[1]
        p, private, err = start("http", a, str(a), f"--listen=127.0.0.1:{http_port}")
        for attempt in range(200):
            try:
                connection = http.client.HTTPConnection("127.0.0.1", http_port, timeout=10)
                connection.request("POST", "/mcp", json.dumps(dict(jsonrpc="2.0", id=1, method="ping")),
                                   {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
                response = connection.getresponse(); payload = response.read(); connection.close()
                assert response.status == 200 and json.loads(payload)["id"] == 1, payload
                break
            except ConnectionRefusedError:
                assert p.poll() is None, "HTTP server exited"
                time.sleep(0.01)
        else: raise AssertionError("HTTP server did not start")
        p.terminate(); p.wait(timeout=15)
        err.seek(0); diagnostic = err.read()
        assert re.findall(r"cache-stats reparsed=(\d+)", diagnostic) == ["0"], diagnostic
        assert not any(p.is_file() for d in ("tmp", "xdg", "home") for p in (private / d).rglob("*"))
        for checkout in (a, b, other, nongit):
            files = {str(p.relative_to(checkout)) for p in checkout.rglob("*") if p.is_file() and ".git" not in p.relative_to(checkout).parts}
            expected = {"a.cpp"} if checkout == nongit else {f"file{i}.cpp" for i in range(3)}
            assert files == expected, (checkout, files)
        print("  PASS  HTTP eager foreground build reuses the same Redis policy")
    finally:
        for process in processes:
            if process.poll() is None: process.kill(); process.wait(timeout=15)
        stub.terminate(); stub.wait(timeout=15)
print("redismcpcheck: ALL PASS")
PY
