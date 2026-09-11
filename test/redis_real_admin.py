#!/usr/bin/env python3
"""Test-only RESP2 admin and real Redis matrix; no third-party Python packages."""

import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse


class RedisError(RuntimeError):
    pass


class RespReader:
    """One bounded reply, including framing, with a deadline across all socket reads."""

    def __init__(self, sock, stream, deadline):
        self.sock, self.stream, self.deadline = sock, stream, deadline
        self.remaining = 1024 * 1024

    def read(self, count):
        if count < 0 or count > self.remaining:
            raise ValueError("admin reply budget exceeded")
        self.remaining -= count
        value = bytearray()
        while len(value) < count:
            remaining_time = self.deadline - time.monotonic()
            if remaining_time <= 0:
                raise ValueError("admin reply deadline exceeded")
            self.sock.settimeout(remaining_time)
            chunk = self.stream.read1(min(65536, count - len(value)))
            if not chunk:
                raise ValueError("truncated admin reply")
            value += chunk
        return bytes(value)

    def line(self):
        line = bytearray()
        while not line.endswith(b"\r\n"):
            if len(line) >= 8192:
                raise ValueError("admin reply line exceeded")
            line += self.read(1)
        return line[:1], bytes(line[1:-2])

    def reply(self, depth=0):
        if depth > 4:
            raise ValueError("admin reply depth exceeded")
        kind, value = self.line()
        if kind == b"-":
            raise RedisError(value.decode(errors="replace"))
        if kind == b"+":
            return value
        if kind == b":":
            return int(value)
        if kind == b"$":
            count = int(value)
            if count == -1:
                return None
            data = self.read(count)
            if self.read(2) != b"\r\n":
                raise ValueError("invalid admin bulk terminator")
            return data
        if kind == b"*" and 0 <= int(value) <= 4096:
            return [self.reply(depth + 1) for _ in range(int(value))]
        raise ValueError("invalid admin RESP reply")


class RedisAdmin:
    """Small bounded RESP client for test metadata/cleanup, never a runtime dependency."""

    def __init__(self, url, username="", password=""):
        self.url = urllib.parse.urlsplit(url)
        if self.url.scheme not in ("redis", "redis+unix") or self.url.username or self.url.password:
            raise ValueError("test URL must use redis or redis+unix, without credentials")
        self.username, self.password = username, password

    def connect(self):
        if self.url.scheme == "redis+unix":
            sock = socket.socket(socket.AF_UNIX)
            sock.settimeout(3)
            try:
                sock.connect(self.url.path)
            except OSError:
                sock.close()
                raise
            database = urllib.parse.parse_qs(self.url.query).get("db", ["0"])[0]
        else:
            sock = socket.create_connection((self.url.hostname, self.url.port or 6379), timeout=3)
            database = self.url.path.lstrip("/") or "0"
        return sock, database

    def command(self, *args):
        args = [arg if isinstance(arg, bytes) else str(arg).encode() for arg in args]
        if sum(map(len, args)) > 1024 * 1024:
            raise ValueError("admin request exceeds 1 MiB")
        sock, database = self.connect()
        deadline = time.monotonic() + 5
        with sock, sock.makefile("rb") as stream:
            def exchange(values):
                sock.settimeout(max(0.001, deadline - time.monotonic()))
                sock.sendall(b"*%d\r\n" % len(values) + b"".join(b"$%d\r\n" % len(v) + v + b"\r\n" for v in values))
                return RespReader(sock, stream, deadline).reply()

            if self.password:
                auth = [b"AUTH"] + ([self.username.encode()] if self.username else []) + [self.password.encode()]
                if exchange(auth) != b"OK":
                    raise ValueError("admin authentication failed")
            if database != "0" and exchange([b"SELECT", database.encode()]) != b"OK":
                raise ValueError("admin database selection failed")
            return exchange(args)


class NamespaceLedger:
    """Record exact observed keys before deleting; SCAN is bounded even on a busy user DB."""

    def __init__(self, admin, namespace, manifest):
        self.admin = admin
        self.prefix = b"rw:v1:" + hashlib.sha256(namespace.encode()).hexdigest().encode() + b":"
        self.manifest = manifest
        self.recorded = set()

    def page(self, cursor):
        cursor, keys = self.admin.command("SCAN", cursor, "MATCH", self.prefix + b"*", "COUNT", 128)
        if not isinstance(cursor, bytes) or not cursor.isdigit() or not isinstance(keys, list):
            raise AssertionError("invalid SCAN result")
        for key in keys:
            if not isinstance(key, bytes) or not key.startswith(self.prefix):
                raise AssertionError("SCAN returned a foreign key; cleanup refused")
        return cursor, keys

    def scan(self):
        cursor, found, deadline = b"0", set(), time.monotonic() + 15
        for _ in range(1024):
            if time.monotonic() >= deadline:
                raise AssertionError("namespace SCAN deadline exceeded")
            cursor, keys = self.page(cursor)
            found.update(keys)
            if len(found) > 4096:
                raise AssertionError("namespace key ceiling exceeded")
            if cursor == b"0":
                return found
        raise AssertionError("namespace SCAN iteration ceiling exceeded")

    def capture(self):
        found = self.scan()
        added = found - self.recorded
        with self.manifest.open("a") as stream:
            for key in sorted(added):
                stream.write(key.hex() + "\n")
        self.recorded.update(added)
        return found

    def cleanup(self):
        # Do not turn a new SCAN result into deletion authority here.
        live = self.scan()
        for key in sorted(live & self.recorded):
            assert key.startswith(self.prefix)
            try:
                self.admin.command("UNLINK", key)
            except RedisError as error:
                if "unknown command" not in str(error).lower():
                    raise
                self.admin.command("DEL", key)
        assert not (self.scan() & self.recorded), "recorded keys survived cleanup"


def fixture(checkout, remote):
    checkout.mkdir()
    subprocess.run(["git", "init", "-q", str(checkout)], check=True)
    subprocess.run(["git", "-C", str(checkout), "remote", "add", "origin", remote], check=True)
    for index in range(3):
        path = checkout / f"file{index}.cpp"
        path.write_text(f"int function{index}() {{ return {index}; }}\n")
        os.utime(path, (1000000000 + len(checkout.name),) * 2)


def run_matrix(binary, scratch, ledger, env, partial=None):
    a, b = scratch / "a", scratch / "independent-b"
    fixture(a, "https://example.com/redis-real/matrix.git")
    fixture(b, "git@example.com:redis-real/matrix.git")

    def run(checkout, expected, extra=None, flags=()):
        result = subprocess.run([str(binary), ".", "--cache=redis", "--no-stable", *flags], cwd=checkout,
                                env=dict(env, **(extra or {})), capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr.decode()
        stats = re.search(rb"cache-stats reparsed=(\d+)", result.stderr)
        assert stats and (expected is None or int(stats[1]) == expected), result.stderr.decode()
        return result

    def metadata():
        keys = ledger.capture()
        assert len(keys) >= 6, "cold run did not publish records and descriptors"
        for key in keys:
            assert ledger.admin.command("TYPE", key) == b"string", key
            assert 0 < ledger.admin.command("TTL", key) <= 2 * 86400, key
        return keys

    cold = run(a, 3)
    initial = metadata()
    assert len(initial) == 6
    assert cold.stdout == run(b, 0).stdout == run(a, 3, flags=("--no-cache",)).stdout
    assert (a / "file0.cpp").stat().st_ino != (b / "file0.cpp").stat().st_ino
    assert (a / "file0.cpp").stat().st_mtime != (b / "file0.cpp").stat().st_mtime
    # Force a shorter TTL via the admin identity; the production user must restore every hit.
    for key in initial:
        assert ledger.admin.command("EXPIRE", key, 60) == 1
    assert run(b, 0).stdout == cold.stdout
    assert all(ledger.admin.command("TTL", key) > 86400 for key in initial)
    (b / "file1.cpp").write_text("int edited_function() { return 99; }\n")
    edited = run(b, 1)
    assert edited.stdout != cold.stdout
    assert edited.stdout == run(b, 3, flags=("--no-cache",)).stdout == run(b, 0).stdout
    assert len(metadata()) == 7
    # Both cold writers share a fresh project and overlapping content, with two processes only.
    concurrent_env = {"RIPWIRE_REDIS_PROJECT": "concurrent"}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(run, path, None, concurrent_env) for path in (a, b)]
        results = [future.result() for future in futures]
    assert results[0].stdout == cold.stdout and results[1].stdout == edited.stdout
    assert all(b"Redis cache" not in result.stderr for result in results)
    assert run(a, 0, concurrent_env).stdout == cold.stdout
    assert run(b, 0, concurrent_env).stdout == edited.stdout
    metadata()
    if partial:
        denied = run(b, 0, partial)
        assert denied.stdout == edited.stdout
        assert len([line for line in denied.stderr.splitlines() if b"Redis cache" in line]) == 1, denied.stderr
        assert run(b, 0).stdout == edited.stdout
        print("  PASS  partial ACL denies refresh while verified hits and deterministic output survive")
    print("  PASS  RESP matrix: independent cold/warm/edit/concurrent checkouts, TYPE, TTL and hit refresh")


def cleanup_controls(scratch):
    class FakeAdmin:
        def __init__(self):
            self.keys, self.deleted, self.foreign, self.endless = set(), [], False, False

        def command(self, *args):
            if args[0] == "SCAN":
                return [b"1" if self.endless else b"0", [b"foreign"] if self.foreign else sorted(self.keys)]
            assert args[0] in ("UNLINK", "DEL")
            self.deleted.append(args[1]); self.keys.remove(args[1])
            return 1

    fake = FakeAdmin()
    ledger = NamespaceLedger(fake, "cleanup-control", scratch / "control.keys")
    assert ledger.prefix == b"rw:v1:" + hashlib.sha256(b"cleanup-control").hexdigest().encode() + b":"
    first, late = ledger.prefix + b"first", ledger.prefix + b"unrecorded"
    fake.keys.add(first); ledger.capture(); fake.keys.add(late); ledger.cleanup()
    assert fake.deleted == [first] and fake.keys == {late}
    assert ledger.manifest.read_text().strip() == first.hex()
    for arm in ("foreign", "endless"):
        setattr(fake, arm, True)
        refused = False
        try:
            ledger.capture()
        except AssertionError as error:
            refused = bool(str(error))
        assert refused, f"cleanup {arm} control did not fire"
        setattr(fake, arm, False)
    print("  PASS  cleanup records exact keys, preserves unrecorded keys, refuses foreign keys and caps SCAN")


def require_acl_denial(identity, command):
    try:
        identity.command(*command)
    except RedisError as error:
        assert "NOPERM" in str(error)
    else:
        raise AssertionError("dedicated ACL identity has excessive privileges")


def provision_ci_users(admin, ledger, url, env, users):
    assert os.environ.get("CI") == "true", "ACL provisioning is restricted to the explicit CI leg"
    partial = None
    for label in ("full", "partial"):
        user = "ripwire-test-" + secrets.token_hex(16)
        secret = secrets.token_hex(32)
        users.append(user)
        rules = ["ACL", "SETUSER", user, "reset", "on", ">" + secret,
                 "~rw:v1:*", "+ping", "+select", "+get", "+mget", "+set", "+expire", "+del"]
        if label == "partial":
            rules.append("-expire")
        assert admin.command(*rules) == b"OK"
        credentials = dict(RIPWIRE_REDIS_USERNAME=user, RIPWIRE_REDIS_PASSWORD=secret)
        identity = RedisAdmin(url, user, secret)
        # Verify the production keyspace boundary and absent admin privilege on the actual server.
        require_acl_denial(identity, ("GET", b"outside:" + ledger.prefix))
        require_acl_denial(identity, ("GET", b"ripwire:" + ledger.prefix))
        require_acl_denial(identity, ("GET", b"rw:v2:" + ledger.prefix))
        require_acl_denial(identity, ("SCAN", 0))
        if label == "full":
            env.update(credentials)
        else:
            partial = credentials
            require_acl_denial(identity, ("EXPIRE", ledger.prefix + b"missing", 10))
    return partial


def finish(ledger, users, server):
    try:
        ledger.capture()
        ledger.cleanup()
        print(f"  PASS  cleaned {len(ledger.recorded)} recorded keys from the random test namespace")
    finally:
        try:
            for user in users:
                ledger.admin.command("ACL", "DELUSER", user)
        finally:
            if server:
                server.terminate(); server.wait(timeout=5)


def main():
    mode, binary = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
    server = None
    with tempfile.TemporaryDirectory(prefix="redis-real-") as directory:
        scratch = pathlib.Path(directory)
        cleanup_controls(scratch)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("RIPWIRE_REDIS_") and key != "RIPWIRE_CACHE_BACKEND"}
        namespace = "real-gate-" + secrets.token_hex(24)
        username = os.environ.get("RIPWIRE_REDIS_TEST_USERNAME", "")
        password = os.environ.get("RIPWIRE_REDIS_TEST_PASSWORD", "")
        if mode == "--fixture":
            server = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).with_name("redis_stub.py"))],
                                      stdout=subprocess.PIPE, text=True)
            ports = json.loads(server.stdout.readline())
            url = f'redis://127.0.0.1:{ports["tcp_port"]}'
            username = password = ""
        else:
            url = os.environ["RIPWIRE_REDIS_TEST_URL"]
        admin = RedisAdmin(url, username, password)
        ledger = NamespaceLedger(admin, namespace, scratch / "created.keys")
        users, partial = [], None
        try:
            assert admin.command("PING") == b"PONG"
            if mode == "--ci-acl":
                partial = provision_ci_users(admin, ledger, url, env, users)
            else:
                env.update(RIPWIRE_REDIS_USERNAME=username, RIPWIRE_REDIS_PASSWORD=password)
            for name in ("tmp", "xdg", "home"):
                (scratch / name).mkdir()
            env.update(RIPWIRE_REDIS_URL=url, RIPWIRE_REDIS_NAMESPACE=namespace, RIPWIRE_REDIS_TTL_DAYS="2",
                       RIPWIRE_REDIS_TIMEOUT_MS="1000", RIPWIRE_CACHE_STATS="1", TMPDIR=str(scratch / "tmp"),
                       XDG_CACHE_HOME=str(scratch / "xdg"), HOME=str(scratch / "home"))
            run_matrix(binary, scratch, ledger, env, partial)
            assert not [path for name in ("tmp", "xdg", "home") for path in (scratch / name).rglob("*") if path.is_file()]
        finally:
            finish(ledger, users, server)


if __name__ == "__main__":
    main()
