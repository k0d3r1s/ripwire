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
        self.lock = threading.RLock()
        self.username = username.encode() if username else None
        self.password = password.encode() if password else None
        self.log_path = log_path
        self.clock = 0.0
        self.databases = {}
        self.commands = []
        self.next_index = 0
        self.faults = {"before": {}, "after": {}}
        self.barriers = {}
        self.command_barriers = {}

    def record(self, command):
        encoded = struct.pack("!I", len(command))
        for argument in command:
            encoded += struct.pack("!I", len(argument)) + argument
        with self.lock:
            command_index = self.next_index
            self.next_index += 1
            self.commands.append((command_index, encoded))
            if self.log_path:
                with open(self.log_path, "ab") as stream:
                    stream.write(struct.pack("!I", len(encoded)))
                    stream.write(encoded)
            return command_index

    def schedule_fault(self, phase, command_index, fault):
        with self.lock:
            self.faults[phase][command_index] = fault

    def take_fault(self, phase, command_index, modes=None):
        with self.lock:
            fault = self.faults[phase].get(command_index)
            if fault is not None and (modes is None or fault.get("mode") in modes):
                del self.faults[phase][command_index]
                return fault
            return None

    def schedule_barrier(self, name, command_index):
        with self.lock:
            barrier = self.barriers.setdefault(name, threading.Event())
            barrier.clear()
            self.command_barriers[command_index] = name

    def barrier_for(self, command_index):
        with self.lock:
            name = self.command_barriers.pop(command_index, None)
            return None if name is None else self.barriers[name]

    def release_barrier(self, name):
        with self.lock:
            barrier = self.barriers.setdefault(name, threading.Event())
            barrier.set()

def state_database(state, index):
    return state.databases.setdefault(index, {})


def state_live(state, index, key):
    database = state_database(state, index)
    item = database.get(key)
    if item is not None and item[1] is not None and item[1] <= state.clock:
        del database[key]
        return None
    return item


def execute_session_command(state, name, args, selected, authenticated):
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
    return None


def execute_read_command(state, name, args, selected):
    if name == b"GET" and len(args) == 1:
        item = state_live(state, selected, args[0])
        return bulk(None if item is None else item[0])
    values = []
    for key in args:
        item = state_live(state, selected, key)
        values.append(bulk(None if item is None else item[0]))
    return array(values)


def execute_set_command(state, args, selected):
    if len(args) < 2:
        return None
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
            return b"-ERR syntax error\r\n"
    if nx and state_live(state, selected, key) is not None:
        return bulk(None)
    state_database(state, selected)[key] = (value, expiry)
    return b"+OK\r\n"


def execute_metadata_command(state, name, args, selected):
    database = state_database(state, selected)
    if name == b"EXPIRE":
        item = state_live(state, selected, args[0])
        if item is None:
            return b":0\r\n"
        database[args[0]] = (item[0], state.clock + int(args[1]))
        return b":1\r\n"
    item = state_live(state, selected, args[0])
    if name == b"TYPE":
        return b"+string\r\n" if item is not None else b"+none\r\n"
    if item is None:
        ttl = -2
    elif item[1] is None:
        ttl = -1
    else:
        ttl = max(0, int(item[1] - state.clock))
    return b":" + str(ttl).encode() + b"\r\n"


def execute_collection_command(state, name, args, selected):
    database = state_database(state, selected)
    if name == b"SCAN":
        pattern = args[2] if len(args) >= 3 and args[1].upper() == b"MATCH" else b"*"
        keys = [bulk(key) for key in sorted(database)
                if state_live(state, selected, key) is not None
                and fnmatch.fnmatchcase(key.decode("latin1"), pattern.decode("latin1"))]
        return array([bulk(b"0"), array(keys)])
    deleted = 0
    for key in args:
        if state_live(state, selected, key) is not None:
            del database[key]
            deleted += 1
    return b":" + str(deleted).encode() + b"\r\n"


def execute_redis_command(state, command, selected, authenticated):
    name = command[0].upper()
    args = command[1:]
    session_response = execute_session_command(state, name, args, selected, authenticated)
    if session_response is not None:
        return session_response
    response = None
    if name == b"GET" and len(args) == 1 or name == b"MGET" and args:
        response = execute_read_command(state, name, args, selected)
    elif name == b"SET":
        response = execute_set_command(state, args, selected)
    elif name == b"EXPIRE" and len(args) == 2 and args[1].isdigit() or name in (b"TTL", b"TYPE") and len(args) == 1:
        response = execute_metadata_command(state, name, args, selected)
    elif name == b"SCAN" and args or name in (b"DEL", b"UNLINK") and args:
        response = execute_collection_command(state, name, args, selected)
    if response is None:
        response = b"-ERR unsupported command\r\n"
    return response, selected, authenticated


def apply_before_fault(response, fault):
    if not fault:
        return response
    mode = fault.get("mode")
    if mode == "auth_error":
        return b"-WRONGPASS " + fault.get("message", "forced").encode() + b"\r\n"
    if mode == "missing_record":
        return bulk(None)
    if mode == "corrupt_payload":
        return bulk(base64.b64decode(fault["value"]))
    if mode == "server_error":
        return b"-ERR " + fault.get("message", "forced").encode() + b"\r\n"
    return response


def serve_redis_connection(handler):
    state = handler.server.state
    with state.lock:
        next_index = state.next_index
    pre_read = state.take_fault("before", next_index, {"non_reader"})
    if pre_read:
        time.sleep(float(pre_read.get("seconds", 1.0)))
        return
    selected = 0
    authenticated = state.password is None
    while True:
        command = handler.read_command()
        command_index = state.record(command)
        barrier = state.barrier_for(command_index)
        if barrier is not None:
            barrier.wait()
        before = state.take_fault("before", command_index)
        if before and before.get("mode") == "drop":
            return
        with state.lock:
            response, selected, authenticated = execute_redis_command(state, command, selected, authenticated)
        response = apply_before_fault(response, before)
        if not handler.send_response(response, state.take_fault("after", command_index)):
            return


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

    def handle(self):
        try:
            serve_redis_connection(self)
        except (ConnectionError, EOFError, OSError, ValueError):
            return


def admin_mutation(state, operation, request):
    if operation == "advance_clock":
        with state.lock:
            state.clock += float(request.get("seconds", 0))
        return {"ok": True}
    if operation == "delete":
        key = base64.b64decode(request["key"])
        with state.lock:
            for database in state.databases.values():
                database.pop(key, None)
        return {"ok": True}
    if operation == "replace":
        key = base64.b64decode(request["key"])
        value = base64.b64decode(request["value"])
        database = int(request.get("db", 0))
        with state.lock:
            state.databases.setdefault(database, {})[key] = (value, None)
        return {"ok": True}
    return None


def admin_fault_control(state, operation, request):
    if operation in ("fail_before", "fail_after"):
        phase = "before" if operation == "fail_before" else "after"
        fault = {"mode": request.get("mode", "drop"), "seconds": request.get("seconds", 1.0)}
        state.schedule_fault(phase, int(request["command_index"]), fault)
        return {"ok": True}
    if operation == "deadline":
        fault = {"mode": "delay", "seconds": request.get("seconds", 1.0)}
        state.schedule_fault("after", int(request["command_index"]), fault)
        return {"ok": True}
    if operation in ("auth_error", "missing_record", "corrupt_payload", "server_error"):
        fault = {"mode": operation}
        if "message" in request:
            fault["message"] = request["message"]
        if "value" in request:
            fault["value"] = request["value"]
        state.schedule_fault("before", int(request["command_index"]), fault)
        return {"ok": True}
    return None


def admin_coordination(state, operation, request):
    if operation == "hold":
        state.schedule_barrier(str(request["barrier"]), int(request["command_index"]))
        return {"ok": True}
    if operation == "release":
        state.release_barrier(str(request["barrier"]))
        return {"ok": True}
    if operation == "command_log":
        with state.lock:
            commands = [{"index": command_index, "record": base64.b64encode(command).decode()}
                        for command_index, command in state.commands]
            return {"commands": commands, "next_index": state.next_index}
    return None


def dispatch_admin_request(state, request):
    operation = request.get("op")
    for response in (admin_mutation(state, operation, request),
                     admin_fault_control(state, operation, request),
                     admin_coordination(state, operation, request)):
        if response is not None:
            return response
    return {"ok": False, "error": "unknown operation"}


class AdminHandler(socketserver.StreamRequestHandler):
    def response(self, value):
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        self.request.sendall(struct.pack("!I", len(encoded)) + encoded)

    def handle(self):
        try:
            request = json.loads(self.rfile.readline())
            self.response(dispatch_admin_request(self.server.state, request))
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
