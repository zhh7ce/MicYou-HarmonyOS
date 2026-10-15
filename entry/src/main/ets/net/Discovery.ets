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
 * MicYou HarmonyOS client — mDNS discovery of the desktop server.
 * The desktop advertises _micyou._tcp; the phone browses for it and connects
 * out to the advertised TCP port, so nothing needs to be listening on the phone.
 */

import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { DEFAULT_TCP_PORT, MDNS_SERVICE_TYPE } from './Wire';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouDiscovery';

export class DiscoveredServer {
  name: string;
  host: string;
  port: number;

  constructor(name: string, host: string, port: number) {
    this.name = name;
    this.host = host;
    this.port = port;
  }

  label(): string {
    return `${this.name} (${this.host}:${this.port})`;
  }
}

export type FoundHandler = (server: DiscoveredServer) => void;

export class ServerDiscovery {
  private service: mdns.DiscoveryService | null = null;
  private context: common.Context | null = null;
  private readonly listener: (info: mdns.LocalServiceInfo) => void = (info: mdns.LocalServiceInfo) => {
    this.handleFound(info);
  };
  onFound: FoundHandler | null = null;

  private emit(info: mdns.LocalServiceInfo, source: string): void {
    const host: string = info.host?.address ?? '';
    hilog.debug(DOMAIN, TAG, '%{public}s %{public}s host=%{public}s port=%{public}s', source, info.serviceName,
      host.length === 0 ? '<none>' : host, `${info.port}`);
    if (host.length === 0) {
      return;
    }
    const handler = this.onFound;
    if (handler !== null) {
      // Browse reports port -1 until a resolve fills it in.
      const port: number = info.port !== undefined && info.port > 0 ? info.port : DEFAULT_TCP_PORT;
      handler(new DiscoveredServer(info.serviceName, host, port));
    }
  }

  private handleFound(info: mdns.LocalServiceInfo): void {
    // A browse event only carries the instance name; the address needs a resolve pass.
    if ((info.host?.address ?? '').length > 0) {
      this.emit(info, 'found');
      return;
    }
    const context = this.context;
    if (context === null) {
      return;
    }
    mdns.resolveLocalService(context, info).then((resolved: mdns.LocalServiceInfo) => {
      this.emit(resolved, 'resolved');
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'resolve failed for %{public}s: %{public}s', info.serviceName, JSON.stringify(err));
    });
  }

  start(context: common.Context): void {
    if (this.service !== null) {
      return;
    }
    this.context = context;
    const service = mdns.createDiscoveryService(context, MDNS_SERVICE_TYPE);
    service.on('serviceFound', this.listener);
    service.startSearchingMDNS();
    this.service = service;
    hilog.info(DOMAIN, TAG, 'browsing %{public}s', MDNS_SERVICE_TYPE);
  }

  stop(): void {
    const service = this.service;
    if (service === null) {
      return;
    }
    service.stopSearchingMDNS();
    service.off('serviceFound', this.listener);
    this.service = null;
    this.context = null;
  }
}
