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
 * MicYou HarmonyOS client — continuous task so capture survives backgrounding.
 * Without it the system suspends the app shortly after the screen goes off and
 * the PC-side mic goes silent.
 */

import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, Want, WantAgent, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouBackground';

export class BackgroundRunner {
  private context: common.UIAbilityContext | null = null;

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.context !== null) {
      return;
    }
    const target: Want = { bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name };
    const info: wantAgent.WantAgentInfo = {
      wants: [target],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_RECORDING, agent);
      this.context = context;
      hilog.info(DOMAIN, TAG, 'continuous task started (AUDIO_RECORDING)');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'continuous task refused: %{public}s', JSON.stringify(err as BusinessError));
    }
  }

  async stop(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    this.context = null;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (err) {
      hilog.debug(DOMAIN, TAG, 'stopBackgroundRunning ignored: %{public}s', JSON.stringify(err as BusinessError));
    }
  }
}
