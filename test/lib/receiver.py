#!/usr/bin/env python3
"""Fake MicYou desktop: control TCP + audio UDP, capturing everything it sees.

Used by the unattended test tier, which cannot watch a GUI. It plays the
server's role on the wire only — handshake, ping cadence, ConnectMessage, and the
same audio-packet validation the desktop applies — and writes one JSON line per
event for analyze.py. It does not decode, resample or play audio; interop with the
real desktop is the observed tier's job (cases/human).

usage: receiver.py --tcp-port 8555 --udp-port 8556 --duration 30 --out capture.jsonl
                   [--stop-ping-after 12]
"""

import argparse
import base64
import json
import os
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wire  # noqa: E402


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def tag(field, wire_type):
    return varint((field << 3) | wire_type)


def len_field(field, payload):
    return tag(field, 2) + varint(len(payload)) + payload


def varint_field(field, value):
    return tag(field, 0) + varint(value)


def ping_frame(timestamp_ms):
    return wire.frame(wire.PACKET_MAGIC,
                      len_field(wire.WRAPPER_PING, len_field(1, varint_field(1, timestamp_ms))))


class Receiver:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.out = open(args.out, "w", encoding="utf-8")
        self.started = time.time()
        self.stats = {"audio": 0, "rejected": 0, "pings_sent": 0, "pongs": 0,
                      "bad_frames": 0, "oversize": 0, "connect": None, "mutes": 0}
        self.stop = threading.Event()
        self.connected = threading.Event()

    def emit(self, record):
        record["t"] = round(time.time() - self.started, 4)
        with self.lock:
            self.out.write(json.dumps(record) + "\n")

    def close(self):
        with self.lock:
            self.out.flush()
            self.out.close()


def control_loop(rx):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", rx.args.tcp_port))
    server.listen(1)
    server.settimeout(1.0)
    rx.emit({"kind": "meta", "tcp_port": rx.args.tcp_port, "udp_port": rx.args.udp_port,
             "pid": os.getpid()})
    while not rx.stop.is_set():
        try:
            conn, peer = server.accept()
        except socket.timeout:
            continue
        threading.Thread(target=serve_control, args=(rx, conn, peer), daemon=True).start()
    server.close()


def serve_control(rx, conn, peer):
    conn.settimeout(1.0)
    try:
        hello = recv_exact(conn, len(wire.HANDSHAKE_CLIENT))
        if hello != wire.HANDSHAKE_CLIENT:
            rx.emit({"kind": "error", "reason": "bad client handshake", "got": repr(hello)})
            return
        conn.sendall(wire.HANDSHAKE_SERVER)
        ping_thread = threading.Thread(target=ping_loop, args=(rx, conn), daemon=True)
        ping_thread.start()
        buf = b""
        while not rx.stop.is_set():
            try:
                chunk = conn.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while len(buf) >= wire.FRAME_HEADER_SIZE:
                magic, length = struct.unpack(">ii", buf[:wire.FRAME_HEADER_SIZE])
                if magic != wire.PACKET_MAGIC:
                    rx.stats["bad_frames"] += 1
                    rx.emit({"kind": "error", "reason": "bad control magic", "magic": magic})
                    return
                if length < 0 or length > wire.MAX_CONTROL_PAYLOAD_SIZE:
                    rx.stats["bad_frames"] += 1
                    rx.emit({"kind": "error", "reason": "bad control length", "length": length})
                    return
                if len(buf) < wire.FRAME_HEADER_SIZE + length:
                    break
                payload = buf[wire.FRAME_HEADER_SIZE:wire.FRAME_HEADER_SIZE + length]
                buf = buf[wire.FRAME_HEADER_SIZE + length:]
                kind, detail = wire.decode_wrapper(payload)
                if kind == "connect":
                    rx.stats["connect"] = detail
                    rx.connected.set()
                    rx.emit({"kind": "connect", "peer": "%s:%d" % peer, **detail})
                elif kind == "pong":
                    rx.stats["pongs"] += 1
                    rx.emit({"kind": "pong", "echo": detail})
                elif kind == "mute":
                    rx.stats["mutes"] += 1
                    rx.emit({"kind": "mute", "muted": detail})
        rx.stop.set()
    finally:
        conn.close()


def ping_loop(rx, conn):
    deadline = None
    if rx.args.stop_ping_after is not None:
        deadline = time.time() + rx.args.stop_ping_after
    while not rx.stop.is_set():
        if deadline is not None and time.time() > deadline:
            return
        try:
            conn.sendall(ping_frame(int(time.time() * 1000)))
            rx.stats["pings_sent"] += 1
        except OSError:
            return
        rx.stop.wait(0.5)


def udp_loop(rx):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", rx.args.udp_port))
    sock.settimeout(1.0)
    while not rx.stop.is_set():
        try:
            data, peer = sock.recvfrom(65536)
        except socket.timeout:
            continue
        except OSError:
            break
        if len(data) > wire.UDP_MAX_DATAGRAM_SIZE:
            rx.stats["oversize"] += 1
            rx.emit({"kind": "reject", "reason": "datagram %d over %d" % (
                len(data), wire.UDP_MAX_DATAGRAM_SIZE)})
            continue
        if len(data) < wire.FRAME_HEADER_SIZE:
            rx.stats["bad_frames"] += 1
            continue
        magic, length = struct.unpack(">ii", data[:wire.FRAME_HEADER_SIZE])
        if magic != wire.UDP_PACKET_MAGIC:
            rx.stats["bad_frames"] += 1
            rx.emit({"kind": "reject", "reason": "bad audio magic 0x%x" % magic})
            continue
        if length != len(data) - wire.FRAME_HEADER_SIZE:
            rx.stats["bad_frames"] += 1
            rx.emit({"kind": "reject", "reason": "audio length %d != body %d" % (
                length, len(data) - wire.FRAME_HEADER_SIZE)})
            continue
        kind, payload = wire.decode_wrapper(data[wire.FRAME_HEADER_SIZE:])
        if kind != "audio":
            continue
        try:
            packet = wire.decode_audio_packet(payload)
        except ValueError as err:
            rx.stats["bad_frames"] += 1
            rx.emit({"kind": "reject", "reason": "undecodable packet: %s" % err})
            continue
        ok, reason = wire.validate_audio_packet(packet)
        if not ok:
            rx.stats["rejected"] += 1
            rx.emit({"kind": "reject", "reason": reason, "seq": packet["sequence"]})
            continue
        rx.stats["audio"] += 1
        rx.emit({
            "kind": "audio", "seq": packet["sequence"], "session": packet["session"],
            "phone_ts": packet["timestamp"], "codec": packet["codec"],
            "rate": packet["sample_rate"], "ch": packet["channel_count"],
            "fmt": packet["audio_format"], "len": len(packet["buffer"]),
            "datagram": len(data), "fec": bool(packet["fec_buffer"]),
            "fec_seq": packet["fec_sequence_number"], "lengths": packet["fec_lengths"],
            "b64": base64.b64encode(packet["buffer"]).decode("ascii"),
        })


def recv_exact(conn, count):
    buf = b""
    while len(buf) < count:
        chunk = conn.recv(count - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tcp-port", type=int, default=8555)
    parser.add_argument("--udp-port", type=int, required=True)
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--stop-ping-after", type=float, default=None)
    args = parser.parse_args()

    rx = Receiver(args)
    threads = [threading.Thread(target=control_loop, args=(rx,), daemon=True),
               threading.Thread(target=udp_loop, args=(rx,), daemon=True)]
    for thread in threads:
        thread.start()

    deadline = time.time() + args.duration
    while time.time() < deadline and not rx.stop.is_set():
        time.sleep(0.2)
    rx.stop.set()
    time.sleep(0.3)
    rx.emit({"kind": "summary", **rx.stats})
    rx.close()
    if rx.stats["connect"] is None:
        print("no ConnectMessage arrived: the phone never reached the receiver",
              file=sys.stderr)
        return 2
    if rx.stats["audio"] == 0:
        print("no valid audio packet arrived", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
