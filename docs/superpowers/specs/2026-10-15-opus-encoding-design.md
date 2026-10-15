# Opus 端侧编码设计（TODO 4.3，方案 A）

- 日期：2026-10-15
- 状态：已与用户逐节确认
- 前置研究：`research/4.3-opus-off-the-shelf.md`（现成件盘点）、`research/4-desktop-codec-matrix.md`（桌面接收端真值）
- 对齐基准：Android `composeApp/.../audio/AudioEngine.kt`（编码器参数与 FEC 线格式）、桌面 `micyou-core`（`transport/session.rs` 校验、`transport/jitter_buffer.rs` 恢复、`transport/opus.rs` 解码）

## 1. 目标与已定决策

给 HarmonyOS 客户端增加端侧 Opus 编码，把带宽从 PCM 的 ~768 kbps 降到 libopus VOIP 默认码率量级，并让桌面 jitter buffer 的丢包恢复真正生效。

| 决策点 | 结论 | 依据 |
|---|---|---|
| 编码器来源 | 自编译 libopus 1.5.2，源码进仓，静态内嵌进 napi 模块 | ohpm/TPC 无现成件；系统 AVCodec 无 FEC/DTX 控制键 |
| FEC 策略 | 带外 XOR 奇偶包，照抄 Android；**不开 in-band FEC** | 桌面 `opus.rs:63` 的 `decode_fec` 恒为 `false`，in-band 冗余是纯浪费码率；带外 XOR 是唯一被实现的恢复路径 |
| 采集参数耦合 | UI 置灰不兼容项：Opus 下采样率限 {16k, 48k}、位深锁 16-bit；切到 Opus 时不兼容的已存值自动迁移为 48k/16-bit | 44.1k Opus 是桌面整路静音陷阱（校验通过但解码器建不起来）；S16LE 是 `opus_encode` 的直接输入，免转换 |
| 编码参数暴露 | 固定默认，不加新设置项：VOIP 应用、20 ms 帧、VBR 开、DTX 开、INBAND_FEC 关、SIGNAL=VOICE、码率用 libopus 自动 | 用户选择；YAGNI |
| 集成形态（方案甲） | napi 只做单帧编码；凑帧（`OpusFrameBuffer`）与 FEC 分组（`FecGroup`）在 ArkTS 控制器路径；`CapturePump` 不改 | 序号/校验/日志留在 ArkTS，native 崩溃面最小 |

## 2. 模块划分

### 新增

```
entry/src/main/cpp/
  CMakeLists.txt          # add_subdirectory(opus) + add_library(mcyopus SHARED napi_init.cpp)
                          # target_link_libraries(mcyopus PRIVATE opus; PUBLIC libace_napi.z.so libhilog_ndk.z.so)
  napi_init.cpp           # 模块名 libmcyopus.so：句柄表 + createEncoder/encode/destroyEncoder
  opus/                   # libopus 1.5.2 上游源码，含 COPYING 等许可证文件
                          # SHA256 65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
  types/libmcyopus/
    index.d.ts            # ArkTS 类型声明
    oh-package.json5      # { name: "libmcyopus.so", types: "index.d.ts", version, description }
entry/src/main/ets/audio/
  OpusBridge.ets          # napi 严格 ArkTS 封装；hilog DOMAIN 0x3307, tag MicYouOpus
  OpusFrameBuffer.ets     # 把任意 PCM16 分片累积成 20 ms 整帧；尾不足一帧在 stop 时丢弃并记日志
  FecGroup.ets            # 收 12 个 Opus 包，XOR（零填充到组内最长包），输出奇偶包描述；未满一组丢弃
```

### 修改

| 文件 | 改动 |
|---|---|
| `net/Pb.ets` | `PbWriter.writePackedUInt32s(field, values)`：proto3 packed repeated uint32（长度前缀 + 串联 varint） |
| `net/Messages.ets` | Opus 数据包直接复用现有 `encodeAudioPacket`（buffer 参数本就与 codec 无关，传 opus 包 + codec=1 即可）；新增 `encodeFecParityPacket(xor, lengths, groupStartSeq, seq, ts, sid, rate, ch, format)`；新常量 `ORDERED_FEC_BUFFER=4`、`ORDERED_FEC_SEQ=5`、`ORDERED_FEC_LENGTHS=7` |
| `net/Wire.ets` | `OPUS_FRAME_SAMPLES = 960`（20 ms @48k，按 rate 换算）、`FEC_GROUP_SIZE = 12`、`OPUS_NATIVE_RATES = [8000,12000,16000,24000,48000]` |
| `app/MicYouController.ets` | start 会话按 settings.codec 建管线；Opus 分支见 §3；teardown 增加 destroyEncoder |
| `pages/SettingsView.ets` | `CODEC_CHOICES` Opus 改 `available: true`；codec=Opus 时对 44100/96000 与 24-bit/float32 芯片置灰（复用 `choice.available` 形态）；切 Opus 时不兼容已存值迁移为 48000/16-bit 并持久化 |
| `entry/oh-package.json5` | 依赖 `"libmcyopus.so": "file:./src/main/cpp/types/libmcyopus"` |
| `entry/build-profile.json5` + `build-profile.example.json5` | `buildOption.externalNativeOptions`：path/abiFilters/arguments（§5） |
| 三套 `string.json` | Opus 启用后如 `codec_opus_hint` 文案需更新，则 base/zh_CN/zh_TW 同步 |
| `AGENTS.md` / `README.md` / `CONTRIBUTING.md` | 模块表加 cpp 与三个新 ets 文件；Known gaps 删除"无端侧 Opus"条目；协议节改写 FEC 描述 |

不改动：`CapturePump.ets`、`AudioSender.ets`、`ConnectionStore.ets`（codec 已持久化）、`ControlClient.ets`。

## 3. 数据流与运行时行为

### 启动顺序（Opus 会话）

1. 权限、TCP 握手、UDP bind、后台任务——全部沿用现有步骤。
2. 采集 config 取自 settings；UI 已保证 Opus 下为 {16k,48k}/16-bit。控制器侧防御：`applied` 返回后若 codec=Opus 且（rate ∉ OPUS_NATIVE_RATES 或 format ≠ 2），把该会话钳制回 48000/S16LE 再建编码器（理论上不可达，防旧 prefs/未来 UI 变动踩静音陷阱）。
3. `pump.start` 之后、进入 Streaming 之前用 `CaptureApplied` 的实际 (rate, channels) 调 `OpusBridge.createEncoder`——编码器必须跟回退后的真实采集参数一致。create 抛错走现有 catch → teardown → Failed。
4. `capCodec = CODEC_OPUS`；`capSampleRate` 编码头上报的是编码器率（= applied 采集率，两者被 §2 钳制绑定）。

### 每帧路径

```
CapturePump on('readData') → 1320 B 分片 → controller.onPcm(payload)
  OpusFrameBuffer.feed(payload)            # frameBytes = 960×2×ch（48k/mono = 1920 B）
    每凑满一帧 → OpusBridge.encode(frameBytes) → opusPacket（VOIP 典型 40–160 B）
      普通包：encodeAudioPacket(opusPacket, seq++, ts, sid, rate, ch, format=2, codec=1)
              → AudioSender.send
      FecGroup.add(opusPacket)
        满 12 包 → 奇偶包（见 §4），sequenceNumber = 当前 seq（不递增）
```

- 电平 RMS 仍从 pump 的 PCM 计算，节流 100 ms 不变；watchdog、mute、snapshot 不变。
- DTX 静默小包（约 2 B）正常发送、正常消耗序号：桌面按 TOC 解析时长、解码成舒适噪声，序号连续故不触发丢包判定。
- `pump.stop()` 尾冲的残余 PCM 凑不满一帧时丢弃并打日志（Android 同样不冲不完整组）；`FecGroup` 未满 12 包的残余组丢弃不发（桌面恢复要求恰好 11/12 源包，残组奇偶包无意义）。
- 编码器实例每会话新建/销毁（与 socket 一次性原则同构）；teardown 顺序：watchdog → pump.stop → destroyEncoder+frameBuffer.reset → audioOut.stop → background.stop → control.close。

## 4. 线格式（奇偶包，逐字段对齐 `AudioEngine.kt:940–988`）

- 检测：桌面按 `fecBuffer` 非空 ⇒ 奇偶包（`FecLayout::ExplicitMarker`）。因此奇偶包必须写 `fecBuffer = [0x01]`（1 字节标记，不是数据）。
- XOR 数据放 `audioPacket.buffer`：12 个源包零填充到最长者后逐字节异或。
- `fecSequenceNumber` = 组起始序号（第 1 个源包的 seq）；普通包该字段不写（proto3 省略解码为 0，组 0 的歧义由 `[0x01]` 标记消除）。
- `fecPacketLengths` = 12 条原始包长度，packed uint32；每条 1..1320（`session.rs` 硬校验）。恢复时按 `lengths[missingSeq − groupStart]` 截掉零填充。
- 奇偶包的 `sequenceNumber` 复用下一个普通包的序号且不递增——桌面忽略 parity 自身 seq，这样音频侧无序号空洞。
- 组边界连续：源包 0..11 的奇偶包占 seq 12，下一组从 12 开始（`jitter_buffer.rs:328–331` 新发送端约定）。
- 奇偶包的 `audioPacket` 元数据（sampleRate/channelCount/audioFormat/codec）与源包一致，codec=1。
- 上限复核：VOIP 20 ms 默认码率下源包 ≪ 1320 B，XOR 缓冲 ≤ 最长源包，奇偶整帧 ≈ XOR + 12×varint + 标量字段 + 8 字节头 < 1472，`AudioSender` 现有守卫保留兜底。

## 5. 构建与打包

- `externalNativeOptions`：
  - `path: "./src/main/cpp/CMakeLists.txt"`
  - `abiFilters: ["arm64-v8a"]`
  - `arguments: "-DOPUS_DISABLE_INTRINSICS=ON -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF"`
- 首轮纯标量实现求稳；Neon（关 DISABLE_INTRINSICS、开 OPUS_USE_NEON）作为后续独立实验，不进本设计。
- 上游 CMake 对 `CMAKE_SYSTEM_NAME=OHOS` 若有 include 检测异常，按惯例补一行 `OR CMAKE_SYSTEM_NAME STREQUAL "OHOS"` 本地 patch，改动以 `micyou-ohos.patch` 形式存 `cpp/opus/` 旁边可追溯。
- 静态内嵌 ⇒ HAP 只多一个 `libmcyopus.so`，无 SONAME 软链/装载顺序坑；体积增量构建后实测记录（预估 300–500 KB）。
- 许可：libopus BSD-3，与 GPL-3 兼容；义务是随包保留 `COPYING`/版权声明文本，源码树进仓即满足。工程自身 napi/CMake 文件按仓库惯例带 GPL 头。

## 6. napi 接口面

```ts
// index.d.ts
export function createEncoder(sampleRate: number, channels: number): number;
export function encode(handle: number, pcm: ArrayBuffer): ArrayBuffer;
export function destroyEncoder(handle: number): void;
```

- C 侧 `opus_encoder_create(rate, ch, OPUS_APPLICATION_VOIP, &err)` 成功后立即 `opus_encoder_ctl`：`SET_VBR(1)`、`SET_DTX(1)`、`SET_INBAND_FEC(0)`、`SET_SIGNAL(OPUS_SIGNAL_VOICE)`；码率不设（libopus 自动）。
- `encode` 前置校验 `pcm.byteLength === frameSamples * 2 * channels`，不符抛 JS Error（信任边界在桥层，AGENTS 惯例）；输出 `napi_create_arraybuffer` 返回裸 Opus 包（输出缓冲 4000 B 上界，实际受码率约束）。
- 句柄表：`std::vector`/map + 单线程访问假定（所有调用来自 ArkTS 主线程的 pump 回调）；非法 handle 抛错。

## 7. 错误处理

- createEncoder/encode 抛错 → 控制器 catch → teardown → phase Failed（现有通道，无新分支）。
- native 返回 0 长度（理论上不发生）→ 桥层抛错，不发空包（`session.rs` 拒空 buffer）。
- `FecGroup`/`OpusFrameBuffer` 为纯 ArkTS 数据结构，无 IO，错误即编程错误，靠 §3 的丢弃策略与日志定位。
- 会话间状态：frameBuffer、FecGroup、sequence 每 start 全量重置，与新建 sockets/encoder 同批。

## 8. 测试与验证

工程无测试 runner，验证 = 构建 + 真机手测（AGENTS 既有流程）：

1. `hvigorw assembleHap` 成功；`unzip -l entry-default-signed.hap` 含 `libs/arm64/libmcyopus.so`。
2. `micyou-cli serve` + nova 14 Pro：Opus/48k/mono 连通 → 桌面解出音频、0% loss；观察带宽从 ~768 kbps 降至 libopus 自动码率量级。
3. 16k/mono Opus 组合复测（编码器与头上报一致）。
4. 切回 PCM 全回归（1320 B 路径行为不变）；44.1k/float32 等 PCM 组合不受影响。
5. 设置页交互：选 Opus → 不兼容芯片置灰、已存值迁移；退出重进持久化正确；三套语言文案齐全。
6. 顺带补测现有 gap：屏幕关闭时 `audioRecording` 连续任务在 Opus 流上的表现。
7. FEC 恢复路径本身不可在局域网可控注入丢包，验收退化为：桌面日志/stats 无奇偶包校验拒绝（奇偶包被 validate 接收），字段对齐以 §4 逐条核对为准。
8. 线格式回归防线：`net/Pb.ets`/`net/Messages.ets` 改动后重跑 out-of-tree 的 protobufjs 对照检查（AGENTS「Tests」既有流程），新增 packed repeated 与 fec 字段的字节级验证。

## 9. 超出范围

- in-band FEC / 桌面 `decode_fec` 利用（桌面侧改动，另一仓）。
- Opus 立体声 UI 组合已在采集参数里（channels 1/2 编码器原生支持），但 20ms 立体声帧 CPU 与包体增大只是线性代价，无需特判。
- Neon intrinsics 开关、CBR/码率设置 UI、AVCodec 系统编码器路线。
- PCM 分支的 FEC（桌面已支持，客户端不做）。
- 44.1k→48k 重采样（被 UI 置灰策略规避，不引入采样率转换代码）。
