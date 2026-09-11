#!/usr/bin/env bash
# RIPWIRE_TEST_DEPS: src/cache_backend.h,src/cache_backend.cpp,src/redis_client.cpp,src/quality.h,src/gitoracle.h,src/ingest_astquery.h,src/ingest_docpass.h,src/mergescout.h,src/mcpindex.h,src/mcpverbs.h,src/mcpedit.h,src/main.cpp,test/redis_blob_unit.cpp,test/mcp_api_driver.cpp,test/redis_stub.py
# Immutable derived caches share across independent checkout paths without filesystem fallback.
set -euo pipefail
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${RIPWIRE_BIN:-$ROOT/build/ripwire}"
BUILD_DIR="${RIPWIRE_MCP_TEST_BUILD_DIR:-$ROOT/build-tests-redisqualitycache}"
cmake -Wno-deprecated -S "$ROOT" -B "$BUILD_DIR" -DRIPWIRE_TESTS=ON >/dev/null
cmake --build "$BUILD_DIR" --target ripwire_test_mcp_api -j2 >/dev/null
DRIVER_DIR="$( mktemp -d )"
trap 'rm -rf "$DRIVER_DIR"' EXIT
"${CXX:-c++}" -std=c++23 -O1 -pthread -I"$ROOT/src" -I"$ROOT/src/infra" -I"$ROOT/third_party" \
    "$ROOT/test/redis_blob_unit.cpp" "$ROOT/src/cache_backend.cpp" "$ROOT/src/redis_client.cpp" "$ROOT/src/infra/diagnostics.cpp" -o "$DRIVER_DIR/blob-driver"
python3 - "$ROOT" "$BIN" "$DRIVER_DIR/blob-driver" "$BUILD_DIR/ripwire_test_mcp_api" <<'PY'
import base64, fcntl, hashlib, json, os, pathlib, re, select, shutil, socket, struct, subprocess, sys, tempfile, time

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
        # Record actual production Git work without mocking its results.
        real_git = shutil.which("git")
        git_log = scratch / "home/git.log"
        git_shim = scratch / "bin/git"
        git_shim.write_text(f'#!{sys.executable}\nimport json,os,sys\n'
                            f'fd=os.open({str(git_log)!r},os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)\n'
                            'os.write(fd,(json.dumps(sys.argv[1:])+"\\n").encode()); os.close(fd)\n'
                            f'os.execv({real_git!r},[{real_git!r},*sys.argv[1:]])\n')
        git_shim.chmod(0o755)
        def git_calls(): return [json.loads(line) for line in git_log.read_text().splitlines()] if git_log.exists() else []
        def work_counts():
            calls = git_calls()
            bridge_log = scratch / "home/bridge.log"
            return dict(qsnap=sum("archive" in c for c in calls), qbody=sum("archive" in c for c in calls),
                        qhist=sum("log" in c and "-p" in c and "-U0" in c for c in calls),
                        qchurn=sum("--format=tformat:__C__%x20%ct" in c and any(arg.startswith("--since=") for arg in c) for c in calls),
                        docmd=len(bridge_log.read_text().splitlines()) if bridge_log.exists() else 0)
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
        def admin(**request):
            with socket.create_connection(("127.0.0.1", ports["admin_port"])) as sock:
                sock.sendall(json.dumps(request).encode() + b"\n"); stream = sock.makefile("rb")
                return json.loads(stream.read(struct.unpack("!I", stream.read(4))[0]))
        def log():
            entries = admin(op="command_log")["commands"]
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
        def span_bytes(path):
            result = subprocess.run([sys.argv[4], "--cache-span-probe", str(path), str(path / "a.cpp")],
                                    input=b"", env=env, capture_output=True, timeout=15)
            assert result.returncode == 0 and result.stdout.strip().isdigit(), ("production span-tier bytesParsed probe missing", result.stdout, result.stderr)
            return int(result.stdout)
        assert span_bytes(a) > 0, "cold production span-tier probe must parse source bytes"
        def assert_cold_sequence(entries, keys, name):
            for key in keys:
                writes = [i for i, c in enumerate(entries) if c[0] == b"SET" and c[1] == key]
                gets = [i for i, c in enumerate(entries) if c[0] == b"GET" and c[1] == key]
                assert writes and gets and min(gets) < min(writes), (name, "cold GET miss must precede SET", key)
        def phase(path, name, flags):
            before = work_counts()
            parsed = span_bytes(path) if name == "stier" else 0
            result = run(path, *flags)
            work = parsed if name == "stier" else work_counts()[name] - before[name]
            return result, work
        def exercise(name, *flags):
            for key in family(name): command(b"DEL", key)
            assert not family(name), (name, "cold family must be absent before the producer GET")
            start = len(log()); (cold, cold_work) = phase(a, name, flags); coldlog = log()[start:]
            keys = family(name)
            assert keys, name + " was not stored in Redis"
            assert_cold_sequence(coldlog, keys, name)
            # Negative control: neither a missing GET nor one reordered after publication can pass.
            no_get = [c for c in coldlog if not (c[0] == b"GET" and c[1] in keys)]
            for mutation in (no_get, no_get + [[b"GET", key] for key in keys]):
                try: assert_cold_sequence(mutation, keys, name)
                except AssertionError: pass
                else: raise AssertionError((name, "cold sequence mutation escaped"))
            assert cold_work > 0, (name, "cold producer did no observable work", cold_work)
            start = len(log()); (warm, warm_work) = phase(b, name, flags); warmlog = log()[start:]
            assert warm_work == 0, (name, "cross-checkout hit recomputed", warm_work)
            assert cold.stdout == warm.stdout == run(b, *flags, "--no-cache").stdout, (name, "output differs")
            assert any(c[0] == b"GET" and c[1] in keys for c in warmlog), (name, "warm GET missing")
            assert any(c[0] == b"EXPIRE" and c[1] in keys for c in warmlog), (name, "warm TTL refresh missing")
            assert not any(c[0] == b"SET" and c[1] in keys for c in warmlog), (name, "warm replacement SET")
            if name == "stier":
                assert sum(c[0] == b"GET" and c[1] in keys for c in warmlog) >= 2, "both the API probe and CLI grep must consume the warm span-tier blob"
            key = keys[0]; command(b"SET", key, b"corrupt", b"EX", b"86400")
            start = len(log()); (healed, healed_work) = phase(b, name, flags); heal_log = log()[start:]
            assert healed.stdout == warm.stdout and any(c[0] == b"SET" and c[1] == key for c in heal_log), (name, "corruption not healed")
            assert healed_work > 0, (name, "corrupt value did not trigger observable recomputation", healed_work)
            if name in ("qsnap", "qbody"):
                diagnostic = b"HEAD Snapshot cache corrupt" if name == "qsnap" else b"window-ref body cache corrupt"
                assert diagnostic in healed.stderr, (name, "existing recompute diagnostic missing", healed.stderr)
            if name == "qsnap":
                reparses = re.findall(rb"cache-stats reparsed=(\d+)", healed.stderr)
                assert len(reparses) >= 2 and reparses[-1] == b"0", ("archived HEAD records were not reused", healed.stderr)
                assert not any(c[0] == b"SET" and b":record:" in c[1] for c in heal_log)
            print("  PASS ", name, "GET miss before SET; warm GET+EXPIRE/no SET; producer work cold/warm/corrupt:",
                  cold_work, warm_work, healed_work, "(archive/patch/name walk, bridge calls, or parsed bytes)")
            valid = command(b"GET", key)
            assert valid[:4] == b"RWB1" and valid[4:68] == hashlib.sha256(key + valid[68:]).hexdigest().encode()
            foreign_key = key + b"-foreign"
            foreign = b"RWB1" + hashlib.sha256(foreign_key + valid[68:]).hexdigest().encode() + valid[68:]
            command(b"SET", foreign_key, foreign, b"EX", b"86400")
            copied = command(b"GET", foreign_key)
            command(b"DEL", foreign_key)
            # docmd intentionally stores raw text, not a structured codec; empty text is its invalid/cache-miss case.
            invalid_payload = b"" if name == "docmd" else valid[68:72]
            invalid_codec = b"RWB1" + hashlib.sha256(key + invalid_payload).hexdigest().encode() + invalid_payload
            cases = (("payload-digest", valid[:68] + bytes([valid[68] ^ 1]) + valid[69:], False),
                     ("cross-key", copied, False), ("inner-codec" if name != "docmd" else "empty-text", invalid_codec, True))
            for corruption, value, outer_valid in cases:
                assert value[:4] == b"RWB1"
                assert (value[4:68] == hashlib.sha256(key + value[68:]).hexdigest().encode()) == outer_valid
                command(b"SET", key, value, b"EX", b"86400")
                start = len(log()); repaired, work = phase(b, name, flags); repair_log = log()[start:]
                writes = [i for i, c in enumerate(repair_log) if c[0] == b"SET" and c[1] == key]
                assert repaired.stdout == warm.stdout and work > 0 and writes, (name, corruption, "did not recompute equivalently", work)
                refreshed_before_repair = any(c[0] == b"EXPIRE" and c[1] == key for c in repair_log[:writes[0]])
                assert refreshed_before_repair == outer_valid, (name, corruption, "outer validation boundary not exercised")
            print("  PASS ", name, "intact envelope payload-digest rejection, cross-key binding, independent inner payload recomputation")
        exercise("qsnap", "--quality-delta")
        exercise("qbody", "--quality-delta")
        exercise("qhist", "--whereis=old_name", "--with-history")
        exercise("qchurn", "--for=new_name")
        # The first ingest also populates document extraction; remove only that test-owned family to exercise its cold arm.
        for key in family("docmd"): command(b"DEL", key)
        exercise("docmd")
        exercise("stier", "--grep=new_name")

        # Same-process prefetch/lazy overlap: delay A's SET, hold B after materialization but before archive,
        # then let A finish. Its cleanup must not remove the tree B owns while B holds the ingest mutex.
        race_repo = scratch / "overlap-repo"; race_repo.mkdir()
        (race_repo / "race.cpp").write_text("int overlap_value() { return 7; }\n")
        for args in (("init", "-q"), ("config", "user.email", "gate@example.com"), ("config", "user.name", "Gate"),
                     ("add", "."), ("commit", "-qm", "overlap fixture")): git(race_repo, *args, old=True)
        race_bin = scratch / "race-bin"; race_bin.mkdir()
        race_git = race_bin / "git"
        race_git.write_text(f'#!{sys.executable}\nimport os,pathlib,sys,time\n'
                            'if "archive" in sys.argv and "RIPWIRE_TEST_ARCHIVE_BARRIER" in os.environ:\n'
                            ' p=pathlib.Path(os.environ["RIPWIRE_TEST_ARCHIVE_BARRIER"])\n'
                            ' count=int((p/"count").read_text())+1 if (p/"count").exists() else 1\n'
                            ' (p/"count").write_text(str(count))\n'
                            ' if count==2:\n'
                            '  (p/"ready").touch()\n'
                            '  deadline=time.monotonic()+15\n'
                            '  while not (p/"release").exists():\n'
                            '   if time.monotonic()>deadline: sys.exit(3)\n'
                            '   time.sleep(0.005)\n'
                            f'os.execv({real_git!r},[{real_git!r},*sys.argv[1:]])\n')
        race_git.chmod(0o755)
        def wait_until(predicate, message):
            deadline = time.monotonic() + 15
            while not predicate():
                assert time.monotonic() < deadline, message
                time.sleep(0.005)
        race_failures = []
        for name, tag in (("qsnap", "qhead"), ("qbody", "qref")):
            race_env = dict(env, RIPWIRE_REDIS_NAMESPACE="overlap-" + name, RIPWIRE_REDIS_PROJECT="overlap-project", RIPWIRE_REDIS_TIMEOUT_MS="15000")
            start = len(log())
            seed = subprocess.run([sys.argv[4], "--cache-tree-probe", str(race_repo), name], env=race_env, capture_output=True, timeout=20)
            assert seed.returncode == 0 and seed.stdout, ("seed production tree probe failed", seed.stderr)
            sequence = log()[start:]
            publish_index = next(i for i, c in enumerate(sequence) if c[0] == b"SET" and b":" + name.encode() + b":" in c[1])
            # Restore the exact cold key state used to discover A's command index, without timing guesses.
            for key in {c[1] for c in sequence if c[0] == b"SET"}: command(b"DEL", key)
            start = len(log()); held_index = start + publish_index
            admin(op="hold", command_index=held_index, barrier="publish-" + name)
            barrier = scratch / ("archive-barrier-" + name); barrier.mkdir()
            overlap_env = dict(race_env, PATH=str(race_bin) + os.pathsep + race_env["PATH"], RIPWIRE_TEST_ARCHIVE_BARRIER=str(barrier))
            process = subprocess.Popen([sys.argv[4], "--cache-tree-overlap", str(race_repo), name], env=overlap_env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                wait_until(lambda: len(log()) > held_index, "prefetch never reached held Redis publication")
                assert log()[held_index][:2] == sequence[publish_index][:2], "held a different command than immutable publication"
                process.stdin.write(b"lazy\n"); process.stdin.flush()
                wait_until(lambda: (barrier / "ready").exists(), "lazy caller could not materialize while Redis publication was held")
                trees = list((scratch / "tmp/ripwire").rglob(f"ripwire-{tag}-{process.pid}"))
                assert len(trees) == 1 and trees[0].is_dir(), "lazy materialization did not create its local tree"
                admin(op="release", barrier="publish-" + name)
                assert select.select([process.stdout], [], [], 15)[0] and process.stdout.readline() == b"prefetch-done\n", "prefetch did not complete while lazy archive was held"
                assert trees[0].is_dir(), (name, "prefetch guard deleted the overlapping lazy tree")
                (barrier / "release").touch()
                output, errors = process.communicate(timeout=20)
                assert process.returncode == 0 and output == seed.stdout, (name, "overlapping tree output differs", errors)
                assert not trees[0].exists(), "lazy invocation failed to clean its local tree"
                print("  PASS ", name, "barrier-controlled same-process prefetch/lazy overlap preserves tree ownership and cleanup")
            except AssertionError as error:
                race_failures.append(str(error))
                print("  FAIL ", error, flush=True)
            finally:
                admin(op="release", barrier="publish-" + name)
                (barrier / "release").touch()
                if process.poll() is None:
                    try: process.communicate(timeout=20)
                    except subprocess.TimeoutExpired: process.kill(); process.communicate()

        refresh_failures = []
        for reply, invalid in ((b":0\r\n", False), (b":1\r\n", False), (b"+OK\r\n", True),
                               (b"$1\r\n1\r\n", True), (b":-1\r\n", True), (b":2\r\n", True)):
            start = len(log())
            admin(op="raw_reply", command_index=start + 2, value=base64.b64encode(reply).decode())
            checked = subprocess.run([sys.argv[3], env["RIPWIRE_REDIS_URL"], "--refresh", "invalid" if invalid else "valid"],
                                     env=env, capture_output=True, timeout=15)
            assert [c[0] for c in log()[start:]] == [b"SET", b"GET", b"EXPIRE"]
            if checked.returncode != 0:
                refresh_failures.append((reply, checked.stderr))
                continue
            assert checked.stderr.count(b"Redis cache unavailable or invalid") == int(invalid), checked.stderr
        assert not race_failures and not refresh_failures, (race_failures, refresh_failures)
        print("  PASS  EXPIRE accepts only integer 0/1; malformed type/value warns as Protocol without discarding a verified hit")
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

        # Mutable local objects are intentional filesystem state, tested separately from blob inventory.
        objects = scratch / "local-objects"
        for folder in ("tmp", "xdg", "home", "repo"): (objects / folder).mkdir(parents=True, exist_ok=True)
        local_env = dict(env, TMPDIR=str(objects / "tmp"), XDG_CACHE_HOME=str(objects / "xdg"), HOME=str(objects / "home"),
                         RIPWIRE_REDIS_NAMESPACE="local-artifacts", RIPWIRE_REDIS_PROJECT="local-artifacts-project")
        local_repo = (objects / "repo").resolve()
        target = local_repo / "lock.cpp"
        target.write_text("int lock_target() { return 1; }\n")
        sidecar = local_repo / ".ripwire_quality_acks"
        for args in (("init", "-q"), ("config", "user.email", "gate@example.com"), ("config", "user.name", "Gate"),
                     ("add", "."), ("commit", "-qm", "local lock fixture")): git(local_repo, *args)
        start = len(log())
        holder = subprocess.Popen([sys.argv[4], "--cache-lock-probe", str(local_repo), str(target), str(sidecar)], env=local_env,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        lock_markers = []
        try:
            assert select.select([holder.stdout], [], [], 15)[0] and holder.stdout.readline().strip() == "locked", "production lock probe did not acquire both locks"
            locks = sorted((objects / "tmp/ripwire/locks").rglob("*.lock"))
            assert len(locks) == 2 and {p.name.split("-")[1] for p in locks} == {"edit", "sidecar"}, locks
            lock_inodes = {p: p.stat().st_ino for p in locks}
            for path in locks:
                marker = ("LOCAL_ONLY_" + path.name).encode(); lock_markers.append(marker)
                path.write_bytes(marker)
                with path.open("rb") as probe:
                    try: fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError: pass
                    else: raise AssertionError(("production lock was not held locally", path))
            holder.stdin.write("release\n"); holder.stdin.flush()
            assert select.select([holder.stdout], [], [], 15)[0] and holder.stdout.readline().strip() == "released", "production lock release missing"
            assert holder.wait(timeout=15) == 0, holder.stderr.read()
            for path in locks:
                assert path.stat().st_ino == lock_inodes[path], ("lock inode replaced", path)
                with path.open("rb") as probe: fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert log()[start:] == [], "production lock lifecycle issued Redis commands"
        finally:
            if holder.poll() is None: holder.kill(); holder.wait()
            holder.stdin.close(); holder.stdout.close(); holder.stderr.close()
        # Exercise the production CLI call sites too; lock state never lands beside the edited source.
        edit = subprocess.run([str(binary), str(local_repo), "--cache=redis", "--replace-symbol-body=lock_target", "--edit-payload=-"],
                              input=b"int lock_target() { return 2; }", env=local_env, capture_output=True)
        assert edit.returncode == 0 and b'"applied":"replace_symbol_body"' in edit.stdout, (edit.stdout, edit.stderr)
        assert "return 2" in target.read_text()
        ack = subprocess.run([str(binary), str(local_repo), "--cache=redis", "--quality-delta", "--quality-ack=local fixture"], env=local_env, capture_output=True)
        assert ack.returncode == 0, (ack.stdout, ack.stderr)
        assert not list(local_repo.rglob("*.lock")), "lock sidecar littered the source checkout"
        assert sorted((objects / "tmp/ripwire/locks").rglob("*.lock")) == locks
        for path in locks:
            assert path.stat().st_ino == lock_inodes[path] and path.read_bytes() in lock_markers
            with path.open("rb") as probe: fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print("  PASS  production edit/sidecar locks held locally, released on scope exit, retained stable inodes, and issued zero Redis commands")

        # Exercise real cloning and production cached-clone reuse, but permit ONLY Git's local file transport.
        remote_url = "https://example.invalid/redis-local-clone.git"
        remote_env = dict(local_env, GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0=f"url.{local_repo.as_uri()}.insteadOf",
                          GIT_CONFIG_VALUE_0=remote_url, GIT_ALLOW_PROTOCOL="file")
        start = len(git_calls())
        remote_cold = subprocess.run([str(binary), remote_url, "--cache=redis", "--no-stable"], env=remote_env, capture_output=True)
        assert remote_cold.returncode == 0 and b"ripwire: cloning " in remote_cold.stderr, remote_cold.stderr
        clones = list((objects / "tmp/ripwire").glob("ripwire-remote-*"))
        assert len(clones) == 1 and (clones[0] / ".git").is_dir() and (clones[0] / "lock.cpp").is_file(), clones
        clone = clones[0]
        assert sum("clone" in c for c in git_calls()[start:]) == 1, "cold remote path did not clone exactly once"
        clone_marker = b"LOCAL_ONLY_REMOTE_GIT_METADATA_2026"
        (clone / ".git/local-only-marker").write_bytes(clone_marker)
        clone_stat = (clone / "lock.cpp").stat()
        start = len(git_calls())
        remote_warm = subprocess.run([str(binary), remote_url, "--cache=redis", "--no-stable"], env=remote_env, capture_output=True)
        assert remote_warm.returncode == 0 and remote_warm.stdout == remote_cold.stdout, remote_warm.stderr
        assert b"reusing cached clone of" in remote_warm.stderr and b"ripwire: cloning " not in remote_warm.stderr
        assert not any("clone" in c or "fetch" in c for c in git_calls()[start:]), "warm remote path fetched or re-cloned"
        assert (clone / ".git/local-only-marker").read_bytes() == clone_marker
        assert ((clone / "lock.cpp").stat().st_ino, (clone / "lock.cpp").stat().st_mtime_ns) == (clone_stat.st_ino, clone_stat.st_mtime_ns)
        allowed_local_files = set(locks) | {p for p in clone.rglob("*") if p.is_file()}
        local_files = {p for folder in ("tmp", "xdg") for p in (objects / folder).rglob("*") if p.is_file()}
        assert local_files == allowed_local_files, ("edit/ack/remote path created unexpected local cache files", local_files - allowed_local_files)
        needles = [*lock_markers, clone_marker, remote_url.encode(), str(objects).encode(), str(objects.resolve()).encode(),
                   clone.name.encode(), *[p.name.encode() for p in locks]]
        for entry in log():
            assert not any(needle in arg for needle in needles for arg in entry), ("local artifact leaked into Redis command", entry[0])
        for key in command(b"SCAN", b"0")[1]:
            value = command(b"GET", key)
            assert not any(needle in key or needle in value for needle in needles), ("local artifact leaked into Redis key/value", key)
        print("  PASS  cached remote clone exists/reuses unchanged on disk via file-only transport; lock/clone markers and paths absent from all Redis commands and values")
    finally:
        server.terminate(); server.wait(timeout=5)
PY
