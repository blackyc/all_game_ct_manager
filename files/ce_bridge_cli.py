#!/usr/bin/env python3
"""Minimal command-line client for the Cheat Engine MCP bridge.

Talks directly to the Lua bridge's Named Pipe
(``\\\\.\\pipe\\CE_MCP_Bridge_v99``) using the same length-prefixed
JSON-RPC framing as ``MCP_Server/mcp_cheatengine.py``.  This exists so the
bridge can be driven from a shell without wiring an MCP client, e.g.

    python ce_bridge_cli.py ping
    python ce_bridge_cli.py call get_process_info
    python ce_bridge_cli.py call read_integer "{\"address\":\"0x1234\",\"type\":\"int\"}"
    python ce_bridge_cli.py list          # every method the bridge exposes
    python ce_bridge_cli.py list read     # only methods containing "read"

Requires an already-loaded bridge inside Cheat Engine and ``pywin32``.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import struct
import sys
import time

PIPE_NAME = r"\\.\pipe\CE_MCP_Bridge_v99"
MAX_RESPONSE_SIZE_BYTES = 16 * 1024 * 1024
DEFAULT_TIMEOUT = float(os.environ.get("CE_MCP_TIMEOUT", "30"))
LUA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "MCP_Server", "ce_mcp_bridge.lua")


def _pipe():
    try:
        import win32file  # noqa: F401  (imported for availability check)
        import win32pipe
    except ImportError:
        sys.exit("pywin32 is missing. Run: python -m pip install -r MCP_Server/requirements.txt")
    return win32file, win32pipe, pywintypes_error()


def pywintypes_error():
    import pywintypes

    return pywintypes.error


def connect(timeout=DEFAULT_TIMEOUT):
    win32file, win32pipe, win_error = _pipe()
    deadline = time.time() + timeout
    last_error = None
    while True:
        try:
            handle = win32file.CreateFile(
                PIPE_NAME,
                win32file.GENERIC_READ | win32file.GENERIC_WRITE,
                0,
                None,
                win32file.OPEN_EXISTING,
                0,
                None,
            )
            win32pipe.SetNamedPipeHandleState(
                handle, win32pipe.PIPE_READMODE_BYTE, None, None
            )
            return handle
        except win_error as exc:  # noqa: PERF203
            last_error = exc
            if time.time() >= deadline:
                raise ConnectionError(
                    "Cheat Engine bridge pipe is not reachable "
                    f"({PIPE_NAME}). Load MCP_Server/ce_mcp_bridge.lua in Cheat Engine "
                    "and wait for the '[MCP v12.0.0] MCP Server Listening' log line. "
                    f"Last error: {exc}"
                ) from exc
            time.sleep(0.25)


def _read_exact(win32file, handle, size):
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = win32file.ReadFile(handle, remaining)[1]
        if not chunk:
            raise ConnectionError("Connection closed while reading from the CE pipe.")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def send(method, params=None, timeout=DEFAULT_TIMEOUT):
    win32file, _, _ = _pipe()
    handle = connect(timeout=timeout)
    try:
        request = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
            "id": int(time.time() * 1000),
        }
        payload = json.dumps(request).encode("utf-8")
        win32file.WriteFile(handle, struct.pack("<I", len(payload)))
        win32file.WriteFile(handle, payload)

        header = _read_exact(win32file, handle, 4)
        length = struct.unpack("<I", header)[0]
        if length > MAX_RESPONSE_SIZE_BYTES:
            raise ConnectionError(f"Response too large: {length} bytes")
        body = _read_exact(win32file, handle, length)
        return json.loads(body.decode("utf-8"))
    finally:
        try:
            win32file.CloseHandle(handle)
        except Exception:
            pass


def list_methods(pattern=None):
    try:
        with open(LUA_PATH, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        sys.exit(f"Cannot read {LUA_PATH}: {exc}")

    names = sorted(set(re.findall(r"^\s{4}([a-z0-9_]+)\s*=\s*cmd_[A-Za-z0-9_]+,", text, re.M)))
    aliases = sorted(set(re.findall(r"^\s*commandAliases\s*=", text, re.M)))
    if pattern:
        needle = pattern.lower()
        names = [n for n in names if needle in n]
    return names, bool(aliases)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Drive the Cheat Engine MCP bridge from a shell.")
    parser.add_argument(
        "action",
        nargs="?",
        default="ping",
        help="ping | call <method> [json-params] | list [substring]",
    )
    parser.add_argument("method_or_pattern", nargs="?", help="method name (call) or substring (list)")
    parser.add_argument("params", nargs="?", help="JSON object with the method parameters")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="pipe timeout in seconds")
    parser.add_argument("--raw", action="store_true", help="print the raw JSON-RPC envelope")
    parser.add_argument(
        "--params-file",
        help="read the JSON params object from this file instead of the positional argument",
    )
    parser.add_argument(
        "--lua-file",
        help="wrap the contents of this Lua file as the 'code' param (evaluate_lua helper)",
    )
    args = parser.parse_args(argv)

    if args.action == "list":
        names, _ = list_methods(args.method_or_pattern)
        print(f"{len(names)} bridge methods:")
        for name in names:
            print(" ", name)
        return 0

    if args.action == "ping":
        method, params = "ping", {}
    elif args.action == "call":
        if not args.method_or_pattern:
            sys.exit("usage: ce_bridge_cli.py call <method> ['{json params}']")
        method = args.method_or_pattern
        if args.lua_file:
            with open(args.lua_file, "r", encoding="utf-8") as fh:
                params = {"code": fh.read()}
        elif args.params_file:
            with open(args.params_file, "r", encoding="utf-8") as fh:
                params = json.load(fh)
        elif args.params:
            params = json.loads(args.params)
        else:
            params = {}
    else:
        sys.exit(f"unknown action: {args.action}")

    try:
        response = send(method, params, timeout=args.timeout)
    except ConnectionError as exc:
        print(f"CONNECTION ERROR: {exc}", file=sys.stderr)
        return 2
    except TimeoutError as exc:
        print(f"TIMEOUT: {exc}", file=sys.stderr)
        return 3

    if args.raw:
        print(json.dumps(response, indent=2, ensure_ascii=False))
        return 0

    if "error" in response:
        print(f"ERROR: {json.dumps(response['error'], ensure_ascii=False)}", file=sys.stderr)
        return 1
    print(json.dumps(response.get("result", response), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
