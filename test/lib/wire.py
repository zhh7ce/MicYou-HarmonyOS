#!/usr/bin/env python3
"""The MicYou wire format, read the way the desktop reads it.

Field numbers mirror entry/src/main/ets/net/Messages.ets and
tauri-app/crates/micyou-protocol/proto/network.proto; the validation rules are a
line-for-line port of validate_audio_packet in
tauri-app/crates/micyou-core/src/transport/session.rs, so a packet the test
receiver accepts is a packet the real desktop accepts too.
"""

PACKET_MAGIC = 0x4D696359      # "MicY", TCP control
UDP_PACKET_MAGIC = 0x4D696355  # "MicU", UDP audio
FRAME_HEADER_SIZE = 8
MAX_CONTROL_PAYLOAD_SIZE = 1024 * 1024
UDP_MAX_DATAGRAM_SIZE = 1472
HANDSHAKE_CLIENT = b"MicYouCheck1"
HANDSHAKE_SERVER = b"MicYouCheck2"

CODEC_PCM = 0
CODEC_OPUS = 1

# session.rs constants
MAX_AUDIO_BUFFER_LEN = 64 * 1024
MAX_PCM_BLOCK_LEN = 1320
FEC_GROUP_SIZE = 12
MIN_SAMPLE_RATE = 8000
MAX_SAMPLE_RATE = 192000
MAX_CHANNEL_COUNT = 2

WRAPPER_AUDIO = 1
WRAPPER_CONNECT = 2
WRAPPER_MUTE = 3
WRAPPER_PING = 5
WRAPPER_PONG = 6
WRAPPER_STATS = 8

ORDERED_SEQUENCE = 1
ORDERED_AUDIO = 2
ORDERED_TIMESTAMP = 3
ORDERED_FEC_BUFFER = 4
ORDERED_FEC_SEQ = 5
ORDERED_SESSION = 6
ORDERED_FEC_LENGTHS = 7

AUDIO_BUFFER = 1
AUDIO_SAMPLE_RATE = 2
AUDIO_CHANNEL_COUNT = 3
AUDIO_FORMAT = 4
AUDIO_CODEC = 5

CONNECT_SESSION = 1
CONNECT_PLATFORM = 2

WT_VARINT = 0
WT_FIXED64 = 1
WT_LEN = 2
WT_FIXED32 = 5


def read_varint(buf, pos):
    value = 0
    shift = 0
    while True:
        byte = buf[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def parse_fields(buf):
    """[(field_number, wire_type, value)] with value int for varint, bytes for LEN."""
    out = []
    pos = 0
    size = len(buf)
    while pos < size:
        tag, pos = read_varint(buf, pos)
        field, wire = tag >> 3, tag & 7
        if wire == WT_VARINT:
            value, pos = read_varint(buf, pos)
        elif wire == WT_LEN:
            length, pos = read_varint(buf, pos)
            value = buf[pos:pos + length]
            if len(value) != length:
                raise ValueError("truncated length-delimited field")
            pos += length
        elif wire == WT_FIXED32:
            value = buf[pos:pos + 4]
            pos += 4
        elif wire == WT_FIXED64:
            value = buf[pos:pos + 8]
            pos += 8
        else:
            raise ValueError("unsupported wire type %d" % wire)
        out.append((field, wire, value))
    return out


def frame(magic, payload):
    import struct
    return struct.pack(">ii", magic, len(payload)) + payload


def unwrap(buf):
    """Split a control-stream buffer that holds exactly one frame."""
    import struct
    magic, length = struct.unpack(">ii", buf[:FRAME_HEADER_SIZE])
    if magic != PACKET_MAGIC:
        raise ValueError("bad control magic 0x%x" % magic)
    if length < 0 or length > MAX_CONTROL_PAYLOAD_SIZE:
        raise ValueError("bad control frame length %d" % length)
    return buf[FRAME_HEADER_SIZE:FRAME_HEADER_SIZE + length]


def decode_audio_packet(payload):
    """OrderedAudioPacket bytes -> dict, with the audio sub-message flattened."""
    ordered = parse_fields(payload)
    audio_raw = b""
    out = {
        "sequence": None, "timestamp": None, "session": None,
        "fec_buffer": b"", "fec_sequence_number": 0, "fec_lengths": [],
    }
    for field, wire, value in ordered:
        if field == ORDERED_SEQUENCE:
            out["sequence"] = value
        elif field == ORDERED_AUDIO:
            audio_raw = value
        elif field == ORDERED_TIMESTAMP:
            out["timestamp"] = value
        elif field == ORDERED_SESSION:
            out["session"] = value
        elif field == ORDERED_FEC_BUFFER:
            out["fec_buffer"] = value
        elif field == ORDERED_FEC_SEQ:
            out["fec_sequence_number"] = value
        elif field == ORDERED_FEC_LENGTHS:
            # packed repeated uint32 (LEN) or, defensively, bare varints
            if wire == WT_LEN:
                pos = 0
                while pos < len(value):
                    one, pos = read_varint(value, pos)
                    out["fec_lengths"].append(one)
            else:
                out["fec_lengths"].append(value)
    if not audio_raw:
        raise ValueError("OrderedAudioPacket without audioPacket")

    out["buffer"] = b""
    for field, wire, value in parse_fields(audio_raw):
        if field == AUDIO_BUFFER:
            out["buffer"] = value
        elif field == AUDIO_SAMPLE_RATE:
            out["sample_rate"] = value
        elif field == AUDIO_CHANNEL_COUNT:
            out["channel_count"] = value
        elif field == AUDIO_FORMAT:
            out["audio_format"] = value
        elif field == AUDIO_CODEC:
            out["codec"] = value
    for key in ("sample_rate", "channel_count", "audio_format", "codec"):
        out.setdefault(key, 0)
    return out


def decode_wrapper(payload):
    """MessageWrapper -> (kind, detail)."""
    for field, wire, value in parse_fields(payload):
        if field == WRAPPER_PING:
            return "ping", decode_timestamp(value)
        if field == WRAPPER_PONG:
            return "pong", decode_timestamp(value)
        if field == WRAPPER_CONNECT:
            session = 0
            platform = ""
            for inner_field, inner_wire, inner_value in parse_fields(value):
                if inner_field == CONNECT_SESSION:
                    session = inner_value
                elif inner_field == CONNECT_PLATFORM:
                    platform = inner_value.decode("utf-8", "replace")
            return "connect", {"session": session, "platform": platform}
        if field == WRAPPER_MUTE:
            for inner_field, inner_wire, inner_value in parse_fields(value):
                if inner_field == 1:
                    return "mute", bool(inner_value)
            return "mute", None
        if field == WRAPPER_AUDIO:
            return "audio", value
    return "ignored", None


def decode_timestamp(buf):
    for field, wire, value in parse_fields(buf):
        if field == 1:
            return value
    return 0


def pcm_frame_size(audio):
    bytes_per_sample = {2: 2, 3: 1, 4: 4, 6: 3}.get(audio["audio_format"])
    if bytes_per_sample is None:
        return None
    channels = audio["channel_count"]
    if channels <= 0:
        return None
    return bytes_per_sample * channels


def validate_audio_packet(packet):
    """Mirror of validate_audio_packet; returns (ok, reason)."""
    if not 1 <= packet["channel_count"] <= MAX_CHANNEL_COUNT:
        return False, "channel_count %d out of 1..2" % packet["channel_count"]
    if not MIN_SAMPLE_RATE <= packet["sample_rate"] <= MAX_SAMPLE_RATE:
        return False, "sample_rate %d out of range" % packet["sample_rate"]
    if not packet["buffer"]:
        return False, "empty buffer"
    if len(packet["buffer"]) > MAX_AUDIO_BUFFER_LEN:
        return False, "buffer %d over cap" % len(packet["buffer"])

    is_opus = packet["codec"] == CODEC_OPUS
    is_fec = bool(packet["fec_buffer"])
    if len(packet["fec_buffer"]) > MAX_PCM_BLOCK_LEN:
        return False, "fec_buffer longer than a PCM block"
    if not is_fec and packet["fec_lengths"]:
        return False, "data packet carries fecPacketLengths"
    if is_fec and packet["fec_lengths"]:
        if len(packet["fec_lengths"]) != FEC_GROUP_SIZE:
            return False, "%d fecPacketLengths, want 12" % len(packet["fec_lengths"])
        for one in packet["fec_lengths"]:
            if one == 0 or one > MAX_PCM_BLOCK_LEN:
                return False, "fec length %d out of 1..1320" % one
        if not is_opus:
            size = pcm_frame_size(packet)
            if size is None:
                return False, "unknown PCM frame size"
            for one in packet["fec_lengths"]:
                if one % size:
                    return False, "fec length %d not frame aligned" % one
    if is_opus:
        return True, ""
    size = pcm_frame_size(packet)
    if size is None or len(packet["buffer"]) % size:
        return False, "PCM buffer not frame aligned"
    return True, ""
