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
 * MicYou HarmonyOS client — session controller.
 * Owns the control connection, the UDP audio path, the capturer and the
 * continuous task, and pushes one snapshot object to whoever is watching.
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { AudioSender } from '../net/AudioSender';
import { ControlClient } from '../net/ControlClient';
import { encodeAudioPacket, InboundKind, InboundMessage } from '../net/Messages';
import { udpPortFor } from '../net/Wire';
import { CaptureApplied, CaptureConfig, CapturePump } from '../audio/CapturePump';
import { BackgroundRunner } from './BackgroundRunner';
import { ensureMicrophone } from './PermissionGate';
import { ConnectionStore } from './ConnectionStore';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouEngine';
const WATCHDOG_INTERVAL_MS: number = 1000;
// Level redraw only needs to be smooth enough to follow voice; the ArkUI gauge
// tweens the rest, so publishing every capture callback would over-render.
const LEVEL_PUBLISH_INTERVAL_MS: number = 100;

export enum EnginePhase {
  Idle = 0,
  Connecting = 1,
  Streaming = 2,
  Failed = 3
}

export class EngineSnapshot {
  phase: EnginePhase = EnginePhase.Idle;
  peer: string = '';
  error: string = '';
  muted: boolean = false;
  rttMs: number = 0;
  jitterMs: number = 0;
  packetLoss: number = 0;
  latencyMs: number = 0;
  packetsSent: number = 0;
  rms: number = 0;
}

export type SnapshotHandler = (snapshot: EngineSnapshot) => void;

export class MicYouController {
  readonly snapshot: EngineSnapshot = new EngineSnapshot();
  // A HarmonyOS socket cannot be re-connect()/bind()-ed once closed, so each
  // session gets fresh transport objects; the old ones are torn down first.
  private control: ControlClient = new ControlClient();
  private audioOut: AudioSender = new AudioSender();
  private readonly pump: CapturePump = new CapturePump();
  private readonly background: BackgroundRunner = new BackgroundRunner();
  private sessionCounter: number = 0;
  private sequence: number = 0;
  // Snapshot of the capture actually in effect for this session (after the
  // pump's source/format fallback). The wire header is encoded from these so it
  // can never disagree with the bytes being sent.
  private capSampleRate: number = 48000;
  private capChannels: number = 1;
  private capFormat: number = 2;
  private capCodec: number = 0;
  private watchdog: number = -1;
  private observer: SnapshotHandler | null = null;
  private stopping: boolean = false;
  private lastLevelAt: number = 0;
  // Process-lifetime guard: once the user stops a session by hand, auto-connect
  // must not silently restart the microphone for the rest of this process.
  private manuallyStopped: boolean = false;

  attach(observer: SnapshotHandler): void {
    this.observer = observer;
    this.publish();
  }

  detach(): void {
    this.observer = null;
  }

  async start(context: common.UIAbilityContext, host: string, tcpPort: number, name: string): Promise<void> {
    if (this.snapshot.phase === EnginePhase.Streaming || this.snapshot.phase === EnginePhase.Connecting) {
      return;
    }
    this.stopping = false;
    this.manuallyStopped = false;
    // Fresh transport objects: the previous session's sockets are closed and a
    // closed TCPSocket/UDPSocket instance is not reusable.
    this.control = new ControlClient();
    this.audioOut = new AudioSender();
    this.sessionCounter += 1;
    this.sequence = 0;
    const sessionId: number = this.sessionCounter;
    const peer: string = `${host}:${tcpPort}`;

    this.setPhase(EnginePhase.Connecting, peer, '');
    if (!await ensureMicrophone(context)) {
      this.setPhase(EnginePhase.Failed, '', 'microphone permission denied');
      return;
    }

    this.control.onInbound = (message: InboundMessage) => this.onInbound(message);
    this.control.onClosed = (reason: string) => this.onBroken(reason);

    try {
      await this.control.open(host, tcpPort, sessionId);
      await this.audioOut.start(host, udpPortFor(tcpPort));
      await this.background.start(context);
      const settings = ConnectionStore.shared.settings;
      const config: CaptureConfig = {
        sampleRate: settings.sampleRate,
        channels: settings.channelCount,
        audioFormat: settings.audioFormat,
        sourceType: settings.sourceType
      };
      // Opus is not implemented on-device yet (TODO 4.3), so the wire codec stays
      // PCM regardless of the stored setting; the UI keeps the Opus choice disabled.
      const applied: CaptureApplied = await this.pump.start(
        (payload: Uint8Array) => this.onPcm(payload, sessionId),
        (level: number) => this.onLevel(level), config);
      this.capSampleRate = applied.sampleRate;
      this.capChannels = applied.channels;
      this.capFormat = applied.audioFormat;
      this.capCodec = 0;
      this.setPhase(EnginePhase.Streaming, peer, '');
      this.startWatchdog();
      // Record only a real success, so a mistyped manual address never pollutes
      // the history. Fire-and-forget: the store persists asynchronously.
      ConnectionStore.shared.recordSuccess(name, host, tcpPort).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'record success failed: %{public}s', err.message);
      });
    } catch (err) {
      const reason: string = (err as Error).message;
      hilog.error(DOMAIN, TAG, 'start failed: %{public}s', reason);
      await this.teardown();
      this.setPhase(EnginePhase.Failed, peer, reason);
    }
  }

  async stop(): Promise<void> {
    if (this.snapshot.phase === EnginePhase.Idle) {
      return;
    }
    this.stopping = true;
    this.manuallyStopped = true;
    await this.teardown();
    this.setPhase(EnginePhase.Idle, '', '');
  }

  wasManuallyStopped(): boolean {
    return this.manuallyStopped;
  }

  private async teardown(): Promise<void> {
    this.stopWatchdog();
    await this.pump.stop();
    this.audioOut.stop();
    await this.background.stop();
    this.control.close();
  }

  private onPcm(payload: Uint8Array, sessionId: number): void {
    if (this.snapshot.phase !== EnginePhase.Streaming) {
      return;
    }
    const frame: ArrayBuffer = encodeAudioPacket(payload, this.sequence, Date.now(), sessionId,
      this.capSampleRate, this.capChannels, this.capFormat, this.capCodec);
    this.sequence += 1;
    this.audioOut.send(new Uint8Array(frame));
    this.snapshot.packetsSent += 1;
  }

  private onLevel(level: number): void {
    this.snapshot.rms = level;
    const now: number = Date.now();
    if (now - this.lastLevelAt >= LEVEL_PUBLISH_INTERVAL_MS) {
      this.lastLevelAt = now;
      this.publish();
    }
  }

  private onInbound(message: InboundMessage): void {
    if (message.kind !== InboundKind.Stats) {
      return;
    }
    this.snapshot.rttMs = message.rttMs;
    this.snapshot.jitterMs = message.jitterMs;
    this.snapshot.packetLoss = message.packetLoss;
    this.snapshot.latencyMs = message.latencyMs;
    this.publish();
  }

  private onBroken(reason: string): void {
    if (this.stopping || this.snapshot.phase === EnginePhase.Idle) {
      return;
    }
    hilog.warn(DOMAIN, TAG, 'link lost: %{public}s', reason);
    this.teardown().then(() => {
      this.setPhase(EnginePhase.Failed, this.snapshot.peer, reason);
    });
  }

  private startWatchdog(): void {
    this.stopWatchdog();
    this.watchdog = setInterval(() => {
      if (this.snapshot.phase !== EnginePhase.Streaming) {
        return;
      }
      if (this.control.isHeartbeatStale()) {
        this.onBroken(`no heartbeat for ${this.control.silenceMs()} ms`);
      } else if (this.audioOut.sendFailedHard()) {
        this.onBroken('UDP audio path failed repeatedly');
      } else {
        // Link stats only arrive from newer desktop builds; the send counter
        // still needs a beat of its own to stay live on screen.
        this.publish();
      }
    }, WATCHDOG_INTERVAL_MS);
  }

  private stopWatchdog(): void {
    if (this.watchdog >= 0) {
      clearInterval(this.watchdog);
      this.watchdog = -1;
    }
  }

  async toggleMute(): Promise<void> {
    const muted: boolean = !this.snapshot.muted;
    this.snapshot.muted = muted;
    this.publish();
    if (this.snapshot.phase === EnginePhase.Streaming) {
      try {
        await this.control.sendMute(muted);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'mute send failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  private setPhase(phase: EnginePhase, peer: string, error: string): void {
    this.snapshot.phase = phase;
    this.snapshot.peer = peer;
    this.snapshot.error = error;
    if (phase === EnginePhase.Idle || phase === EnginePhase.Connecting) {
      this.snapshot.rttMs = 0;
      this.snapshot.jitterMs = 0;
      this.snapshot.packetLoss = 0;
      this.snapshot.latencyMs = 0;
      this.snapshot.packetsSent = 0;
      this.snapshot.rms = 0;
    }
    this.publish();
  }

  private publish(): void {
    const observer = this.observer;
    if (observer !== null) {
      observer(this.snapshot);
    }
  }
}
