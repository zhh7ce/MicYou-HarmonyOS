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
 * MicYou HarmonyOS client — persistent connection record and settings.
 * Backed by @ohos.data.preferences under the instance name micyou_prefs.
 * The store is a process-wide singleton: the ability initialises it once with
 * the context, the controller writes a success record, and the page reads the
 * last server / history / settings back and observes changes.
 *
 * History is kept as parallel arrays rather than one JSON blob so the values
 * stay inside the primitive types preferences persists reliably, and no JSON
 * round-trip is needed under strict ArkTS.
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouStore';
const STORE_NAME: string = 'micyou_prefs';
const MAX_HISTORY: number = 10;

const K_LAST_NAME: string = 'last_name';
const K_LAST_HOST: string = 'last_host';
const K_LAST_PORT: string = 'last_port';
const K_LAST_AT: string = 'last_connected_at';
const K_HIST_NAME: string = 'history_name';
const K_HIST_HOST: string = 'history_host';
const K_HIST_PORT: string = 'history_port';
const K_HIST_AT: string = 'history_connected_at';
const K_HIST_COUNT: string = 'history_connect_count';
const K_AUTO_CONNECT: string = 'auto_connect';
const K_THEME: string = 'theme_mode';
const K_LANGUAGE: string = 'app_language';
const K_SAMPLE_RATE: string = 'sample_rate';
const K_CHANNEL_COUNT: string = 'channel_count';
const K_AUDIO_FORMAT: string = 'audio_format';
const K_CODEC: string = 'codec';
const K_SOURCE: string = 'source_type';

const DEFAULT_SAMPLE_RATE: number = 48000;
const DEFAULT_CHANNEL_COUNT: number = 1;
const DEFAULT_AUDIO_FORMAT: number = 2; // 16-bit PCM, mirrors Wire.AUDIO_FORMAT_16BIT
const DEFAULT_CODEC: number = 0; // PCM, mirrors Wire.CODEC_PCM
const DEFAULT_SOURCE: number = 0; // SOURCE_TYPE_MIC, mirrors Wire.SOURCE_MIC

export class StoredServer {
  name: string;
  host: string;
  port: number;
  connectedAt: number;
  connectCount: number;

  constructor(name: string, host: string, port: number, connectedAt: number, connectCount: number) {
    this.name = name;
    this.host = host;
    this.port = port;
    this.connectedAt = connectedAt;
    this.connectCount = connectCount;
  }

  key(): string {
    return `${this.host}:${this.port}`;
  }

  displayName(): string {
    return this.name.length > 0 ? this.name : this.host;
  }
}

export class ConnectionSettings {
  autoConnect: boolean = false;
  // 0 = follow system, 1 = light, 2 = dark (mirrors ConfigurationConstant.ColorMode intent).
  themeMode: number = 0;
  // 0 = follow system, 1 = English, 2 = 简体中文, 3 = 繁體中文. Mapped to an
  // i18n language tag in AppEnvironment.applyLanguage; needs an app restart.
  appLanguage: number = 0;
  sampleRate: number = DEFAULT_SAMPLE_RATE;
  channelCount: number = DEFAULT_CHANNEL_COUNT;
  audioFormat: number = DEFAULT_AUDIO_FORMAT;
  codec: number = DEFAULT_CODEC;
  sourceType: number = DEFAULT_SOURCE;
}

export type StoreChangeHandler = () => void;

export class ConnectionStore {
  static readonly shared: ConnectionStore = new ConnectionStore();

  private prefs: preferences.Preferences | null = null;
  private initPromise: Promise<void> | null = null;
  private lastServer: StoredServer | null = null;
  private historyList: Array<StoredServer> = [];
  private settingsData: ConnectionSettings = new ConnectionSettings();
  private ready: boolean = false;
  onChanged: StoreChangeHandler | null = null;

  ensureInit(context: common.Context): Promise<void> {
    if (this.initPromise === null) {
      this.initPromise = this.init(context);
    }
    return this.initPromise;
  }

  private async init(context: common.Context): Promise<void> {
    try {
      const prefs: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
      this.prefs = prefs;
      await this.reload(prefs);
      this.ready = true;
      hilog.info(DOMAIN, TAG, 'loaded %{public}d history entries', this.historyList.length);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(err));
    }
  }

  isLoaded(): boolean {
    return this.ready;
  }

  get last(): StoredServer | null {
    return this.lastServer;
  }

  get history(): Array<StoredServer> {
    return this.historyList;
  }

  get settings(): ConnectionSettings {
    return this.settingsData;
  }

  private async reload(prefs: preferences.Preferences): Promise<void> {
    const emptyStr: Array<string> = [];
    const emptyNum: Array<number> = [];

    const lastName: string = await prefs.get(K_LAST_NAME, '') as string;
    const lastHost: string = await prefs.get(K_LAST_HOST, '') as string;
    const lastPort: number = await prefs.get(K_LAST_PORT, 0) as number;
    const lastAt: number = await prefs.get(K_LAST_AT, 0) as number;
    this.lastServer = lastHost.length > 0 ? new StoredServer(lastName, lastHost, lastPort, lastAt, 0) : null;

    const names: Array<string> = await prefs.get(K_HIST_NAME, emptyStr) as Array<string>;
    const hosts: Array<string> = await prefs.get(K_HIST_HOST, emptyStr) as Array<string>;
    const ports: Array<number> = await prefs.get(K_HIST_PORT, emptyNum) as Array<number>;
    const ats: Array<number> = await prefs.get(K_HIST_AT, emptyNum) as Array<number>;
    const counts: Array<number> = await prefs.get(K_HIST_COUNT, emptyNum) as Array<number>;

    const list: Array<StoredServer> = [];
    for (let i = 0; i < hosts.length; i++) {
      const name: string = i < names.length ? names[i] : '';
      const port: number = i < ports.length ? ports[i] : 0;
      const at: number = i < ats.length ? ats[i] : 0;
      const count: number = i < counts.length ? counts[i] : 1;
      list.push(new StoredServer(name, hosts[i], port, at, count));
    }
    this.historyList = list;

    this.settingsData.autoConnect = await prefs.get(K_AUTO_CONNECT, false) as boolean;
    this.settingsData.themeMode = await prefs.get(K_THEME, 0) as number;
    this.settingsData.appLanguage = await prefs.get(K_LANGUAGE, 0) as number;
    this.settingsData.sampleRate = await prefs.get(K_SAMPLE_RATE, DEFAULT_SAMPLE_RATE) as number;
    this.settingsData.channelCount = await prefs.get(K_CHANNEL_COUNT, DEFAULT_CHANNEL_COUNT) as number;
    this.settingsData.audioFormat = await prefs.get(K_AUDIO_FORMAT, DEFAULT_AUDIO_FORMAT) as number;
    this.settingsData.codec = await prefs.get(K_CODEC, DEFAULT_CODEC) as number;
    this.settingsData.sourceType = await prefs.get(K_SOURCE, DEFAULT_SOURCE) as number;
  }

  async recordSuccess(name: string, host: string, port: number): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    const now: number = Date.now();
    this.lastServer = new StoredServer(name, host, port, now, 0);

    const key: string = `${host}:${port}`;
    let existing: StoredServer | null = null;
    const kept: Array<StoredServer> = [];
    for (let i = 0; i < this.historyList.length; i++) {
      const entry: StoredServer = this.historyList[i];
      if (entry.key() === key) {
        existing = entry;
      } else {
        kept.push(entry);
      }
    }
    const count: number = existing !== null ? existing.connectCount + 1 : 1;
    const resolvedName: string = name.length > 0 ? name : (existing !== null ? existing.name : '');
    kept.unshift(new StoredServer(resolvedName, host, port, now, count));
    kept.sort((a: StoredServer, b: StoredServer) => b.connectedAt - a.connectedAt);
    if (kept.length > MAX_HISTORY) {
      kept.length = MAX_HISTORY;
    }
    this.historyList = kept;

    await this.persist();
    this.notify();
  }

  async removeHistory(host: string, port: number): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    const key: string = `${host}:${port}`;
    const kept: Array<StoredServer> = [];
    for (let i = 0; i < this.historyList.length; i++) {
      const entry: StoredServer = this.historyList[i];
      if (entry.key() !== key) {
        kept.push(entry);
      }
    }
    this.historyList = kept;
    const last = this.lastServer;
    if (last !== null && last.key() === key) {
      this.lastServer = null;
    }
    await this.persist();
    this.notify();
  }

  async clearHistory(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.historyList = [];
    this.lastServer = null;
    await this.persist();
    this.notify();
  }

  async setAutoConnect(value: boolean): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.settingsData.autoConnect = value;
    await this.persist();
    this.notify();
  }

  async setThemeMode(value: number): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.settingsData.themeMode = value;
    await this.persist();
    this.notify();
  }

  async setAppLanguage(value: number): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.settingsData.appLanguage = value;
    await this.persist();
    this.notify();
  }

  async setChannelCount(value: number): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.settingsData.channelCount = value;
    await this.persist();
    this.notify();
  }

  async setSampleRate(value: number): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.settingsData.sampleRate = value;
    await this.persist();
    this.notify();
  }

  async setAudioFormat(value: number): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.settingsData.audioFormat = value;
    await this.persist();
    this.notify();
  }

  async setCodec(value: number): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.settingsData.codec = value;
    await this.persist();
    this.notify();
  }

  async setSourceType(value: number): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.settingsData.sourceType = value;
    await this.persist();
    this.notify();
  }

  private async persist(): Promise<void> {
    const prefs = this.prefs;
    if (prefs === null) {
      return;
    }
    const last = this.lastServer;
    const names: Array<string> = [];
    const hosts: Array<string> = [];
    const ports: Array<number> = [];
    const ats: Array<number> = [];
    const counts: Array<number> = [];
    for (let i = 0; i < this.historyList.length; i++) {
      const entry: StoredServer = this.historyList[i];
      names.push(entry.name);
      hosts.push(entry.host);
      ports.push(entry.port);
      ats.push(entry.connectedAt);
      counts.push(entry.connectCount);
    }
    try {
      await prefs.put(K_LAST_NAME, last !== null ? last.name : '');
      await prefs.put(K_LAST_HOST, last !== null ? last.host : '');
      await prefs.put(K_LAST_PORT, last !== null ? last.port : 0);
      await prefs.put(K_LAST_AT, last !== null ? last.connectedAt : 0);
      await prefs.put(K_HIST_NAME, names);
      await prefs.put(K_HIST_HOST, hosts);
      await prefs.put(K_HIST_PORT, ports);
      await prefs.put(K_HIST_AT, ats);
      await prefs.put(K_HIST_COUNT, counts);
      await prefs.put(K_AUTO_CONNECT, this.settingsData.autoConnect);
      await prefs.put(K_THEME, this.settingsData.themeMode);
      await prefs.put(K_LANGUAGE, this.settingsData.appLanguage);
      await prefs.put(K_SAMPLE_RATE, this.settingsData.sampleRate);
      await prefs.put(K_CHANNEL_COUNT, this.settingsData.channelCount);
      await prefs.put(K_AUDIO_FORMAT, this.settingsData.audioFormat);
      await prefs.put(K_CODEC, this.settingsData.codec);
      await prefs.put(K_SOURCE, this.settingsData.sourceType);
      await prefs.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'persist failed: %{public}s', JSON.stringify(err));
    }
  }

  private notify(): void {
    const handler = this.onChanged;
    if (handler !== null) {
      handler();
    }
  }
}
