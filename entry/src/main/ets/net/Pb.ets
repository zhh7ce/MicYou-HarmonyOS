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
 * MicYou HarmonyOS client — minimal proto3 wire codec.
 * Only the subset the MicYou protocol needs: varint, length-delimited and
 * fixed32 fields. 64-bit values are encoded by repeated division so they stay
 * exact inside the double range without requiring BigInt.
 */

export const WT_VARINT: number = 0;
export const WT_FIXED64: number = 1;
export const WT_LEN: number = 2;
export const WT_FIXED32: number = 5;

const INITIAL_CAPACITY: number = 1024;
const MAX_VARINT_BYTES: number = 10;

export class PbWriter {
  private buf: Uint8Array = new Uint8Array(INITIAL_CAPACITY);
  private pos: number = 0;

  private reserve(need: number): void {
    if (this.pos + need <= this.buf.length) {
      return;
    }
    let capacity: number = this.buf.length;
    while (capacity < this.pos + need) {
      capacity *= 2;
    }
    const next = new Uint8Array(capacity);
    next.set(this.buf.subarray(0, this.pos));
    this.buf = next;
  }

  private pushByte(value: number): void {
    this.reserve(1);
    this.buf[this.pos] = value & 0xff;
    this.pos += 1;
  }

  writeVarint(value: number): void {
    let rest: number = Math.floor(value);
    let bytes: number = 0;
    while (rest >= 128) {
      this.pushByte((rest % 128) | 0x80);
      rest = Math.floor(rest / 128);
      bytes += 1;
      if (bytes >= MAX_VARINT_BYTES) {
        throw new Error('varint overflow');
      }
    }
    this.pushByte(rest);
  }

  writeTag(field: number, wireType: number): void {
    this.writeVarint(field * 8 + wireType);
  }

  /** proto3 skips default values, and so do we. */
  writeInt(field: number, value: number): void {
    if (value === 0) {
      return;
    }
    this.writeTag(field, WT_VARINT);
    this.writeVarint(value);
  }

  writeBool(field: number, value: boolean): void {
    if (!value) {
      return;
    }
    this.writeTag(field, WT_VARINT);
    this.writeVarint(1);
  }

  /** Explicit-presence bool: always emits the field, including false. */
  writeOptionalBool(field: number, value: boolean): void {
    this.writeTag(field, WT_VARINT);
    this.writeVarint(value ? 1 : 0);
  }

  writeFloat(field: number, value: number): void {
    if (value === 0) {
      return;
    }
    this.writeTag(field, WT_FIXED32);
    this.reserve(4);
    const view = new DataView(this.buf.buffer, this.buf.byteOffset + this.pos, 4);
    view.setFloat32(0, value, true);
    this.pos += 4;
  }

  writeBytes(field: number, data: Uint8Array): void {
    this.writeTag(field, WT_LEN);
    this.writeVarint(data.length);
    this.reserve(data.length);
    this.buf.set(data, this.pos);
    this.pos += data.length;
  }

  /** ASCII only: the wire carries nothing but the platform tag. */
  writeAscii(field: number, text: string): void {
    const bytes = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) {
      bytes[i] = text.charCodeAt(i) & 0xff;
    }
    this.writeBytes(field, bytes);
  }

  /** Nested message: caller has already encoded it to bytes. */
  writeMessage(field: number, payload: Uint8Array): void {
    this.writeBytes(field, payload);
  }

  toUint8(): Uint8Array {
    const out = new Uint8Array(this.pos);
    out.set(this.buf.subarray(0, this.pos));
    return out;
  }

  toArrayBuffer(): ArrayBuffer {
    return this.toUint8().buffer;
  }
}

export class PbReader {
  private data: Uint8Array;
  private pos: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  get remaining(): number {
    return this.data.length - this.pos;
  }

  readVarint(): number {
    let result: number = 0;
    let scale: number = 1;
    while (this.remaining > 0) {
      const byte: number = this.data[this.pos];
      this.pos += 1;
      result += (byte & 0x7f) * scale;
      if ((byte & 0x80) === 0) {
        return result;
      }
      scale *= 128;
      if (scale > 9007199254740992) {
        throw new Error('varint exceeds safe integer range');
      }
    }
    throw new Error('truncated varint');
  }

  readTag(): number {
    return this.readVarint();
  }

  skip(wireType: number): void {
    if (wireType === WT_VARINT) {
      this.readVarint();
      return;
    }
    if (wireType === WT_FIXED64) {
      this.pos += 8;
      return;
    }
    if (wireType === WT_FIXED32) {
      this.pos += 4;
      return;
    }
    if (wireType === WT_LEN) {
      const len: number = this.readVarint();
      this.pos += len;
      return;
    }
    throw new Error(`unsupported wire type ${wireType}`);
  }

  readBytes(): Uint8Array {
    const len: number = this.readVarint();
    if (len < 0 || len > this.remaining) {
      throw new Error('truncated length-delimited field');
    }
    const out = new Uint8Array(len);
    out.set(this.data.subarray(this.pos, this.pos + len));
    this.pos += len;
    return out;
  }

  readFloat32(): number {
    if (this.remaining < 4) {
      throw new Error('truncated float32');
    }
    const view = new DataView(this.data.buffer, this.data.byteOffset + this.pos, 4);
    this.pos += 4;
    return view.getFloat32(0, true);
  }
}
