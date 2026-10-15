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
 * MicYou HarmonyOS client — settings destination.
 * The Android home screen has no counterpart for connection history, the last
 * connected device or auto-connect, so those live here, alongside the theme
 * choice and the capture settings (source, sample rate, channels, bit depth,
 * codec). Capture choices apply to the next session and are gated by the
 * running device's API level, keeping the compile baseline at 5.0.0(12).
 * Rendered inside a NavDestination pushed by the home Navigation.
 */

import { deviceInfo } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';

import { AppEnvironment } from '../app/AppEnvironment';
import { ConnectionStore, StoredServer } from '../app/ConnectionStore';
import {
  AUDIO_FORMAT_16BIT,
  AUDIO_FORMAT_24BIT,
  AUDIO_FORMAT_FLOAT32,
  CODEC_OPUS,
  CODEC_PCM,
  SOURCE_CAMCORDER,
  SOURCE_LIVE,
  SOURCE_MIC,
  SOURCE_UNPROCESSED,
  SOURCE_VOICE_COMMUNICATION,
  SOURCE_VOICE_RECOGNITION,
  isOpusNativeRate
} from '../net/Wire';

interface ThemeChoice {
  value: number;
  label: Resource;
}

interface ChannelChoice {
  value: number;
  label: Resource;
}

// Source choices carry the minimum HarmonyOS API level that exposes them, so the
// UI only offers what the running device can actually create.
interface SourceChoice {
  value: number;
  minApi: number;
  label: Resource;
}

interface TextChoice {
  value: number;
  label: string;
}

interface CodecChoice {
  value: number;
  label: Resource;
  available: boolean;
}

interface RateChipArgs {
  choice: TextChoice;
  disabled: boolean;
}

interface BitDepthChipArgs {
  choice: TextChoice;
  disabled: boolean;
}

const THEME_CHOICES: Array<ThemeChoice> = [
  { value: 0, label: $r('app.string.theme_system') },
  { value: 1, label: $r('app.string.theme_light') },
  { value: 2, label: $r('app.string.theme_dark') }
];

// Language labels are shown in their own tongue, so they stay identical across
// locales. Options map to the resource directories that exist: base (en),
// zh_CN, zh_TW. System follows the device language ("default").
const LANGUAGE_CHOICES: Array<ThemeChoice> = [
  { value: 0, label: $r('app.string.lang_system') },
  { value: 1, label: $r('app.string.lang_en') },
  { value: 2, label: $r('app.string.lang_zh_cn') },
  { value: 3, label: $r('app.string.lang_zh_tw') }
];

const CHANNEL_CHOICES: Array<ChannelChoice> = [
  { value: 1, label: $r('app.string.channel_mono') },
  { value: 2, label: $r('app.string.channel_stereo') }
];

const SOURCE_CHOICES: Array<SourceChoice> = [
  { value: SOURCE_MIC, minApi: 8, label: $r('app.string.source_mic') },
  { value: SOURCE_VOICE_COMMUNICATION, minApi: 8, label: $r('app.string.source_voice_comm') },
  { value: SOURCE_VOICE_RECOGNITION, minApi: 9, label: $r('app.string.source_voice_recog') },
  { value: SOURCE_CAMCORDER, minApi: 13, label: $r('app.string.source_camcorder') },
  { value: SOURCE_UNPROCESSED, minApi: 14, label: $r('app.string.source_unprocessed') },
  { value: SOURCE_LIVE, minApi: 20, label: $r('app.string.source_live') }
];

// Stored value is the wire audioFormat constant the desktop decoder keys on.
const BITDEPTH_CHOICES: Array<TextChoice> = [
  { value: AUDIO_FORMAT_16BIT, label: '16-bit' },
  { value: AUDIO_FORMAT_24BIT, label: '24-bit' },
  { value: AUDIO_FORMAT_FLOAT32, label: '32-bit float' }
];

const RATE_CHOICES: Array<TextChoice> = [
  { value: 16000, label: '16 kHz' },
  { value: 44100, label: '44.1 kHz' },
  { value: 48000, label: '48 kHz' },
  { value: 96000, label: '96 kHz' }
];

const CODEC_CHOICES: Array<CodecChoice> = [
  { value: CODEC_PCM, label: $r('app.string.codec_pcm'), available: true },
  { value: CODEC_OPUS, label: $r('app.string.codec_opus'), available: true }
];

@Component
export struct SettingsView {
  onBack: () => void = () => {};
  @State autoConnect: boolean = false;
  @State themeMode: number = 0;
  @State appLanguage: number = 0;
  @State channelCount: number = 1;
  @State sourceType: number = SOURCE_MIC;
  @State sampleRate: number = 48000;
  @State audioFormat: number = AUDIO_FORMAT_16BIT;
  @State codec: number = CODEC_PCM;
  @State deviceApi: number = 12;
  @State lastServer: StoredServer | null = null;
  @State historyList: Array<StoredServer> = [];

  aboutToAppear(): void {
    this.deviceApi = deviceInfo.sdkApiVersion;
    this.refresh();
  }

  private refresh(): void {
    const store: ConnectionStore = ConnectionStore.shared;
    this.lastServer = store.last;
    this.historyList = store.history.slice();
    this.autoConnect = store.settings.autoConnect;
    this.themeMode = store.settings.themeMode;
    this.appLanguage = store.settings.appLanguage;
    this.channelCount = store.settings.channelCount;
    this.sourceType = store.settings.sourceType;
    this.sampleRate = store.settings.sampleRate;
    this.audioFormat = store.settings.audioFormat;
    this.codec = store.settings.codec;
  }

  private availableSources(): Array<SourceChoice> {
    const list: Array<SourceChoice> = [];
    for (let i = 0; i < SOURCE_CHOICES.length; i++) {
      const choice: SourceChoice = SOURCE_CHOICES[i];
      if (choice.minApi <= this.deviceApi) {
        list.push(choice);
      }
    }
    return list;
  }

  private setAutoConnect(value: boolean): void {
    if (value === this.autoConnect) {
      return;
    }
    this.autoConnect = value;
    ConnectionStore.shared.setAutoConnect(value);
    this.refresh();
  }

  private setTheme(value: number): void {
    if (value === this.themeMode) {
      return;
    }
    this.themeMode = value;
    ConnectionStore.shared.setThemeMode(value);
    AppEnvironment.applyTheme();
    this.refresh();
  }

  private setLanguage(value: number): void {
    if (value === this.appLanguage) {
      return;
    }
    this.appLanguage = value;
    ConnectionStore.shared.setAppLanguage(value);
    AppEnvironment.applyLanguage();
    this.refresh();
  }

  private setChannel(value: number): void {
    if (value === this.channelCount) {
      return;
    }
    this.channelCount = value;
    ConnectionStore.shared.setChannelCount(value);
    this.refresh();
  }

  private setSource(value: number): void {
    if (value === this.sourceType) {
      return;
    }
    this.sourceType = value;
    ConnectionStore.shared.setSourceType(value);
    this.refresh();
  }

  private setRate(value: number): void {
    if (value === this.sampleRate) {
      return;
    }
    this.sampleRate = value;
    ConnectionStore.shared.setSampleRate(value);
    this.refresh();
  }

  private setBitDepth(value: number): void {
    if (value === this.audioFormat) {
      return;
    }
    this.audioFormat = value;
    ConnectionStore.shared.setAudioFormat(value);
    this.refresh();
  }

  private setCodecValue(value: number): void {
    if (value === this.codec) {
      return;
    }
    this.codec = value;
    ConnectionStore.shared.setCodec(value);
    if (value === CODEC_OPUS) {
      // Migrate an already-stored choice Opus cannot encode; the controller
      // would clamp it at session start anyway, so the UI must not keep
      // showing a value that is not in effect.
      if (!isOpusNativeRate(this.sampleRate)) {
        this.sampleRate = 48000;
        ConnectionStore.shared.setSampleRate(48000);
      }
      if (this.audioFormat !== AUDIO_FORMAT_16BIT) {
        this.audioFormat = AUDIO_FORMAT_16BIT;
        ConnectionStore.shared.setAudioFormat(AUDIO_FORMAT_16BIT);
      }
    }
    this.refresh();
  }

  private opusLockedRate(value: number): boolean {
    return this.codec === CODEC_OPUS && !isOpusNativeRate(value);
  }

  private opusLockedFormat(value: number): boolean {
    return this.codec === CODEC_OPUS && value !== AUDIO_FORMAT_16BIT;
  }

  private removeEntry(host: string, port: number): void {
    ConnectionStore.shared.removeHistory(host, port);
    this.refresh();
  }

  private clearAll(): void {
    ConnectionStore.shared.clearHistory();
    this.refresh();
  }

  @Builder
  sectionHeader(title: Resource) {
    Row({ space: 8 }) {
      Column()
        .width(5)
        .height(18)
        .borderRadius(3)
        .backgroundColor($r('app.color.primary'))
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  fieldLabel(label: Resource, hint: Resource) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.on_surface'))
      Text(hint)
        .fontSize(12)
        .fontColor($r('app.color.on_surface_variant'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  themeChip(choice: ThemeChoice) {
    Text(choice.label)
      .fontSize(14)
      .fontColor(this.themeMode === choice.value
        ? $r('app.color.on_primary') : $r('app.color.on_surface_variant'))
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor(this.themeMode === choice.value
        ? $r('app.color.primary') : $r('app.color.surface_container_high'))
      .onClick(() => this.setTheme(choice.value))
  }

  @Builder
  languageChip(choice: ThemeChoice) {
    Text(choice.label)
      .fontSize(14)
      .fontColor(this.appLanguage === choice.value
        ? $r('app.color.on_primary') : $r('app.color.on_surface_variant'))
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor(this.appLanguage === choice.value
        ? $r('app.color.primary') : $r('app.color.surface_container_high'))
      .onClick(() => this.setLanguage(choice.value))
  }

  @Builder
  channelChip(choice: ChannelChoice) {
    Text(choice.label)
      .fontSize(14)
      .fontColor(this.channelCount === choice.value
        ? $r('app.color.on_primary') : $r('app.color.on_surface_variant'))
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor(this.channelCount === choice.value
        ? $r('app.color.primary') : $r('app.color.surface_container_high'))
      .onClick(() => this.setChannel(choice.value))
  }

  @Builder
  sourceChip(choice: SourceChoice) {
    Text(choice.label)
      .fontSize(14)
      .fontColor(this.sourceType === choice.value
        ? $r('app.color.on_primary') : $r('app.color.on_surface_variant'))
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor(this.sourceType === choice.value
        ? $r('app.color.primary') : $r('app.color.surface_container_high'))
      .onClick(() => this.setSource(choice.value))
  }

  @Builder
  rateChip(args: RateChipArgs) {
    Text(args.choice.label)
      .fontSize(14)
      .fontColor(args.disabled
        ? $r('app.color.outline')
        : (this.sampleRate === args.choice.value ? $r('app.color.on_primary') : $r('app.color.on_surface_variant')))
      .opacity(args.disabled ? 0.5 : 1)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor(this.sampleRate === args.choice.value
        ? $r('app.color.primary') : $r('app.color.surface_container_high'))
      .onClick(() => {
        if (!args.disabled) {
          this.setRate(args.choice.value);
        }
      })
  }

  @Builder
  bitDepthChip(args: BitDepthChipArgs) {
    Text(args.choice.label)
      .fontSize(14)
      .fontColor(args.disabled
        ? $r('app.color.outline')
        : (this.audioFormat === args.choice.value ? $r('app.color.on_primary') : $r('app.color.on_surface_variant')))
      .opacity(args.disabled ? 0.5 : 1)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor(this.audioFormat === args.choice.value
        ? $r('app.color.primary') : $r('app.color.surface_container_high'))
      .onClick(() => {
        if (!args.disabled) {
          this.setBitDepth(args.choice.value);
        }
      })
  }

  @Builder
  codecChip(choice: CodecChoice) {
    Text(choice.label)
      .fontSize(14)
      .fontColor(!choice.available
        ? $r('app.color.outline')
        : (this.codec === choice.value ? $r('app.color.on_primary') : $r('app.color.on_surface_variant')))
      .opacity(choice.available ? 1 : 0.5)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor(choice.available && this.codec === choice.value
        ? $r('app.color.primary') : $r('app.color.surface_container_high'))
      .onClick(() => {
        if (choice.available) {
          this.setCodecValue(choice.value);
        }
      })
  }

  build() {
    NavDestination() {
      Column({ space: 16 }) {
        Row({ space: 4 }) {
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(22)
              .fontColor([$r('app.color.on_surface')])
          }
          .width(40)
          .height(40)
          .backgroundColor($r('app.color.surface_container'))
          .onClick(() => this.onBack())

          Text($r('app.string.settings_title'))
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_surface'))
            .margin({ left: 8 })
        }
        .width('100%')
        .padding({ top: 8, bottom: 4 })

        Scroll() {
          Column({ space: 20 }) {
            // Appearance
            Column({ space: 12 }) {
              this.sectionHeader($r('app.string.section_appearance'))

              Column({ space: 10 }) {
                Text($r('app.string.theme_mode'))
                  .fontSize(15)
                  .fontColor($r('app.color.on_surface'))
                Row({ space: 10 }) {
                  ForEach(THEME_CHOICES, (choice: ThemeChoice) => {
                    this.themeChip(choice)
                  }, (choice: ThemeChoice) => `${choice.value}`)
                }
                .width('100%')

                Divider().color($r('app.color.surface_container_high'))

                Text($r('app.string.lang_mode'))
                  .fontSize(15)
                  .fontColor($r('app.color.on_surface'))
                Text($r('app.string.lang_restart_hint'))
                  .fontSize(12)
                  .fontColor($r('app.color.on_surface_variant'))
                  .width('100%')
                Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(10), cross: LengthMetrics.vp(10) } }) {
                  ForEach(LANGUAGE_CHOICES, (choice: ThemeChoice) => {
                    this.languageChip(choice)
                  }, (choice: ThemeChoice) => `${choice.value}`)
                }
                .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.surface_bright'))
            }
            .width('100%')

            // Audio
            Column({ space: 12 }) {
              this.sectionHeader($r('app.string.section_audio'))

              Column({ space: 14 }) {
                this.fieldLabel($r('app.string.source_mode'), $r('app.string.audio_applies_hint'))
                Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(10), cross: LengthMetrics.vp(10) } }) {
                  ForEach(this.availableSources(), (choice: SourceChoice) => {
                    this.sourceChip(choice)
                  }, (choice: SourceChoice) => `${choice.value}`)
                }
                .width('100%')

                Divider().color($r('app.color.surface_container_high'))

                this.fieldLabel($r('app.string.sample_rate_mode'), $r('app.string.audio_applies_hint'))
                Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(10), cross: LengthMetrics.vp(10) } }) {
                  ForEach(RATE_CHOICES, (choice: TextChoice) => {
                    this.rateChip({ choice: choice, disabled: this.opusLockedRate(choice.value) })
                  }, (choice: TextChoice) => `${choice.value}`)
                }
                .width('100%')

                Divider().color($r('app.color.surface_container_high'))

                this.fieldLabel($r('app.string.channel_mode'), $r('app.string.channel_mode_hint'))
                Row({ space: 10 }) {
                  ForEach(CHANNEL_CHOICES, (choice: ChannelChoice) => {
                    this.channelChip(choice)
                  }, (choice: ChannelChoice) => `${choice.value}`)
                }
                .width('100%')

                Divider().color($r('app.color.surface_container_high'))

                this.fieldLabel($r('app.string.bitdepth_mode'), $r('app.string.bitdepth_hint'))
                Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(10), cross: LengthMetrics.vp(10) } }) {
                  ForEach(BITDEPTH_CHOICES, (choice: TextChoice) => {
                    this.bitDepthChip({ choice: choice, disabled: this.opusLockedFormat(choice.value) })
                  }, (choice: TextChoice) => `${choice.value}`)
                }
                .width('100%')

                Divider().color($r('app.color.surface_container_high'))

                this.fieldLabel($r('app.string.codec_mode'), $r('app.string.codec_opus_hint'))
                Row({ space: 10 }) {
                  ForEach(CODEC_CHOICES, (choice: CodecChoice) => {
                    this.codecChip(choice)
                  }, (choice: CodecChoice) => `${choice.value}`)
                }
                .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.surface_bright'))
            }
            .width('100%')

            // Connection record
            Column({ space: 12 }) {
              this.sectionHeader($r('app.string.section_connection'))

              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text($r('app.string.auto_connect'))
                    .fontSize(15)
                    .fontColor($r('app.color.on_surface'))
                  Text($r('app.string.auto_connect_hint'))
                    .fontSize(12)
                    .fontColor($r('app.color.on_surface_variant'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.autoConnect })
                  .selectedColor($r('app.color.primary'))
                  .onChange((isOn: boolean) => this.setAutoConnect(isOn))
              }
              .width('100%')
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.surface_bright'))

              if (this.lastServer !== null) {
                Column({ space: 6 }) {
                  Text($r('app.string.last_header'))
                    .fontSize(13)
                    .fontColor($r('app.color.on_surface_variant'))
                  Row({ space: 8 }) {
                    Text((this.lastServer as StoredServer).displayName())
                      .fontSize(15)
                      .fontColor($r('app.color.on_surface'))
                    Text(`${(this.lastServer as StoredServer).host}:${(this.lastServer as StoredServer).port}`)
                      .fontSize(12)
                      .fontColor($r('app.color.on_surface_variant'))
                    Blank()
                  }
                  .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding(16)
                .borderRadius(16)
                .backgroundColor($r('app.color.surface_bright'))
              }

              Column({ space: 10 }) {
                Text($r('app.string.history_header'))
                  .fontSize(13)
                  .fontColor($r('app.color.on_surface_variant'))

                if (this.historyList.length === 0) {
                  Text($r('app.string.history_empty'))
                    .fontSize(12)
                    .fontColor($r('app.color.on_surface_variant'))
                    .width('100%')
                }

                ForEach(this.historyList, (entry: StoredServer) => {
                  Row({ space: 8 }) {
                    Column({ space: 2 }) {
                      Row({ space: 6 }) {
                        Text(entry.displayName())
                          .fontSize(15)
                          .fontColor($r('app.color.on_surface'))
                        if (entry.connectCount > 1) {
                          Text(`×${entry.connectCount}`)
                            .fontSize(11)
                            .fontColor($r('app.color.on_surface_variant'))
                        }
                      }
                      Text(`${entry.host}:${entry.port}`)
                        .fontSize(12)
                        .fontColor($r('app.color.on_surface_variant'))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Button({ type: ButtonType.Circle, stateEffect: true }) {
                      SymbolGlyph($r('sys.symbol.xmark'))
                        .fontSize(16)
                        .fontColor([$r('app.color.on_surface_variant')])
                    }
                    .width(36)
                    .height(36)
                    .backgroundColor($r('app.color.surface_container'))
                    .onClick(() => this.removeEntry(entry.host, entry.port))
                  }
                  .width('100%')
                }, (entry: StoredServer) => entry.key())

                if (this.historyList.length > 0) {
                  Text($r('app.string.clear_history'))
                    .fontSize(14)
                    .fontColor($r('app.color.error'))
                    .onClick(() => this.clearAll())
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.surface_bright'))
            }
            .width('100%')

            // About
            Column({ space: 8 }) {
              this.sectionHeader($r('app.string.section_about'))
              Column({ space: 6 }) {
                Text($r('app.string.page_title'))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.on_surface'))
                Text($r('app.string.notice'))
                  .fontSize(12)
                  .fontColor($r('app.color.on_surface_variant'))
                  .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.surface_bright'))
            }
            .width('100%')
          }
          .width('100%')
          .padding({ bottom: 24 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_container'))
    }
    .hideTitleBar(true)
  }
}
