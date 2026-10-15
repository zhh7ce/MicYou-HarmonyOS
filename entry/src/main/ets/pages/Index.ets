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
 * MicYou HarmonyOS client — the single screen, laid out to match the Android
 * MobileHome: a header card, a connection card (discovered list + manual
 * address), a full-height control card with the level ring under a centred
 * start/stop FAB, and a bottom bar with the mute pill and status dot.
 * The Android phone UI shows no link statistics, so none are rendered here;
 * stats live only on the desktop. Settings is a NavDestination holding the
 * connection record (history / last / auto-connect) and the theme mode,
 * because Android keeps no counterpart for those on the phone home screen.
 */

import { AppEnvironment } from '../app/AppEnvironment';
import { EnginePhase, EngineSnapshot, MicYouController } from '../app/MicYouController';
import { ConnectionStore, StoredServer } from '../app/ConnectionStore';
import { DiscoveredServer, ServerDiscovery } from '../net/Discovery';
import { DEFAULT_TCP_PORT } from '../net/Wire';
import { SettingsView } from './SettingsView';

// Give mDNS a window to re-resolve a device that may have changed IP before an
// auto-connect commits to the stale address in history.
const AUTO_CONNECT_DELAY_MS: number = 1500;

@Entry
@Component
struct Index {
  @State phase: EnginePhase = EnginePhase.Idle;
  @State peer: string = '';
  @State failure: string = '';
  @State muted: boolean = false;
  @State rms: number = 0;
  @State servers: Array<DiscoveredServer> = [];
  @State hostInput: string = '';
  @State portInput: string = `${DEFAULT_TCP_PORT}`;
  @State targetName: string = '';
  @State selectedKey: string = '';
  private readonly pathStack: NavPathStack = new NavPathStack();
  private readonly discovery: ServerDiscovery = new ServerDiscovery();
  private readonly controller: MicYouController = AppEnvironment.controller;

  async aboutToAppear(): Promise<void> {
    this.controller.attach((snapshot: EngineSnapshot) => this.applySnapshot(snapshot));
    this.discovery.onFound = (server: DiscoveredServer) => this.remember(server);
    // Start browsing before the preferences load so discovery is not blocked.
    this.discovery.start(AppEnvironment.requireContext());

    const store: ConnectionStore = ConnectionStore.shared;
    await store.ensureInit(AppEnvironment.requireContext());
    this.prefillFromLast(store.last);
    this.maybeAutoConnect();
  }

  aboutToDisappear(): void {
    this.discovery.stop();
    ConnectionStore.shared.onChanged = null;
    this.controller.detach();
  }

  private applySnapshot(snapshot: EngineSnapshot): void {
    this.phase = snapshot.phase;
    this.peer = snapshot.peer;
    this.failure = snapshot.error;
    this.muted = snapshot.muted;
    this.rms = snapshot.rms;
  }

  private prefillFromLast(last: StoredServer | null): void {
    if (last === null || this.hostInput.length > 0) {
      return;
    }
    this.hostInput = last.host;
    this.portInput = `${last.port}`;
    this.targetName = last.name;
    this.selectedKey = last.key();
  }

  private remember(server: DiscoveredServer): void {
    for (let i = 0; i < this.servers.length; i++) {
      const known = this.servers[i];
      if (known.host === server.host && known.port === server.port) {
        return;
      }
    }
    this.servers.push(server);
  }

  private rescan(): void {
    this.servers = [];
    this.discovery.stop();
    this.discovery.start(AppEnvironment.requireContext());
  }

  private selectTarget(server: DiscoveredServer): void {
    this.hostInput = server.host;
    this.portInput = `${server.port}`;
    this.targetName = server.name;
    this.selectedKey = `${server.host}:${server.port}`;
  }

  private connectTo(host: string, port: number, name: string): void {
    const trimmed: string = host.trim();
    if (trimmed.length === 0 || port <= 0 || port > 65534) {
      return;
    }
    this.controller.start(AppEnvironment.requireContext(), trimmed, port, name);
  }

  private toggleRun(): void {
    if (this.phase === EnginePhase.Streaming || this.phase === EnginePhase.Connecting) {
      this.controller.stop();
      return;
    }
    this.connectTo(this.hostInput, this.portOrDefault(), this.targetName);
  }

  private maybeAutoConnect(): void {
    const store: ConnectionStore = ConnectionStore.shared;
    const last: StoredServer | null = store.last;
    if (!store.settings.autoConnect || last === null) {
      return;
    }
    if (this.phase !== EnginePhase.Idle || this.controller.wasManuallyStopped()) {
      return;
    }
    setTimeout(() => {
      // Re-check after the mDNS window: the user may have connected or stopped
      // in the meantime, and a same-name discovery overrides the stale address.
      if (this.phase !== EnginePhase.Idle || this.controller.wasManuallyStopped()) {
        return;
      }
      let host: string = last.host;
      let port: number = last.port;
      for (let i = 0; i < this.servers.length; i++) {
        const found: DiscoveredServer = this.servers[i];
        if (last.name.length > 0 && found.name === last.name) {
          host = found.host;
          port = found.port;
          break;
        }
      }
      this.connectTo(host, port, last.name);
    }, AUTO_CONNECT_DELAY_MS);
  }

  private portOrDefault(): number {
    const parsed: number = Number.parseInt(this.portInput, 10);
    return Number.isNaN(parsed) ? DEFAULT_TCP_PORT : parsed;
  }

  private statusText(): Resource {
    if (this.phase === EnginePhase.Connecting) {
      return $r('app.string.status_connecting');
    }
    if (this.phase === EnginePhase.Streaming) {
      return $r('app.string.status_streaming');
    }
    if (this.phase === EnginePhase.Failed) {
      return $r('app.string.status_failed');
    }
    return $r('app.string.status_idle');
  }

  private statusColor(): ResourceColor {
    if (this.phase === EnginePhase.Streaming) {
      return $r('app.color.primary');
    }
    if (this.phase === EnginePhase.Connecting) {
      return $r('app.color.tertiary');
    }
    if (this.phase === EnginePhase.Failed) {
      return $r('app.color.error');
    }
    return $r('app.color.on_surface_variant');
  }

  private fabColor(): ResourceColor {
    if (this.phase === EnginePhase.Connecting) {
      return $r('app.color.tertiary');
    }
    if (this.phase === EnginePhase.Streaming) {
      return $r('app.color.error');
    }
    return $r('app.color.primary');
  }

  private fabSymbol(): Resource {
    if (this.phase === EnginePhase.Connecting) {
      return $r('sys.symbol.arrow_clockwise');
    }
    if (this.phase === EnginePhase.Streaming) {
      return $r('sys.symbol.link_slash');
    }
    return $r('sys.symbol.link');
  }

  private fabSize(): number {
    return this.phase === EnginePhase.Streaming ? 100 : 80;
  }

  private levelPercent(): number {
    // Voice RMS sits low, so a square-root mapping keeps the ring responsive.
    return Math.round(Math.min(1, Math.sqrt(this.rms)) * 100);
  }

  @Builder
  routeMap(name: string) {
    if (name === 'settings') {
      SettingsView({ onBack: () => this.pathStack.pop() })
    }
  }

  build() {
    Navigation(this.pathStack) {
      Column({ space: 10 }) {
        // 1. Header card
        Row({ space: 12 }) {
          Image($r('app.media.app_logo'))
            .width(36)
            .height(36)
            .borderRadius(10)
            .alt($r('app.string.page_title'))

          Column({ space: 2 }) {
            Text($r('app.string.page_title'))
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.primary'))
            Text($r('app.string.page_subtitle'))
              .fontSize(12)
              .fontColor($r('app.color.on_surface_variant'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.gearshape'))
              .fontSize(20)
              .fontColor([$r('app.color.on_surface_variant')])
          }
          .width(40)
          .height(40)
          .backgroundColor($r('app.color.surface_container'))
          .onClick(() => this.pathStack.pushPath({ name: 'settings' }))
        }
        .width('100%')
        .padding(14)
        .borderRadius(20)
        .backgroundColor($r('app.color.surface_bright'))

        // 2. Connection card
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text($r('app.string.discovered_header'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_surface'))
              .layoutWeight(1)
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                .fontSize(18)
                .fontColor([$r('app.color.primary')])
            }
            .width(34)
            .height(34)
            .backgroundColor($r('app.color.surface_container'))
            .onClick(() => this.rescan())
          }
          .width('100%')

          if (this.servers.length === 0) {
            Text($r('app.string.scanning'))
              .fontSize(12)
              .fontColor($r('app.color.on_surface_variant'))
              .width('100%')
          }
          ForEach(this.servers, (server: DiscoveredServer) => {
            Row({ space: 8 }) {
              SymbolGlyph(this.selectedKey === `${server.host}:${server.port}`
                ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle_fill'))
                .fontSize(16)
                .fontColor([this.selectedKey === `${server.host}:${server.port}`
                  ? $r('app.color.primary') : $r('app.color.outline')])
              Column({ space: 2 }) {
                Text(server.name)
                  .fontSize(14)
                  .fontColor($r('app.color.on_surface'))
                Text(`${server.host}:${server.port}`)
                  .fontSize(12)
                  .fontColor($r('app.color.on_surface_variant'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding(10)
            .borderRadius(12)
            .backgroundColor(this.selectedKey === `${server.host}:${server.port}`
              ? $r('app.color.primary_container') : $r('app.color.surface_container_high'))
            .onClick(() => this.selectTarget(server))
          }, (server: DiscoveredServer) => `${server.host}:${server.port}`)

          Row({ space: 8 }) {
            TextInput({ placeholder: $r('app.string.host_hint'), text: this.hostInput })
              .fontSize(14)
              .layoutWeight(2)
              .onChange((value: string) => {
                this.hostInput = value;
                this.targetName = '';
                this.selectedKey = value.trim().length > 0 ? `${value.trim()}:${this.portOrDefault()}` : '';
              })
            TextInput({ placeholder: $r('app.string.port_hint'), text: this.portInput })
              .fontSize(14)
              .type(InputType.Number)
              .width(96)
              .onChange((value: string) => {
                this.portInput = value;
              })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .borderRadius(20)
        .backgroundColor($r('app.color.surface_bright'))

        // 3. Control card: status + level ring + FAB
        Column({ space: 8 }) {
          Row({ space: 6 }) {
            Text(this.statusText())
              .fontSize(14)
              .fontColor(this.statusColor())
            if (this.phase === EnginePhase.Streaming) {
              Text($r('app.string.live'))
                .fontSize(10)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.live_badge'))
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
                .backgroundColor($r('app.color.primary'))
            }
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')

          if (this.peer.length > 0) {
            Text(this.peer)
              .fontSize(12)
              .fontColor($r('app.color.on_surface_variant'))
          }

          Stack() {
            Progress({ value: this.levelPercent(), total: 100, type: ProgressType.Ring })
              .width(200)
              .height(200)
              .color($r('app.color.primary'))
              .backgroundColor($r('app.color.surface_container_high'))
              .style({ strokeWidth: 10 })
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph(this.fabSymbol())
                .fontSize(32)
                .fontColor([$r('app.color.on_primary')])
            }
            .width(this.fabSize())
            .height(this.fabSize())
            .backgroundColor(this.fabColor())
            .onClick(() => this.toggleRun())
          }
          .layoutWeight(1)

          if (this.failure.length > 0) {
            Text(this.failure)
              .fontSize(12)
              .fontColor($r('app.color.error'))
              .textAlign(TextAlign.Center)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding(14)
        .borderRadius(20)
        .backgroundColor($r('app.color.surface_bright'))

        // 4. Bottom bar: mute pill + status dot
        Row() {
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            Row({ space: 6 }) {
              SymbolGlyph(this.muted ? $r('sys.symbol.mic_slash') : $r('sys.symbol.mic_fill'))
                .fontSize(16)
                .fontColor([this.muted
                  ? $r('app.color.on_error_container') : $r('app.color.on_surface_variant')])
              Text(this.muted ? $r('app.string.unmute') : $r('app.string.mute'))
                .fontSize(14)
                .fontColor(this.muted
                  ? $r('app.color.on_error_container') : $r('app.color.on_surface_variant'))
            }
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          }
          .borderRadius(20)
          .backgroundColor(this.muted
            ? $r('app.color.error_container') : $r('app.color.surface_container_highest'))
          .onClick(() => this.controller.toggleMute())

          Blank()

          SymbolGlyph($r('sys.symbol.circle_fill'))
            .fontSize(14)
            .fontColor([this.statusColor()])
        }
        .width('100%')
        .padding({ left: 14, right: 14 })
      }
      .width('100%')
      .height('100%')
      .padding(12)
      .backgroundColor($r('app.color.surface_container'))
    }
    .navDestination(this.routeMap)
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
  }
}
