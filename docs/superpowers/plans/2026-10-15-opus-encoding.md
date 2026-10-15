# On-Device Opus Encoding 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 MicYou HarmonyOS 客户端加端侧 Opus 编码（libopus 1.5.2 经 NDK 静态内嵌 napi 模块），20 ms VOIP 帧 + VBR/DTX + 带外 XOR FEC，并在设置页启用 Opus 且置灰不兼容采集参数。

**Architecture:** 方案甲——napi 只做单帧编码（createEncoder/encode/destroyEncoder），凑帧（OpusFrameBuffer）、FEC 分组（FecGroup）、序号与线格式全在 ArkTS；CapturePump/AudioSender/ConnectionStore 零改动。奇偶包逐字段对齐 Android `AudioEngine.kt:940-988`。

**Tech Stack:** ArkTS（严格模式）、HarmonyOS NDK（C++/napi）、CMake、libopus 1.5.2（BSD-3，源码进仓）、hvigor 6.26.2。

**Spec:** `docs/superpowers/specs/2026-10-15-opus-encoding-design.md`（执行时先读它，本计划以它为准）

## Global Constraints

每个任务都隐含遵守本节：

- 严格 ArkTS：无 `any`；所有声明（含 lambda 参数）显式类型；空判定用 `=== null`。
- 每个新建 `.ets` / `.cpp` / `CMakeLists.txt` 顶部带仓库 GPL 头块（SPDX 行 + GPL-3.0-or-later 段落 + zhh7ce 版权行，从任一现有 `.ets` 原文复制）。
- hilog：`DOMAIN = 0x3307`，格式串一律 `%{public}s` / `%{public}d`；新 tag 只用 `MicYouOpus`。
- 用户可见文案只进 `entry/src/main/resources/{base,zh_CN,zh_TW}/element/string.json`，三套同步；颜色只走 `$r('app.color.xxx')`。
- `@Builder` 只有在接收单个对象字面量参数时才随状态重渲染（AGENTS「UI rules」）；新 builder 一律 `foo(args: FooArgs)` 形态。
- 构建前 `export DEVECO_SDK_HOME=/opt/devecostudio/sdk`；`hvigorw assembleHap --no-daemon`。
- `entry/build-profile.json5` 已 gitignore、`build-profile.example.json5` 进仓：改前者必须同步改后者。
- abi 只有 `arm64-v8a`。
- commit message 英文 `<type>: <description>`；代码与文档分开 commit；**不 push**。
- 工程无测试 runner（AGENTS「Tests」）：逻辑层验证用 out-of-tree 一次性 Node harness（不落仓），线格式用 protobufjs 对照 `network.proto`（`../MicYou/tauri-app/crates/micyou-protocol/proto/network.proto`，package `micyou`）；端到端验证 = 真机 + `cargo run -p micyou-cli -- serve`。
- 真机步骤（nova 14 Pro）需要用户在旁配合观察桌面 GUI，属既定验收方式。

---

### Task 1: 引入 libopus 1.5.2 源码

**Files:**
- Create: `entry/src/main/cpp/opus/`（上游解包全树，含 `COPYING`）

**Interfaces:**
- Consumes: 无
- Produces: `entry/src/main/cpp/opus/include/opus/opus.h`（Task 2 include 路径）、`entry/src/main/cpp/opus/CMakeLists.txt`（`add_subdirectory` 目标名 `opus`）

- [ ] **Step 1: 下载并校验**

```bash
cd /tmp
curl -LO https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.5.2.tar.gz
echo '65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1  opus-1.5.2.tar.gz' | sha256sum -c -
```

预期输出 `opus-1.5.2.tar.gz: OK`。失败即停，报告哈希差异，不要继续。

- [ ] **Step 2: 解包进仓**

```bash
tar xf opus-1.5.2.tar.gz
mkdir -p /home/zhh7ce/Documents/codes/MicYou-HarmonyOS/entry/src/main/cpp/opus
cp -a /tmp/opus-1.5.2/. /home/zhh7ce/Documents/codes/MicYou-HarmonyOS/entry/src/main/cpp/opus/
ls /home/zhh7ce/Documents/codes/MicYou-HarmonyOS/entry/src/main/cpp/opus/COPYING
ls /home/zhh7ce/Documents/codes/MicYou-HarmonyOS/entry/src/main/cpp/opus/include/opus/opus.h
```

不裁剪、不改动任何上游文件（许可证义务靠保留原文件，见 spec §5）。

- [ ] **Step 3: Commit**

```bash
cd /home/zhh7ce/Documents/codes/MicYou-HarmonyOS
git add entry/src/main/cpp/opus
git commit -m "feat: vendor libopus 1.5.2 sources for the on-device encoder"
```

---

### Task 2: napi 模块 mcyopus + 构建接线（首个 native 产物）

**Files:**
- Create: `entry/src/main/cpp/CMakeLists.txt`
- Create: `entry/src/main/cpp/napi_init.cpp`
- Create: `entry/src/main/cpp/types/libmcyopus/index.d.ts`
- Create: `entry/src/main/cpp/types/libmcyopus/oh-package.json5`
- Modify: `entry/oh-package.json5`（空依赖表加一行）
- Modify: `entry/build-profile.json5` 与 `entry/build-profile.example.json5`（`buildOption.externalNativeOptions`）

**Interfaces:**
- Consumes: Task 1 的 `opus/` 源码树与 `opus/include/` 头文件
- Produces（ArkTS 侧，Task 5 依赖）:
  ```ts
  // 模块名 'libmcyopus.so'
  export function createEncoder(sampleRate: number, channels: number): number; // 返回 handle ≥ 1
  export function encode(handle: number, pcm: ArrayBuffer): ArrayBuffer;       // 单帧 → 裸 opus 包
  export function destroyEncoder(handle: number): void;
  ```

- [ ] **Step 1: 写 `cpp/CMakeLists.txt`**

```cmake
# SPDX-License-Identifier: GPL-3.0-or-later
# MicYou HarmonyOS client — napi bridge around the vendored libopus sources.
cmake_minimum_required(VERSION 3.16)
project(mcyopus LANGUAGES C CXX)

# Encoder options live here (not in externalNativeOptions.arguments) so the
# gitignored build-profile never changes what gets compiled.
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_DISABLE_INTRINSICS ON CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)

add_subdirectory(opus)

add_library(mcyopus SHARED napi_init.cpp)
target_include_directories(mcyopus PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/opus/include)
target_link_libraries(mcyopus PRIVATE opus libace_napi.z.so libhilog_ndk.z.so)
```

- [ ] **Step 2: 写 `cpp/napi_init.cpp`**

GPL 头块（同现有 `.ets`，版权年份照抄）之后：

```cpp
#include <napi/native_api.h>
#include <hilog/log.h>
#include <opus/opus.h>
#include <vector>
#include <cstring>

#undef LOG_DOMAIN
#define LOG_DOMAIN 0x3307
#undef LOG_TAG
#define LOG_TAG "MicYouOpus"

namespace {

struct Slot {
    OpusEncoder *enc;
    int32_t frameSamples; // rate * 20 / 1000, the only frame size this client encodes
    int32_t channels;
    bool live;
};

std::vector<Slot> g_slots;

bool IsOpusRate(int32_t rate) {
    return rate == 8000 || rate == 12000 || rate == 16000 || rate == 24000 || rate == 48000;
}

napi_value CreateEncoder(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t rate = 0;
    int32_t channels = 0;
    napi_get_value_int32(env, args[0], &rate);
    napi_get_value_int32(env, args[1], &channels);
    if (!IsOpusRate(rate) || (channels != 1 && channels != 2)) {
        napi_throw_error(env, nullptr, "invalid opus encoder config");
        return nullptr;
    }
    int err = OPUS_OK;
    OpusEncoder *enc = opus_encoder_create(rate, channels, OPUS_APPLICATION_VOIP, &err);
    if (enc == nullptr) {
        napi_throw_error(env, nullptr, opus_strerror(err));
        return nullptr;
    }
    opus_encoder_ctl(enc, OPUS_SET_VBR(1));
    opus_encoder_ctl(enc, OPUS_SET_DTX(1));
    opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(0));
    opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    Slot slot;
    slot.enc = enc;
    slot.frameSamples = rate * 20 / 1000;
    slot.channels = channels;
    slot.live = true;
    g_slots.push_back(slot);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "createEncoder rate=%{public}d ch=%{public}d handle=%{public}d",
                 rate, channels, static_cast<int>(g_slots.size()));
    napi_value out = nullptr;
    napi_create_int32(env, static_cast<int32_t>(g_slots.size()), &out); // handle = 1-based index
    return out;
}

napi_value Encode(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = 0;
    napi_get_value_int32(env, args[0], &handle);
    if (handle < 1 || static_cast<size_t>(handle) > g_slots.size() || !g_slots[handle - 1].live) {
        napi_throw_error(env, nullptr, "bad opus handle");
        return nullptr;
    }
    Slot &slot = g_slots[handle - 1];
    bool isAb = false;
    napi_is_arraybuffer(env, args[1], &isAb);
    if (!isAb) {
        napi_throw_error(env, nullptr, "pcm must be an ArrayBuffer");
        return nullptr;
    }
    void *data = nullptr;
    size_t byteLen = 0;
    napi_get_arraybuffer_info(env, args[1], &data, &byteLen);
    // The bridge contract: exactly one 20 ms S16LE frame for this encoder's channel count.
    const size_t want = static_cast<size_t>(slot.frameSamples) * 2u * static_cast<size_t>(slot.channels);
    if (byteLen != want) {
        napi_throw_error(env, nullptr, "bad opus input frame size");
        return nullptr;
    }
    unsigned char out[4000];
    int n = opus_encode(slot.enc, static_cast<opus_int16 *>(data), slot.frameSamples, out, sizeof(out));
    if (n < 0) {
        napi_throw_error(env, nullptr, opus_strerror(n));
        return nullptr;
    }
    napi_value buf = nullptr;
    void * backing = nullptr;
    napi_create_arraybuffer(env, static_cast<size_t>(n), &backing, &buf);
    memcpy(backing, out, static_cast<size_t>(n));
    return buf;
}

napi_value DestroyEncoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = 0;
    napi_get_value_int32(env, args[0], &handle);
    if (handle < 1 || static_cast<size_t>(handle) > g_slots.size()) {
        return nullptr; // destroy is forgiving: double-destroy on teardown is not a session error
    }
    Slot &slot = g_slots[handle - 1];
    if (slot.live) {
        opus_encoder_destroy(slot.enc);
        slot.enc = nullptr;
        slot.live = false;
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "destroyEncoder handle=%{public}d", handle);
    }
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"createEncoder", nullptr, CreateEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"encode", nullptr, Encode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroyEncoder", nullptr, DestroyEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "mcyopus",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterMcyopusModule() {
    napi_module_register(&g_module);
}
```

上面代码即最终形态，不需要额外修正。

- [ ] **Step 3: 写类型与包声明**

`cpp/types/libmcyopus/index.d.ts`：

```ts
export function createEncoder(sampleRate: number, channels: number): number;
export function encode(handle: number, pcm: ArrayBuffer): ArrayBuffer;
export function destroyEncoder(handle: number): void;
```

`cpp/types/libmcyopus/oh-package.json5`：

```json5
{
  "name": "libmcyopus.so",
  "types": "./index.d.ts",
  "version": "1.0.0",
  "description": "napi bridge exposing the vendored libopus encoder to MicYou"
}
```

- [ ] **Step 4: 接线构建配置**

`entry/oh-package.json5` 的 `dependencies` 加：

```json5
"dependencies": {
  "libmcyopus.so": "file:./src/main/cpp/types/libmcyopus"
}
```

`entry/build-profile.json5`（与 `build-profile.example.json5` 同步）的 `module` 级 `buildOption` 加：

```json5
"buildOption": {
  "externalNativeOptions": {
    "path": "./src/main/cpp/CMakeLists.txt",
    "arguments": "",
    "abiFilters": ["arm64-v8a"]
  }
}
```

（若 `buildOption` 已存在则并入，不重复键。`arguments` 留空：编码选项固定在 CMakeLists 里 FORCE。）

- [ ] **Step 5: 构建验证**

```bash
cd /home/zhh7ce/Documents/codes/MicYou-HarmonyOS
export DEVECO_SDK_HOME=/opt/devecostudio/sdk
ohpm install --registry https://ohpm.openharmony.cn/ohpm/ || ohpm install
hvigorw assembleHap --no-daemon
unzip -l entry/build/default/outputs/default/entry-default-signed.hap | grep libmcyopus
```

预期：构建成功且输出含 `libs/arm64-v8a/libmcyopus.so`；顺手记录 `.so` 大小（HAP 体积增量数据，写进 Task 8 的文档改动）。

失败分诊（spec §5）：
- OHOS 下 opus 的 `check_include_file(unistd.h)` 类探测报错 → 在 `entry/src/main/cpp/opus/CMakeLists.txt` 对应判断处补 `OR CMAKE_SYSTEM_NAME STREQUAL "OHOS"`，改动保存为 `entry/src/main/cpp/opus-micyou-ohos.patch`（`git diff` 生成）随本任务提交。
- 不得通过删校验或放宽 CMake 选项来"修好"构建。

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/cpp entry/oh-package.json5 build-profile.example.json5
git commit -m "feat: add mcyopus napi module wrapping the vendored libopus encoder"
```

（`entry/build-profile.json5` gitignored，不 add。）

---

### Task 3: 线格式层——packed uint32 与奇偶包编码

**Files:**
- Modify: `entry/src/main/ets/net/Pb.ets`（PbWriter 加方法）
- Modify: `entry/src/main/ets/net/Messages.ets`（fec 常量 + `encodeFecParityPacket`）
- Test: out-of-tree harness `/tmp/micyou-proto-verify/`（不落仓）

**Interfaces:**
- Consumes: `PbWriter`（`net/Pb.ets:29`）、`network.proto`（package `micyou`，`AudioPacketMessageOrdered` 字段 4/5/7）
- Produces（Task 5/6 依赖）:
  ```ts
  // net/Pb.ets
  writePackedUInt32s(field: number, values: Array<number>): void;
  // net/Messages.ets
  export function encodeFecParityPacket(xor: Uint8Array, lengths: Array<number>, groupStartSeq: number,
    sequence: number, timestamp: number, sessionId: number,
    sampleRate: number, channelCount: number, audioFormat: number): ArrayBuffer;
  ```
  Opus 数据包**不加新函数**：现有 `encodeAudioPacket(..., codec)` 传 opus 字节 + `CODEC_OPUS` 即可（spec §2）。

- [ ] **Step 1: 先写失败验证脚本**

```bash
mkdir -p /tmp/micyou-proto-verify && cd /tmp/micyou-proto-verify
npm init -y >/dev/null && npm i protobufjs
cp /home/zhh7ce/Documents/codes/MicYou-HarmonyOS/entry/src/main/ets/net/Pb.ets pb.ts
cp /home/zhh7ce/Documents/codes/MicYou-HarmonyOS/entry/src/main/ets/net/Messages.ets messages.ts
sed -i "s#'./Pb'#'./pb.ts'#" messages.ts
```

写 `parity.test.mts`（全文如下，直接落盘）：

```ts
// parity.test.mts —— node --experimental-strip-types parity.test.mts
import protobuf from 'protobufjs';

const root = protobuf.loadSync('/home/zhh7ce/Documents/codes/MicYou/tauri-app/crates/micyou-protocol/proto/network.proto');
const Wrapper = root.lookupType('micyou.MessageWrapper');

const { PbWriter } = await import('./pb.ts');
const { encodeFecParityPacket, encodeAudioPacket } = await import('./messages.ts');
const CODEC_OPUS = 1;

// 1) parity packet round-trip
const xor = new Uint8Array([0xaa, 0xbb, 0xcc]);
const frame = encodeFecParityPacket(xor, [100, 87, 40], 0, 12, 1730000000000, 7, 48000, 1, 2);
const decoded = Wrapper.decode(new Uint8Array(frame));
const ordered = decoded.audioPacket;
if (ordered.sequenceNumber !== 12) throw new Error('seq');
if (ordered.fecSequenceNumber !== 0) throw new Error('fec seq');           // group 0 omitted -> 0
if (!(ordered.fecBuffer.length === 1 && ordered.fecBuffer[0] === 1)) throw new Error('marker');
if (ordered.fecPacketLengths.length !== 3 || ordered.fecPacketLengths[1] !== 87) throw new Error('lengths');
if (Buffer.compare(Buffer.from(ordered.buffer), Buffer.from([0xaa, 0xbb, 0xcc])) !== 0) throw new Error('xor body');
if (ordered.sampleRate !== 48000 || ordered.channelCount !== 1 || ordered.codec !== CODEC_OPUS) throw new Error('meta');
if (Number(ordered.sessionId) !== 7) throw new Error('session');

// 2) regular opus data packet: fec fields must stay absent
const data = encodeAudioPacket(new Uint8Array([0xf8, 0x01, 0x02]), 5, 1730000000001, 7, 48000, 1, 2, CODEC_OPUS);
const dOrder = Wrapper.decode(new Uint8Array(data)).audioPacket;
if (dOrder.fecBuffer.length !== 0) throw new Error('regular packet leaked fecBuffer');
if (dOrder.fecPacketLengths.length !== 0) throw new Error('regular packet leaked fecPacketLengths');

// 3) group-12 parity: fecSequenceNumber present (12), marker present
const p2 = Wrapper.decode(new Uint8Array(
  encodeFecParityPacket(xor, [50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50], 12, 24, 1, 7, 48000, 1, 2)
)).audioPacket;
if (p2.fecSequenceNumber !== 12) throw new Error('group 12 start');
if (p2.fecPacketLengths.length !== 12) throw new Error('12 lengths');

console.log('PROTO OK: parity + data + group12');
```

- [ ] **Step 2: 运行确认失败**

```bash
node --experimental-strip-types parity.test.mts
```

预期 FAIL：`encodeFecParityPacket is not a function`（`writePackedUInt32s` 同不存在）。

- [ ] **Step 3: 实现 PbWriter.writePackedUInt32s**

`net/Pb.ets`，`writeBytes` 之后（`:114` 附近）加：

```ets
  /** proto3 packed repeated uint32: one length-delimited field of bare varints. */
  writePackedUInt32s(field: number, values: Array<number>): void {
    if (values.length === 0) {
      return;
    }
    const packed = new PbWriter();
    for (let i = 0; i < values.length; i++) {
      const value: number = values[i];
      if (value < 0 || value > 4294967295) {
        throw new Error(`uint32 out of range: ${value}`);
      }
      packed.writeVarint(value);
    }
    this.writeBytes(field, packed.toUint8());
  }
```

- [ ] **Step 4: 实现 encodeFecParityPacket**

`net/Messages.ets`：常量区加（注释同步改写第 115-116 行的旧说明——fec 字段从此有生产者）：

```ets
const ORDERED_FEC_BUFFER: number = 4;
const ORDERED_FEC_SEQ: number = 5;
const ORDERED_FEC_LENGTHS: number = 7;
const FEC_MARKER: Uint8Array = new Uint8Array([1]);
```

import 增加 `CODEC_OPUS`（来自 `./Wire`），在 `encodeAudioPacket` 后加：

```ets
/**
 * Out-of-band XOR parity packet, field-for-field like Android AudioEngine.kt:956-987.
 * The XOR body goes in audioPacket.buffer; fecBuffer is only the non-empty
 * [0x01] marker that makes the desktop's ExplicitMarker layout detect parity.
 * sequence is the NEXT regular packet's number, deliberately not consumed.
 * audioFormat is the capture wire value, telemetry only for codec 1.
 */
export function encodeFecParityPacket(xor: Uint8Array, lengths: Array<number>, groupStartSeq: number,
  sequence: number, timestamp: number, sessionId: number,
  sampleRate: number, channelCount: number, audioFormat: number): ArrayBuffer {
  const audio = new PbWriter();
  audio.writeBytes(AUDIO_BUFFER, xor);
  audio.writeInt(AUDIO_SAMPLE_RATE, sampleRate);
  audio.writeInt(AUDIO_CHANNEL_COUNT, channelCount);
  audio.writeInt(AUDIO_FORMAT, audioFormat);
  audio.writeInt(AUDIO_CODEC, CODEC_OPUS);

  const ordered = new PbWriter();
  ordered.writeInt(ORDERED_SEQUENCE, sequence);
  ordered.writeMessage(ORDERED_AUDIO, audio.toUint8());
  ordered.writeInt(ORDERED_TIMESTAMP, timestamp);
  ordered.writeBytes(ORDERED_FEC_BUFFER, FEC_MARKER);
  ordered.writeInt(ORDERED_FEC_SEQ, groupStartSeq); // group 0 omits it; proto3 decodes 0
  ordered.writeInt(ORDERED_SESSION, sessionId);
  ordered.writePackedUInt32s(ORDERED_FEC_LENGTHS, lengths);

  const outer = new PbWriter();
  outer.writeMessage(WRAPPER_AUDIO, ordered.toUint8());
  return outer.toArrayBuffer();
}
```

- [ ] **Step 5: 运行 harness 确认通过**

```bash
cp /home/zhh7ce/Documents/codes/MicYou-HarmonyOS/entry/src/main/ets/net/Pb.ets pb.ts
cp /home/zhh7ce/Documents/codes/MicYou-HarmonyOS/entry/src/main/ets/net/Messages.ets messages.ts
sed -i "s#'./Pb'#'./pb.ts'#" messages.ts
node --experimental-strip-types parity.test.mts
```

预期 `PROTO OK: parity + data + group12`。（`Wire.ets` 被 Messages import：同样拷入并把 `'./Wire'` 改成 `'./wire.ts'`。）

- [ ] **Step 6: ArkTS 编译 + 既有 PCM 回归**

```bash
cd /home/zhh7ce/Documents/codes/MicYou-HarmonyOS
hvigorw assembleHap --no-daemon
```

预期构建成功（`encodeFecParityPacket` 尚无调用者，编译过即可）。

- [ ] **Step 7: Commit**

```bash
git add entry/src/main/ets/net/Pb.ets entry/src/main/ets/net/Messages.ets
git commit -m "feat: encode out-of-band XOR FEC parity packets on the wire"
```

---

### Task 4: 凑帧与 FEC 分组（ArkTS 单元 + Wire 常量）

**Files:**
- Modify: `entry/src/main/ets/net/Wire.ets`（新常量/函数）
- Create: `entry/src/main/ets/audio/OpusFrameBuffer.ets`
- Create: `entry/src/main/ets/audio/FecGroup.ets`
- Test: out-of-tree harness `/tmp/micyou-units/`（不落仓）

**Interfaces:**
- Consumes: `Wire.ets` 既有常量
- Produces（Task 5/6 依赖）:
  ```ts
  // net/Wire.ets
  export const OPUS_FRAME_MS: number;                    // 20
  export function opusFrameSamples(sampleRate: number): number;
  export function opusFrameBytes(sampleRate: number, channels: number): number;
  export function isOpusNativeRate(rate: number): boolean;
  export const FEC_GROUP_SIZE: number;                   // 12

  // audio/OpusFrameBuffer.ets
  export type OpusFrameHandler = (frame: ArrayBuffer) => void;
  export class OpusFrameBuffer {
    start(sampleRate: number, channels: number): void;
    feed(chunk: Uint8Array, sink: OpusFrameHandler): void;
    reset(): number;                                      // 返回丢弃的尾部字节数，同时清空 carry
  }

  // audio/FecGroup.ets
  export interface FecParity {
    xor: Uint8Array;
    lengths: Array<number>;
    groupStartSeq: number;
  }
  export class FecGroup {
    add(packet: Uint8Array, seq: number): FecParity | null; // 满 12 包返回奇偶描述并自重置
    reset(): void;
  }
  ```

- [ ] **Step 1: Wire.ets 加常量**

```ets
export const OPUS_FRAME_MS: number = 20;
export const FEC_GROUP_SIZE: number = 12;
const OPUS_NATIVE_RATES: Array<number> = [8000, 12000, 16000, 24000, 48000];

/** Samples per channel in one MicYou Opus frame at this capture rate. */
export function opusFrameSamples(sampleRate: number): number {
  return Math.floor(sampleRate * OPUS_FRAME_MS / 1000);
}

/** One 20 ms S16LE frame for (rate, channels), the exact input size opus_encode wants. */
export function opusFrameBytes(sampleRate: number, channels: number): number {
  return opusFrameSamples(sampleRate) * 2 * channels;
}

/** Rates the desktop's opus decoder can be created for; anything else is a silent-stream trap. */
export function isOpusNativeRate(rate: number): boolean {
  return OPUS_NATIVE_RATES.indexOf(rate) >= 0;
}
```

- [ ] **Step 2: 写两个实现类**

`audio/OpusFrameBuffer.ets`（GPL 头块后）：

```ets
import { hilog } from '@kit.PerformanceAnalysisKit';
import { opusFrameBytes } from '../net/Wire';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouOpus';

export type OpusFrameHandler = (frame: ArrayBuffer) => void;

export class OpusFrameBuffer {
  private frameBytes: number = 0;
  private carry: Uint8Array = new Uint8Array(0);

  start(sampleRate: number, channels: number): void {
    this.frameBytes = opusFrameBytes(sampleRate, channels);
    this.carry = new Uint8Array(0);
  }

  /** Concatenate the carry-over with the chunk and emit every whole 20 ms frame. */
  feed(chunk: Uint8Array, sink: OpusFrameHandler): void {
    if (this.frameBytes <= 0) {
      return;
    }
    const joined = new Uint8Array(this.carry.length + chunk.length);
    joined.set(this.carry, 0);
    joined.set(chunk, this.carry.length);
    let consumed: number = 0;
    while (joined.length - consumed >= this.frameBytes) {
      const frame = new ArrayBuffer(this.frameBytes);
      new Uint8Array(frame).set(joined.subarray(consumed, consumed + this.frameBytes));
      consumed += this.frameBytes;
      sink(frame);
    }
    const rest = new Uint8Array(joined.length - consumed);
    rest.set(joined.subarray(consumed));
    this.carry = rest;
  }

  /** Session stop: the sub-frame remainder is dropped, as on Android (no padding, no partial encode). */
  reset(): number {
    const dropped: number = this.carry.length;
    this.carry = new Uint8Array(0);
    this.frameBytes = 0;
    if (dropped > 0) {
      hilog.info(DOMAIN, TAG, 'dropped %{public}d tail bytes below one opus frame', dropped);
    }
    return dropped;
  }
}
```

（实现时 import 从 `'../net/Wire'` 引 `opusFrameBytes`，删除首行自引用示意。）

`audio/FecGroup.ets`（GPL 头块后）：

```ets
import { FEC_GROUP_SIZE } from '../net/Wire';

export interface FecParity {
  xor: Uint8Array;
  lengths: Array<number>;
  groupStartSeq: number;
}

export class FecGroup {
  private packets: Array<Uint8Array> = [];
  private lengths: Array<number> = [];
  private groupStartSeq: number = 0;

  /** seq is the sequence number the caller spent on this packet. */
  add(packet: Uint8Array, seq: number): FecParity | null {
    if (this.packets.length === 0) {
      this.groupStartSeq = seq;
    }
    this.packets.push(packet);
    this.lengths.push(packet.length);
    if (this.packets.length < FEC_GROUP_SIZE) {
      return null;
    }
    let longest: number = 0;
    for (let i = 0; i < this.lengths.length; i++) {
      if (this.lengths[i] > longest) {
        longest = this.lengths[i];
      }
    }
    const out = new Uint8Array(longest);
    for (let i = 0; i < this.packets.length; i++) {
      const p: Uint8Array = this.packets[i];
      for (let j = 0; j < p.length; j++) {
        out[j] = out[j] ^ p[j];
      }
      // bytes past p.length XOR against zero padding: no-op by construction.
    }
    const parity: FecParity = { xor: out, lengths: this.lengths, groupStartSeq: this.groupStartSeq };
    this.packets = [];
    this.lengths = [];
    return parity;
  }

  /** Partial groups are discarded: desktop recovery needs exactly 11-of-12 sources. */
  reset(): void {
    this.packets = [];
    this.lengths = [];
    this.groupStartSeq = 0;
  }
}
```

- [ ] **Step 3: 写单元 harness（失败优先）**

```bash
mkdir -p /tmp/micyou-units && cd /tmp/micyou-units
cp <repo>/entry/src/main/ets/net/Wire.ets wire.ts
cp <repo>/entry/src/main/ets/audio/OpusFrameBuffer.ets framebuffer.ts
cp <repo>/entry/src/main/ets/audio/FecGroup.ets fecgroup.ts
```

改写三个拷贝的 import：`'../net/Wire'`→`'./wire.ts'`；framebuffer 删掉 hilog 行并把 `hilog.info(...)` 替换为 `void dropped;`（Node 无 @kit）。写 `units.test.mts`：

```ts
import { opusFrameBytes, opusFrameSamples, isOpusNativeRate } from './wire.ts';
import { OpusFrameBuffer } from './framebuffer.ts';
import { FecGroup } from './fecgroup.ts';
import assert from 'node:assert';

// frame math
assert.strictEqual(opusFrameSamples(48000), 960);
assert.strictEqual(opusFrameBytes(48000, 1), 1920);
assert.strictEqual(opusFrameBytes(16000, 2), 1280);
assert.ok(isOpusNativeRate(24000) && !isOpusNativeRate(44100));

// accumulation across pump chunks (1320 B slices do not divide 1920)
const fb = new OpusFrameBuffer();
fb.start(48000, 1);
const frames: Array<Uint8Array> = [];
fb.feed(new Uint8Array(1320), (f) => frames.push(new Uint8Array(f)));   // 0 frames, 1320 carried
assert.strictEqual(frames.length, 0);
fb.feed(new Uint8Array(1320), (f) => frames.push(new Uint8Array(f)));   // 2640 -> 1 frame, 720 carried
assert.strictEqual(frames.length, 1);
assert.strictEqual(frames[0].length, 1920);
assert.strictEqual(fb.reset(), 720);
fb.feed(new Uint8Array(3840), (f) => frames.push(new Uint8Array(f)));   // exact 2 frames
assert.strictEqual(frames.length, 3);
assert.strictEqual(fb.reset(), 0);

// XOR + group bookkeeping, incl. variable-length padding semantics
const fg = new FecGroup();
const a = new Uint8Array([0xff, 0x0f]);
const b = new Uint8Array([0x0f]);
let parity = null;
for (let i = 0; i < 10; i++) { parity = fg.add(a, 12 * 1 + i); assert.strictEqual(parity, null); }
parity = fg.add(b, 12 * 1 + 10); assert.strictEqual(parity, null);
parity = fg.add(a, 12 * 1 + 11);
assert.ok(parity !== null);
if (parity !== null) {
  assert.strictEqual(parity.groupStartSeq, 13);
  assert.strictEqual(parity.lengths.length, 12);
  assert.strictEqual(parity.lengths[10], 1);
  assert.strictEqual(parity.xor.length, 2);
  assert.strictEqual(parity.xor[0], 0xff);
  assert.strictEqual(parity.xor[1], 0x0f);
}
```

期望值手算依据：11 个 `[0xff, 0x0f]` + 1 个 `[0x0f]`——byte0 有奇数个 0xff 参与异或得 `0xff`，byte1 有奇数个 0x0f 得 `0x0f`（b 在 byte1 处按零填充，不翻转结果），故 `xor = [0xff, 0x0f]`。断言即按此写出，不留注释。

- [ ] **Step 4: 运行 harness**

```bash
node --experimental-strip-types units.test.mts
```

预期 PASS（若 Step 2 先于 Step 3 写完，可先对旧行为空实现跑一次红，再实现跑绿——顺序不豁免，红必须见过一次）。

- [ ] **Step 5: ArkTS 编译**

```bash
cd /home/zhh7ce/Documents/codes/MicYou-HarmonyOS && hvigorw assembleHap --no-daemon
```

预期成功（两类尚无调用者）。

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/net/Wire.ets entry/src/main/ets/audio/OpusFrameBuffer.ets entry/src/main/ets/audio/FecGroup.ets
git commit -m "feat: frame accumulation and XOR FEC grouping for the opus send path"
```

---

### Task 5: OpusBridge + 控制器 Opus 数据路径（真机首流）

**Files:**
- Create: `entry/src/main/ets/audio/OpusBridge.ets`
- Modify: `entry/src/main/ets/app/MicYouController.ets`
- Modify: `entry/src/main/ets/pages/SettingsView.ets`——仅 `CODEC_CHOICES`（`:120-124`）Opus 改 `available: true`、删旧注释；置灰/迁移留 Task 7

**Interfaces:**
- Consumes: Task 2 的 `libmcyopus.so` 三函数；Task 4 的 `OpusFrameBuffer`、`isOpusNativeRate`、`opusFrameBytes`；Task 3 结论（数据包走现有 `encodeAudioPacket`）
- Produces（Task 6 依赖）:
  ```ts
  // audio/OpusBridge.ets
  export class OpusBridge {
    create(sampleRate: number, channels: number): void;
    encode(frame: ArrayBuffer): ArrayBuffer;
    destroy(): void;
  }
  // MicYouController 新增私有成员（Task 6 直接引用这些名字）
  private readonly encoder: OpusBridge;
  private readonly frameBuffer: OpusFrameBuffer;
  private readonly fecGroup: FecGroup;          // 本任务只建/重置，不消费返回值
  private opusMode: boolean;
  ```

- [ ] **Step 1: 写 OpusBridge.ets**

GPL 头块后：

```ets
import { createEncoder, encode, destroyEncoder } from 'libmcyopus.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3307;
const TAG: string = 'MicYouOpus';

export class OpusBridge {
  private handle: number = 0;

  create(sampleRate: number, channels: number): void {
    if (this.handle !== 0) {
      throw new Error('opus encoder already created');
    }
    this.handle = createEncoder(sampleRate, channels);
    hilog.info(DOMAIN, TAG, 'encoder created %{public}d Hz / %{public}d ch', sampleRate, channels);
  }

  encode(frame: ArrayBuffer): ArrayBuffer {
    return encode(this.handle, frame);
  }

  destroy(): void {
    if (this.handle !== 0) {
      destroyEncoder(this.handle);
      hilog.info(DOMAIN, TAG, 'encoder destroyed');
      this.handle = 0;
    }
  }
}
```

- [ ] **Step 2: 控制器接入 Opus 分支**

`MicYouController.ets`：

import 增加：`CODEC_OPUS`, `isOpusNativeRate`（`../net/Wire`）；`OpusBridge`, `OpusFrameBuffer`（`../audio/...`）；`FecGroup`。

字段区（`:78-81` 旁）加：

```ets
private readonly encoder: OpusBridge = new OpusBridge();
private readonly frameBuffer: OpusFrameBuffer = new OpusFrameBuffer();
private readonly fecGroup: FecGroup = new FecGroup();
private opusMode: boolean = false;
```

`start()`：构建 `config` 处（`:128-133`）之后、`pump.start` 之前加钳制（UI 之外的防御，spec §3）：

```ets
const wantOpus: boolean = settings.codec === CODEC_OPUS;
if (wantOpus && (!isOpusNativeRate(config.sampleRate) || config.audioFormat !== AUDIO_FORMAT_16BIT)) {
  hilog.warn(DOMAIN, TAG, 'opus config clamped from %{public}d/fmt%{public}d to 48000/16-bit',
    config.sampleRate, config.audioFormat);
  config.sampleRate = 48000;
  config.audioFormat = AUDIO_FORMAT_16BIT;
}
```

（`CaptureConfig` 是 interface、字段可变；import `AUDIO_FORMAT_16BIT`。）

`:134-135` 的旧注释（"Opus is not implemented…"）删除。`applied` 赋值后（`:139-142` 处）改为：

```ets
this.capSampleRate = applied.sampleRate;
this.capChannels = applied.channels;
this.capFormat = applied.audioFormat;
this.opusMode = wantOpus;
if (this.opusMode) {
  // 钳制只保证请求值合法；applied 回退不改采样率、并把位深归到 16-bit，故此处必然合法。
  this.encoder.create(applied.sampleRate, applied.channels);
  this.frameBuffer.start(applied.sampleRate, applied.channels);
  this.fecGroup.reset();
  this.capCodec = CODEC_OPUS;
} else {
  this.capCodec = CODEC_PCM;
}
```

`onPcm()`（`:180-189`）开头分支：

```ets
private onPcm(payload: Uint8Array, sessionId: number): void {
  if (this.snapshot.phase !== EnginePhase.Streaming) {
    return;
  }
  if (this.opusMode) {
    this.frameBuffer.feed(payload, (frame: ArrayBuffer) => this.onOpusFrame(frame, sessionId));
    return;
  }
  … 现有 PCM 五行原样 …
}

private onOpusFrame(frame: ArrayBuffer, sessionId: number): void {
  const packet: Uint8Array = new Uint8Array(this.encoder.encode(frame));
  const seq: number = this.sequence;
  this.sequence += 1;
  const data: ArrayBuffer = encodeAudioPacket(packet, seq, Date.now(), sessionId,
    this.capSampleRate, this.capChannels, this.capFormat, CODEC_OPUS);
  this.audioOut.send(new Uint8Array(data));
  this.snapshot.packetsSent += 1;
  // FEC 消费在 Task 6；这里先返回值丢弃。
  this.fecGroup.add(packet, seq);
}
```

`teardown()`（`:172-178`）在 `await this.pump.stop()` 后加：

```ets
this.frameBuffer.reset();
this.fecGroup.reset();
this.encoder.destroy();
```

`start()` 里 `this.sequence = 0;` 旁（`:110`）加 `this.opusMode = false; this.fecGroup.reset(); this.frameBuffer.reset(); this.encoder.destroy();`（防上个会话异常残留；`destroy()` 对空句柄是 no-op）。

- [ ] **Step 3: 编译**

```bash
hvigorw assembleHap --no-daemon
```

- [ ] **Step 4: 真机首流冒烟**

桌面侧（另一个终端，`../MicYou/tauri-app`）：`cargo run -p micyou-cli -- serve`。

```bash
HDC=/opt/devecostudio/sdk/default/openharmony/toolchains/hdc
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.zhh7ce.micyou.hmos
$HDC shell hilog -r
$HDC shell "aa start -b com.zhh7ce.micyou.hmos -a EntryAbility"
```

设置页选 Opus（此时仅芯片可选），返回首页点 FAB。由用户确认桌面收到音频、音质正常；`$HDC shell "hilog -x -P $($HDC shell pidof com.zhh7ce.micyou.hmos)" | grep MicYou` 里应见 `encoder created 48000 Hz` 与流式发送日志；带宽相对 PCM 明显下降。任一条不满足 → 用 superpowers:systematic-debugging 分诊，不带病提交。

- [ ] **Step 5: PCM 回归**

codec 切回 PCM，再跑一次 FAB 会话，确认与之前行为一致（1320 B 分片、~73 包/s）。

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/audio/OpusBridge.ets entry/src/main/ets/app/MicYouController.ets entry/src/main/ets/pages/SettingsView.ets
git commit -m "feat: stream on-device opus frames through the opus codec path"
```

---

### Task 6: FEC 奇偶包接线

**Files:**
- Modify: `entry/src/main/ets/app/MicYouController.ets`（`onOpusFrame`）

**Interfaces:**
- Consumes: Task 3 `encodeFecParityPacket`；Task 4 `FecGroup.add → FecParity | null`
- Produces: 无下游任务依赖（终端）

- [ ] **Step 1: 实现奇偶包发送**

`onOpusFrame` 末尾两行替换：

```ets
const parity: FecParity | null = this.fecGroup.add(packet, seq);
if (parity !== null) {
  const fecFrame: ArrayBuffer = encodeFecParityPacket(parity.xor, parity.lengths, parity.groupStartSeq,
    this.sequence, Date.now(), sessionId, this.capSampleRate, this.capChannels, this.capFormat);
  this.audioOut.send(new Uint8Array(fecFrame));
  // parity reuses this.sequence WITHOUT incrementing it (Android AudioEngine.kt:970-972).
  this.snapshot.packetsSent += 1;
}
```

import 增加 `encodeFecParityPacket`（`../net/Messages`）、`FecParity`（`../audio/FecGroup`）。

- [ ] **Step 2: 编译 + 真机验证**

`hvigorw assembleHap --no-daemon` → 装、起会话（同 Task 5 Step 4 流程）。验收（spec §8.7 的退化标准）：
- 桌面 CLI 会话期间无 `invalid audio packet` 类拒绝日志、音频连续；
- 抓一个 datagram 计数验证节奏：普通包 ~50/s（48k/20ms），奇偶包 ~4.2/s；`packetsSent` 相应增长；
- 用户耳检音质无回退（奇偶包不应打断解码）。

- [ ] **Step 3: Commit**

```bash
git add entry/src/main/ets/app/MicYouController.ets
git commit -m "feat: emit XOR parity packets every 12th opus frame for desktop recovery"
```

---

### Task 7: 设置页启用 Opus——置灰与迁移

**Files:**
- Modify: `entry/src/main/ets/pages/SettingsView.ets`（`:113-118` RATE_CHOICES 用法、`:340-364` 两个 chip builder、`:466+` ForEach 调用、`:237-244` setCodecValue）
- Modify: `entry/src/main/resources/{base,zh_CN,zh_TW}/element/string.json`（`codec_opus_hint` 改写）

**Interfaces:**
- Consumes: Task 4 `isOpusNativeRate`、`AUDIO_FORMAT_16BIT`；`ConnectionStore` 现有 setter
- Produces: 无

- [ ] **Step 1: 置灰参数对象 + builder 改造**

文件顶部加接口（与现有 `CodecChoice` 同段）：

```ets
interface RateChipArgs {
  choice: TextChoice;
  disabled: boolean;
}

interface BitDepthChipArgs {
  choice: TextChoice;
  disabled: boolean;
}
```

`rateChip`/`bitDepthChip` 改为（以 rate 为例，bitDepth 同构）：

```ets
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
```

判定方法（类内私有）：

```ets
private opusLockedRate(value: number): boolean {
  return this.codec === CODEC_OPUS && !isOpusNativeRate(value);
}

private opusLockedFormat(value: number): boolean {
  return this.codec === CODEC_OPUS && value !== AUDIO_FORMAT_16BIT;
}
```

ForEach 调用改为传新字面量（保证 AGENTS 的重渲染规则成立）：

```ets
ForEach(RATE_CHOICES, (choice: TextChoice) => {
  this.rateChip({ choice: choice, disabled: this.opusLockedRate(choice.value) })
}, (choice: TextChoice) => choice.label.toString())
```

bitDepth 处同构替换。

- [ ] **Step 2: 切到 Opus 时迁移不兼容已存值**

`setCodecValue` 体替换为：

```ets
private setCodecValue(value: number): void {
  if (value === this.codec) {
    return;
  }
  this.codec = value;
  ConnectionStore.shared.setCodec(value);
  if (value === CODEC_OPUS) {
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
```

import 增加 `isOpusNativeRate`（`../net/Wire`；`CODEC_OPUS`、`AUDIO_FORMAT_16BIT` 已在）。

- [ ] **Step 3: 三套 `codec_opus_hint` 文案**

base：`"Opus encodes 20 ms VOIP frames with FEC; capture choices narrow to compatible rates."`
zh_CN：`"Opus 以 20 毫秒 VOIP 帧编码并附带 FEC，采样率与位深会限制到兼容组合。"`
zh_TW：`"Opus 以 20 毫秒 VOIP 幀編碼並附带 FEC，取樣率與位元深度會限制到相容組合。"`

- [ ] **Step 4: 编译 + 用户目检**

`hvigorw assembleHap --no-daemon`，装机后进设置页：
1. 选 Opus → 44.1k/96k、24-bit/float 芯片半透明不可点；已选 44.1k 时自动跳到 48k；
2. 退出重进设置页，选择保持；
3. 切回 PCM → 全部芯片恢复可选；
4. Opus 下起会话验证迁移后的持久值确实生效。

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/pages/SettingsView.ets entry/src/main/resources
git commit -m "feat: enable the opus codec choice and gate incompatible capture settings"
```

---

### Task 8: 文档更新（独立 commit）

**Files:**
- Modify: `AGENTS.md`
- Modify: `README.md`、`CONTRIBUTING.md`（如含相关表述）

- [ ] **Step 1: AGENTS.md**

逐处修订（改前先对照 spec）：
1. Overview「no native code, no third-party dependencies」→ 改为：无第三方 **ArkTS** 依赖（`oh-package.json5` 只含本地 napi types 包）；含一个 native 模块（vendored libopus，BSD-3）。
2. Wire protocol 节：`codec` 条目删除"hard-codes capCodec = 0 / Opus disabled"表述，改为 PCM 与 Opus 双分支；`UDP_PCM_PAYLOAD_SIZE` 说明补一句 Opus 分支按 20 ms 帧（16k→320、48k→960 样点/声道）凑帧、包体远小于 1320；FEC 条目改写为"带外 XOR（12 包一组，`fecBuffer=[0x01]` 标记、`fecSequenceNumber`=组起始、12 条 packed `fecPacketLengths`、奇偶包复用下一序号）；in-band FEC 刻意不开——桌面 `decode_fec` 恒为 false"。
3. How it runs 第 8 步与数据路径段：补 codec 分支与 OpusFrameBuffer/FecGroup；`capCodec` 不再恒 0。
4. Modules 表加 4 行：`audio/OpusBridge.ets`、`audio/OpusFrameBuffer.ets`、`audio/FecGroup.ets`、`entry/src/main/cpp`（napi_init + vendored opus + CMake）。
5. Build 节：加 native 构建说明（externalNativeOptions、`.so` 体积实测值、opus 源选项 FORCE 在 CMakeLists）。
6. Known gaps 删除 Opus 条目（含"Opus chip disabled"句）；Wi-Fi-only 等其余条目不动。
7. mermaid 图：`CT --> NM` 之间补 Opus 路径一行。

- [ ] **Step 2: README / CONTRIBUTING**

README 特性列表若有"PCM only"表述改为"PCM + Opus(VOIP, FEC)"；CONTRIBUTING 的协议/验证节提一句：改 `net/Pb.ets`/`net/Messages.ets` 后必须重跑 protobufjs 对照（本计划 Task 3 的 harness 模式）。libopus BSD-3 声明义务：在 README 构建/许可处一句"vendored libopus under BSD-3, notices in entry/src/main/cpp/opus/COPYING"。

- [ ] **Step 3: Commit（与代码分开的 docs commit）**

```bash
git add AGENTS.md README.md CONTRIBUTING.md
git commit -m "docs: cover the on-device opus encoder and its FEC wire path"
```

---

### Task 9: 全量回归清单（终任务，不产码）

- [ ] **Step 1: 构建链**

```bash
hvigorw clean --no-daemon && hvigorw assembleHap --no-daemon
unzip -l entry/build/default/outputs/default/entry-default-signed.hap | grep libmcyopus
```

- [ ] **Step 2: 真机矩阵（对照 spec §8，用户在旁执行/目检）**

| # | 场景 | 通过标准 |
|---|---|---|
| 1 | Opus 48k/mono/16-bit 全流程 | 桌面出声、0% loss、码率数十 kbps |
| 2 | Opus 16k/mono | 头上报 16000、桌面正常 |
| 3 | Opus 48k/stereo | 正常（帧 3840 B） |
| 4 | PCM 回归 48k/mono 16-bit | 与 main 行为一致 |
| 5 | PCM 44.1k/float32 | 不受 Opus 逻辑影响 |
| 6 | 会话中途 mute/恢复 | 奇偶组跨静音继续，桌面仍解得出 |
| 7 | 断连（拔网线/杀桌面） | watchdog Failed 路径 + teardown 销毁 encoder |
| 8 | 息屏后台（覆盖既有 gap） | 连续任务保活、流不断；结果记录到 AGENTS known gaps 或移除该 gap |
| 9 | 杀进程重进（自动连接开） | auto-connect 走 Opus 参数一致 |

- [ ] **Step 3: 清理与收尾**

harness 目录（/tmp/micyou-proto-verify、/tmp/micyou-units）删除。任何 8/9 发现的新 gap 记入 AGENTS Known gaps（docs commit）。全部通过后向用户报告矩阵结果，由用户决定是否 push。

---

## Self-Review 记录

- Spec 覆盖：§1 决策（Task 2 ctl 组 / Task 6 FEC / Task 7 UI）、§2 文件清单（Task 1-8 一一对应）、§3 启动顺序与钳制（Task 5 Step 2）、§4 线格式（Task 3 + Task 6）、§5 构建（Task 2）、§6 napi 面（Task 2）、§7 错误处理（Task 5 Step 2 teardown 顺序 + Task 9 #7）、§8 验证（各任务 Step + Task 9）、§9 范围外（无任务，符合）。
- 占位符扫描：已清——所有代码块为最终形态；harness 的 XOR 期望值附了手算依据；失败步骤都给了预期报错文本。
- 类型一致性：`opusFrameBytes/FecParity/FecGroup.add/OpusFrameBuffer.feed/reset/OpusBridge/encodeFecParityPacket` 签名在 Interfaces 块与各任务代码间逐一对齐；`capCodec` 语义与 Task 5 分支一致。
