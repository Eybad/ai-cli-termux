import argparse
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import time


HTTP2_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
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
FLAG_PADDED = 0x8
FLAG_PRIORITY = 0x20

MAX_MESSAGE_BYTES = 1_000_000


def encode_varint(value):
    if value < 0:
        raise ValueError("Protobuf varint must be non-negative")
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
    while offset < len(data):
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if not (byte & 0x80):
            return value, offset
        shift += 7
        if shift > 63:
            raise ValueError("Protobuf varint overflow")
    raise ValueError("Truncated protobuf varint")


def encode_string_field(field_number, text):
    encoded = text.encode("utf-8")
    return encode_varint((field_number << 3) | 2) + encode_varint(len(encoded)) + encoded


def encode_uint64_field(field_number, value):
    return encode_varint((field_number << 3) | 0) + encode_varint(value)


def decode_fields(data):
    fields = []
    offset = 0
    while offset < len(data):
        tag, offset = decode_varint(data, offset)
        field_number = tag >> 3
        wire_type = tag & 0x7
        if wire_type == 0:
            value, offset = decode_varint(data, offset)
        elif wire_type == 1:
            if offset + 8 > len(data):
                raise ValueError("Truncated 64-bit protobuf field")
            value = data[offset:offset + 8]
            offset += 8
        elif wire_type == 2:
            length, offset = decode_varint(data, offset)
            if offset + length > len(data):
                raise ValueError("Truncated length-delimited protobuf field")
            value = data[offset:offset + length]
            offset += length
        elif wire_type == 5:
            if offset + 4 > len(data):
                raise ValueError("Truncated 32-bit protobuf field")
            value = data[offset:offset + 4]
            offset += 4
        else:
            raise ValueError(f"Unsupported protobuf wire type {wire_type}")
        fields.append((field_number, wire_type, value))
    return fields


def encode_hpack_int(value, prefix_bits, first_byte_mask=0):
    max_prefix = (1 << prefix_bits) - 1
    if value < max_prefix:
        return bytes([first_byte_mask | value])
    out = bytearray([first_byte_mask | max_prefix])
    value -= max_prefix
    while value >= 128:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def encode_hpack_str(text):
    raw = text.encode("utf-8")
    return encode_hpack_int(len(raw), 7, 0) + raw


def encode_grpc_headers(path):
    return b"".join((
        b"\x83",  # :method: POST
        b"\x86",  # :scheme: http
        b"\x04" + encode_hpack_str(path),
        b"\x01" + encode_hpack_str("localhost"),
        b"\x00" + encode_hpack_str("content-type") + encode_hpack_str("application/grpc"),
        b"\x00" + encode_hpack_str("te") + encode_hpack_str("trailers"),
    ))


def build_frame(frame_type, flags, stream_id, payload=b""):
    length = len(payload)
    header = bytes((
        (length >> 16) & 0xFF,
        (length >> 8) & 0xFF,
        length & 0xFF,
        frame_type,
        flags,
    )) + struct.pack(">I", stream_id & 0x7FFFFFFF)
    return header + payload


def encode_grpc_message(payload):
    return struct.pack(">BI", 0, len(payload)) + payload


class GrpcStdioClient:
    def __init__(self, process, deadline):
        self.process = process
        self.deadline = deadline
        self.buffers = {}
        self.ended = set()
        self.write_raw(HTTP2_PREFACE + build_frame(FRAME_SETTINGS, 0, 0))

    def write_raw(self, data):
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def read_exact(self, size):
        stream = self.process.stdout
        data = bytearray()
        while len(data) < size:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
                raise TimeoutError("Host response timed out")
            chunk = os.read(stream.fileno(), size - len(data))
            if not chunk:
                raise EOFError("Host closed stdout before the final result")
            data.extend(chunk)
        return bytes(data)

    def read_frame(self):
        header = self.read_exact(9)
        length = (header[0] << 16) | (header[1] << 8) | header[2]
        frame_type = header[3]
        flags = header[4]
        stream_id = struct.unpack(">I", header[5:9])[0] & 0x7FFFFFFF
        if length > MAX_MESSAGE_BYTES:
            raise ValueError("Host response exceeds the smoke test limit")
        payload = self.read_exact(length) if length else b""
        return frame_type, flags, stream_id, payload

    def send_rpc(self, stream_id, path, message_bytes):
        headers = encode_grpc_headers(path)
        self.write_raw(
            build_frame(FRAME_HEADERS, FLAG_END_HEADERS, stream_id, headers)
            + build_frame(FRAME_DATA, FLAG_END_STREAM, stream_id, encode_grpc_message(message_bytes))
        )

    def send_goaway(self):
        try:
            self.write_raw(build_frame(FRAME_GOAWAY, 0, 0, struct.pack(">II", 0, 0)))
        except BrokenPipeError:
            pass

    def _consume_frame(self):
        frame_type, flags, stream_id, payload = self.read_frame()
        if frame_type == FRAME_SETTINGS:
            if not (flags & FLAG_ACK):
                try:
                    self.write_raw(build_frame(FRAME_SETTINGS, FLAG_ACK, 0))
                except BrokenPipeError:
                    pass
            return
        if frame_type == FRAME_PING:
            if not (flags & FLAG_ACK):
                try:
                    self.write_raw(build_frame(FRAME_PING, FLAG_ACK, 0, payload))
                except BrokenPipeError:
                    pass
            return
        if frame_type == FRAME_WINDOW_UPDATE:
            return
        if frame_type == FRAME_GOAWAY:
            error_code = struct.unpack(">I", payload[4:8])[0] if len(payload) >= 8 else -1
            raise ValueError(f"Host sent HTTP/2 GOAWAY (error {error_code})")
        if frame_type == FRAME_RST_STREAM:
            error_code = struct.unpack(">I", payload[:4])[0] if len(payload) >= 4 else -1
            raise ValueError(f"Host reset HTTP/2 stream {stream_id} (error {error_code})")
        if frame_type == FRAME_HEADERS:
            if flags & FLAG_END_STREAM:
                self.ended.add(stream_id)
            return
        if frame_type == FRAME_DATA:
            data = payload
            if flags & FLAG_PADDED:
                if not data:
                    raise ValueError("Malformed padded HTTP/2 DATA frame")
                pad_len = data[0]
                if pad_len >= len(data):
                    raise ValueError("Invalid HTTP/2 DATA frame padding")
                data = data[1:len(data) - pad_len]
            if data:
                self.buffers.setdefault(stream_id, bytearray()).extend(data)
                increment = struct.pack(">I", len(data))
                try:
                    self.write_raw(
                        build_frame(FRAME_WINDOW_UPDATE, 0, 0, increment)
                        + build_frame(FRAME_WINDOW_UPDATE, 0, stream_id, increment)
                    )
                except BrokenPipeError:
                    pass
            if flags & FLAG_END_STREAM:
                self.ended.add(stream_id)

    def receive_message(self, stream_id):
        buf = self.buffers.setdefault(stream_id, bytearray())
        while True:
            if len(buf) >= 5:
                compressed, size = struct.unpack(">BI", buf[:5])
                if compressed != 0:
                    raise ValueError("Host returned an unsupported compressed gRPC message")
                if size > MAX_MESSAGE_BYTES:
                    raise ValueError("Host response exceeds the smoke test limit")
                if len(buf) >= 5 + size:
                    message = bytes(buf[5:5 + size])
                    del buf[:5 + size]
                    return message
            if stream_id in self.ended:
                raise EOFError("Host closed gRPC stream before the final result")
            self._consume_frame()

    def wait_stream_end(self, stream_id):
        while stream_id not in self.ended:
            self._consume_frame()


def parse_session_opened(message):
    for field_num, wire_type, value in decode_fields(message):
        if field_num == 1 and wire_type == 2:
            for inner_num, inner_type, inner_val in decode_fields(value):
                if inner_num == 1 and inner_type == 2:
                    session_id = inner_val.decode("utf-8")
                    if session_id:
                        return session_id
    raise ValueError("Host did not open the synthetic session")


def parse_execution_started(message, expected_execution_id):
    for field_num, wire_type, value in decode_fields(message):
        if field_num == 1 and wire_type == 2:
            execution_id = ""
            cell_id = ""
            for inner_num, inner_type, inner_val in decode_fields(value):
                if inner_num == 1 and inner_type == 2:
                    execution_id = inner_val.decode("utf-8")
                elif inner_num == 2 and inner_type == 2:
                    cell_id = inner_val.decode("utf-8")
            if execution_id == expected_execution_id and cell_id:
                return cell_id
    raise ValueError("Host did not start execution")


def verify_execution_outcome(message):
    outcome_bytes = None
    for field_num, wire_type, value in decode_fields(message):
        if field_num == 2 and wire_type == 2:
            outcome_bytes = value
    if outcome_bytes is None:
        raise ValueError("Host did not return the final execution response")

    texts = []
    other_content = False
    completed_bytes = None
    non_completed = False
    for field_num, wire_type, value in decode_fields(outcome_bytes):
        if field_num == 2 and wire_type == 2:
            item_text = None
            for item_num, item_type, item_val in decode_fields(value):
                if item_num == 1 and item_type == 2:
                    text = ""
                    for text_num, text_type, text_val in decode_fields(item_val):
                        if text_num == 1 and text_type == 2:
                            text = text_val.decode("utf-8")
                    item_text = text
                else:
                    other_content = True
            if item_text is not None:
                texts.append(item_text)
        elif field_num in (3, 4) and wire_type == 2:
            non_completed = True
        elif field_num == 5 and wire_type == 2:
            completed_bytes = value

    if completed_bytes is None or non_completed:
        raise ValueError("Host did not complete execution")

    error_text = None
    for field_num, wire_type, value in decode_fields(completed_bytes):
        if field_num == 1 and wire_type == 2:
            error_text = value.decode("utf-8")

    if error_text is not None or other_content or texts != ["true"]:
        raise ValueError("Host did not return true without an execution error")


def execute(host, source, timeout):
    deadline = time.monotonic() + timeout
    process = subprocess.Popen(
        [str(host)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    try:
        client = GrpcStdioClient(process, deadline)
        client.send_rpc(1, "/codex.code_mode.v1.CodeModeHost/OpenSession", b"")
        session_id = parse_session_opened(client.receive_message(1))

        execute_request = b"".join((
            encode_string_field(1, session_id),
            encode_string_field(2, "cache-smoke"),
            encode_string_field(3, "cache-smoke"),
            encode_string_field(4, source),
            encode_uint64_field(6, 10000),
            encode_uint64_field(7, 1000),
        ))
        client.send_rpc(3, "/codex.code_mode.v1.CodeModeHost/Execute", execute_request)
        parse_execution_started(client.receive_message(3), "cache-smoke")
        verify_execution_outcome(client.receive_message(3))
        client.wait_stream_end(3)

        client.send_goaway()
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Host shutdown timed out")
        if process.wait(timeout=remaining) != 0:
            raise ValueError(f"Host exited with status {process.returncode}")
    finally:
        if not process.stdin.closed:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
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
