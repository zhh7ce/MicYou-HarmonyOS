export function createEncoder(sampleRate: number, channels: number): number;
export function encode(handle: number, pcm: ArrayBuffer): ArrayBuffer;
export function destroyEncoder(handle: number): void;
