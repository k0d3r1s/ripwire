#!/usr/bin/env bash
# RIPWIRE_TEST_DEPS: src/cache_backend.h,src/cache_backend.cpp,src/redis_client.cpp,src/quality.h,src/gitoracle.h,src/ingest_astquery.h,src/ingest_docpass.h,src/mergescout.h,src/mcpindex.h,src/mcpverbs.h,test/redis_blob_unit.cpp,test/redis_stub.py
# Immutable derived caches share across independent checkout paths without filesystem fallback.
set -euo pipefail
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${RIPWIRE_BIN:-$ROOT/build/ripwire}"
DRIVER_DIR="$( mktemp -d )"
trap 'rm -rf "$DRIVER_DIR"' EXIT
"${CXX:-c++}" -std=c++23 -O1 -pthread -I"$ROOT/src" -I"$ROOT/src/infra" -I"$ROOT/third_party" \
    "$ROOT/test/redis_blob_unit.cpp" "$ROOT/src/cache_backend.cpp" "$ROOT/src/redis_client.cpp" "$ROOT/src/infra/diagnostics.cpp" -o "$DRIVER_DIR/blob-driver"
python3 - "$ROOT" "$BIN" "$DRIVER_DIR/blob-driver" <<'PY'
import base64, json, os, pathlib, re, select, socket, struct, subprocess, sys, tempfile, time

root, binary = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).resolve()
with tempfile.TemporaryDirectory(prefix="redisquality-") as tmp:
    scratch = pathlib.Path(tmp)
    server = subprocess.Popen([sys.executable, str(root / "test/redis_stub.py")], stdout=subprocess.PIPE, text=True)
    try:
        ports = json.loads(server.stdout.readline())
        env = {k: v for k, v in os.environ.items() if not k.startswith("RIPWIRE_REDIS_") and k != "RIPWIRE_CACHE_BACKEND"}
        for name in ("tmp", "xdg", "home", "bin"):
            (scratch / name).mkdir()
        env.update(TMPDIR=str(scratch / "tmp"), XDG_CACHE_HOME=str(scratch / "xdg"), HOME=str(scratch / "home"),
                   RIPWIRE_REDIS_NAMESPACE="derived-gate", RIPWIRE_REDIS_PROJECT="derived-project",
                   RIPWIRE_REDIS_URL=f'redis://127.0.0.1:{ports["tcp_port"]}', RIPWIRE_REDIS_TTL_DAYS="1",
                   RIPWIRE_CACHE_STATS="1", PATH=str(scratch / "bin") + os.pathsep + env["PATH"])
        bridge = scratch / "bin/markitdown"
        bridge.write_text('#!/bin/sh\necho bridge >> "$HOME/bridge.log"\necho "# Extracted Deck"\necho "Cache document"\n')
        bridge.chmod(0o755)
        def command(*args):
            with socket.create_connection(("127.0.0.1", ports["tcp_port"])) as sock:
                sock.sendall(b"*%d\r\n" % len(args) + b"".join(b"$%d\r\n" % len(a) + a + b"\r\n" for a in args))
                stream = sock.makefile("rb")
                def read():
                    line = stream.readline(); kind, value = line[:1], line[1:-2]
                    if kind == b"*": return [read() for _ in range(int(value))]
                    if kind == b"$":
                        if value == b"-1": return None
                        data = stream.read(int(value)); assert stream.read(2) == b"\r\n"; return data
                    if kind == b":": return int(value)
                    assert kind == b"+", line
                    return value
                return read()
        def log():
            with socket.create_connection(("127.0.0.1", ports["admin_port"])) as sock:
                sock.sendall(b'{"op":"command_log"}\n'); stream = sock.makefile("rb")
                entries = json.loads(stream.read(struct.unpack("!I", stream.read(4))[0]))["commands"]
            result = []
            for entry in entries:
                raw = base64.b64decode(entry["record"]); count = struct.unpack("!I", raw[:4])[0]; pos = 4; args = []
                for _ in range(count):
                    size = struct.unpack("!I", raw[pos:pos + 4])[0]; pos += 4
                    args.append(raw[pos:pos + size]); pos += size
                result.append(args)
            return result
        def git(path, *args, old=False):
            date = "2026-01-01T12:00:00+0000" if old else "2026-09-01T12:00:00+0000"
            return subprocess.run(["git", "-C", str(path), *args], env=dict(env, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date),
                                  check=True, capture_output=True).stdout
        a = scratch / "a"; a.mkdir()
        git(a, "init", "-q"); git(a, "config", "user.email", "gate@example.com"); git(a, "config", "user.name", "Gate")
        (a / "a.cpp").write_text("int old_name() { return 1; }\n" + "// padding\n" * 4000)
        (a / "deck.docx").write_text("immutable document fixture")
        git(a, "add", "."); git(a, "commit", "-qm", "initial", old=True)
        (a / "a.cpp").write_text("int new_name() { return 2; }\n" + "// padding\n" * 4000)
        git(a, "commit", "-qam", "rename")
        (a / "a.cpp").write_text("int new_name() { return 3; }\n" + "// padding\n" * 4000)
        git(a, "commit", "-qam", "rewrite"); git(a, "remote", "add", "origin", "https://example.com/derived.git")
        b = scratch / "different-checkout"
        subprocess.run(["git", "clone", "-q", str(a), str(b)], env=env, check=True)
        def run(path, *flags):
            result = subprocess.run([str(binary), ".", "--cache=redis", "--no-stable", *flags], cwd=path, env=env, capture_output=True)
            assert result.returncode in (0, 2), result.stderr.decode()
            return result
        def family(name): return [k for k in command(b"SCAN", b"0")[1] if b":" + name.encode() + b":" in k]
        def exercise(name, *flags):
            for key in family(name): command(b"DEL", key)
            start = len(log()); cold = run(a, *flags); coldlog = log()[start:]
            keys = family(name)
            assert keys, name + " was not stored in Redis"
            assert any(c[0] == b"SET" and c[1] in keys for c in coldlog), (name, "cold SET missing")
            start = len(log()); warm = run(b, *flags); warmlog = log()[start:]
            assert cold.stdout == warm.stdout == run(b, *flags, "--no-cache").stdout, (name, "output differs")
            assert any(c[0] == b"GET" and c[1] in keys for c in warmlog), (name, "warm GET missing")
            assert any(c[0] == b"EXPIRE" and c[1] in keys for c in warmlog), (name, "warm TTL refresh missing")
            assert not any(c[0] == b"SET" and c[1] in keys for c in warmlog), (name, "warm replacement SET")
            key = keys[0]; command(b"SET", key, b"corrupt", b"EX", b"86400")
            start = len(log()); healed = run(b, *flags); heal_log = log()[start:]
            assert healed.stdout == warm.stdout and any(c[0] == b"SET" and c[1] == key for c in heal_log), (name, "corruption not healed")
            if name == "qsnap":
                reparses = re.findall(rb"cache-stats reparsed=(\d+)", healed.stderr)
                assert len(reparses) >= 2 and reparses[-1] == b"0", ("archived HEAD records were not reused", healed.stderr)
                assert not any(c[0] == b"SET" and b":record:" in c[1] for c in heal_log)
            print("  PASS ", name, "cross-checkout GET, TTL, no replacement SET, uncached equality, corruption repair")
        exercise("qsnap", "--quality-delta")
        exercise("qbody", "--quality-delta")
        exercise("qhist", "--whereis=old_name", "--with-history")
        exercise("qchurn", "--for=new_name")
        # The first ingest also populates document extraction; remove only that test-owned family to exercise its cold arm.
        for key in family("docmd"): command(b"DEL", key)
        exercise("docmd")
        exercise("stier", "--grep=new_name")
        # A workspace must query each file's own project, even when both projects have identical bytes.
        other = scratch / "separate-project"
        subprocess.run(["git", "clone", "-q", str(a), str(other)], env=env, check=True)
        git(other, "remote", "set-url", "origin", "https://example.com/other-derived.git")
        workspace_env = dict(env, RIPWIRE_REDIS_NAMESPACE="derived-workspace")
        workspace_env.pop("RIPWIRE_REDIS_PROJECT")
        def workspace_grep(*paths, disabled=False):
            args = [str(binary), *map(str, paths), "--cache=redis", "--grep=new_name", "--no-stable"]
            if disabled: args.append("--no-cache")
            result = subprocess.run(args, cwd=scratch, env=workspace_env, capture_output=True)
            assert result.returncode == 0, result.stderr
            return result.stdout
        start = len(log()); workspace_grep(a); workspace_grep(other)
        project_keys = {c[1] for c in log()[start:] if c[0] == b"SET" and b":stier:" in c[1]}
        assert len(project_keys) == 2, ("fixture must create one span-tier key per project", project_keys)
        start = len(log()); workspace = workspace_grep(a, other); workspace_log = log()[start:]
        queried_keys = {c[1] for c in workspace_log if c[0] == b"GET" and b":stier:" in c[1]}
        assert queried_keys == project_keys, ("workspace span-tier queries must preserve both project identities", queried_keys, project_keys)
        assert not any(c[0] == b"SET" and b":stier:" in c[1] for c in workspace_log)
        assert workspace == workspace_grep(a, other, disabled=True)
        print("  PASS  workspace grep preserves per-file project isolation and reuses both projects without SET")
        cold = run(a, "--merge-scout=HEAD~1")
        start = len(log()); warm = run(b, "--merge-scout=HEAD~1"); archived_log = log()[start:]
        assert cold.stdout == warm.stdout == run(b, "--merge-scout=HEAD~1", "--no-cache").stdout
        reparses = re.findall(rb"cache-stats reparsed=(\d+)", warm.stderr)
        assert len(reparses) >= 2 and all(n == b"0" for n in reparses), warm.stderr
        assert any(c[0] == b"MGET" for c in archived_log)
        assert not any(c[0] == b"SET" for c in archived_log), "warm merge-scout replaced archived records"
        assert not family("qheadsnap") and not family("qms"), "tree ingests became generic blobs"
        print("  PASS  archived HEAD and merge-scout reuse record store across checkout paths")

        # Two independent MCP processes observe the same HEAD move. The first warms without a
        # quality request, the second proves prefetch itself consumes that snapshot without SET.
        processes = []
        errors = []
        try:
            for checkout in (a, b):
                err = tempfile.TemporaryFile(mode="w+"); errors.append(err)
                process = subprocess.Popen([str(binary), "--mcp", "--cache=redis"], cwd=checkout,
                                           env=dict(env, RIPWIRE_QSNAP_PREFETCH_MIN_FILES="1", RIPWIRE_MCP_TIMINGS="1"),
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True)
                processes.append(process)
            def request(process, checkout, ident, verb="find_symbol"):
                args = dict(path=str(checkout))
                if verb == "find_symbol": args["symbol"] = "new_name"
                frame = dict(jsonrpc="2.0", id=ident, method="tools/call", params=dict(name=verb, arguments=args))
                process.stdin.write(json.dumps(frame) + "\n"); process.stdin.flush()
                assert select.select([process.stdout], [], [], 15)[0], "MCP response timeout"
                reply = json.loads(process.stdout.readline())
                assert reply.get("id") == ident and not reply.get("error") and not reply.get("result", {}).get("isError"), reply
                return reply["result"]["content"][0]["text"]
            for process, checkout in zip(processes, (a, b)): request(process, checkout, 1)
            # Identical commit object in each clone; no source changes, so the index remains warm.
            for checkout in (a, b):
                git(checkout, "-c", "user.name=Gate", "-c", "user.email=gate@example.com", "commit", "--allow-empty", "-qm", "prefetch")
            assert git(a, "rev-parse", "HEAD") == git(b, "rev-parse", "HEAD")
            for index, (process, checkout, err) in enumerate(zip(processes, (a, b), errors)):
                start = len(log()); request(process, checkout, 2)
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    err.seek(0); diagnostic = err.read()
                    if "ripwire-prefetch done" in diagnostic: break
                    time.sleep(0.02)
                assert "ripwire-prefetch spawn" in diagnostic and "ripwire-prefetch done" in diagnostic, diagnostic
                prefetch_log = log()[start:]
                assert any(c[0] == b"GET" and b":qsnap:" in c[1] for c in prefetch_log)
                writes = [c for c in prefetch_log if c[0] == b"SET" and b":qsnap:" in c[1]]
                assert bool(writes) == (index == 0), (index, "prefetch replacement SET")
                start = len(log()); request(process, checkout, 3, "quality_delta")
                assert not any(c[0] == b"SET" and b":qsnap:" in c[1] for c in log()[start:])
            print("  PASS  MCP prefetch explicitly completes; second checkout prefetch and lazy quality reuse qsnap")
        finally:
            for process in processes:
                process.stdin.close()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            for err in errors: err.close()
        assert all(command(b"TTL", key) > 0 for key in command(b"SCAN", b"0")[1])
        inventory = [str(p.relative_to(scratch)) for folder in ("tmp", "xdg") for p in (scratch / folder).rglob("*") if p.is_file()]
        assert not inventory, ("local cache files leaked", inventory)
        for key in command(b"SCAN", b"0")[1]:
            assert len(key) <= 512 and not any(c in key for c in (b"{", b"}", b"\r", b"\n", b"\0"))
            value = command(b"GET", key)
            assert str(scratch).encode() not in value and b"ripwire-qhead-" not in value, key
        print("  PASS  complete private TMP/XDG inventory empty; key bounds and local tree paths excluded")
        subprocess.run([sys.argv[3], env["RIPWIRE_REDIS_URL"]], env=env, check=True)
        for key in command(b"SCAN", b"0")[1]:
            assert len(key) <= 512 and all(32 <= c < 127 for c in key) and b"{" not in key and b"}" not in key
            assert command(b"TTL", key) > 0
    finally:
        server.terminate(); server.wait(timeout=5)
PY
