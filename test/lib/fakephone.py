#!/usr/bin/env python3
"""An independent, deliberately correct MicYou packet emitter, used by selfcheck.sh.

This is the oracle for the test harness, not for the phone: it re-implements the wire
format from the field numbers in the desktop's network.proto, so receiver.py and
analyze.py can be exercised without a device and, more importantly, fed one seeded
defect at a time. If a gate in analyze.py can never fail, this script is what proves
it. The client's own encoder is ArkTS and is validated against the real desktop in the
human tier.

usage: fakephone.py --tcp-port 18555 --udp-port 18556 --profile opus-48k-mono
                    --seconds 6 [--break xor|parity-seq|lengths|group-start|rate|payload]
"""

import argparse
import ctypes
import json
import socket
import struct
import sys
import threading
import time

WRAPPER_AUDIO, WRAPPER_CONNECT = 1, 2
SEQ, A_AUDIO, TS, FEC_BUFFER, FEC_SEQ, SESSION, FEC_LENGTHS = 1, 2, 3, 4, 5, 6, 7
A_BUFFER, A_RATE, A_CH, A_FMT, A_CODEC = 1, 2, 3, 4, 5
MAGIC_TCP, MAGIC_UDP = 0x4D696359, 0x4D696355
HANDSHAKE, REPLY = b"MicYouCheck1", b"MicYouCheck2"
FEC_GROUP = 12
APPLICATION_VOIP = 2048
SET_VBR, SET_INBAND_FEC, SET_DTX, SET_SIGNAL = 4006, 4012, 4016, 4024
SIGNAL_VOICE = 3001
PCM_PAYLOAD = 1320

PROFILES = {
    "opus-48k-mono": (1, 48000, 1, 2),
    "opus-16k-mono": (1, 16000, 1, 2),
    "opus-48k-stereo": (1, 48000, 2, 2),
    "pcm-48k-mono": (0, 48000, 1, 2),
    "pcm-16k-mono": (0, 16000, 1, 2),
}


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value == 0:
            out.append(byte)
            return bytes(out)
        out.append(byte | 0x80)


def tag(field, kind):
    return varint((field << 3) | kind)


def vfield(field, value):
    return tag(field, 0) + varint(value)


def bfield(field, payload):
    return tag(field, 2) + varint(len(payload)) + payload


def packed(values):
    return b"".join(varint(v) for v in values)


def frame(magic, payload):
    return struct.pack(">ii", magic, len(payload)) + payload


def audio_packet(body, seq, session, rate, ch, fmt, codec, fec=None):
    """OrderedAudioPacket: a data packet, or a parity packet when fec is given."""
    audio = bfield(A_BUFFER, body) + vfield(A_RATE, rate) + vfield(A_CH, ch)
    audio += vfield(A_FMT, fmt) + vfield(A_CODEC, codec)
    ordered = vfield(SEQ, seq) + bfield(A_AUDIO, audio)
    ordered += vfield(TS, int(time.time() * 1000))
    if fec is None:
        ordered += vfield(SESSION, session)
    else:
        # a parity packet carries the XOR in audio.buffer and the group metadata in
        # the ordered message, with the marker that makes the desktop detect it
        xor, lengths, group_start = fec
        parity_audio = bfield(A_BUFFER, xor) + vfield(A_RATE, rate) + vfield(A_CH, ch)
        parity_audio += vfield(A_FMT, fmt) + vfield(A_CODEC, 1)
        ordered = vfield(SEQ, seq) + bfield(A_AUDIO, parity_audio)
        ordered += vfield(TS, int(time.time() * 1000))
        ordered += bfield(FEC_BUFFER, b"\x01") + vfield(FEC_SEQ, group_start)
        ordered += vfield(SESSION, session) + bfield(FEC_LENGTHS, packed(lengths))
    return frame(MAGIC_UDP, bfield(WRAPPER_AUDIO, ordered))


def open_encoder(rate, ch):
    lib = ctypes.CDLL("libopus.so.0")
    lib.opus_encoder_create.argtypes = [ctypes.c_int32, ctypes.c_int, ctypes.c_int,
                                        ctypes.POINTER(ctypes.c_int)]
    lib.opus_encoder_create.restype = ctypes.c_void_p
    lib.opus_encode.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int32,
                                ctypes.c_char_p, ctypes.c_int32]
    lib.opus_encode.restype = ctypes.c_int32
    # the handle is a 64-bit pointer: without argtypes ctypes would pass it as an int
    lib.opus_encoder_ctl.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lib.opus_encoder_ctl.restype = ctypes.c_int
    err = ctypes.c_int(-1)
    handle = lib.opus_encoder_create(rate, ch, APPLICATION_VOIP, ctypes.byref(err))
    assert handle and err.value == 0, "opus_encoder_create failed (%d)" % err.value
    for request, value in ((SET_VBR, 1), (SET_INBAND_FEC, 0), (SET_DTX, 1),
                           (SET_SIGNAL, SIGNAL_VOICE)):
        lib.opus_encoder_ctl(handle, request, value)
    return lib, handle


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--tcp-port", type=int, default=18555)
    parser.add_argument("--udp-port", type=int, default=18556)
    parser.add_argument("--profile", default="opus-48k-mono", choices=sorted(PROFILES))
    parser.add_argument("--seconds", type=float, default=6)
    parser.add_argument("--session", type=int, default=17)
    parser.add_argument("--break", dest="broken", default=None,
                        choices=["xor", "parity-seq", "lengths", "group-start", "rate",
                                 "payload"])
    args = parser.parse_args()

    codec, rate, ch, fmt = PROFILES[args.profile]
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    sock = socket.create_connection((args.host, args.tcp_port), timeout=5)
    sock.sendall(HANDSHAKE)
    if sock.recv(12) != REPLY:
        print("receiver did not answer the handshake", file=sys.stderr)
        return 1
    sock.sendall(frame(MAGIC_TCP, bfield(WRAPPER_CONNECT,
                                         vfield(1, args.session) + bfield(2, b"harmonyos"))))

    stop = threading.Event()

    def drain():
        sock.settimeout(0.5)
        while not stop.is_set():
            try:
                if not sock.recv(4096):
                    return
            except (socket.timeout, OSError):
                return

    threading.Thread(target=drain, daemon=True).start()

    lib = encoder = pcm = out = samples = None
    if codec == 1:
        lib, encoder = open_encoder(rate, ch)
        samples = rate // 50
        pcm = (ctypes.c_int16 * (samples * ch))()
        for i in range(samples * ch):
            pcm[i] = int(4000 * (((i // ch) % 40) - 20) / 20)
        out = ctypes.create_string_buffer(4000)

    def payload():
        if codec == 1:
            n = lib.opus_encode(encoder, ctypes.addressof(pcm), samples, out, 4000)
            if n <= 0:
                raise RuntimeError("opus_encode -> %d" % n)
            return out.raw[:n]
        return bytes(((i * 37) % 251) for i in range(PCM_PAYLOAD))

    seq = 0
    group = []
    lengths = []
    group_start = 0
    # Opus emits 20 ms frames; a 1320 B PCM payload is a different duration, and
    # analyze.py derives the expected packet rate from the profile.
    interval = 0.02 if codec == 1 else float(PCM_PAYLOAD) / (rate * ch * 2)
    end = time.time() + args.seconds
    next_send = time.time()
    while time.time() < end:
        body = payload()
        if args.broken == "payload" and seq == 5:
            body = body[:-4]  # still frame-aligned, so only the size gate can see it
        declared_rate = rate + 1000 if args.broken == "rate" else rate
        udp.sendto(audio_packet(body, seq, args.session, declared_rate, ch, fmt, codec),
                   (args.host, args.udp_port))
        if not group:
            group_start = seq
        group.append(body)
        lengths.append(len(body))
        seq += 1
        if codec == 1 and len(group) == FEC_GROUP:
            longest = max(lengths)
            xor = bytearray(longest)
            for part in group:
                for i, byte in enumerate(part):
                    xor[i] ^= byte
            if args.broken == "xor":
                xor[0] ^= 0xFF
            declared = list(lengths)
            if args.broken == "lengths":
                declared[0] += 1
            # a parity packet spends the NEXT data packet's number without consuming it
            parity_seq = seq + 1 if args.broken == "parity-seq" else seq
            start = group_start + 1 if args.broken == "group-start" else group_start
            udp.sendto(audio_packet(bytes(xor), parity_seq, args.session, declared_rate, ch,
                                    fmt, 1, fec=(bytes(xor), declared, start)),
                       (args.host, args.udp_port))
            group = []
            lengths = []
        next_send += interval
        delay = next_send - time.time()
        if delay > 0:
            time.sleep(delay)
    stop.set()
    sock.close()
    print(json.dumps({"data": seq, "profile": args.profile, "broken": args.broken}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
