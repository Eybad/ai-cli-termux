import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SMOKE = Path(__file__).with_name("smoke-codex-code-mode.py")
HOST = '''
import os
import struct
import sys
import time

PREFACE = b"PRI * HTTP/2.0\\r\\n\\r\\nSM\\r\\n\\r\\n"
FRAME_DATA = 0x0
FRAME_HEADERS = 0x1
FRAME_RST_STREAM = 0x3
FRAME_SETTINGS = 0x4
FRAME_PING = 0x6
FRAME_GOAWAY = 0x7
FRAME_WINDOW_UPDATE = 0x8

FLAG_END_STREAM = 0x1
FLAG_ACK = 0x1
FLAG_END_HEADERS = 0x4


def encode_varint(value):
    out = bytearray()
    while True:
        chunk = value & 0x7F
        value >>= 7
        if value:
            out.append(chunk | 0x80)
        else:
            out.append(chunk)
            return bytes(out)


def decode_varint(data, offset):
    value = 0
    shift = 0
    while True:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if not (byte & 0x80):
            return value, offset
        shift += 7


def encode_bytes(field_number, payload):
    return encode_varint((field_number << 3) | 2) + encode_varint(len(payload)) + payload


def encode_string(field_number, text):
    return encode_bytes(field_number, text.encode("utf-8"))


def decode_fields(data):
    fields = {}
    offset = 0
    while offset < len(data):
        tag, offset = decode_varint(data, offset)
        field_number = tag >> 3
        wire_type = tag & 0x7
        if wire_type == 0:
            value, offset = decode_varint(data, offset)
        elif wire_type == 2:
            length, offset = decode_varint(data, offset)
            value = data[offset:offset + length]
            offset += length
        else:
            sys.exit(2)
        fields.setdefault(field_number, []).append(value)
    return fields


def build_frame(frame_type, flags, stream_id, payload=b""):
    length = len(payload)
    return bytes((
        (length >> 16) & 0xFF,
        (length >> 8) & 0xFF,
        length & 0xFF,
        frame_type,
        flags,
    )) + struct.pack(">I", stream_id) + payload


def send_frame(frame_type, flags, stream_id, payload=b""):
    sys.stdout.buffer.write(build_frame(frame_type, flags, stream_id, payload))
    sys.stdout.buffer.flush()


def send_grpc_message(stream_id, payload, end_stream=False):
    framed = struct.pack(">BI", 0, len(payload)) + payload
    send_frame(FRAME_DATA, FLAG_END_STREAM if end_stream else 0, stream_id, framed)


def read_exact(size):
    data = sys.stdin.buffer.read(size)
    if len(data) < size:
        return None
    return data


def read_frame():
    header = read_exact(9)
    if header is None:
        return None
    length = (header[0] << 16) | (header[1] << 8) | header[2]
    frame_type = header[3]
    flags = header[4]
    stream_id = struct.unpack(">I", header[5:9])[0] & 0x7FFFFFFF
    payload = read_exact(length) if length else b""
    if payload is None:
        return None
    return frame_type, flags, stream_id, payload


def read_rpc_request(expected_stream):
    buf = bytearray()
    while True:
        frame = read_frame()
        if frame is None:
            sys.exit(3)
        frame_type, flags, stream_id, payload = frame
        if frame_type == FRAME_SETTINGS and not (flags & FLAG_ACK):
            send_frame(FRAME_SETTINGS, FLAG_ACK, 0)
            continue
        if frame_type == FRAME_PING and not (flags & FLAG_ACK):
            send_frame(FRAME_PING, FLAG_ACK, 0, payload)
            continue
        if frame_type in (FRAME_SETTINGS, FRAME_WINDOW_UPDATE, FRAME_HEADERS):
            continue
        if frame_type == FRAME_DATA and stream_id == expected_stream:
            buf.extend(payload)
            if flags & FLAG_END_STREAM:
                compressed, size = struct.unpack(">BI", buf[:5])
                if compressed != 0 or len(buf) != 5 + size:
                    sys.exit(4)
                return bytes(buf[5:])


if read_exact(len(PREFACE)) != PREFACE:
    sys.exit(2)
send_frame(FRAME_SETTINGS, 0, 0)

read_rpc_request(1)
send_frame(FRAME_HEADERS, FLAG_END_HEADERS, 1, b"\\x88")
session_opened = encode_bytes(1, encode_string(1, "session-1"))
send_grpc_message(1, session_opened)

execute_req = decode_fields(read_rpc_request(3))
if execute_req.get(1) != [b"session-1"] or 5 in execute_req:
    sys.exit(4)
execution_id = execute_req[2][0].decode("utf-8")
source = execute_req[4][0].decode("utf-8")

if MODE == "trailers_only_error":
    send_frame(FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 3, b"\\x88")
    sys.exit(0)

send_frame(FRAME_HEADERS, FLAG_END_HEADERS, 3, b"\\x88")
started = encode_bytes(1, encode_string(1, execution_id) + encode_string(2, "cell-1"))
send_grpc_message(3, started)

if MODE == "started_only":
    sys.exit(0)
if MODE == "rst_stream":
    send_frame(FRAME_RST_STREAM, 0, 3, struct.pack(">I", 2))
    sys.exit(0)
if MODE == "stall":
    time.sleep(30)
if MODE == "class_failure" and "[ab]" in source:
    sys.exit(11)

text_value = "false" if MODE == "false_result" else "true"
content_item = encode_bytes(1, encode_string(1, text_value))
if MODE == "yielded_outcome":
    outcome_fields = encode_string(1, "cell-1") + encode_bytes(2, content_item) + encode_bytes(3, b"")
else:
    completed = encode_string(1, "Synthetic execution failure") if MODE == "execution_error" else b""
    outcome_fields = encode_string(1, "cell-1") + encode_bytes(2, content_item) + encode_bytes(5, completed)

if MODE == "bad_exit_closed_stdin":
    os.close(0)

send_grpc_message(3, encode_bytes(2, outcome_fields))
send_frame(FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 3, b"")

if MODE in ("bad_exit", "bad_exit_closed_stdin"):
    sys.exit(11)
if MODE == "shutdown_stall":
    time.sleep(30)

while read_frame() is not None:
    pass
'''


class CodeModeSmokeTests(unittest.TestCase):
    def run_host(self, mode):
        temp_root = os.environ.get("TMPDIR")
        if not temp_root and os.environ.get("PREFIX"):
            temp_root = str(Path(os.environ["PREFIX"]) / "tmp")
        with tempfile.TemporaryDirectory(prefix="codex-smoke-test.", dir=temp_root) as directory:
            host = Path(directory) / "host"
            host.write_text(f"#!{sys.executable}\nMODE = {mode!r}\n" + HOST)
            host.chmod(0o700)
            return subprocess.run(
                [sys.executable, str(SMOKE), str(host), "--timeout", "1"],
                capture_output=True, text=True, timeout=10,
            )

    def test_both_regex_results_and_clean_shutdown_pass(self):
        result = self.run_host("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("PASS:"), 2)

    def test_execution_started_without_result_fails(self):
        result = self.run_host("started_only")
        self.assertEqual(result.returncode, 1)
        self.assertIn("before the final result", result.stderr)

    def test_character_class_is_checked_after_alternation(self):
        result = self.run_host("class_failure")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.count("PASS:"), 1)

    def test_false_result_fails(self):
        result = self.run_host("false_result")
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not return true", result.stderr)

    def test_execution_error_fails(self):
        result = self.run_host("execution_error")
        self.assertEqual(result.returncode, 1)
        self.assertIn("execution error", result.stderr)

    def test_yielded_outcome_fails(self):
        result = self.run_host("yielded_outcome")
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not complete execution", result.stderr)

    def test_trailers_only_error_fails(self):
        result = self.run_host("trailers_only_error")
        self.assertEqual(result.returncode, 1)
        self.assertIn("before the final result", result.stderr)

    def test_rst_stream_fails(self):
        result = self.run_host("rst_stream")
        self.assertEqual(result.returncode, 1)
        self.assertIn("reset HTTP/2 stream", result.stderr)

    def test_nonzero_exit_after_true_fails(self):
        result = self.run_host("bad_exit")
        self.assertEqual(result.returncode, 1)
        self.assertIn("exited with status 11", result.stderr)

    def test_nonzero_exit_with_closed_stdin_reports_exit_status(self):
        result = self.run_host("bad_exit_closed_stdin")
        self.assertEqual(result.returncode, 1)
        self.assertIn("exited with status 11", result.stderr)

    def test_execution_timeout_fails(self):
        result = self.run_host("stall")
        self.assertEqual(result.returncode, 1)
        self.assertIn("timed out", result.stderr)

    def test_shutdown_timeout_fails(self):
        result = self.run_host("shutdown_stall")
        self.assertEqual(result.returncode, 1)
        self.assertIn("timed out", result.stderr)


if __name__ == "__main__":
    unittest.main()
