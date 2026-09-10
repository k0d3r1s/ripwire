#!/usr/bin/env bash
# Redis ingest: independent checkouts, immutable records, TTLs and uncached degradation.
set -euo pipefail
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${RIPWIRE_BIN:-$ROOT/build/ripwire}"
BUILD_DIR="${RIPWIRE_TEST_BUILD_DIR:-$ROOT/build-tests}"
cmake -Wno-deprecated -S "$ROOT" -B "$BUILD_DIR" -DRIPWIRE_TESTS=ON \
    -DRIPWIRE_CACHE_RECORD_SOURCE_ROOT="$ROOT" -DRIPWIRE_CACHE_RECORD_BASELINE=OFF >/dev/null
cmake --build "$BUILD_DIR" --target ripwire_test_cache_record -j2 >/dev/null
python3 - "$ROOT" "$BIN" "$BUILD_DIR/ripwire_test_cache_record" <<'PY'
import base64, json, os, pathlib, re, socket, struct, subprocess, sys, tempfile, time

root, binary, driver = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).resolve(), pathlib.Path(sys.argv[3]).resolve()
with tempfile.TemporaryDirectory(prefix="redisingest-") as tmp:
    scratch = pathlib.Path(tmp)
    server = subprocess.Popen([sys.executable, str(root / "test/redis_stub.py")], stdout=subprocess.PIPE, text=True)
    try:
        ports = json.loads(server.stdout.readline())
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("RIPWIRE_REDIS_") or key == "RIPWIRE_CACHE_BACKEND":
                del env[key]
        for name in ("tmp", "xdg", "home"):
            (scratch / name).mkdir()
        env.update(TMPDIR=str(scratch / "tmp"), XDG_CACHE_HOME=str(scratch / "xdg"),
                   HOME=str(scratch / "home"), RIPWIRE_CACHE_STATS="1", RIPWIRE_REDIS_NAMESPACE="ingest-gate",
                   RIPWIRE_REDIS_URL=f'redis://127.0.0.1:{ports["tcp_port"]}',
                   RIPWIRE_REDIS_TIMEOUT_MS="100", RIPWIRE_REDIS_TTL_DAYS="1")
        def admin(op, **args):
            with socket.create_connection(("127.0.0.1", ports["admin_port"])) as sock:
                sock.sendall(json.dumps(dict(op=op, **args)).encode() + b"\n")
                stream = sock.makefile("rb")
                return json.loads(stream.read(struct.unpack("!I", stream.read(4))[0]))
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
        def run(checkout, expected, *flags, extra=None):
            result = subprocess.run([str(binary), ".", "--cache=redis", "--no-stable", *flags], cwd=checkout,
                                    env=dict(env, **(extra or {})), capture_output=True)
            assert result.returncode == 0, result.stderr.decode()
            found = re.search(rb"cache-stats reparsed=(\d+)", result.stderr)
            assert found and int(found[1]) == expected, (str(checkout), expected, result.stderr.decode())
            return result
        def keys(): return command(b"SCAN", b"0")[1]
        def records(): return [k for k in keys() if b":record:" in k]
        def descriptors(): return [k for k in keys() if b":descriptor:" in k]
        def ttl():
            assert all(command(b"TTL", key) > 0 for key in keys()), "persistent or expired key"
        def fixture(name, remote):
            path = scratch / name; path.mkdir()
            subprocess.run(["git", "init", "-q", str(path)], check=True)
            subprocess.run(["git", "-C", str(path), "remote", "add", "origin", remote], check=True)
            for i in range(3):
                source = path / f"file{i}.cpp"
                source.write_text(f"int function{i}() {{ return {i}; }}\n")
                os.utime(source, (1000000000 + len(name), 1000000000 + len(name)))
            return path
        a = fixture("a", "https://example.com/team/project.git")
        b = fixture("checkout-b", "git@example.com:team/project.git")
        cold = run(a, 3)
        assert len(records()) == 3 and len(descriptors()) == 3, "Redis ingest records/descriptors were not stored"
        warm = run(b, 0)
        assert cold.stdout == warm.stdout, "cross-checkout output differs"
        c = fixture("ssh-checkout", "ssh://git@example.com/team/project.git")
        assert run(c, 0).stdout == cold.stdout
        assert (a / "file0.cpp").stat().st_ino != (b / "file0.cpp").stat().st_ino
        assert (a / "file0.cpp").stat().st_mtime != (b / "file0.cpp").stat().st_mtime
        ttl()
        print("  PASS  independent HTTPS/SCP checkout reuses every parse record")
        saved = records()
        admin("delete", key=base64.b64encode(saved[0]).decode())
        assert run(b, 1).stdout == warm.stdout
        key = records()[0]
        original = command(b"GET", key)
        command(b"SET", key, b"corrupt", b"EX", b"86400")
        assert run(b, 1).stdout == warm.stdout
        command(b"SET", key, original, b"EX", b"86400")
        for corrupt in (b"x" * (4 * 1024 * 1024 + 1), original[:4] + b"0" * 64 + original[68:],
                        original[:68] + b"0" * 64 + original[132:], original[:132] + b"\0" * 4 + original[136:]):
            assert corrupt != original
            command(b"SET", key, corrupt, b"EX", b"86400")
            assert run(b, 1).stdout == warm.stdout
        command(b"SET", key, original, b"EX", b"86400")
        descriptor = descriptors()[0]
        command(b"SET", descriptor, b"unrelated descriptor", b"EX", b"86400")
        assert run(b, 0).stdout == warm.stdout
        print("  PASS  missing/corrupt records reparse only their path")
        (b / "file1.cpp").write_text("int changed_function() { return 99; }\n")
        changed = run(b, 1)
        assert changed.stdout == run(b, 3, "--no-cache").stdout
        assert run(b, 0).stdout == changed.stdout
        print("  PASS  one-file edit and warm output equal uncached output")
        for extra in ({"RIPWIRE_REDIS_NAMESPACE": "other"}, {"RIPWIRE_REDIS_PROJECT": "other"}):
            assert run(b, 3, extra=extra).stdout == changed.stdout
            assert run(b, 0, extra=extra).stdout == changed.stdout
        print("  PASS  namespace and project overrides isolate records")
        # Same-namespace substitution cannot authenticate another project's envelope, even if path
        # and source bytes match. Parser/cache generation, architecture and rich/lean all key apart.
        original_records = records()
        other = {"RIPWIRE_REDIS_PROJECT": "poison-target"}
        run(b, 3, extra=other)
        new_records = [k for k in records() if k not in original_records]
        source_by_suffix = {k.split(b":record:")[1]: command(b"GET", k) for k in original_records}
        for key in new_records:
            command(b"SET", key, source_by_suffix[key.split(b":record:")[1]], b"EX", b"86400")
        assert run(b, 3, extra=other).stdout == changed.stdout
        for key in new_records: command(b"DEL", key)
        for field in (4, 5, 6):
            identity_project = {"RIPWIRE_REDIS_PROJECT": f"identity-{field}"}
            before = set(records()); run(b, 3, extra=identity_project)
            current = [k for k in records() if k not in before]
            assert len(current) == 3
            for key in current:
                parts = key.split(b":"); parts[field] = b"999"
                command(b"SET", b":".join(parts), command(b"GET", key), b"EX", b"86400")
                command(b"DEL", key)
            run(b, 3, extra=identity_project)
        rich = run(b, 3, "--for=function")
        assert run(b, 0, "--for=function").stdout == rich.stdout
        assert run(b, 3, "--for=function", "--no-cache").stdout == rich.stdout
        for sub in ("sub-one", "sub-two"):
            path = b / sub; path.mkdir(); (path / "a.cpp").write_text("int nested() { return 1; }\n")
            run(path, 1); run(path, 0)
        print("  PASS  project poisoning, generations, architecture, rich/lean and repository-relative roots isolate")
        # Narrow walks refresh only active paths. Neither deletion nor excludes delete other keys;
        # fake-clock advancement proves bounded retention without wall-clock sleeps.
        expiry = fixture("expiry", "https://example.com/team/expiry.git")
        before = set(keys()); run(expiry, 3)
        expiry_keys = set(keys()) - before
        (expiry / "file0.cpp").unlink()
        assert run(expiry, 0, "--exclude=file1.cpp").stdout == run(expiry, 1, "--exclude=file1.cpp", "--no-cache").stdout
        assert expiry_keys <= set(keys())
        admin("advance_clock", seconds=43201)
        run(expiry, 0, "--exclude=file1.cpp")
        admin("advance_clock", seconds=43201)
        live_expiry = expiry_keys & set(keys())
        assert len(live_expiry) == 2, live_expiry
        run(expiry, 1)
        print("  PASS  deleted/excluded descriptors expire while active paths refresh")
        # Restore b after all old keys expired; remove nested fixtures from its crawl.
        for sub in ("sub-one", "sub-two"):
            (b / sub / "a.cpp").unlink(); (b / sub).rmdir()
        changed = run(b, 3)
        # Fault both sides of each atomic publication. A descriptor can exist only when its record
        # exists; every created key has TTL. The command offsets are MGET, SET record, SET descriptor.
        for phase in ("fail_before", "fail_after"):
            for offset in (1, 2):
                probe = fixture(f"fault-{phase}-{offset}", f"https://example.com/{phase}/{offset}.git")
                for i in (1, 2): (probe / f"file{i}.cpp").unlink()
                before = set(keys()); next_index = admin("command_log")["next_index"]
                admin(phase, command_index=next_index + offset, mode="drop")
                run(probe, 1)
                added = set(keys()) - before
                recs = [k for k in added if b":record:" in k]
                descs = [k for k in added if b":descriptor:" in k]
                assert not descs or recs, (phase, offset, added)
                if offset == 1: assert not descs, (phase, added)
                ttl()
        print("  PASS  before/after record and descriptor faults never leave persistent keys or dangling descriptors")
        # Hold A's first SET while B completes. A then becomes descriptor last writer, but both
        # source variants must remain directly addressable and the overlapping record must verify.
        race_env = dict(env, RIPWIRE_REDIS_PROJECT="race")
        index = admin("command_log")["next_index"]
        admin("hold", barrier="writer-a", command_index=index + 1)
        writer = subprocess.Popen([str(binary), ".", "--cache=redis", "--no-stable"], cwd=a, env=race_env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for _ in range(1000):
            if admin("command_log")["next_index"] >= index + 2: break
            time.sleep(0.005)
        else: raise AssertionError("writer did not reach barrier")
        run(b, 3, extra={"RIPWIRE_REDIS_PROJECT": "race"})
        admin("release", barrier="writer-a")
        stdout, stderr = writer.communicate(timeout=10)
        assert writer.returncode == 0, stderr
        assert run(a, 0, extra={"RIPWIRE_REDIS_PROJECT": "race"}).stdout == stdout
        assert run(b, 0, extra={"RIPWIRE_REDIS_PROJECT": "race"}).stdout == changed.stdout
        print("  PASS  overlapping writers preserve all content records regardless of descriptor last writer")
        bulk = fixture("bulk", "https://example.com/team/bulk.git")
        for i in range(3, 39): (bulk / f"file{i}.cpp").write_text(f"int bulk{i}() {{ return {i}; }}\n")
        bulk_output = run(bulk, 39).stdout
        assert run(bulk, 0).stdout == bulk_output
        admin("server_error", command_index=admin("command_log")["next_index"])
        assert run(bulk, 16).stdout == bulk_output, "batch failure leaked beyond its bounded file set"
        log = admin("command_log")["commands"]
        mget_sizes = []
        for entry in log:
            raw = base64.b64decode(entry["record"])
            count = struct.unpack("!I", raw[:4])[0]
            first_size = struct.unpack("!I", raw[4:8])[0]
            if raw[8:8 + first_size] == b"MGET": mget_sizes.append(count - 1)
        assert max(mget_sizes) == 16 and all(0 < count <= 16 for count in mget_sizes), mget_sizes
        admin("fail_before", command_index=admin("command_log")["next_index"] + 1, mode="drop")
        assert run(b, 0).stdout == changed.stdout, "TTL refresh failure discarded a verified hit"
        print("  PASS  bounded MGET batches isolate a failed batch; refresh failure retains verified hits")
        next_index = admin("command_log")["next_index"]
        admin("deadline", command_index=next_index, seconds=0.3)
        degraded = run(b, 3)
        assert degraded.stdout == changed.stdout
        assert len([line for line in degraded.stderr.splitlines() if b"Redis cache" in line]) == 1, degraded.stderr
        # Sequential backend failures in one process; exact MCP routing proof belongs to Task 5.
        with tempfile.TemporaryFile() as errors:
            process = subprocess.Popen([str(driver), "--redis-ingest-driver", str(b)], env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True)
            for op, args in (("deadline", {"seconds": 0.3}), ("fail_before", {"mode": "malformed"}),
                             ("auth_error", {}), ("server_error", {})):
                admin(op, command_index=admin("command_log")["next_index"], **args)
                process.stdin.write("ingest\n"); process.stdin.flush()
                assert process.stdout.readline().strip() == "3", op
            process.stdin.write("corrupt-record\n"); process.stdin.flush()
            assert process.stdout.readline().strip() == "rejected"
            process.stdin.close(); assert process.wait(timeout=10) == 0
            errors.seek(0); lines = errors.read().splitlines()
            assert len([line for line in lines if b"cache-stats" not in line]) == 1, lines
        for operation in ("auth_error", "server_error"):
            admin(operation, command_index=admin("command_log")["next_index"])
            assert run(b, 3).stdout == changed.stdout
        with socket.socket() as closed:
            closed.bind(("127.0.0.1", 0)); closed_port = closed.getsockname()[1]
        assert run(b, 3, extra={"RIPWIRE_REDIS_URL": f"redis://127.0.0.1:{closed_port}"}).stdout == changed.stdout
        print("  PASS  timeout, malformed, auth and server failures share one process warning; outage remains uncached")
        ttl()
        artifacts = [p for name in ("tmp", "xdg", "home") for p in (scratch / name).rglob("*") if p.is_file()]
        assert not artifacts, artifacts
        print("  PASS  timeout degrades once with identical output and no local cache artifacts")
    finally:
        server.terminate(); server.wait()
PY
