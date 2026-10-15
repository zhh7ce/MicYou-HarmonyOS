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
 * MicYou HarmonyOS client — XOR FEC grouping for the opus send path. Collects
 * one group of 12 audio packets and hands back the byte-wise parity plus the
 * per-packet lengths the desktop recovery path needs.
 */

import { FEC_GROUP_SIZE } from '../net/Wire';

export interface FecParity {
  xor: Uint8Array;
  lengths: Array<number>;
  groupStartSeq: number;
}

export class FecGroup {
  private packets: Array<Uint8Array> = [];
  private lengths: Array<number> = [];
  private groupStartSeq: number = 0;

  /** seq is the sequence number the caller spent on this packet. */
  add(packet: Uint8Array, seq: number): FecParity | null {
    if (this.packets.length === 0) {
      this.groupStartSeq = seq;
    }
    this.packets.push(packet);
    this.lengths.push(packet.length);
    if (this.packets.length < FEC_GROUP_SIZE) {
      return null;
    }
    let longest: number = 0;
    for (let i = 0; i < this.lengths.length; i++) {
      if (this.lengths[i] > longest) {
        longest = this.lengths[i];
      }
    }
    const out = new Uint8Array(longest);
    for (let i = 0; i < this.packets.length; i++) {
      const p: Uint8Array = this.packets[i];
      for (let j = 0; j < p.length; j++) {
        out[j] = out[j] ^ p[j];
      }
      // bytes past p.length XOR against zero padding: no-op by construction.
    }
    const parity: FecParity = { xor: out, lengths: this.lengths, groupStartSeq: this.groupStartSeq };
    this.packets = [];
    this.lengths = [];
    return parity;
  }

  /** Partial groups are discarded: desktop recovery needs exactly 11-of-12 sources. */
  reset(): void {
    this.packets = [];
    this.lengths = [];
    this.groupStartSeq = 0;
  }
}
