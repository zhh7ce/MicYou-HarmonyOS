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
 * MicYou HarmonyOS client — accumulation of the pump's fixed 1320-byte PCM
 * slices into whole 20 ms opus frames. A frame straddles two readData chunks
 * because 1320 does not divide 1920, so the remainder is carried across calls.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { opusFrameBytes } from '../net/Wire';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouOpus';

export type OpusFrameHandler = (frame: ArrayBuffer) => void;

export class OpusFrameBuffer {
  private frameBytes: number = 0;
  private carry: Uint8Array = new Uint8Array(0);

  start(sampleRate: number, channels: number): void {
    this.frameBytes = opusFrameBytes(sampleRate, channels);
    this.carry = new Uint8Array(0);
  }

  /** Concatenate the carry-over with the chunk and emit every whole 20 ms frame. */
  feed(chunk: Uint8Array, sink: OpusFrameHandler): void {
    if (this.frameBytes <= 0) {
      return;
    }
    const joined = new Uint8Array(this.carry.length + chunk.length);
    joined.set(this.carry, 0);
    joined.set(chunk, this.carry.length);
    let consumed: number = 0;
    while (joined.length - consumed >= this.frameBytes) {
      const frame = new ArrayBuffer(this.frameBytes);
      new Uint8Array(frame).set(joined.subarray(consumed, consumed + this.frameBytes));
      consumed += this.frameBytes;
      sink(frame);
    }
    const rest = new Uint8Array(joined.length - consumed);
    rest.set(joined.subarray(consumed));
    this.carry = rest;
  }

  /** Session stop: the sub-frame remainder is dropped, as on Android (no padding, no partial encode). */
  reset(): number {
    const dropped: number = this.carry.length;
    this.carry = new Uint8Array(0);
    this.frameBytes = 0;
    if (dropped > 0) {
      hilog.info(DOMAIN, TAG, 'dropped %{public}d tail bytes below one opus frame', dropped);
    }
    return dropped;
  }
}
