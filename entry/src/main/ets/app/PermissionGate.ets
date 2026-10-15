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
 * MicYou HarmonyOS client — recording permission handling.
 */

import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouPermission';
const REQUIRED_PERMISSIONS: Array<Permissions> = ['ohos.permission.MICROPHONE'];

export async function ensureMicrophone(context: common.UIAbilityContext): Promise<boolean> {
  const manager = abilityAccessCtrl.createAtManager();
  try {
    const result = await manager.requestPermissionsFromUser(context, REQUIRED_PERMISSIONS);
    const grants: Array<number> = result.authResults;
    for (let i = 0; i < grants.length; i++) {
      if (grants[i] === 0) {
        return true;
      }
    }
    hilog.warn(DOMAIN, TAG, 'microphone permission denied by user');
    return false;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'permission request failed: %{public}s', JSON.stringify(err as BusinessError));
    return false;
  }
}
