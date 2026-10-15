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
 * MicYou HarmonyOS client — TCP control connection.
 * Handshake, frame dispatch, pong replies and heartbeat supervision.
 */

import { connection, socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import {
  decodeWrapper,
  encodeConnect,
  encodeMute,
  encodePong,
  InboundKind,
  InboundMessage
} from './Messages';
import {
  buildFrame,
  CLIENT_PLATFORM,
  FrameAssembler,
  handshakeClientBytes,
  HEARTBEAT_TIMEOUT_MS,
  isHandshakeServerReply,
  PACKET_MAGIC
} from './Wire';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouControl';
const CONNECT_TIMEOUT_MS: number = 5000;
const HANDSHAKE_LENGTH: number = 12;

export type InboundHandler = (message: InboundMessage) => void;
export type ClosedHandler = (reason: string) => void;

export class ControlClient {
  private readonly sock: socket.TCPSocket = socket.constructTCPSocketInstance();
  private readonly assembler: FrameAssembler = new FrameAssembler();
  private handshakeDone: boolean = false;
  private pendingHandshake: Uint8Array = new Uint8Array(0);
  private handshakeWaiter: ((ok: boolean) => void) | null = null;
  private lastPingAt: number = 0;
  private terminated: boolean = false;
  onInbound: InboundHandler | null = null;
  onClosed: ClosedHandler | null = null;

  async open(ip: string, tcpPort: number, sessionId: number): Promise<void> {
    this.sock.on('message', (info: socket.SocketMessageInfo) => {
      this.receive(new Uint8Array(info.message));
    });
    this.sock.on('close', () => {
      this.fail('control connection closed by peer');
    });

    const address: connection.NetAddress = { address: ip, port: tcpPort, family: 1 };
    const options: socket.TCPConnectOptions = { address: address, timeout: CONNECT_TIMEOUT_MS };
    await this.sock.connect(options);

    await this.handshake();
    await this.sendFrame(encodeConnect(sessionId, CLIENT_PLATFORM));
    this.lastPingAt = Date.now();
  }

  private handshake(): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void) => {
      this.handshakeWaiter = (ok: boolean) => {
        this.handshakeWaiter = null;
        if (ok) {
          resolve();
        } else {
          reject(new Error('handshake rejected by server'));
        }
      };
      const options: socket.TCPSendOptions = { data: handshakeClientBytes().buffer };
      this.sock.send(options).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'handshake send failed: %{public}s', JSON.stringify(err));
        const waiter = this.handshakeWaiter;
        if (waiter !== null) {
          waiter(false);
        }
      });
    });
  }

  private receive(chunk: Uint8Array): void {
    try {
      if (!this.handshakeDone) {
        const merged = new Uint8Array(this.pendingHandshake.length + chunk.length);
        merged.set(this.pendingHandshake, 0);
        merged.set(chunk, this.pendingHandshake.length);
        if (merged.length < HANDSHAKE_LENGTH) {
          this.pendingHandshake = merged;
          return;
        }
        if (!isHandshakeServerReply(merged.subarray(0, HANDSHAKE_LENGTH))) {
          this.fail('invalid handshake reply');
          return;
        }
        this.completeHandshake(true);
        this.assembler.feed(merged.subarray(HANDSHAKE_LENGTH));
      } else {
        this.assembler.feed(chunk);
      }
      let frame = this.assembler.next();
      while (frame !== null) {
        this.dispatch(decodeWrapper(frame));
        frame = this.assembler.next();
      }
    } catch (err) {
      this.fail(`control stream error: ${(err as Error).message}`);
    }
  }

  private completeHandshake(ok: boolean): void {
    this.handshakeDone = ok;
    const waiter = this.handshakeWaiter;
    if (waiter !== null) {
      waiter(ok);
    }
  }

  private dispatch(message: InboundMessage): void {
    if (message.kind === InboundKind.Ping) {
      this.lastPingAt = Date.now();
      this.sendFrame(encodePong(message.timestamp)).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'pong send failed: %{public}s', JSON.stringify(err));
      });
      return;
    }
    const handler = this.onInbound;
    if (handler !== null) {
      handler(message);
    }
  }

  sendFrame(payload: ArrayBuffer): Promise<void> {
    const options: socket.TCPSendOptions = { data: buildFrame(PACKET_MAGIC, new Uint8Array(payload)) };
    return this.sock.send(options);
  }

  sendMute(muted: boolean): Promise<void> {
    return this.sendFrame(encodeMute(muted));
  }

  silenceMs(): number {
    return Date.now() - this.lastPingAt;
  }

  isHeartbeatStale(): boolean {
    return !this.terminated && this.lastPingAt > 0 && this.silenceMs() > HEARTBEAT_TIMEOUT_MS;
  }

  close(): void {
    if (this.terminated) {
      return;
    }
    this.terminated = true;
    this.sock.off('message');
    this.sock.off('close');
    this.sock.close().catch((err: BusinessError) => {
      hilog.debug(DOMAIN, TAG, 'close ignored: %{public}s', JSON.stringify(err));
    });
  }

  private fail(reason: string): void {
    if (this.terminated) {
      return;
    }
    if (!this.handshakeDone) {
      this.completeHandshake(false);
    }
    this.terminated = true;
    const handler = this.onClosed;
    if (handler !== null) {
      handler(reason);
    }
    this.close();
  }
}
