/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * MicYou — Turns your phone into a high-quality PC microphone.
 * Copyright (C) 2026 zhh7ce <https://github.com/zhh7ce/MicYou-HarmonyOS>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 */

/*
 * MicYou HarmonyOS client — wire constants and TCP frame assembly.
 * Mirrors tauri-app/crates/micyou-protocol and composeApp network/Protocol.kt.
 */

export const PACKET_MAGIC: number = 0x4d696359; // "MicY", TCP control frames
export const UDP_PACKET_MAGIC: number = 0x4d696355; // "MicU", UDP audio frames
export const FRAME_HEADER_SIZE: number = 8;
export const MAX_CONTROL_PAYLOAD_SIZE: number = 1024 * 1024;
export const UDP_MAX_DATAGRAM_SIZE: number = 1472;
export const UDP_PCM_PAYLOAD_SIZE: number = 1320;
export const UDP_PORT_OFFSET: number = 1;
export const DEFAULT_TCP_PORT: number = 8554;
export const CODEC_PCM: number = 0;
export const CODEC_OPUS: number = 1;
// audioFormat uses the Android AudioFormat encoding constants the desktop decoder keys on:
// 2 = PCM 16-bit, 4 = PCM float32, 6 = PCM 24-bit packed. 32-bit integer has no branch there.
export const AUDIO_FORMAT_16BIT: number = 2;
export const AUDIO_FORMAT_FLOAT32: number = 4;
export const AUDIO_FORMAT_24BIT: number = 6;
export const CLIENT_PLATFORM: string = 'harmonyos';
export const MDNS_SERVICE_TYPE: string = '_micyou._tcp';
export const HANDSHAKE_CLIENT: string = 'MicYouCheck1';
export const HANDSHAKE_SERVER: string = 'MicYouCheck2';
export const HEARTBEAT_TIMEOUT_MS: number = 5000;

// Persisted capture-source ids. The numbers match audio.SourceType so the store
// survives across SDKs; CapturePump maps each to the concrete enum member.
export const SOURCE_MIC: number = 0;
export const SOURCE_VOICE_RECOGNITION: number = 1;
export const SOURCE_VOICE_COMMUNICATION: number = 7;
export const SOURCE_CAMCORDER: number = 13;
export const SOURCE_UNPROCESSED: number = 14;
export const SOURCE_LIVE: number = 17;

export const OPUS_FRAME_MS: number = 20;
export const FEC_GROUP_SIZE: number = 12;
const OPUS_NATIVE_RATES: Array<number> = [8000, 12000, 16000, 24000, 48000];

/** Samples per channel in one MicYou Opus frame at this capture rate. */
export function opusFrameSamples(sampleRate: number): number {
  return Math.floor(sampleRate * OPUS_FRAME_MS / 1000);
}

/** One 20 ms S16LE frame for (rate, channels), the exact input size opus_encode wants. */
export function opusFrameBytes(sampleRate: number, channels: number): number {
  return opusFrameSamples(sampleRate) * 2 * channels;
}

/** Rates the desktop's opus decoder can be created for; anything else is a silent-stream trap. */
export function isOpusNativeRate(rate: number): boolean {
  return OPUS_NATIVE_RATES.indexOf(rate) >= 0;
}

/** Bytes in one interleaved PCM frame component for a wire audioFormat constant. */
export function bytesPerSampleFor(format: number): number {
  if (format === AUDIO_FORMAT_FLOAT32) {
    return 4;
  }
  if (format === AUDIO_FORMAT_24BIT) {
    return 3;
  }
  // 16-bit and anything unexpected fall back to the verified capture path.
  return 2;
}

export function udpPortFor(tcpPort: number): number {
  const udpPort: number = tcpPort + UDP_PORT_OFFSET;
  if (udpPort < 0 || udpPort > 65535) {
    throw new Error(`UDP port overflow for TCP port ${tcpPort}`);
  }
  return udpPort;
}

function asciiBytes(text: string): Uint8Array {
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i) & 0xff;
  }
  return out;
}

export function handshakeClientBytes(): Uint8Array {
  return asciiBytes(HANDSHAKE_CLIENT);
}

export function isHandshakeServerReply(data: Uint8Array): boolean {
  if (data.length !== HANDSHAKE_SERVER.length) {
    return false;
  }
  for (let i = 0; i < data.length; i++) {
    if (data[i] !== HANDSHAKE_SERVER.charCodeAt(i)) {
      return false;
    }
  }
  return true;
}

/** magic (i32 BE) + payload length (i32 BE) + protobuf payload. */
export function buildFrame(magic: number, payload: Uint8Array): ArrayBuffer {
  const out = new Uint8Array(FRAME_HEADER_SIZE + payload.length);
  const view = new DataView(out.buffer);
  view.setInt32(0, magic, false);
  view.setInt32(4, payload.length, false);
  out.set(payload, FRAME_HEADER_SIZE);
  return out.buffer;
}

/**
 * Reassembles the TCP stream into frames. The socket hands out arbitrary
 * chunks, so a frame can straddle two callbacks and two frames can share one.
 */
export class FrameAssembler {
  private buf: Uint8Array = new Uint8Array(4096);
  private len: number = 0;

  private ensure(extra: number): void {
    if (this.len + extra <= this.buf.length) {
      return;
    }
    let capacity: number = this.buf.length;
    while (capacity < this.len + extra) {
      capacity *= 2;
    }
    const next = new Uint8Array(capacity);
    next.set(this.buf.subarray(0, this.len));
    this.buf = next;
  }

  feed(chunk: Uint8Array): void {
    this.ensure(chunk.length);
    this.buf.set(chunk, this.len);
    this.len += chunk.length;
  }

  /** Returns the next complete payload, or null when more bytes are needed. */
  next(): Uint8Array | null {
    if (this.len < FRAME_HEADER_SIZE) {
      return null;
    }
    const view = new DataView(this.buf.buffer, this.buf.byteOffset, this.len);
    const magic: number = view.getInt32(0, false);
    if (magic !== PACKET_MAGIC) {
      throw new Error(`invalid packet magic 0x${magic.toString(16)}`);
    }
    const payloadLen: number = view.getInt32(4, false);
    if (payloadLen < 0 || payloadLen > MAX_CONTROL_PAYLOAD_SIZE) {
      throw new Error(`invalid control frame length ${payloadLen}`);
    }
    if (this.len < FRAME_HEADER_SIZE + payloadLen) {
      return null;
    }
    const payload = new Uint8Array(payloadLen);
    payload.set(this.buf.subarray(FRAME_HEADER_SIZE, FRAME_HEADER_SIZE + payloadLen));
    this.consume(FRAME_HEADER_SIZE + payloadLen);
    return payload;
  }

  private consume(amount: number): void {
    const rest: number = this.len - amount;
    for (let i = 0; i < rest; i++) {
      this.buf[i] = this.buf[amount + i];
    }
    this.len = rest;
  }
}
