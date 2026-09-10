#!/usr/bin/env python3
"""Deterministic stdlib-only RESP2 stub used by redisclientcheck.sh."""

import argparse
import base64
import fnmatch
import json
import os
import signal
import socket
import socketserver
import struct
import threading
import time


def bulk(value):
    if value is None:
        return b"$-1\r\n"
    return b"$" + str(len(value)).encode() + b"\r\n" + value + b"\r\n"


def array(values):
    return b"*" + str(len(values)).encode() + b"\r\n" + b"".join(values)


class State:
    def __init__(self, username, password, log_path):
        self.lock = threading.Lock()
        self.username = username.encode() if username else None
        self.password = password.encode() if password else None
        self.log_path = log_path
        self.clock = 0.0
        self.databases = {}
        self.commands = []
        self.next_fault = None
        self.hold = threading.Event()
        self.hold.set()

    def record(self, command):
        encoded = struct.pack("!I", len(command))
        for argument in command:
            encoded += struct.pack("!I", len(argument)) + argument
        with self.lock:
            self.commands.append(encoded)
            if self.log_path:
                with open(self.log_path, "ab") as stream:
                    stream.write(struct.pack("!I", len(encoded)))
                    stream.write(encoded)

    def take_fault(self, phase):
        with self.lock:
            fault = self.next_fault
            if fault and fault.get("phase") == phase:
                self.next_fault = None
                return fault
        return None

    def database(self, index):
        with self.lock:
            return self.databases.setdefault(index, {})

    def live(self, index, key):
        database = self.database(index)
        item = database.get(key)
        if item is not None and item[1] is not None and item[1] <= self.clock:
            del database[key]
            return None
        return item


class RedisHandler(socketserver.BaseRequestHandler):
    def read_line(self):
        data = bytearray()
        while not data.endswith(b"\r\n"):
            chunk = self.request.recv(1)
            if not chunk or len(data) > 65536:
                raise EOFError
            data += chunk
        return bytes(data[:-2])

    def read_command(self):
        line = self.read_line()
        if not line.startswith(b"*"):
            raise ValueError
        count = int(line[1:])
        if count < 1 or count > 4096:
            raise ValueError
        result = []
        for _ in range(count):
            length_line = self.read_line()
            if not length_line.startswith(b"$"):
                raise ValueError
            length = int(length_line[1:])
            if length < 0 or length > 64 * 1024 * 1024:
                raise ValueError
            value = bytearray()
            while len(value) < length + 2:
                chunk = self.request.recv(length + 2 - len(value))
                if not chunk:
                    raise EOFError
                value += chunk
            if value[-2:] != b"\r\n":
                raise ValueError
            result.append(bytes(value[:-2]))
        return result

    def send_response(self, response, fault):
        if fault:
            mode = fault.get("mode", "drop")
            if mode == "drop":
                return False
            if mode == "malformed":
                response = b"!malformed\r\n"
            elif mode == "truncate":
                self.request.sendall(response[: max(1, len(response) // 2)])
                return False
            elif mode == "delay":
                time.sleep(float(fault.get("seconds", 1.0)))
            elif mode == "slow_drip":
                delay = float(fault.get("seconds", 0.05))
                for byte in response:
                    self.request.sendall(bytes((byte,)))
                    time.sleep(delay)
                return True
        self.request.sendall(response)
        return True

    def execute(self, command, selected, authenticated):
        name = command[0].upper()
        args = command[1:]
        state = self.server.state
        if name == b"AUTH":
            expected = [state.password] if state.username is None else [state.username, state.password]
            if state.password is None or args != expected:
                return b"-WRONGPASS invalid username-password pair\r\n", selected, False
            return b"+OK\r\n", selected, True
        if state.password is not None and not authenticated:
            return b"-NOAUTH authentication required\r\n", selected, authenticated
        if name == b"SELECT" and len(args) == 1 and args[0].isdigit():
            return b"+OK\r\n", int(args[0]), authenticated
        if name == b"PING" and len(args) <= 1:
            return (b"+PONG\r\n" if not args else bulk(args[0])), selected, authenticated

        database = state.database(selected)
        if name == b"GET" and len(args) == 1:
            item = state.live(selected, args[0])
            return bulk(None if item is None else item[0]), selected, authenticated
        if name == b"MGET" and args:
            values = []
            for key in args:
                item = state.live(selected, key)
                values.append(bulk(None if item is None else item[0]))
            return array(values), selected, authenticated
        if name == b"SET" and len(args) >= 2:
            key, value = args[:2]
            nx = False
            expiry = None
            option_index = 2
            while option_index < len(args):
                option = args[option_index].upper()
                if option == b"NX":
                    nx = True
                    option_index += 1
                elif option == b"EX" and option_index + 1 < len(args) and args[option_index + 1].isdigit():
                    expiry = state.clock + int(args[option_index + 1])
                    option_index += 2
                else:
                    return b"-ERR syntax error\r\n", selected, authenticated
            if nx and state.live(selected, key) is not None:
                return bulk(None), selected, authenticated
            database[key] = (value, expiry)
            return b"+OK\r\n", selected, authenticated
        if name == b"EXPIRE" and len(args) == 2 and args[1].isdigit():
            item = state.live(selected, args[0])
            if item is None:
                return b":0\r\n", selected, authenticated
            database[args[0]] = (item[0], state.clock + int(args[1]))
            return b":1\r\n", selected, authenticated
        if name == b"TTL" and len(args) == 1:
            item = state.live(selected, args[0])
            if item is None:
                ttl = -2
            elif item[1] is None:
                ttl = -1
            else:
                ttl = max(0, int(item[1] - state.clock))
            return b":" + str(ttl).encode() + b"\r\n", selected, authenticated
        if name == b"TYPE" and len(args) == 1:
            return (b"+string\r\n" if state.live(selected, args[0]) is not None else b"+none\r\n"), selected, authenticated
        if name == b"SCAN" and args:
            pattern = b"*"
            if len(args) >= 3 and args[1].upper() == b"MATCH":
                pattern = args[2]
            keys = []
            for key in sorted(database):
                if state.live(selected, key) is not None and fnmatch.fnmatchcase(key.decode("latin1"), pattern.decode("latin1")):
                    keys.append(bulk(key))
            return array([bulk(b"0"), array(keys)]), selected, authenticated
        if name in (b"DEL", b"UNLINK") and args:
            deleted = 0
            for key in args:
                if state.live(selected, key) is not None:
                    del database[key]
                    deleted += 1
            return b":" + str(deleted).encode() + b"\r\n", selected, authenticated
        return b"-ERR unsupported command\r\n", selected, authenticated

    def handle(self):
        state = self.server.state
        before = state.take_fault("before")
        if before:
            if before.get("mode") == "non_reader":
                time.sleep(float(before.get("seconds", 1.0)))
            return
        selected = 0
        authenticated = state.password is None
        try:
            while True:
                command = self.read_command()
                state.record(command)
                state.hold.wait()
                response, selected, authenticated = self.execute(command, selected, authenticated)
                if not self.send_response(response, state.take_fault("after")):
                    return
        except (ConnectionError, EOFError, OSError, ValueError):
            return


class AdminHandler(socketserver.StreamRequestHandler):
    def response(self, value):
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        self.request.sendall(struct.pack("!I", len(encoded)) + encoded)

    def handle(self):
        try:
            request = json.loads(self.rfile.readline())
            state = self.server.state
            operation = request.get("op")
            if operation == "advance_clock":
                with state.lock:
                    state.clock += float(request.get("seconds", 0))
                self.response({"ok": True})
            elif operation == "delete":
                key = base64.b64decode(request["key"])
                with state.lock:
                    for database in state.databases.values():
                        database.pop(key, None)
                self.response({"ok": True})
            elif operation == "replace":
                key = base64.b64decode(request["key"])
                value = base64.b64decode(request["value"])
                database = int(request.get("db", 0))
                with state.lock:
                    state.databases.setdefault(database, {})[key] = (value, None)
                self.response({"ok": True})
            elif operation in ("fail_before", "fail_after"):
                with state.lock:
                    state.next_fault = {"phase": "before" if operation == "fail_before" else "after",
                                        "mode": request.get("mode", "drop"), "seconds": request.get("seconds", 1.0)}
                self.response({"ok": True})
            elif operation == "hold":
                state.hold.clear()
                self.response({"ok": True})
            elif operation == "release":
                state.hold.set()
                self.response({"ok": True})
            elif operation == "command_log":
                with state.lock:
                    commands = [base64.b64encode(command).decode() for command in state.commands]
                self.response({"commands": commands})
            else:
                self.response({"ok": False, "error": "unknown operation"})
        except Exception:
            self.response({"ok": False, "error": "invalid request"})


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


class ThreadingUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tcp-host", default="127.0.0.1")
    parser.add_argument("--tcp-port", type=int, default=0)
    parser.add_argument("--admin-port", type=int, default=0)
    parser.add_argument("--unix")
    parser.add_argument("--username")
    parser.add_argument("--password")
    parser.add_argument("--log")
    args = parser.parse_args()

    state = State(args.username, args.password, args.log)
    redis_tcp = ThreadingTCPServer((args.tcp_host, args.tcp_port), RedisHandler)
    redis_tcp.state = state
    admin = ThreadingTCPServer(("127.0.0.1", args.admin_port), AdminHandler)
    admin.state = state
    servers = [redis_tcp, admin]
    unix_server = None
    if args.unix:
        try:
            os.unlink(args.unix)
        except FileNotFoundError:
            pass
        unix_server = ThreadingUnixServer(args.unix, RedisHandler)
        unix_server.state = state
        servers.append(unix_server)

    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in servers]
    for thread in threads:
        thread.start()
    print(json.dumps({"tcp_port": redis_tcp.server_address[1], "admin_port": admin.server_address[1], "unix": args.unix}), flush=True)

    stopped = threading.Event()
    def stop(_signum, _frame):
        stopped.set()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    stopped.wait()
    for server in servers:
        server.shutdown()
        server.server_close()
    if args.unix:
        try:
            os.unlink(args.unix)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
