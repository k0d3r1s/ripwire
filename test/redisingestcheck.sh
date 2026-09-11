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
import base64, hashlib, json, os, pathlib, re, socket, struct, subprocess, sys, tempfile, time

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
        def logged_commands(start):
            commands = []
            for entry in admin("command_log")["commands"]:
                if entry["index"] < start: continue
                raw = base64.b64decode(entry["record"])
                count = struct.unpack("!I", raw[:4])[0]; offset = 4; args = []
                for _ in range(count):
                    size = struct.unpack("!I", raw[offset:offset + 4])[0]; offset += 4
                    args.append(raw[offset:offset + size]); offset += size
                commands.append((entry["index"], args))
            return commands
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
        for mode in ("fail-pending", "fail-parse", "fail-extract"):
            failed = fixture(mode, f"https://example.com/team/{mode}.git")
            (failed / "file0.cpp").write_text("int transient_failure_target() { return 7; }\n")
            before_failure = set(keys())
            injected = subprocess.run([str(driver), "--redis-ingest-driver", str(failed)], env=env,
                                      input=mode + "\n", text=True, capture_output=True)
            assert injected.returncode == 0 and injected.stdout.strip() == "3", (mode, injected.returncode, injected.stderr)
            failure_keys = set(keys()) - before_failure
            assert len(failure_keys) == 4, (mode, "failed extraction published a record or descriptor", failure_keys)
            failed_path_hash = hashlib.sha256(b"file0.cpp").hexdigest().encode()
            assert not any(failed_path_hash in key for key in failure_keys), (mode, failure_keys)
            healthy = run(failed, 1)
            assert b"transient_failure_target" in healthy.stdout
            assert healthy.stdout == run(failed, 3, "--no-cache").stdout
            healthy_peer = fixture(mode + "-peer", f"git@example.com:team/{mode}.git")
            (healthy_peer / "file0.cpp").write_bytes((failed / "file0.cpp").read_bytes())
            assert run(healthy_peer, 0).stdout == healthy.stdout == run(failed, 0).stdout
            for key in set(keys()) - before_failure: command(b"DEL", key)
        print("  PASS  parse and immediate/deferred extraction failures never publish; healthy hosts reparse then share")
        cold = run(a, 3)
        assert len(records()) == 3 and len(descriptors()) == 3, "Redis ingest records/descriptors were not stored"
        namespace_hash = hashlib.sha256(b"ingest-gate").hexdigest().encode()
        project_hash = hashlib.sha256(b"example.com/team/project\n.").hexdigest().encode()
        scope = b"rw:v1:" + namespace_hash + b":" + project_hash + b":ingest:"
        cache_header = (root / "src/ingest_cache.h").read_text()
        cache_version = re.search(r"kCacheVersion\s*=\s*(\d+)", cache_header)[1].encode()
        parser_version = int(re.search(r"kParserVer\s*=\s*(\d+)", cache_header)[1])
        arch = str((0 if sys.byteorder == "little" else 1) | (struct.calcsize("P") << 1)).encode()
        lean_prefix = scope + cache_version + b":" + str(parser_version).encode() + b":" + arch + b":lean:"
        expected_keys = set()
        for source in sorted(a.glob("*.cpp")):
            path_hash = hashlib.sha256(source.name.encode()).hexdigest().encode()
            digest = hashlib.sha256(source.read_bytes()).hexdigest().encode()
            expected_keys.update((lean_prefix + b"descriptor:" + path_hash, lean_prefix + b"record:" + path_hash + b":" + digest))
        assert set(keys()) == expected_keys, ("exact rw:v1 ingest descriptor/record key contract", keys(), expected_keys)
        print("  PASS  exact versioned ingest keys preserve namespace/project/path/source hashes and native architecture")
        assert all(command(b"TTL", key) == 86400 for key in keys()), "configured TTL is not one day"
        defaults = {"RIPWIRE_REDIS_PROJECT": "default-ttl", "RIPWIRE_REDIS_TTL_DAYS": ""}
        before_defaults = set(keys()); run(a, 3, extra=defaults)
        default_keys = set(keys()) - before_defaults
        assert len(default_keys) == 6
        assert all(command(b"TTL", key) == 30 * 86400 for key in default_keys), "default TTL is not 30 days"
        admin("advance_clock", seconds=123)
        assert all(command(b"TTL", key) == 30 * 86400 - 123 for key in default_keys)
        run(a, 0, extra=defaults)
        assert all(command(b"TTL", key) == 30 * 86400 for key in default_keys), "hit did not refresh record and descriptor"
        for key in default_keys: command(b"DEL", key)
        print("  PASS  exact configured/default TTL and verified-hit refresh for records and descriptors")
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
        for field in (5, 6, 7):
            identity_project = {"RIPWIRE_REDIS_PROJECT": f"identity-{field}"}
            before = set(records()); run(b, 3, extra=identity_project)
            current = [k for k in records() if k not in before]
            assert len(current) == 3
            for key in current:
                parts = key.split(b":")
                assert len(parts) == 12 and parts[:2] == [b"rw", b"v1"] and parts[4] == b"ingest" and parts[field].isdigit(), parts
                parts[field] = b"999"
                command(b"SET", b":".join(parts), command(b"GET", key), b"EX", b"86400")
                command(b"DEL", key)
            run(b, 3, extra=identity_project)
        rich = run(b, 3, "--for=function")
        rich_prefix = scope + cache_version + b":" + str(parser_version + 1).encode() + b":" + arch + b":rich:"
        rich_keys = [key for key in keys() if key.startswith(rich_prefix)]
        assert len(rich_keys) == 6 and all(re.fullmatch(rb"(?:descriptor:[0-9a-f]{64}|record:[0-9a-f]{64}:[0-9a-f]{64})",
                                                     key[len(rich_prefix):]) for key in rich_keys), rich_keys
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
        active_hash = hashlib.sha256(b"file2.cpp").hexdigest().encode()
        assert len(live_expiry) == 2 and all(active_hash in key for key in live_expiry), live_expiry
        assert sum(b":descriptor:" in key for key in live_expiry) == 1
        assert all(command(b"TTL", key) == 43199 for key in live_expiry)
        run(expiry, 1)
        print("  PASS  deleted/excluded descriptors expire while active paths refresh")
        # Restore b after all old keys expired; remove nested fixtures from its crawl.
        for sub in ("sub-one", "sub-two"):
            (b / sub / "a.cpp").unlink(); (b / sub).rmdir()
        changed = run(b, 3)
        # Fault both sides of each atomic publication. A descriptor can exist only when its record
        # exists; every created key has TTL. The command offsets are MGET, SET record, SET descriptor.
        orphans = set()
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
                if recs and not descs: orphans.update(recs)
                ttl()
        assert orphans, "orphan expiry arm did not create an orphan"
        admin("advance_clock", seconds=86401)
        assert all(command(b"TTL", key) == -2 and command(b"GET", key) is None for key in orphans)
        changed = run(b, 3)
        print("  PASS  interrupted publication orphans expire at the configured TTL")
        print("  PASS  before/after record and descriptor faults never leave persistent keys or dangling descriptors")
        # Hold A's first SET while B completes. A then becomes descriptor last writer, but both
        # source variants must remain directly addressable and the overlapping record must verify.
        for attempt in range(3):
            race_options = dict(RIPWIRE_REDIS_PROJECT=f"race-{attempt}", RIPWIRE_REDIS_TIMEOUT_MS="10000")
            race_env = dict(env, **race_options)
            index = admin("command_log")["next_index"]
            barrier = f"writer-a-{attempt}"
            admin("hold", barrier=barrier, command_index=index + 1)
            writer = subprocess.Popen([str(binary), ".", "--cache=redis", "--no-stable"], cwd=a, env=race_env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                for _ in range(1000):
                    if admin("command_log")["next_index"] >= index + 2: break
                    time.sleep(0.005)
                else: raise AssertionError("writer did not reach barrier")
                held = logged_commands(index)
                assert len(held) == 2 and held[0][1][0] == b"MGET", held
                held_key = held[1][1][1]
                assert held[1][1][0] == b"SET" and b":record:" in held_key, held
                assert command(b"GET", held_key) is None and writer.poll() is None
                other = run(b, 3, extra=race_options)
                assert b"Redis cache" not in other.stderr, other.stderr
                assert command(b"GET", held_key) is not None and writer.poll() is None
                completed = logged_commands(index + 2)
                assert sum(args[0] == b"SET" for _, args in completed) == 6, completed
                after_b = admin("command_log")["next_index"]
            finally:
                admin("release", barrier=barrier)
                stdout, stderr = writer.communicate(timeout=15)
            assert writer.returncode == 0 and b"Redis cache" not in stderr, stderr
            assert b"reparsed=3 reused=0" in stderr, stderr
            after_release = logged_commands(after_b)
            assert any(args[0] == b"GET" and args[1] == held_key for _, args in after_release), after_release
            assert sum(args[0] == b"SET" and b":descriptor:" in args[1] for _, args in after_release) == 3, after_release
            assert run(a, 0, extra=race_options).stdout == stdout
            assert run(b, 0, extra=race_options).stdout == changed.stdout
        print("  PASS  three ordered overlapping writer races preserve every record without timeouts")
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
