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
 * MicYou HarmonyOS client — process-wide handles.
 * getContext() is deprecated at this API level, so the ability publishes its
 * context here once during creation and the pages read it back from there.
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { i18n } from '@kit.LocalizationKit';
import { MicYouController } from './MicYouController';
import { ConnectionStore } from './ConnectionStore';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouEnv';

// The stored appLanguage index mapped to an i18n language tag. "default" makes
// the app follow the system language. zh-CN / zh-TW are the region tags that
// match the zh_CN / zh_TW resource directories; "en" resolves to base (English).
function languageTag(index: number): string {
  if (index === 1) {
    return 'en';
  }
  if (index === 2) {
    return 'zh-CN';
  }
  if (index === 3) {
    return 'zh-TW';
  }
  return 'default';
}

export class AppEnvironment {
  private static context: common.UIAbilityContext | null = null;
  static readonly controller: MicYouController = new MicYouController();
  static readonly connectionStore: ConnectionStore = ConnectionStore.shared;

  static publish(context: common.UIAbilityContext): void {
    AppEnvironment.context = context;
    // Kick off the asynchronous preferences load here so it overlaps with the
    // window/page startup; Index awaits the same promise before rendering.
    AppEnvironment.connectionStore.ensureInit(context);
  }

  static requireContext(): common.UIAbilityContext {
    const context = AppEnvironment.context;
    if (context === null) {
      throw new Error('ability context is not published yet');
    }
    return context;
  }

  /** Push the stored theme choice (0 system / 1 light / 2 dark) onto the window. */
  static applyTheme(): void {
    const context = AppEnvironment.context;
    if (context === null) {
      return;
    }
    const mode: number = AppEnvironment.connectionStore.settings.themeMode;
    let colorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === 1) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === 2) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    try {
      context.setColorMode(colorMode);
    } catch (err) {
      // setColorMode is API 18+; on an older compatible device keep the system theme.
      hilog.warn(DOMAIN, TAG, 'setColorMode unsupported: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * Persist the app's preferred language via i18n. HarmonyOS only re-resolves
   * resources on the next cold start, so the UI does not switch immediately —
   * the Settings hint tells the user to restart the app.
   */
  static applyLanguage(): void {
    const mode: number = AppEnvironment.connectionStore.settings.appLanguage;
    try {
      i18n.System.setAppPreferredLanguage(languageTag(mode));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setAppPreferredLanguage failed: %{public}s', JSON.stringify(err));
    }
  }

  static forget(): void {
    AppEnvironment.context = null;
  }
}
