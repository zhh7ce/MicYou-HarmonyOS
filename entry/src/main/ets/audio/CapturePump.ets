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
 * MicYou HarmonyOS client — microphone capture and PCM packetisation.
 * Builds the AudioCapturer from a per-session capture config (sample rate,
 * channel count, bit depth, source type), falls back to the plain MIC 16-bit
 * path when the device rejects a request, and slices the stream into fixed-size
 * payloads that fit one datagram without IP fragmentation.
 */

import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import {
  AUDIO_FORMAT_16BIT,
  AUDIO_FORMAT_24BIT,
  AUDIO_FORMAT_FLOAT32,
  SOURCE_CAMCORDER,
  SOURCE_LIVE,
  SOURCE_MIC,
  SOURCE_UNPROCESSED,
  SOURCE_VOICE_COMMUNICATION,
  SOURCE_VOICE_RECOGNITION,
  UDP_PCM_PAYLOAD_SIZE,
  bytesPerSampleFor
} from '../net/Wire';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouCapture';

// Requested stream parameters for one capture session. `audioFormat` is the wire
// constant the desktop decoder keys on (2 = 16-bit, 4 = float32, 6 = 24-bit);
// `sourceType` is the persisted SOURCE_* id.
export interface CaptureConfig {
  sampleRate: number;
  channels: number;
  audioFormat: number;
  sourceType: number;
}

// The config actually in effect after fallback; the controller encodes the wire
// header from these values so they can never disagree with what was captured.
export interface CaptureApplied {
  sampleRate: number;
  channels: number;
  audioFormat: number;
  sourceType: number;
}

export type PcmPayloadHandler = (payload: Uint8Array) => void;
export type LevelHandler = (level: number) => void;

function mapSampleRate(rate: number): audio.AudioSamplingRate {
  switch (rate) {
    case 8000:
      return audio.AudioSamplingRate.SAMPLE_RATE_8000;
    case 16000:
      return audio.AudioSamplingRate.SAMPLE_RATE_16000;
    case 44100:
      return audio.AudioSamplingRate.SAMPLE_RATE_44100;
    case 96000:
      return audio.AudioSamplingRate.SAMPLE_RATE_96000;
    case 48000:
    default:
      return audio.AudioSamplingRate.SAMPLE_RATE_48000;
  }
}

function mapSampleFormat(format: number): audio.AudioSampleFormat {
  switch (format) {
    case AUDIO_FORMAT_24BIT:
      return audio.AudioSampleFormat.SAMPLE_FORMAT_S24LE;
    case AUDIO_FORMAT_FLOAT32:
      return audio.AudioSampleFormat.SAMPLE_FORMAT_F32LE;
    case AUDIO_FORMAT_16BIT:
    default:
      return audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE;
  }
}

function mapSource(source: number): audio.SourceType {
  switch (source) {
    case SOURCE_VOICE_RECOGNITION:
      return audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION;
    case SOURCE_VOICE_COMMUNICATION:
      return audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION;
    case SOURCE_CAMCORDER:
      return audio.SourceType.SOURCE_TYPE_CAMCORDER;
    case SOURCE_UNPROCESSED:
      return audio.SourceType.SOURCE_TYPE_UNPROCESSED;
    case SOURCE_LIVE:
      return audio.SourceType.SOURCE_TYPE_LIVE;
    case SOURCE_MIC:
    default:
      return audio.SourceType.SOURCE_TYPE_MIC;
  }
}

export class CapturePump {
  private capturer: audio.AudioCapturer | null = null;
  private carry: Uint8Array = new Uint8Array(0);
  private sink: PcmPayloadHandler | null = null;
  private levelSink: LevelHandler | null = null;
  private channels: number = 1;
  private bytesPerSample: number = 2;
  private bytesPerFrame: number = 2;
  private audioFormat: number = AUDIO_FORMAT_16BIT;

  private readonly readListener: (buffer: ArrayBuffer) => void = (buffer: ArrayBuffer) => {
    const chunk = new Uint8Array(buffer);
    this.consume(chunk);
    this.emitLevel(chunk);
  };

  /**
   * Starts capture from the config, falling back to plain MIC 16-bit when the
   * device rejects the requested source or format. Returns the applied config so
   * the caller can encode the wire header to match what is really being captured.
   */
  async start(sink: PcmPayloadHandler, levelSink: LevelHandler | null, config: CaptureConfig): Promise<CaptureApplied> {
    this.sink = sink;
    this.levelSink = levelSink;
    this.carry = new Uint8Array(0);

    const wanted: CaptureConfig = {
      sampleRate: config.sampleRate,
      channels: config.channels > 0 ? config.channels : 1,
      audioFormat: config.audioFormat,
      sourceType: config.sourceType
    };

    let applied: CaptureApplied;
    try {
      await this.open(wanted);
      applied = { sampleRate: wanted.sampleRate, channels: wanted.channels,
        audioFormat: wanted.audioFormat, sourceType: wanted.sourceType };
    } catch (err) {
      const reason: string = (err as Error).message;
      hilog.warn(DOMAIN, TAG, 'capture request rejected (%{public}s), falling back to MIC/16-bit', reason);
      const fallback: CaptureConfig = {
        sampleRate: wanted.sampleRate,
        channels: wanted.channels,
        audioFormat: AUDIO_FORMAT_16BIT,
        sourceType: SOURCE_MIC
      };
      await this.open(fallback);
      applied = { sampleRate: fallback.sampleRate, channels: fallback.channels,
        audioFormat: fallback.audioFormat, sourceType: fallback.sourceType };
    }

    hilog.info(DOMAIN, TAG, 'capture active: %{public}d Hz / %{public}d ch / fmt %{public}d / src %{public}d',
      applied.sampleRate, applied.channels, applied.audioFormat, applied.sourceType);
    return applied;
  }

  // Mutates the byte-accounting fields and creates + starts the capturer.
  private async open(cfg: CaptureConfig): Promise<void> {
    this.channels = cfg.channels;
    this.audioFormat = cfg.audioFormat;
    this.bytesPerSample = bytesPerSampleFor(cfg.audioFormat);
    this.bytesPerFrame = this.bytesPerSample * this.channels;

    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: mapSampleRate(cfg.sampleRate),
      channels: this.channels >= 2 ? audio.AudioChannel.CHANNEL_2 : audio.AudioChannel.CHANNEL_1,
      sampleFormat: mapSampleFormat(cfg.audioFormat),
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: mapSource(cfg.sourceType),
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = { streamInfo: streamInfo, capturerInfo: capturerInfo };

    const capturer = await audio.createAudioCapturer(options);
    try {
      capturer.on('readData', this.readListener);
      await capturer.start();
    } catch (err) {
      // Release what we just made before propagating, so the fallback open() is
      // not competing with a leaked capturer holding the microphone.
      capturer.off('readData', this.readListener);
      try {
        await capturer.release();
      } catch (releaseErr) {
        hilog.debug(DOMAIN, TAG, 'release after failed start: %{public}s', JSON.stringify(releaseErr as BusinessError));
      }
      throw err as Error;
    }
    this.capturer = capturer;
  }

  private consume(chunk: Uint8Array): void {
    const sink = this.sink;
    if (sink === null || chunk.length === 0) {
      return;
    }
    const merged = new Uint8Array(this.carry.length + chunk.length);
    merged.set(this.carry, 0);
    merged.set(chunk, this.carry.length);

    let offset: number = 0;
    while (merged.length - offset >= UDP_PCM_PAYLOAD_SIZE) {
      sink(merged.subarray(offset, offset + UDP_PCM_PAYLOAD_SIZE));
      offset += UDP_PCM_PAYLOAD_SIZE;
    }
    const rest = new Uint8Array(merged.length - offset);
    rest.set(merged.subarray(offset));
    this.carry = rest;
  }

  /** Linear RMS of the buffer for the capture format, normalised to 0..1. */
  private emitLevel(chunk: Uint8Array): void {
    const levelSink = this.levelSink;
    if (levelSink === null || chunk.length < this.bytesPerSample) {
      return;
    }
    const view = new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength);
    const sampleCount: number = Math.floor(chunk.length / this.bytesPerSample);
    let sumSquare: number = 0;
    for (let i = 0; i < sampleCount; i++) {
      const byteOffset: number = i * this.bytesPerSample;
      let sample: number = 0;
      if (this.audioFormat === AUDIO_FORMAT_FLOAT32) {
        const value: number = view.getFloat32(byteOffset, true);
        sample = Number.isFinite(value) ? value : 0;
      } else if (this.audioFormat === AUDIO_FORMAT_24BIT) {
        const raw: number = view.getUint8(byteOffset) | (view.getUint8(byteOffset + 1) << 8)
          | (view.getInt8(byteOffset + 2) << 16);
        sample = raw / 8388608.0;
      } else {
        sample = view.getInt16(byteOffset, true) / 32768.0;
      }
      sumSquare += sample * sample;
    }
    const rms: number = sampleCount > 0 ? Math.sqrt(sumSquare / sampleCount) : 0;
    levelSink(Math.min(1, rms));
  }

  /** Emits the tail so stopping does not drop up to one payload of audio. */
  flush(): void {
    const sink = this.sink;
    if (sink === null) {
      return;
    }
    // validate_audio_packet rejects PCM payloads that are not frame aligned.
    const aligned: number = Math.floor(this.carry.length / this.bytesPerFrame) * this.bytesPerFrame;
    if (aligned > 0) {
      sink(this.carry.subarray(0, aligned));
    }
    this.carry = new Uint8Array(0);
  }

  async stop(): Promise<void> {
    const capturer = this.capturer;
    this.capturer = null;
    this.sink = null;
    this.levelSink = null;
    if (capturer === null) {
      return;
    }
    this.flush();
    capturer.off('readData', this.readListener);
    try {
      await capturer.stop();
    } catch (err) {
      hilog.debug(DOMAIN, TAG, 'stop on a non-running capturer: %{public}s', JSON.stringify(err as BusinessError));
    }
    try {
      await capturer.release();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'release failed: %{public}s', JSON.stringify(err as BusinessError));
    }
  }
}
