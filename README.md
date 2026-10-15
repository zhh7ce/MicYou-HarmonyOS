# MicYou HarmonyOS 客户端

把 HarmonyOS NEXT 手机当作电脑麦克风：应用从手机麦克风采集音频，按 MicYou 线协议推给桌面端服务器，桌面端把它写进一个虚拟麦克风设备。

上游项目是 MicYou（桌面端服务器 + 安卓 / iOS 客户端）：<https://github.com/MicYou-Dev/MicYou>，本仓库是它的鸿蒙端客户端。

## 目录结构

```
entry/src/main/ets/
  net/          Pb.ets              最小 proto3 编解码（varint、length-delimited、fixed32）
                Wire.ets            帧头、握手字节、FrameAssembler、协议常量、SOURCE_* 常量
                Messages.ets        MessageWrapper 编解码
                ControlClient.ets   TCP 控制连接：握手、帧分发、pong、心跳监督
                AudioSender.ets     UDP 音频发送
                Discovery.ets       mDNS _micyou._tcp 浏览与解析
  audio/        CapturePump.ets     AudioCapturer 回调采集、按配置切片、失败回退
  app/          MicYouController.ets 会话状态机
                ConnectionStore.ets @ohos.data.preferences 持久层（历史 / 上次连接 / 设置）
                BackgroundRunner.ets audioRecording 长任务
                PermissionGate.ets   麦克风权限
                AppEnvironment.ets   UIAbility 上下文持有 + 主题 / 语言应用
  pages/        Index.ets           主页面（Navigation 容器）
                SettingsView.ets     设置页（NavDestination）
```

单 `entry` HAP 模块，纯 ArkTS，没有 native 代码，`oh-package.json5` 为空——proto3 编解码是自己在 `net/Pb.ets` 里实现的，不引入 protobuf 运行时。bundleName 为 `com.zhh7ce.micyou.hmos`，`vendor` 为 `zhh7ce`。

图标不是手画的：`scripts/gen_logo.py`（唯一依赖 Pillow，只作为开发工具，不进应用）用一个几何常量描述扁平麦克风标记，重跑一次写出六张 PNG——头部图 `app_logo.png`、启动窗口图 `startIcon.png`，以及 `AppScope` 与 `entry` 两处分层启动图标的 `foreground.png` / `background.png`。

## 生命周期与运行流程

`EntryAbility` 只做三件事：`onCreate` 把 `UIAbilityContext` 交给 `AppEnvironment.publish`（这一 API 层级下 `getContext()` 已废弃，页面不能再直接取），publish 里同时 kick 起 `ConnectionStore.ensureInit`，加载完成后链式 `AppEnvironment.applyTheme()` 把主题色推到窗口；`onWindowStageCreate` 加载 `pages/Index`；`onDestroy` 停引擎并 `AppEnvironment.forget`。

主页面 `Index.aboutToAppear`：

1. `controller.attach` 注册快照观察者，然后 `discovery.start` 开始 mDNS 浏览；一个 browse 事件只带实例名，`Discovery` 会用 `mdns.resolveLocalService` 解析出地址；`startSearchingMDNS()` 必须显式调，不然一个事件都收不到
2. `await ConnectionStore.shared.ensureInit` 完成后，用上次连接设备回填手动 host/port
3. 若 `autoConnect` 打开且有 `last` 记录，且本进程未被用户手动停止过，则延后 1.5 s 再触发连接；这段时间内 mDNS 若发现同名设备，会用发现到的新地址覆盖历史地址

`MicYouController.start(context, host, tcpPort, name)` 顺序：

1. 相位 `Connecting`；每次会话都新建 `ControlClient` 与 `AudioSender`（HarmonyOS 的 socket 关闭后不能重连），sessionId 自增、sequence 归零
2. 麦克风权限
3. `control.open` — TCP 连接 + `MicYouCheck1` / `MicYouCheck2` 握手 + `ConnectMessage{sessionId, platform: "harmonyos"}`
4. `audioOut.start` — UDP 绑定，目标端口 = 控制端口 + 1
5. `background.start` — `audioRecording` 长任务，带一个回指本 ability 的 wantAgent
6. 从 `ConnectionStore.shared.settings` 读一份 `CaptureConfig { sampleRate, channels, audioFormat, sourceType }` 交给 `pump.start`；返回的 `CaptureApplied` 存到 controller 的 `capSampleRate/capChannels/capFormat`，`capCodec` 硬编 `0`（PCM，Opus 见"已知空白"）
7. 相位 `Streaming`，启动 1 s 看门狗
8. `ConnectionStore.recordSuccess(name, host, tcpPort)` 只在这一步之后 fire-and-forget，写错的地址不会污染历史

任一步抛错都反向 teardown：停看门狗 → flush 并释放 capturer → 关 UDP → 停长任务 → 关 TCP，相位 `Failed`。

数据面：`CapturePump` 的 `on('readData')` 回调把缓冲区按 1320 字节切片，`MicYouController.onPcm` 用**实际生效**的采样率/声道/`audioFormat` + `codec=0` 编成 `OrderedAudioPacket`（sequence、unix ms timestamp、sessionId）发到 UDP；同一次回调里按格式算 RMS 推给 `onLevel`，controller 每 100 ms 才 republish 一次快照，避免 ArkUI 过度重绘。看门狗负责：5 s 内没收到桌面端 ping，或 UDP 连续失败 500 次，判链路断；否则每秒至少 publish 一次让发送计数在老桌面端上也保持爬升。

## 构建与安装

需要 DevEco Studio 或 Command Line Tools + HarmonyOS SDK。本机 SDK 为 26.0.0（API 26），项目 `compatibleSdkVersion` 保持 5.0.0(12)，成员 `@since` 高于 12 的 API 通过 `deviceInfo.sdkApiVersion` 在运行时门控，而不是把基线拉高。

`build-profile.json5` 是本机签名材料，仓库不跟踪。从示例起步：

```bash
cp build-profile.example.json5 build-profile.json5
```

然后在 DevEco 里 File > Project Structure > Project > Signing Configs，勾选 "Automatically generate signature"，登录华为开发者账号。DevEco 会往 `~/.ohos/config/` 写 `.cer/.p7b/.p12` 三件，把路径和两份加密口令填回 `build-profile.json5`。口令密文只在生成它的机器上可解，不要外传。

```bash
export DEVECO_SDK_HOME=/opt/devecostudio/sdk
hvigorw assembleHap --no-daemon
```

产物在 `entry/build/default/outputs/default/`：`entry-default-signed.hap` 可以装机；`entry-default-unsigned.hap` 装不上。装机、抓日志、UI 布局 dump 见 `AGENTS.md` 的 "Debug loop"。

## 线协议

协议本身定义在桌面仓库的 `tauri-app/crates/micyou-protocol/proto/network.proto`；本客户端只用 `net/` 下的手写 proto3 子集，不引入 protobuf 运行时。

- TCP 8554 传控制帧，UDP 8555（`udpPortFor` 计算 = TCP 端口 + 1）传音频
- 一帧 = `magic (i32 BE) + 载荷长度 (i32 BE) + protobuf 载荷`；TCP 用 `0x4D696359`（"MicY"），UDP 用 `0x4D696355`（"MicU"）
- socket 打开之后必须先发 `MicYouCheck1`、等 12 字节 `MicYouCheck2`，然后才允许出现任何帧
- 紧跟着 `ConnectMessage{sessionId, platform: "harmonyos"}`；sessionId 打在每一个音频包上，桌面端还要求音频的源 IP 与控制连接一致
- 桌面端每约 500 ms 发一个 ping，客户端把收到的 timestamp 原样 echo 回 pong；pong 也是保活手段——桌面端把下一帧超过 10 s 未到的连接判死
- 桌面端 2.1.1+ 每秒推一条 `StatsMessage`。字段类型混用：`rttMs` 与 `latencyMs` 是 int32（varint），`jitterMs` 与 `packetLoss` 是 float（fixed32 小端）；`readStats` 按 wire type 分派，不是按字段号猜
- `optional bool is_muted` 即使值为 false 也必须上线，否则桌面端会解成 `None`；因此走 `PbWriter.writeOptionalBool`，不是零值省略

音频包（`AudioPacketMessageOrdered`）：

- 载荷固定切成 1320 字节（`UDP_PCM_PAYLOAD_SIZE`），确保一个 UDP 数据报在 1472 字节以内不触发 IP 分片；一帧字节数 = `bytesPerSampleFor(audioFormat) × channels`，16-bit 单声道 = 660 帧 = 13.75 ms（48 kHz），换格式或立体声每包时长会变
- `codec` 目前只有 PCM (`0`)。`CODEC_OPUS = 1` 常量存在但发送路径写死 `capCodec = 0`；端上 Opus 的路线已定为 NDK + napi 引 libopus（VOIP 应用、20 ms 帧、in-band FEC、DTX），尚未实现
- `audioFormat` 沿用安卓的编码常量：`2` = 16-bit S16LE、`6` = 24-bit packed S24LE、`4` = float32 F32LE；只有这三种在桌面端的 `validate_audio_packet` / 解码分支里有对应处理，其它（包括 32-bit 整数 PCM）不暴露
- FEC 字段（`fecBuffer`、`fecSequenceNumber`、`fecPacketLengths`）在 PCM 分支全省略，桌面端在 lengths 空的时候也接受

采集来源（`audio.SourceType`，持久化用与之原值一致的 `SOURCE_*` 常量，见 `net/Wire.ets`）：

| 常量 | 原值 | 起用 API | 备注 |
|---|---|---|---|
| `SOURCE_MIC` | 0 | 8 | 默认；标准录音通道 |
| `SOURCE_VOICE_RECOGNITION` | 1 | 9 | 语音识别通道 |
| `SOURCE_VOICE_COMMUNICATION` | 7 | 8 | 通话上行；SDK 文档明确写：只有同时播放 `STREAM_USAGE_VOICE_COMMUNICATION` / `_VIDEO_COMMUNICATION` 渲染器时 3A 才生效，纯采集不保证 AEC |
| `SOURCE_CAMCORDER` | 13 | 13 | 摄像机通道 |
| `SOURCE_UNPROCESSED` | 14 | 14 | 原始 ADC 通道 |
| `SOURCE_LIVE` | 17 | 20 | 直播通道 |

`CapturePump.start` 在 `createAudioCapturer` 抛错时（不支持的组合、采集焦点冲突等），会先释放半建的 capturer，然后用 `SOURCE_MIC` + `AUDIO_FORMAT_16BIT` 重试；返回给 controller 的 `CaptureApplied` 记录实际生效的配置，`onPcm` 就用它编头，所以线上头部和字节流一致。

## 设置项

主页面右上齿轮进设置页（`SettingsView`，作为 `NavDestination`，路由名 `settings`）。所有条目落 `@ohos.data.preferences`，实例名 `micyou_prefs`，进程内单例 `ConnectionStore.shared`。

- 外观：主题（跟随系统 / 浅色 / 深色，走 `context.setColorMode`，API 18+，低于则回落系统主题）；语言（跟随系统 / English / 简体中文 / 繁體中文，走 `i18n.System.setAppPreferredLanguage`，需冷重启才生效，UI 上有对应提示）
- 音频：来源 / 采样率（16k / 44.1k / 48k / 96k）/ 声道（单声道 / 立体声）/ 位深（16-bit / 24-bit / 32-bit float）/ 编码（PCM 可用，Opus 禁用占位）；来源列表按 `deviceInfo.sdkApiVersion` 过滤，成员 `@since` 高于设备版本的选项不显示
- 连接记录：自动连接开关（默认关）、上次连接设备、历史列表（按 `host:port` 去重、`connectedAt` 倒序、上限 10、`connectCount` 计数）、单条删除、清空全部
- 关于：应用名与功能描述

## 已验证

- `hvigorw assembleHap` 干净构建并出签名 HAP
- proto3 编解码在 protobufjs 独立解析器上往返过（本仓库外的一次性检查，protobufjs 不是项目依赖）：字段号、wire type 与生成的字节序列完全对齐 protobufjs 自己的 encoder；`StatsMessage` 的 float32 字段正确解出；`FrameAssembler` 在逐字节与整块两种投递节奏下都能正常组帧
- nova 14 Pro 对桌面 GUI：mDNS 发现 → 连接 → 48 kHz 回调采集 → UDP 约 73 帧/秒 → 桌面解码 0.00% 丢包、0.7–0.9 ms 抖动、8–11 ms 往返

## 已知空白

- 只有 Wi-Fi 模式：没有 USB（`hdc` 端口转发），没有 web 模式
- 只有 PCM：`CODEC_OPUS = 1` 常量存在，Opus 编码路径未接入；没有 on-device FEC 冗余包，也没有带宽下降，桌面端把丢包还原成爆音
- `mute` 只被推给桌面端；入站 `MuteMessage` 会解码但不响应；桌面端的 `PluginMessage` 完全忽略
- `audioRecording` 长任务在灭屏情况下没有实测
- 自动连接失败只试一次，不做退避重连；`SOURCE_TYPE_VOICE_COMMUNICATION` 被真实来电抢占的采集焦点冲突路径没有实测
- 桌面端要识别 `"harmonyos"` 需要上游 `transport/tcp.rs` 里的 `ClientPlatform::HarmonyOs` 分支，2.1.0 正式版没有这个补丁，此时桌面端把设备显示成 "MicYou Mobile"，只是显示差异，会话功能不受影响
- `StatsMessage` 只在桌面端 2.1.1+ 发送；老服务器上不刷新 RTT/抖动/丢包/延迟；鸿蒙主页面本来就不渲染这些链路统计（与安卓对齐），但 `EngineSnapshot` 依然携带它们的字段，桌面端才有可视性

## 如何参与

环境准备、构建与签名、代码风格、提交规范见 [`CONTRIBUTING.md`](CONTRIBUTING.md)；装机调试与真机验证的具体命令见 [`AGENTS.md`](AGENTS.md) 的 "Debug loop"。项目没有自动化测试，验收标准是一次干净构建加一轮真机对测。

问题反馈用仓库的 issue 模板（`.github/ISSUE_TEMPLATE/`）：bug 模板会要求填手机型号、应用版本、桌面端版本、采集设置和 `MicYouEngine` / `MicYouControl` / `MicYouCapture` 三个 tag 的日志片段；涉及线协议字段的请求请在 issue 里先说明，因为这类改动要桌面端和安卓端一起跟。

## 许可

GPL-3.0-or-later，详见 `LICENSE`。贡献即视为以同一许可授权。
