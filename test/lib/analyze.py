#!/usr/bin/env python3
"""Assert the captured stream against what the encoder is supposed to emit.

Reads the receiver's JSONL and checks arithmetic the phone cannot fake: sequence
continuity, one parity per twelve data packets, the parity being the real XOR of
that group, the group's declared lengths matching the payloads on the wire, and —
for Opus profiles — that a stock libopus decoder accepts every packet in order.

usage: analyze.py --in capture.jsonl --profile opus-48k-mono [--json report.json]

Exit 0 when every gate passes, 1 otherwise. Advisory numbers are printed but never
gate.
"""

import argparse
import base64
import ctypes
import ctypes.util
import json
import sys

PROFILES = {
    "opus-48k-mono": {"codec": 1, "rate": 48000, "ch": 1, "fmt": 2, "fec": True,
                      "hz": 50.0, "tol": 0.15},
    "opus-48k-stereo": {"codec": 1, "rate": 48000, "ch": 2, "fmt": 2, "fec": True,
                        "hz": 50.0, "tol": 0.15},
    "opus-16k-mono": {"codec": 1, "rate": 16000, "ch": 1, "fmt": 2, "fec": True,
                      "hz": 50.0, "tol": 0.15},
    "pcm-48k-mono": {"codec": 0, "rate": 48000, "ch": 1, "fmt": 2, "fec": False,
                     "hz": 48000 * 2 / 1320.0, "tol": 0.10, "payload": 1320},
    "pcm-44100-float32": {"codec": 0, "rate": 44100, "ch": 1, "fmt": 4, "fec": False,
                          "hz": 44100 * 4 / 1320.0, "tol": 0.10, "payload": 1320},
    "pcm-48k-24bit": {"codec": 0, "rate": 48000, "ch": 1, "fmt": 6, "fec": False,
                      "hz": 48000 * 3 / 1320.0, "tol": 0.10, "payload": 1320},
    "pcm-16k-mono": {"codec": 0, "rate": 16000, "ch": 1, "fmt": 2, "fec": False,
                     "hz": 16000 * 2 / 1320.0, "tol": 0.10, "payload": 1320},
}

FEC_GROUP_SIZE = 12


class Report:
    def __init__(self):
        self.lines = []
        self.failed = False

    def gate(self, ok, name, detail):
        self.lines.append({"ok": ok, "name": name, "detail": detail})
        print("{} {}: {}".format("PASS" if ok else "FAIL", name, detail))
        if not ok:
            self.failed = True

    def note(self, name, detail):
        self.lines.append({"ok": True, "name": name, "detail": detail, "advisory": True})
        print("note {}: {}".format(name, detail))


def load(path):
    events = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                events.append(json.loads(line))
    return events


def open_opus(rate, channels):
    """ctypes handle on the system libopus, or None when it is unavailable."""
    for name in ("libopus.so.0", "libopus.so", ctypes.util.find_library("opus")):
        if not name:
            continue
        try:
            lib = ctypes.CDLL(name)
        except OSError:
            continue
        lib.opus_decoder_create.argtypes = [ctypes.c_int32, ctypes.c_int,
                                            ctypes.POINTER(ctypes.c_int)]
        lib.opus_decoder_create.restype = ctypes.c_void_p
        lib.opus_decode.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32,
                                    ctypes.POINTER(ctypes.c_int16), ctypes.c_int32,
                                    ctypes.c_int]
        lib.opus_decode.restype = ctypes.c_int
        # Without this the handle is passed as a 32-bit int and the pointer truncates.
        lib.opus_decoder_destroy.argtypes = [ctypes.c_void_p]
        err = ctypes.c_int(-1)
        handle = lib.opus_decoder_create(rate if rate in (8000, 12000, 16000, 24000, 48000)
                                         else 48000, channels, ctypes.byref(err))
        if handle and err.value == 0:
            return lib, handle
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--in", dest="src", required=True)
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES))
    parser.add_argument("--json", default=None)
    parser.add_argument("--min-packets", type=int, default=25)
    args = parser.parse_args()

    profile = PROFILES[args.profile]
    rep = Report()
    events = load(args.src)
    audio = [e for e in events if e["kind"] == "audio"]
    rejects = [e for e in events if e["kind"] == "reject"]
    summary = next((e for e in events if e["kind"] == "summary"), None)
    connect = next((e for e in events if e["kind"] == "connect"), None)
    if summary is None:
        rep.gate(False, "summary", "receiver wrote no summary line")
        return 1

    data = [e for e in audio if not e["fec"]]
    parity = [e for e in audio if e["fec"]]
    rep.gate(connect is not None and connect.get("platform") == "harmonyos",
             "connect", "platform=%r session=%r" % (
                 (connect or {}).get("platform"), (connect or {}).get("session")))
    rep.gate(not rejects and not summary["bad_frames"], "validation",
             "%d rejects, %d bad frames, %d oversize (desktop rules: session.rs "
             "validate_audio_packet)" % (len(rejects), summary["bad_frames"],
                                         summary["oversize"]))
    if rejects:
        for item in rejects[:5]:
            print("     reject: %s (seq %s)" % (item["reason"], item.get("seq")))
    rep.gate(len(data) >= args.min_packets, "volume",
             "%d data packets (min %d)" % (len(data), args.min_packets))

    wrong = [e for e in audio
             if (e["codec"], e["rate"], e["ch"], e["fmt"]) !=
                (profile["codec"], profile["rate"], profile["ch"], profile["fmt"])]
    rep.gate(not wrong, "header",
             "codec/rate/ch/fmt on every packet == %s%s" % (args.profile,
             "" if not wrong else ", %d off: seq %s -> %s/%s/%s/%s" % (
                 len(wrong), wrong[0]["seq"], wrong[0]["codec"], wrong[0]["rate"],
                 wrong[0]["ch"], wrong[0]["fmt"])))

    sessions = {e["session"] for e in audio}
    rep.gate(len(sessions) == 1, "session", "one session id across the capture: %s" % sessions)

    gaps = [(a["seq"], b["seq"]) for a, b in zip(data, data[1:]) if b["seq"] != a["seq"] + 1]
    rep.gate(not gaps, "sequence",
             "%d..%d strictly +1 (%d breaks%s)" % (
                 data[0]["seq"] if data else -1, data[-1]["seq"] if data else -1,
                 len(gaps), "" if not gaps else ", first %s" % (gaps[0],)))

    span = max((data[-1]["t"] - data[0]["t"]) if len(data) > 1 else 0.0, 0.001)
    hz = len(data) / span
    expected = profile["hz"]
    rep.gate(abs(hz - expected) <= expected * profile["tol"], "packet-rate",
             "%.2f data pkt/s, expected %.1f (+-%d%%)" % (hz, expected, profile["tol"] * 100))
    rep.note("payload-rate",
             "%.1f KB/s audio payload, %.1f KB/s on the wire" % (
                 sum(e["len"] for e in data) / span / 1024,
                 sum(e["datagram"] for e in data) / span / 1024))

    if profile["fec"]:
        want = len(data) // FEC_GROUP_SIZE
        rep.gate(len(parity) == want, "fec-cadence",
                 "%d parity packets for %d data packets, expected floor(n/12)=%d" % (
                     len(parity), len(data), want))
        # rebuild groups in arrival order and check the parity arithmetic
        group, mismatches, seq_bad, start_bad = [], [], [], []
        by_seq = {e["seq"]: e for e in data}
        # Arrival order is the truth the desktop sees, so walk the capture once and
        # remember where each parity sits: the data packet right after a parity must
        # reuse the number the parity carries.
        positions = {id(e): i for i, e in enumerate(audio)}
        for e in audio:
            if e["fec"]:
                if len(group) != FEC_GROUP_SIZE:
                    mismatches.append("group under %d members" % len(group))
                else:
                    lengths = [len(base64.b64decode(by_seq[s]["b64"])) for s in
                               [g["seq"] for g in group]]
                    if e["lengths"] != lengths:
                        mismatches.append("seq %s declares %s, payloads are %s" % (
                            e["seq"], e["lengths"], lengths))
                    longest = max(lengths)
                    xor = bytearray(longest)
                    for item in group:
                        raw = base64.b64decode(item["b64"])
                        for i, byte in enumerate(raw):
                            xor[i] ^= byte
                    body = base64.b64decode(e["b64"])
                    if bytes(xor) != body:
                        mismatches.append("seq %s parity is not the group XOR (%d vs %d bytes)" % (
                            e["seq"], len(xor), len(body)))
                    first = group[0]["seq"]
                    declared = e["fec_seq"] if e["fec_seq"] else first
                    if declared != first:
                        start_bad.append("%s != %s" % (declared, first))
                    nxt = None
                    for later in audio[positions[id(e)] + 1:]:
                        if not later["fec"]:
                            nxt = later["seq"]
                            break
                    if nxt is not None and nxt != e["seq"]:
                        seq_bad.append("parity %s followed by data %s" % (e["seq"], nxt))
                group = []
            else:
                group.append(e)
        rep.gate(not mismatches, "fec-xor",
                 "every parity equals the XOR of its 12 sources, with matching lengths"
                 if not mismatches else "; ".join(mismatches[:3]))
        rep.gate(not start_bad, "fec-group-start",
                 "fecSequenceNumber is the group's first sequence"
                 if not start_bad else ", ".join(start_bad[:3]))
        rep.gate(not seq_bad, "fec-seq-reuse",
                 "parity carries the next data packet's number without consuming it"
                 if not seq_bad else "; ".join(seq_bad[:3]))
    else:
        rep.gate(not parity, "fec-absent", "PCM path sent no FEC fields: %d parity" % len(parity))
        payload_bad = [e["seq"] for e in data if e["len"] != profile.get("payload")]
        rep.gate(not payload_bad, "payload",
                 "every PCM payload is %d B%s" % (profile.get("payload"),
                 "" if not payload_bad else ", off at %s" % payload_bad[:5]))

    if profile["codec"] == 1:
        decoder = open_opus(profile["rate"], profile["ch"])
        if decoder is None:
            rep.note("decode", "no system libopus to decode with — structure checks only")
        else:
            lib, handle = decoder
            failures = []
            decoded_samples = 0
            tiny = 0
            frame_size = profile["rate"] // 50
            out = (ctypes.c_int16 * (frame_size * profile["ch"] * 2))()
            for e in data:
                raw = base64.b64decode(e["b64"])
                if len(raw) <= 2:
                    tiny += 1
                got = lib.opus_decode(handle, raw, len(raw), out, frame_size, 0)
                if got < 0:
                    failures.append("seq %s -> %d" % (e["seq"], got))
                else:
                    decoded_samples += got
            rep.gate(not failures, "decode",
                     "libopus decoded all %d opus packets (%d silent/DTX <=2 B, %d samples out)"
                     % (len(data), tiny, decoded_samples)
                     if not failures else "first failures: %s" % failures[:3])
            rep.note("bitrate", "%.1f kbps average payload per 20 ms frame" % (
                sum(e["len"] for e in data) * 8 / span / 1000))
            lib.opus_decoder_destroy(handle)

    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({"profile": args.profile, "checks": rep.lines}, handle, indent=2)
    print("---")
    print("RESULT %s (%d gates failed)" % ("PASS" if not rep.failed else "FAIL",
                                           1 if rep.failed else 0))
    return 1 if rep.failed else 0


if __name__ == "__main__":
    sys.exit(main())
