# 自动化测试

这个目录是 Opus 推流链路的回归测试。分两层：

- `cases/auto/` 不需要人看着。脚本自己点手机、自己扮桌面端、自己校验抓到的包，跑完直接给出 PASS/FAIL。
- `cases/human/` 需要人观察。脚本照样把手机操作做完，然后在观察点停下来，打印该看什么，等你输入 pass/fail/skip。

你忙的时候跑 auto 层，有空的时候跑 human 层。

## 运行前提

```bash
git submodule update --init           # lib/opus，a01 编译需要
export DEVECO_SDK_HOME=/opt/devecostudio/sdk
```

手机用数据线连到本机、和桌面端在同一个 Wi-Fi、屏幕解锁。`hdc` 在 SDK 里，路径已经写死在 `lib/env.sh`，也可以用环境变量覆盖。

human 层里 h01/h02 需要你自己把桌面端 GUI 起起来（默认 8554），auto 层不需要——它用 `lib/receiver.py` 自己收流，端口默认 8555/8556，不会和 GUI 抢。

## 命令

```bash
test/run.sh --list                    # 列出用例，不碰手机
test/run.sh --auto                    # 无人值守整层
test/run.sh --auto --only a03         # 只跑某一条（按名字前缀匹配）
test/run.sh --auto --install          # 先编译打包（a01），再跑其它
test/run.sh --human                   # 需要人观察的一层，必须有终端交互
test/run.sh --auto --allow-disruptive # 允许跑会 force-stop 应用、息屏的两条用例
```

环境变量：`SESSION_SECONDS`（默认 30，每条推流用例的时长）、`HUMAN_SESSION_SECONDS`、`LOSS_PROBABILITY`（h02 丢包率，默认 0.05）、`TEST_TCP_PORT`、`DESKTOP_IP`、`CASE_TIMEOUT_SECONDS`（auto 层单条超时，默认 600）、`SKIP_INSTALL=1`（复用已安装的 HAP，省时间）。

产物都在 `test/results/<时间戳>/` 下，按用例分子目录：`capture.jsonl` 是抓到的每一个包，`app.log` 是手机端 hilog，`receiver.log` 是假桌面端的统计，`layout-N.json` 是界面 dump，human 层的结论追加在 `human.log`。

## 用例清单

auto 层：

| 用例 | 证明什么 |
|---|---|
| a01_build_hap | 原生模块还能编出来、还能进包；`.so` 体积没有意外膨胀 |
| a02_opus_gating_ui | 选 Opus 后不支持的采样率/位深在控件树上就是灰的（opacity 0.5），并当场迁移到 48 kHz/16-bit |
| a03_opus_48k_mono | 48 kHz 单声道 Opus：50 pkt/s、每 12 个数据包一个校验包、校验体是那 12 个的逐字节 XOR、系统 libopus 能把整条流按序解码 |
| a04_opus_16k_mono | 16 kHz 非 48k 采样率同样成立 |
| a05_opus_48k_stereo | 立体声下帧长变成 3840 B，FEC 分组仍然闭合 |
| a06_pcm_48k_mono | PCM 回归：Opus 改动没有碰原来的发送路径 |
| a07_pcm_44100_float32 | Opus 编不了的比例/格式仍然走 PCM，且 1320 B 载荷不变 |
| a08_migration_over_wire | 存了不兼容的设置再切 Opus，线上包头确实是 48 kHz/16-bit，不是界面上的旧值 |
| a09_mute_across_fec_group | 会话中途静音打断了 FEC 分组，之后序号与校验算术仍然连续 |
| a10_heartbeat_stale | 桌面端不再 ping，看门狗判死，teardown 里 native encoder 被 destroy |
| a11_autoconnect_relaunch | 进程被杀后 auto-connect 自己重建 Opus 会话，包头和存的一致（disruptive） |
| a12_screen_off | 息屏 60 秒后 `audioRecording` 长任务还在推流（disruptive） |

human 层：

| 用例 | 需要你看什么 |
|---|---|
| h01_desktop_gui_opus | 真实桌面端能不能解出这条 Opus 流、听起来对不对、DTX 静音时虚拟麦克风是否安静下来、日志里有没有 `invalid audio packet` |
| h02_desktop_fec_recovery | 用 iptables 注入 5% 丢包后，桌面端 FEC 能不能把丢掉的包补回来（听不出断续） |
| h03_ui_look | 灰掉的 chip 在视觉上是否像"不可选"、Opus 那行提示文案是否解释了行为 |

## auto 层证明不了什么

这条要写清楚，免得把 auto 层全绿当成整件事全绿：

- 它校验的是包的合法性与编码算术。真实桌面端的抖动缓冲、FEC 重建、重采样、DSP 链、虚拟麦克风都不在这条路上，那部分只有 h01/h02 能证明。
- 它听不见声音。音质、机器音、断续、噪声门行为都靠人耳。
- 它注入不了真丢包。校验包的 XOR 是自己重算的，不是从网络丢失里恢复出来的。
- 界面只读控件树（文本、bounds、opacity、backgroundColor），布局是否好看、文案是否顺眼判断不了。

## 加一条用例

```bash
$EDITOR test/cases/auto/aNN_something.sh
```

模板：

```bash
#!/usr/bin/env bash
# aNN: 一句话说明这条证明什么。
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready                                  # 连手机、装包、起应用、把目标指向假桌面端
apply_profile opus "48 kHz" mono "16-bit"  # 设置页里把 codec/采样率/声道/位深点好
run_session "$CASE_DIR" "$SESSION_SECONDS"
$PY "$TEST_LIB_DIR/analyze.py" --in "$CASE_DIR/capture.jsonl" --profile opus-48k-mono
```

点手机一律通过控件树查坐标，不要写死坐标：`d_tap_text`、`d_tap_label`（多语言标签用这个）、`d_tap_fab`、`d_tap_mute`、`d_open_settings`、`d_set_input`。需要在界面上断言状态时用 `d_chip_attr`（读 opacity 之类）和 `d_assert_selected`（同一组 chip 里背景色独特的那个就是选中项）。

假桌面端的收流选项在 `rx_start`/`run_session` 后面追加即可，比如 `--stop-ping-after 10`。校验规则改 `lib/wire.py` 时要对着桌面端 `tauri-app/crates/micyou-core/src/transport/session.rs` 改，那边是权威。

要标记成会打扰手机使用的用例，在文件头注释里写 `disruptive`，`run.sh` 就会默认跳过它。

## 框架自检

`test/selfcheck.sh` 不需要手机、不需要桌面端，跑的是测试框架自己：

```bash
test/selfcheck.sh
```

它做两件事。一是对着一份人造控件树跑 `lib/` 里的 shell 库（chip 灰度读取、选中项判定、按钮几何定位、文本框重写），确认点手机的那套代码解析得出正确结果；二是用 `lib/fakephone.py` 发一条刻意完全正确的流给 `lib/receiver.py`，再逐条注入缺陷（XOR 错、parity 序号错、lengths 错、分组起始错、包头采样率错、PCM 载荷长度错），要求每条缺陷只打中属于它的那个门限，空流也必须判红。这样门限本身不可能变成恒真。

历史上这一步抓到过两个真实缺陷：`fec-seq-reuse` 曾经在 parity 之前的记录里搜索后继数据包（永远搜不到，因此永远通过），以及 `opus_decoder_destroy` 没设 `argtypes` 导致 64 位句柄被截成 32 位而段错误。改过 `lib/` 任何文件之后先跑它，再去跑手机。

