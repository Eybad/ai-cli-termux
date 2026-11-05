import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SMOKE = Path(__file__).with_name("smoke-codex-code-mode.py")
HOST = '''
import json
import struct
import sys
import time

def receive():
    size = struct.unpack("<I", sys.stdin.buffer.read(4))[0]
    return json.loads(sys.stdin.buffer.read(size))

def send(message):
    payload = json.dumps(message).encode()
    sys.stdout.buffer.write(struct.pack("<I", len(payload)) + payload)
    sys.stdout.buffer.flush()

receive()
send({"type": "connection/ready", "selectedVersion": 1})
receive()
send({"type": "operation/response", "id": 1, "result": {
    "status": "ok", "value": {"type": "session/ready"}}})
request = receive()["request"]["request"]
if request["enabled_tools"] != []:
    sys.exit(4)
send({"type": "operation/response", "id": 2, "result": {
    "status": "ok", "value": {"type": "execution/started"}}})
if MODE == "started_only":
    sys.exit(0)
if MODE == "stall":
    time.sleep(30)
if MODE == "class_failure" and "[ab]" in request["source"]:
    sys.exit(11)
result = {"status": "ok", "value": {"Result": {
    "content_items": [{"type": "input_text", "text": "true"}],
    "error_text": None}}}
if MODE == "false_result":
    result["value"]["Result"]["content_items"][0]["text"] = "false"
if MODE == "execution_error":
    result["value"]["Result"]["error_text"] = "Synthetic execution failure"
send({"type": "execute/initialResponse", "id": 2, "result": result})
if MODE == "bad_exit":
    sys.exit(11)
if MODE == "shutdown_stall":
    time.sleep(30)
sys.stdin.buffer.read()
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

    def test_nonzero_exit_after_true_fails(self):
        result = self.run_host("bad_exit")
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
