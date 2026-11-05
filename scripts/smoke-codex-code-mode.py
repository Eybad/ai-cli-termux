import argparse
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import time


def receive(stream, deadline):
    def read(size):
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
                raise TimeoutError("Host response timed out")
            chunk = os.read(stream.fileno(), size - len(data))
            if not chunk:
                raise EOFError("Host closed stdout before the final result")
            data.extend(chunk)
        return data

    size = struct.unpack("<I", read(4))[0]
    if size > 1_000_000:
        raise ValueError("Host response exceeds the smoke test limit")
    return json.loads(read(size))


def execute(host, source, timeout):
    deadline = time.monotonic() + timeout
    process = subprocess.Popen(
        [str(host)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )

    def request(message):
        payload = json.dumps(message).encode()
        process.stdin.write(struct.pack("<I", len(payload)) + payload)
        process.stdin.flush()
        return receive(process.stdout, deadline)

    try:
        ready = request({
            "type": "connection/hello", "supportedVersions": [1],
            "requiredCapabilities": [], "optionalCapabilities": [],
        })
        if ready.get("type") != "connection/ready" or ready.get("selectedVersion") != 1:
            raise ValueError("Host did not negotiate protocol version 1")
        opened = request({
            "type": "operation/request", "id": 1,
            "request": {"method": "session/open", "sessionId": "cache-smoke"},
        })
        if (opened.get("id") != 1
                or opened.get("result", {}).get("status") != "ok"
                or opened.get("result", {}).get("value", {}).get("type") != "session/ready"):
            raise ValueError("Host did not open the synthetic session")
        response = request({
            "type": "operation/request", "id": 2,
            "request": {
                "method": "session/execute", "sessionId": "cache-smoke",
                "request": {
                    "tool_call_id": "cache-smoke", "enabled_tools": [],
                    "source": source, "yield_time_ms": 10000,
                    "max_output_tokens": 1000,
                },
            },
        })
        if (response.get("id") != 2
                or response.get("result", {}).get("status") != "ok"
                or response.get("result", {}).get("value", {}).get("type") != "execution/started"):
            raise ValueError("Host did not start execution")
        response = receive(process.stdout, deadline)
        if response.get("type") != "execute/initialResponse" or response.get("id") != 2:
            raise ValueError("Host did not return the final execution response")
        result = response.get("result", {})
        value = result.get("value", {}).get("Result", {})
        if (result.get("status") != "ok" or value.get("error_text") is not None
                or value.get("content_items") != [{"type": "input_text", "text": "true"}]):
            raise ValueError("Host did not return true without an execution error")
        process.stdin.close()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Host shutdown timed out")
        if process.wait(timeout=remaining) != 0:
            raise ValueError(f"Host exited with status {process.returncode}")
    finally:
        if not process.stdin.closed:
            process.stdin.close()
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host", type=Path)
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    for source in ('text(/a|b/.test("alpha"));', 'text(/[ab]/.test("alpha"));'):
        execute(args.host.resolve(), source, args.timeout)
        print(f"PASS: {source}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, EOFError, ValueError, TimeoutError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
