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
 * MicYou HarmonyOS client — UDP audio path.
 * Audio frames go to the TCP port + 1 with the "MicU" magic, and the server
 * only accepts them when the source IP matches the live control connection.
 */

import { connection, socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { buildFrame, FRAME_HEADER_SIZE, UDP_MAX_DATAGRAM_SIZE, UDP_PACKET_MAGIC } from './Wire';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouAudioOut';
const MAX_CONSECUTIVE_FAILURES: number = 500;

export class AudioSender {
  private readonly sock: socket.UDPSocket = socket.constructUDPSocketInstance();
  private target: connection.NetAddress | null = null;
  private consecutiveFailures: number = 0;
  private bound: boolean = false;

  async start(host: string, tcpPort: number): Promise<void> {
    const bindAddress: connection.NetAddress = { address: '0.0.0.0', port: 0, family: 1 };
    await this.sock.bind(bindAddress);
    this.bound = true;
    this.target = { address: host, port: tcpPort, family: 1 };
  }

  send(payload: Uint8Array): void {
    const target = this.target;
    if (target === null) {
      return;
    }
    if (FRAME_HEADER_SIZE + payload.length > UDP_MAX_DATAGRAM_SIZE) {
      hilog.warn(DOMAIN, TAG, 'dropped oversized datagram: %{public}d', payload.length);
      return;
    }
    const options: socket.UDPSendOptions = {
      data: buildFrame(UDP_PACKET_MAGIC, payload),
      address: target
    };
    this.sock.send(options).then(() => {
      this.consecutiveFailures = 0;
    }).catch((err: BusinessError) => {
      this.consecutiveFailures += 1;
      if (this.consecutiveFailures === MAX_CONSECUTIVE_FAILURES) {
        hilog.error(DOMAIN, TAG, 'UDP send failed %{public}d times in a row', this.consecutiveFailures);
      }
    });
  }

  sendFailedHard(): boolean {
    return this.consecutiveFailures >= MAX_CONSECUTIVE_FAILURES;
  }

  stop(): void {
    this.target = null;
    if (this.bound) {
      this.bound = false;
      this.sock.close().catch((err: BusinessError) => {
        hilog.debug(DOMAIN, TAG, 'udp close ignored: %{public}s', JSON.stringify(err));
      });
    }
  }
}
