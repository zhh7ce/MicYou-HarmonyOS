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

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

import { AppEnvironment } from '../app/AppEnvironment';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // The pages cannot reach their context through the deprecated getContext(),
    // so the ability hands it over once here.
    AppEnvironment.publish(this.context);
    // Apply the stored theme once the preferences have loaded.
    AppEnvironment.connectionStore.ensureInit(this.context)
      .then(() => AppEnvironment.applyTheme())
      .catch((): void => {});
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    AppEnvironment.controller.stop().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'stop on destroy failed: %{public}s', err.message);
    });
    AppEnvironment.forget();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'load content failed: %{public}d', err.code);
      }
    });
  }
}
