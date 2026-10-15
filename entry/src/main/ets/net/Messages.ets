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
 * MicYou HarmonyOS client — MessageWrapper encode/decode.
 * Field numbers follow tauri-app/crates/micyou-protocol/proto/network.proto.
 */

import { PbReader, PbWriter, WT_FIXED32, WT_FIXED64, WT_LEN, WT_VARINT } from './Pb';
import { CODEC_OPUS } from './Wire';

const WRAPPER_AUDIO: number = 1;
const WRAPPER_CONNECT: number = 2;
const WRAPPER_MUTE: number = 3;
const WRAPPER_PING: number = 5;
const WRAPPER_PONG: number = 6;
const WRAPPER_STATS: number = 8;

const ORDERED_SEQUENCE: number = 1;
const ORDERED_AUDIO: number = 2;
const ORDERED_TIMESTAMP: number = 3;
const ORDERED_SESSION: number = 6;
const ORDERED_FEC_BUFFER: number = 4;
const ORDERED_FEC_SEQ: number = 5;
const ORDERED_FEC_LENGTHS: number = 7;

const FEC_MARKER: Uint8Array = new Uint8Array([1]);

const AUDIO_BUFFER: number = 1;
const AUDIO_SAMPLE_RATE: number = 2;
const AUDIO_CHANNEL_COUNT: number = 3;
const AUDIO_FORMAT: number = 4;
const AUDIO_CODEC: number = 5;

const CONNECT_SESSION: number = 1;
const CONNECT_PLATFORM: number = 2;

const MUTE_IS_MUTED: number = 1;
const TIMESTAMP: number = 1;

const STATS_RTT: number = 1;
const STATS_JITTER: number = 2;
const STATS_LOSS: number = 3;
const STATS_LATENCY: number = 4;

export enum InboundKind {
  Ignored = 0,
  Ping = 1,
  Pong = 2,
  Stats = 3,
  Mute = 4
}

export class InboundMessage {
  kind: InboundKind = InboundKind.Ignored;
  timestamp: number = 0;
  rttMs: number = 0;
  jitterMs: number = 0;
  packetLoss: number = 0;
  latencyMs: number = 0;
  muted: boolean = false;
}

export function encodeConnect(sessionId: number, platform: string): ArrayBuffer {
  const inner = new PbWriter();
  inner.writeInt(CONNECT_SESSION, sessionId);
  inner.writeAscii(CONNECT_PLATFORM, platform);

  const outer = new PbWriter();
  outer.writeMessage(WRAPPER_CONNECT, inner.toUint8());
  return outer.toArrayBuffer();
}

export function encodePong(timestamp: number): ArrayBuffer {
  const inner = new PbWriter();
  inner.writeInt(TIMESTAMP, timestamp);

  const outer = new PbWriter();
  outer.writeMessage(WRAPPER_PONG, inner.toUint8());
  return outer.toArrayBuffer();
}

export function encodeMute(muted: boolean): ArrayBuffer {
  const inner = new PbWriter();
  // optional bool: false has to be present on the wire or the server reads None.
  inner.writeOptionalBool(MUTE_IS_MUTED, muted);

  const outer = new PbWriter();
  outer.writeMessage(WRAPPER_MUTE, inner.toUint8());
  return outer.toArrayBuffer();
}

export function encodeAudioPacket(pcm: Uint8Array, sequence: number, timestamp: number,
  sessionId: number, sampleRate: number, channelCount: number, audioFormat: number, codec: number): ArrayBuffer {
  const audio = new PbWriter();
  audio.writeBytes(AUDIO_BUFFER, pcm);
  audio.writeInt(AUDIO_SAMPLE_RATE, sampleRate);
  audio.writeInt(AUDIO_CHANNEL_COUNT, channelCount);
  audio.writeInt(AUDIO_FORMAT, audioFormat);
  audio.writeInt(AUDIO_CODEC, codec);

  const ordered = new PbWriter();
  ordered.writeInt(ORDERED_SEQUENCE, sequence);
  ordered.writeMessage(ORDERED_AUDIO, audio.toUint8());
  ordered.writeInt(ORDERED_TIMESTAMP, timestamp);
  ordered.writeInt(ORDERED_SESSION, sessionId);
  // Data packets carry no FEC fields: parity lives in its own out-of-band
  // encodeFecParityPacket frame, and validate_audio_packet accepts empty lengths.

  const outer = new PbWriter();
  outer.writeMessage(WRAPPER_AUDIO, ordered.toUint8());
  return outer.toArrayBuffer();
}

/**
 * Out-of-band XOR parity packet, field-for-field like Android AudioEngine.kt:956-987.
 * The XOR body goes in audioPacket.buffer; fecBuffer is only the non-empty
 * [0x01] marker that makes the desktop's ExplicitMarker layout detect parity.
 * sequence is the NEXT regular packet's number, deliberately not consumed.
 * audioFormat is the capture wire value, telemetry only for codec 1.
 */
export function encodeFecParityPacket(xor: Uint8Array, lengths: Array<number>, groupStartSeq: number,
  sequence: number, timestamp: number, sessionId: number,
  sampleRate: number, channelCount: number, audioFormat: number): ArrayBuffer {
  const audio = new PbWriter();
  audio.writeBytes(AUDIO_BUFFER, xor);
  audio.writeInt(AUDIO_SAMPLE_RATE, sampleRate);
  audio.writeInt(AUDIO_CHANNEL_COUNT, channelCount);
  audio.writeInt(AUDIO_FORMAT, audioFormat);
  audio.writeInt(AUDIO_CODEC, CODEC_OPUS);

  const ordered = new PbWriter();
  ordered.writeInt(ORDERED_SEQUENCE, sequence);
  ordered.writeMessage(ORDERED_AUDIO, audio.toUint8());
  ordered.writeInt(ORDERED_TIMESTAMP, timestamp);
  ordered.writeBytes(ORDERED_FEC_BUFFER, FEC_MARKER);
  ordered.writeInt(ORDERED_FEC_SEQ, groupStartSeq); // group 0 omits it; proto3 decodes 0
  ordered.writeInt(ORDERED_SESSION, sessionId);
  ordered.writePackedUInt32s(ORDERED_FEC_LENGTHS, lengths);

  const outer = new PbWriter();
  outer.writeMessage(WRAPPER_AUDIO, ordered.toUint8());
  return outer.toArrayBuffer();
}

export function decodeWrapper(payload: Uint8Array): InboundMessage {
  const result = new InboundMessage();
  const reader = new PbReader(payload);
  while (reader.remaining > 0) {
    const tag: number = reader.readTag();
    const field: number = Math.floor(tag / 8);
    const wireType: number = tag % 8;
    if (field === WRAPPER_PING && wireType === WT_LEN) {
      result.kind = InboundKind.Ping;
      result.timestamp = readTimestamp(reader.readBytes());
      return result;
    }
    if (field === WRAPPER_PONG && wireType === WT_LEN) {
      result.kind = InboundKind.Pong;
      result.timestamp = readTimestamp(reader.readBytes());
      return result;
    }
    if (field === WRAPPER_STATS && wireType === WT_LEN) {
      readStats(reader.readBytes(), result);
      result.kind = InboundKind.Stats;
      return result;
    }
    if (field === WRAPPER_MUTE && wireType === WT_LEN) {
      result.kind = InboundKind.Mute;
      result.muted = readMute(reader.readBytes());
      return result;
    }
    reader.skip(wireType);
  }
  return result;
}

function readTimestamp(bytes: Uint8Array): number {
  const reader = new PbReader(bytes);
  let value: number = 0;
  while (reader.remaining > 0) {
    const tag: number = reader.readTag();
    const field: number = Math.floor(tag / 8);
    const wireType: number = tag % 8;
    if (field === TIMESTAMP && wireType === WT_VARINT) {
      value = reader.readVarint();
      return value;
    }
    reader.skip(wireType);
  }
  return value;
}

function readMute(bytes: Uint8Array): boolean {
  const reader = new PbReader(bytes);
  while (reader.remaining > 0) {
    const tag: number = reader.readTag();
    const field: number = Math.floor(tag / 8);
    const wireType: number = tag % 8;
    if (field === MUTE_IS_MUTED && wireType === WT_VARINT) {
      return reader.readVarint() !== 0;
    }
    reader.skip(wireType);
  }
  return false;
}

function readStats(bytes: Uint8Array, result: InboundMessage): void {
  const reader = new PbReader(bytes);
  while (reader.remaining > 0) {
    const tag: number = reader.readTag();
    const field: number = Math.floor(tag / 8);
    const wireType: number = tag % 8;
    if (wireType === WT_VARINT) {
      const value: number = reader.readVarint();
      if (field === STATS_RTT) {
        result.rttMs = value;
      } else if (field === STATS_LATENCY) {
        result.latencyMs = value;
      }
      continue;
    }
    if (wireType === WT_FIXED32) {
      const value: number = reader.readFloat32();
      if (field === STATS_JITTER) {
        result.jitterMs = value;
      } else if (field === STATS_LOSS) {
        result.packetLoss = value;
      }
      continue;
    }
    reader.skip(wireType);
  }
}
