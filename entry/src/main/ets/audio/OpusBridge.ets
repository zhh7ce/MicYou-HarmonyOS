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
 * MicYou HarmonyOS client — thin ArkTS bridge over the mcyopus napi module.
 * Owns exactly one native encoder handle per session; every call must come
 * from the main JS thread because the module keeps global slots without
 * locking.
 */

import { createEncoder, encode, destroyEncoder } from 'libmcyopus.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouOpus';

export class OpusBridge {
  private handle: number = 0;

  create(sampleRate: number, channels: number): void {
    if (this.handle !== 0) {
      throw new Error('opus encoder already created');
    }
    this.handle = createEncoder(sampleRate, channels);
    hilog.info(DOMAIN, TAG, 'encoder created %{public}d Hz / %{public}d ch', sampleRate, channels);
  }

  encode(frame: ArrayBuffer): ArrayBuffer {
    return encode(this.handle, frame);
  }

  destroy(): void {
    if (this.handle !== 0) {
      destroyEncoder(this.handle);
      hilog.info(DOMAIN, TAG, 'encoder destroyed');
      this.handle = 0;
    }
  }
}
